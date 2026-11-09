extends Node
## game_bridge.gd — autoload "Game"
## RPC boundary between the presentation shell (main thread) and game logic
## (one dedicated worker thread).
##
## Why a thread: dummyscheme and llama_context are not thread-safe, so the VM
## must be owned by exactly one thread. The worker creates, uses and destroys
## the ScmLlama instance; the main thread only renders and reads a cached
## snapshot. Requests travel as plain data {fn, args, ticket} — that shape
## survives a later move to a server: swap the queue for a socket, game code
## unchanged.
##
## Model discovery order:
##   1. $THEFORD_MODEL
##   2. <project>/models/Qwen3-0.6B-Q4_K_M.gguf
## If neither exists the game still runs: NPCs fall back to canned lines.

signal bridge_ready(llm_available: bool)
signal rpc_replied(ticket: int, result: Variant)
signal snapshot_changed
## Token pieces streamed out of an in-flight llm-generate (live dialog).
signal stream_pieces(pieces: PackedStringArray)

const DEFAULT_GGUF := "models/Qwen3-0.6B-Q4_K_M.gguf"

var use_llm := false
var vm_error := ""
var booted := false
## Main-thread view of what the HUD needs; only the bridge writes it.
## last_turn is the mechanism trace of the most recent game:talk:
##   {topic, intent, verdict, reason, source, model, learned, prefill_tps, decode_tps}
var snapshot := {
	"quest_text": "",
	"carried": 0,
	"model": "",
	"llm_version": "",
	"last_turn": {},
}

var _thread: Thread = null
var _mutex := Mutex.new()
var _sem := Semaphore.new()
var _inbound: Array = []    # [{ticket, fn, args}]  main -> worker
var _outbound: Array = []   # [{kind, ...}]         worker -> main
var _replies := {}          # ticket -> result, main thread
var _next_ticket := 0
var _running := false

var _scheme_path := ""
var _main_scm := ""
var _model_path := ""

func _ready() -> void:
	# Resolve paths here: ProjectSettings is a main-thread singleton.
	var scheme_dir: String = ProjectSettings.globalize_path("res://scheme")
	_scheme_path = scheme_dir + "/?.scm;" + scheme_dir + "/?/init.scm"
	_main_scm = ProjectSettings.globalize_path("res://scheme/game/main.scm")
	_model_path = OS.get_environment("THEFORD_MODEL")
	if _model_path == "":
		var guess: String = ProjectSettings.globalize_path("res://").path_join(DEFAULT_GGUF)
		if FileAccess.file_exists(guess):
			_model_path = guess
	_running = true
	_thread = Thread.new()
	var err: int = _thread.start(_worker_main)
	if err != OK:
		_running = false
		booted = true
		vm_error = "无法启动逻辑线程（错误码 %d）" % err
		push_error("[scmllama] " + vm_error)
		emit_signal("bridge_ready", false)

## ---- worker thread: owns the VM end to end --------------------------------

func _worker_main() -> void:
	var msg := {
		"kind": "ready",
		"llm": false,
		"error": "",
		"status": [],
	}
	var vm: ScmLlama = ScmLlama.new()
	var err: String = vm.add_scheme_path(_scheme_path)
	if err == "":
		err = vm.load_file(_main_scm)

	if err == "":
		if _model_path != "":
			vm.call_fn("game:set-model-path", [_model_path])
			# Blocking load (~1s for 0.6B Q4) happens on this thread, so the
			# window stays responsive while it runs.
			var ok: Variant = vm.call_fn("game:boot", [])
			msg["llm"] = (ok is bool and ok)
		var st: Variant = vm.call_fn("game:status", [])
		if st is Array and st.size() == 2:
			msg["status"] = st
		var eng: Variant = vm.call_fn("game:engine-info", [])
		if eng is Array:
			msg["engine"] = eng
	else:
		msg["error"] = err
	_push(msg)

	while _running:
		_sem.wait()
		if not _running:
			break
		var batch: Array = []
		_mutex.lock()
		batch = _inbound
		_inbound = []
		_mutex.unlock()
		for req in batch:
			var result: Variant = null
			if err == "":
				result = vm.call_fn(req["fn"], req["args"])
			_mutex.lock()
			_outbound.append({
				"kind": "reply",
				"ticket": req["ticket"],
				"fn": req["fn"],
				"result": result,
			})
			_mutex.unlock()
	# Dropping the last reference here frees the VM on this thread.
	vm = null

## ---- main thread: drain results, absorb state -----------------------------

