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
## $THEFORD_AI_QUALITY (off|low|medium|high or 0..3) sets how much the model
## does; off never loads it. It is the player's preference, not save state.

signal bridge_ready(llm_available: bool)
signal rpc_replied(ticket: int, result: Variant)
signal snapshot_changed
## Token pieces streamed out of an in-flight llm-generate (live dialog).
signal stream_pieces(pieces: PackedStringArray)

const DEFAULT_GGUF := "models/Qwen3-0.6B-Q4_K_M.gguf"
const DEFAULT_AI_QUALITY := "medium"

var use_llm := false
## Effective AI level: off/low/medium/high (see scheme/game/llm.scm).
var ai_quality := DEFAULT_AI_QUALITY
var vm_error := ""
var booted := false
## Main-thread view of what the HUD needs; only the bridge writes it.
## last_turn is the mechanism trace of the most recent game:talk:
##   {topic, intent, verdict, reason, source, model, learned, prefill_tps, decode_tps}
var snapshot := {
	"quest_text": "",
	"carried": 0,
	"xp": 0,             # shared player experience counter (game:quests)
	"quest_completions": 0,  # increments on a quest completion, drives the jingle
	"quests": [],       # [[id, title, state, text, [[objective, done, need], ...]], ...]
	"day": 1,
	"hour": 8,
	"minute": 0,
	"weather": "sun",
	"people": [],       # [[id, "map:anchor", activity], ...]
	"bag": [],          # [[type, count, display-name, sprite-key, slots], ...]
	"bag_slots": 0,     # slots the carried stacks take
	"bag_capacity": 30, # slots the bag has
	"held": "",         # tool type-string in hand, or ""
	"hp": 10,           # player health (from game:hp)
	"max_hp": 10,
	"game_over": false, # hp reached 0; the shell shows the death screen
	"container": {},    # open container view: {id, name, capacity, slots, rows}
	"model": "",
	"llm_version": "",
	"ai_quality": DEFAULT_AI_QUALITY, # off/low/medium/high (scheme/game/llm.scm)
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
	ai_quality = _read_ai_quality()
	_running = true
	_thread = Thread.new()
	var err: int = _thread.start(_worker_main)
	if err != OK:
		_running = false
		booted = true
		vm_error = "无法启动逻辑线程（错误码 %d）" % err
		push_error("[scmllama] " + vm_error)
		emit_signal("bridge_ready", false)

## $THEFORD_AI_QUALITY accepts a name or 0..3; unknown values keep the default.
func _read_ai_quality() -> String:
	var raw := OS.get_environment("THEFORD_AI_QUALITY").strip_edges().to_lower()
	match raw:
		"", "2", "medium":
			return "medium"
		"0", "off":
			return "off"
		"1", "low":
			return "low"
		"3", "high":
			return "high"
		_:
			push_warning("[TheFord] 未知 THEFORD_AI_QUALITY=%s，按 medium 处理" % raw)
			return "medium"

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
		# The AI level is set before boot so an `off` startup never touches the
		# GGUF (fast boot, no model memory). Switching up later boots on demand.
		vm.call_fn("game:set-ai-quality", [ai_quality])
		if _model_path != "":
			vm.call_fn("game:set-model-path", [_model_path])
			# Blocking load (~1s for 0.6B Q4) happens on this thread, so the
			# window stays responsive while it runs.
			var ok: Variant = vm.call_fn("game:boot", [])
			msg["llm"] = (ok is bool and ok)
		var st: Variant = vm.call_fn("game:status", [])
		if st is Array and st.size() == 6:
			msg["status"] = st
		var eng: Variant = vm.call_fn("game:engine-info", [])
		if eng is Array:
			msg["engine"] = eng
	else:
		msg["error"] = err
	msg["quality"] = ai_quality
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
				if req.has("load_path"):
					result = vm.load_file(str(req["load_path"]))
				else:
					result = vm.call_fn(req["fn"], req["args"])
			_mutex.lock()
			_outbound.append({
				"kind": "reply",
				"ticket": req["ticket"],
				"fn": req["fn"],
				"result": result,
				"keep_reply": req.get("keep_reply", false),
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
			if bool(m.get("keep_reply", false)):
				_replies[ticket] = result
			rpc_replied.emit(ticket, result)

func _on_ready(m: Dictionary) -> void:
	vm_error = str(m.get("error", ""))
	use_llm = bool(m.get("llm", false))
	ai_quality = str(m.get("quality", ai_quality))
	var st: Variant = m.get("status")
	if st is Array and st.size() == 6:
		_write_snapshot(st[0], st[1], st.slice(2))
	_write_engine(m.get("engine"), false)
	snapshot["ai_quality"] = ai_quality
	booted = true
	if vm_error != "":
		push_error("[scmllama] Scheme bootstrap failed: " + vm_error)
	elif ai_quality == "off":
		print("[TheFord] AI 档位 off：不加载模型，NPC 使用预置台词（quality 可随时开启）")
	elif not use_llm:
		print("[TheFord] 未找到模型，NPC 将使用预置台词（THEFORD_MODEL 可指定 GGUF 路径）")
	emit_signal("bridge_ready", use_llm)

## engine-info = (model-desc use-llm? llama.cpp-version ai-quality); the same
## shape comes back from game:set-ai-quality, so a GM switch refreshes the HUD
## and the bridge's use_llm flag without a restart.
func _write_engine(eng: Variant, notify: bool = true) -> void:
	if not (eng is Array and eng.size() >= 3):
		return
	snapshot["model"] = str(eng[0])
	use_llm = bool(eng[1])
	snapshot["llm_version"] = str(eng[2])
	if eng.size() >= 4:
		ai_quality = str(eng[3])
		snapshot["ai_quality"] = ai_quality
	if notify:
		snapshot_changed.emit()

## Cache the state-bearing parts of replies so the HUD never calls the VM.
func _absorb(fn: String, result: Variant) -> void:
	match fn:
		"game:status", "game:tick", "game:debug-set-time", "game:debug-advance", "game:debug-set-weather":
			if result is Array and result.size() == 6:
				_write_snapshot(result[0], result[1], result.slice(2))
		"game:greet":
			if result is Array and result.size() >= 3:
				_write_snapshot(result[1], result[2])
		"game:talk":
			if result is Array and result.size() >= 3:
				_write_snapshot(result[1], result[2])
			if result is Array and result.size() >= 5 and result[4] is Array:
				var learned: bool = result.size() >= 4 and bool(result[3])
				_store_turn(result[4], learned)
		"game:reload":
			snapshot["last_turn"] = {}
			snapshot["container"] = {}
			if result is Array and result.size() == 6:
				_write_snapshot(result[0], result[1], result.slice(2))
			# Even an unchanged status needs a repaint: last_turn was cleared.
			snapshot_changed.emit()
		"game:load":
			# (ok status) — a load replaces every state module, so drop the
			# per-turn trace and any half-open container view with it.
			snapshot["last_turn"] = {}
			snapshot["container"] = {}
			if result is Array and result.size() == 2:
				if result[1] is Array and result[1].size() == 6:
					_write_snapshot(result[1][0], result[1][1], result[1].slice(2))
			snapshot_changed.emit()
		"game:engine-info", "game:set-ai-quality":
			_write_engine(result)
		"game:people":
			if result is Array:
				_write_people(result)
		"game:quests":
			# (xp completions rows) — the quest log reads only this cached view.
			if result is Array and result.size() >= 3:
				snapshot["xp"] = int(result[0])
				snapshot["quest_completions"] = int(result[1])
				snapshot["quests"] = result[2] if result[2] is Array else []
				snapshot_changed.emit()
		"game:bag":
			if result is Array and result.size() >= 1:
				snapshot["bag"] = result[0] if result[0] is Array else []
				snapshot["held"] = str(result[1]) if result.size() >= 2 else ""
				snapshot["bag_slots"] = int(result[3]) if result.size() >= 4 else 0
				snapshot["bag_capacity"] = int(result[4]) if result.size() >= 5 else 30
				snapshot_changed.emit()
		"game:container", "game:transfer":
			_write_container(result)
		"game:close-container":
			snapshot["container"] = {}
			snapshot_changed.emit()
		"game:hp":
			# (hp max-hp down?) — lives in Scheme's entity registry, mirrored
			# here so the HUD hearts and the death check need no VM call.
			if result is Array and result.size() >= 2:
				snapshot["hp"] = int(result[0])
				snapshot["max_hp"] = int(result[1])
				snapshot["game_over"] = bool(result[2]) if result.size() >= 3 else false
				snapshot_changed.emit()
	# Anything that can move an objective refreshes the log on the next batch,
	# even with the clock paused (GM `speed 0` in acceptance scripts).
	if fn in ["game:take", "game:talk", "game:greet", "game:quest-target",
			"game:debug-give"]:
		send("game:quests")

## An open container view is (id name capacity slots-used rows); #f closes it.
func _write_container(result: Variant) -> void:
	if result is Array and result.size() >= 5:
		snapshot["container"] = {
			"id": str(result[0]),
			"name": str(result[1]),
			"capacity": int(result[2]),
			"slots": int(result[3]),
			"rows": result[4] if result[4] is Array else [],
		}
	else:
		snapshot["container"] = {}
	snapshot_changed.emit()

## NPC schedule rows: [id, anchor, activity]. Repaint only on a real change so
## the per-second refresh does not spam the HUD.
func _write_people(rows: Array) -> void:
	if snapshot["people"] == rows:
		return
	snapshot["people"] = rows.duplicate(true)
	snapshot_changed.emit()

func _write_snapshot(quest_text: Variant, carried: Variant, clock: Array = []) -> void:
	var qt := str(quest_text)
	var c := int(carried)
	var d := int(clock[0]) if clock.size() == 4 else int(snapshot["day"])
	var h := int(clock[1]) if clock.size() == 4 else int(snapshot["hour"])
	var m := int(clock[2]) if clock.size() == 4 else int(snapshot["minute"])
	var w := str(clock[3]) if clock.size() == 4 else str(snapshot["weather"])
	if str(snapshot["quest_text"]) == qt and int(snapshot["carried"]) == c \
			and int(snapshot["day"]) == d and int(snapshot["hour"]) == h \
			and int(snapshot["minute"]) == m and str(snapshot["weather"]) == w:
		return
	snapshot["quest_text"] = qt
	snapshot["carried"] = c
	snapshot["day"] = d
	snapshot["hour"] = h
	snapshot["minute"] = m
	snapshot["weather"] = w
	snapshot_changed.emit()

## decision = (topic intent verdict reason source model-desc prefill-tps decode-tps quality)
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
		"quality": str(decision[8]) if decision.size() > 8 else ai_quality,
		"learned": learned,
	}
	snapshot["last_turn"] = turn
	if turn["model"] != "":
		snapshot["model"] = turn["model"]
	snapshot_changed.emit()

## ---- RPC surface ----------------------------------------------------------

## Queue a call and return immediately; the result comes back via rpc_replied.
## Only awaited calls retain their reply in _replies; fire-and-forget ticks do
## not grow that dictionary for the lifetime of the game.
func send(fn: String, args: Array = [], keep_reply: bool = false) -> int:
	var ticket := _next_ticket
	_next_ticket += 1
	if not _running:
		if keep_reply:
			_replies[ticket] = null
		rpc_replied.emit(ticket, null)
		return ticket
	_mutex.lock()
	_inbound.append({"ticket": ticket, "fn": fn, "args": args, "keep_reply": keep_reply})
	_mutex.unlock()
	_sem.post()
	return ticket

## Queue a call and await its result without blocking any thread.
func call_async(fn: String, args: Array = []) -> Variant:
	var ticket := send(fn, args, true)
	while not _replies.has(ticket):
		await rpc_replied
	var result: Variant = _replies.get(ticket)
	_replies.erase(ticket)
	return result

## Load an acceptance script on the VM's worker thread. The caller resolves the
## restricted res:// path here on the main thread; the VM only sees a filename.
func load_async(path: String) -> Variant:
	var ticket := _next_ticket
	_next_ticket += 1
	if not _running:
		return "逻辑线程未运行"
	_mutex.lock()
	_inbound.append({"ticket": ticket, "fn": "acceptance:load", "args": [],
			"load_path": path, "keep_reply": true})
	_mutex.unlock()
	_sem.post()
	while not _replies.has(ticket):
		await rpc_replied
	var result: Variant = _replies.get(ticket)
	_replies.erase(ticket)
	return result

## Dev hot reload: re-read scheme/game/data/*.scm on the worker and reset the
## quest, talk caches and clock. Content edits take effect without restarting Godot.
func reload_data() -> Variant:
	var result: Variant = await call_async("game:reload", [])
	# The reload empties the bag and resets health; neither is in the status
	# reply, so ask for both before the shell repaints.
	send("game:bag")
	send("game:hp")
	return result

## Write a `table`-DSL Scheme source save. `host` is the host-owned map and body
## positions; Scheme writes it into the same file as a quoted literal. A failed
## call returns null (the worker boundary reports the Scheme error).
func save_state(path: String, host: Variant) -> Variant:
	return await call_async("game:save", [path, host])

## Read the host slot only, without touching game state. Used before rebuilding
## the map, since the saved entity state must land after that rebuild.
func peek_save(path: String) -> Variant:
	return await call_async("game:peek-save", [path])

## Apply the save. Worker calls are FIFO, so the view refreshes queued after the
## await are guaranteed to see restored state.
func load_state(path: String) -> Variant:
	var result: Variant = await call_async("game:load", [path])
	send("game:bag")
	send("game:hp")
	send("game:people")
	send("game:quests")
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