func _process(_delta: float) -> void:
	# Token stream from the worker (llm-generate callbacks land in the
	# extension's queue; owner-free, fine even while the worker is busy).
	var pieces: PackedStringArray = ScmLlama.stream_poll()
	if not pieces.is_empty():
		if OS.get_environment("THEFORD_DEBUG_STREAM") == "1":
			print("[stream] +%d pieces" % pieces.size())
		stream_pieces.emit(pieces)
	_mutex.lock()
	var msgs: Array = _outbound
	_outbound = []
	_mutex.unlock()
	if msgs.is_empty():
		return
	for m in msgs:
		if str(m.get("kind", "")) == "ready":
			_on_ready(m)
		else:
			var fn := str(m.get("fn", ""))
			var result: Variant = m.get("result")
			_absorb(fn, result)
			var ticket := int(m["ticket"])
			_replies[ticket] = result
			rpc_replied.emit(ticket, result)

func _on_ready(m: Dictionary) -> void:
	vm_error = str(m.get("error", ""))
	use_llm = bool(m.get("llm", false))
	var st: Variant = m.get("status")
	if st is Array and st.size() == 2:
		_write_snapshot(st[0], st[1])
	var eng: Variant = m.get("engine")
	if eng is Array and eng.size() >= 3:
		snapshot["model"] = str(eng[0])
		snapshot["llm_version"] = str(eng[2])
	booted = true
	if vm_error != "":
		push_error("[scmllama] Scheme bootstrap failed: " + vm_error)
	elif not use_llm:
		print("[TheFord] 未找到模型，NPC 将使用预置台词（THEFORD_MODEL 可指定 GGUF 路径）")
	emit_signal("bridge_ready", use_llm)

## Cache the state-bearing parts of replies so the HUD never calls the VM.
func _absorb(fn: String, result: Variant) -> void:
	match fn:
		"game:status":
			if result is Array and result.size() == 2:
				_write_snapshot(result[0], result[1])
		"game:greet":
			if result is Array and result.size() >= 3:
				_write_snapshot(result[1], result[2])
		"game:talk":
			if result is Array and result.size() >= 3:
				_write_snapshot(result[1], result[2])
			if result is Array and result.size() >= 5 and result[4] is Array:
				var learned: bool = result.size() >= 4 and bool(result[3])
				_store_turn(result[4], learned)
		"game:take-ore":
			if result is int:
				_write_snapshot(snapshot["quest_text"], result)

func _write_snapshot(quest_text: Variant, carried: Variant) -> void:
	var qt := str(quest_text)
	var c := int(carried)
	if str(snapshot["quest_text"]) == qt and int(snapshot["carried"]) == c:
		return
	snapshot["quest_text"] = qt
	snapshot["carried"] = c
	snapshot_changed.emit()

## decision = (topic intent verdict reason source model-desc prefill-tps decode-tps)
## from game:talk. The two t/s values come from the Scheme-side llm-perf table.
func _store_turn(decision: Array, learned: bool) -> void:
	var turn := {
		"topic": str(decision[0]) if decision.size() > 0 else "",
		"intent": str(decision[1]) if decision.size() > 1 else "",
		"verdict": str(decision[2]) if decision.size() > 2 else "",
		"reason": str(decision[3]) if decision.size() > 3 else "",
		"source": str(decision[4]) if decision.size() > 4 else "",
		"model": str(decision[5]) if decision.size() > 5 else "",
		"prefill_tps": float(decision[6]) if decision.size() > 6 else 0.0,
		"decode_tps": float(decision[7]) if decision.size() > 7 else 0.0,
		"learned": learned,
	}
	snapshot["last_turn"] = turn
	if turn["model"] != "":
		snapshot["model"] = turn["model"]
	snapshot_changed.emit()

## ---- RPC surface ----------------------------------------------------------

## Queue a call and return immediately; the result comes back via rpc_replied.
func send(fn: String, args: Array = []) -> int:
	var ticket := _next_ticket
	_next_ticket += 1
	if not _running:
		_replies[ticket] = null
		rpc_replied.emit(ticket, null)
		return ticket
	_mutex.lock()
	_inbound.append({"ticket": ticket, "fn": fn, "args": args})
	_mutex.unlock()
	_sem.post()
	return ticket

## Queue a call and await its result without blocking any thread.
func call_async(fn: String, args: Array = []) -> Variant:
	var ticket := send(fn, args)
	while not _replies.has(ticket):
		await rpc_replied
	var result: Variant = _replies.get(ticket)
	_replies.erase(ticket)
	return result

func _push(msg: Dictionary) -> void:
	_mutex.lock()
	_outbound.append(msg)
	_mutex.unlock()

func _exit_tree() -> void:
	if not _running:
		return
	_running = false
	_sem.post()
	if _thread != null:
		_thread.wait_to_finish()
		_thread = null
