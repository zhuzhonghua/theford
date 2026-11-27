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
##   2. <project>/models/Qwen3-0.6B-Q4_K_M.gguf (editor) or beside the binary
## If neither exists the game still runs: NPCs fall back to canned lines.
## $THEFORD_AI_QUALITY (off|low|medium|high or 0..3) sets how much the model
## does; off never loads it. It is the player's preference, not save state.
##
## File paths: the native VM opens .scm files with fopen(), which cannot see
## inside a PCK. In the editor res:// is a real directory; in an export the
## whole scheme tree is unpacked once into user:// and the VM is pointed there.
## scheme_path() is the single resolver shared with the acceptance runner.

signal bridge_ready(llm_available: bool)
signal rpc_replied(ticket: int, result: Variant)
signal snapshot_changed
## Token pieces streamed out of an in-flight llm-generate (live dialog).
signal stream_pieces(pieces: PackedStringArray)

const DEFAULT_GGUF := "models/Qwen3-0.6B-Q4_K_M.gguf"
const DEFAULT_AI_QUALITY := "medium"
const SCHEME_ROOT := "res://scheme"
const PCK_SCHEME_DIR := "user://scheme_pck"

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
	"story_facts": [],  # [[fact-id, value], ...] from game:story-status
	"story_place": "",  # nearest named anchor the player is at
	"story_beat": "",   # last beat that played
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
var _scheme_dir := ""   # real OS path to the scheme tree (project or unpacked PCK)

func _ready() -> void:
	# Resolve paths here: ProjectSettings is a main-thread singleton.
	_scheme_dir = _prepare_scheme_dir()
	_scheme_path = _scheme_dir + "/?.scm;" + _scheme_dir + "/?/init.scm"
	_main_scm = _scheme_dir + "/game/main.scm"
	_model_path = _find_model_path()
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

## ---- resource path resolution ------------------------------------------------

## The VM calls fopen() directly, so it needs real directories. Editor builds
## use the project tree (hot reload must see live edits); exports unpack the
## .scm files from the PCK once into user:// at startup.
func _prepare_scheme_dir() -> String:
	var project_path: String = ProjectSettings.globalize_path(SCHEME_ROOT)
	# The env override exercises the exported-build path from the editor, for
	# testing the PCK unpack without producing a build.
	var force_pck := OS.get_environment("THEFORD_FORCE_PCK_SCHEME") == "1"
	if OS.has_feature("editor") and not force_pck and DirAccess.dir_exists_absolute(project_path):
		return project_path
	var dest: String = ProjectSettings.globalize_path(PCK_SCHEME_DIR)
	_unpack_scheme_dir(SCHEME_ROOT, dest)
	return dest

func _unpack_scheme_dir(from: String, to: String) -> void:
	var dir := DirAccess.open(from)
	if dir == null:
		push_error("[TheFord] 无法读取 scheme 目录：%s" % from)
		return
	DirAccess.make_dir_recursive_absolute(to)
	dir.list_dir_begin()
	var entry := dir.get_next()
	while entry != "":
		if not entry.begins_with("."):
			var child_from := from.path_join(entry)
			var child_to := to.path_join(entry)
			if dir.current_is_dir():
				_unpack_scheme_dir(child_from, child_to)
			elif entry.ends_with(".scm"):
				var body := FileAccess.get_file_as_bytes(child_from)
				if not body.is_empty():
					var out := FileAccess.open(child_to, FileAccess.WRITE)
					if out == null:
						push_error("[TheFord] 无法写出 scheme 文件：%s" % child_to)
					else:
						out.store_buffer(body)
						out.close()
		entry = dir.get_next()
	dir.list_dir_end()

## Resolve a res:// scheme resource to a real path the VM can open. Shared with
## the acceptance runner so both boot and script loading follow one policy.
func scheme_path(res_path: String) -> String:
	if res_path.begins_with(SCHEME_ROOT + "/"):
		return _scheme_dir + res_path.substr(SCHEME_ROOT.length())
	return ProjectSettings.globalize_path(res_path)

## The GGUF is intentionally not packed into the PCK (378 MB); an exported build
## looks beside the binary / in its Resources folder, or under user://, or uses
## $THEFORD_MODEL. Without it the game is still playable on canned lines.
func _find_model_path() -> String:
	var explicit: String = OS.get_environment("THEFORD_MODEL").strip_edges()
	if explicit != "":
		return explicit
	var exe_dir: String = OS.get_executable_path().get_base_dir()
	var candidates := [
		ProjectSettings.globalize_path("res://").path_join(DEFAULT_GGUF),
		exe_dir.path_join(DEFAULT_GGUF),
		exe_dir.path_join("../Resources").path_join(DEFAULT_GGUF),
		ProjectSettings.globalize_path("user://").path_join(DEFAULT_GGUF),
	]
	for candidate in candidates:
		if FileAccess.file_exists(candidate):
			return candidate
	return ""

## $THEFORD_AI_QUALITY accepts low/medium/high or 1..3. off/0 are rejected to
## low: the product always boots the GGUF and blocks entry if it fails.
func _read_ai_quality() -> String:
	var raw := OS.get_environment("THEFORD_AI_QUALITY").strip_edges().to_lower()
	match raw:
		"", "2", "medium":
			return "medium"
		"0", "off", "1", "low":
			return "low"
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
		# Quality only changes token budget/tier replay; the GGUF always loads.
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
	elif not use_llm:
		push_error("[TheFord] 模型加载失败：无法进入游戏（检查 models/ 或 THEFORD_MODEL）")
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
## Table-driven: adding a state-bearing RPC needs one row + one small method,
## not another branch in a 75-line match.
const ABSORBERS := {
	"game:status": "_absorb_status", "game:tick": "_absorb_status",
	"game:debug-set-time": "_absorb_status", "game:debug-advance": "_absorb_status",
	"game:debug-set-weather": "_absorb_status",
	"game:greet": "_absorb_greet", "game:talk": "_absorb_talk",
	"game:reload": "_absorb_reload", "game:load": "_absorb_load",
	"game:engine-info": "_absorb_engine", "game:set-ai-quality": "_absorb_engine",
	"game:people": "_absorb_people", "game:quests": "_absorb_quests",
	"game:bag": "_absorb_bag", "game:container": "_absorb_container",
	"game:transfer": "_absorb_container",
	"game:close-container": "_absorb_close_container",
	"game:hp": "_absorb_hp", "game:story-status": "_absorb_story",
}
## Anything that can move an objective refreshes the log on the next batch,
## even with the clock paused (GM `speed 0` in acceptance scripts).
const REFRESH_TRIGGERS := {
	"game:take": true, "game:talk": true, "game:greet": true,
	"game:quest-target": true, "game:debug-give": true,
}

func _absorb(fn: String, result: Variant) -> void:
	var method: String = ABSORBERS.get(fn, "")
	if method != "":
		call(method, result)
	if REFRESH_TRIGGERS.has(fn):
		send("game:quests")

func _absorb_status(result: Variant) -> void:
	if result is Array and result.size() == 6:
		_write_snapshot(result[0], result[1], result.slice(2))

func _absorb_greet(result: Variant) -> void:
	if result is Array and result.size() >= 3:
		_write_snapshot(result[1], result[2])

func _absorb_talk(result: Variant) -> void:
	_absorb_greet(result)
	if result is Array and result.size() >= 5 and result[4] is Array:
		var learned: bool = result.size() >= 4 and bool(result[3])
		_store_turn(result[4], learned)

func _clear_turn() -> void:
	snapshot["last_turn"] = {}
	snapshot["container"] = {}

func _absorb_reload(result: Variant) -> void:
	_clear_turn()
	_absorb_status(result)
	# Even an unchanged status needs a repaint: last_turn was cleared.
	snapshot_changed.emit()

func _absorb_load(result: Variant) -> void:
	# (ok status) — a load replaces every state module, so drop the per-turn
	# trace and any half-open container view with it.
	_clear_turn()
	if result is Array and result.size() == 2:
		_absorb_status(result[1])
	snapshot_changed.emit()

func _absorb_engine(result: Variant) -> void:
	_write_engine(result)

func _absorb_people(result: Variant) -> void:
	if result is Array:
		_write_people(result)

func _absorb_quests(result: Variant) -> void:
	# (xp completions rows) — the quest log reads only this cached view.
	if result is Array and result.size() >= 3:
		snapshot["xp"] = int(result[0])
		snapshot["quest_completions"] = int(result[1])
		snapshot["quests"] = result[2] if result[2] is Array else []
		snapshot_changed.emit()

func _absorb_bag(result: Variant) -> void:
	if result is Array and result.size() >= 1:
		snapshot["bag"] = result[0] if result[0] is Array else []
		snapshot["held"] = str(result[1]) if result.size() >= 2 else ""
		snapshot["bag_slots"] = int(result[3]) if result.size() >= 4 else 0
		snapshot["bag_capacity"] = int(result[4]) if result.size() >= 5 else 30
		snapshot_changed.emit()

func _absorb_container(result: Variant) -> void:
	_write_container(result)

func _absorb_close_container(_result: Variant) -> void:
	snapshot["container"] = {}
	snapshot_changed.emit()

func _absorb_hp(result: Variant) -> void:
	# (hp max-hp down?) — mirrored here so HUD hearts / death check need no VM.
	if result is Array and result.size() >= 2:
		snapshot["hp"] = int(result[0])
		snapshot["max_hp"] = int(result[1])
		snapshot["game_over"] = bool(result[2]) if result.size() >= 3 else false
		snapshot_changed.emit()

func _absorb_story(result: Variant) -> void:
	# (facts place last) — read-only mirror of Scheme's story state.
	if result is Array and result.size() >= 3:
		snapshot["story_facts"] = result[0] if result[0] is Array else []
		snapshot["story_place"] = str(result[1])
		snapshot["story_beat"] = str(result[2])
		snapshot_changed.emit()

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
## One ticket/queue implementation for all three public entry points.
func _enqueue(fn: String, args: Array, keep_reply: bool, load_path := "") -> int:
	var ticket := _next_ticket
	_next_ticket += 1
	if not _running:
		if keep_reply:
			_replies[ticket] = null
		rpc_replied.emit(ticket, null)
		return ticket
	var req := {"ticket": ticket, "fn": fn, "args": args, "keep_reply": keep_reply}
	if load_path != "":
		req["load_path"] = load_path
	_mutex.lock()
	_inbound.append(req)
	_mutex.unlock()
	_sem.post()
	return ticket

func _await_ticket(ticket: int) -> Variant:
	while not _replies.has(ticket):
		await rpc_replied
	var result: Variant = _replies.get(ticket)
	_replies.erase(ticket)
	return result

## Fire-and-forget call; the snapshot absorbs its state reply.
func send(fn: String, args: Array = [], keep_reply: bool = false) -> int:
	return _enqueue(fn, args, keep_reply)

## Queue a call and await its result without blocking any thread.
func call_async(fn: String, args: Array = []) -> Variant:
	return await _await_ticket(_enqueue(fn, args, true))

## Load an acceptance script on the VM's worker thread. The caller resolves the
## restricted res:// path here on the main thread; the VM only sees a filename.
func load_async(path: String) -> Variant:
	if not _running:
		return "逻辑线程未运行"
	return await _await_ticket(_enqueue("acceptance:load", [], true, path))


## Dev hot reload: re-read scheme/game/data/*.scm on the worker and reset the
## quest, talk caches and clock. Content edits take effect without restarting Godot.
func reload_data() -> Variant:
	var result: Variant = await call_async("game:reload", [])
	# The reload empties the bag and resets health; neither is in the status
	# reply, so ask for both before the shell repaints.
	send("game:bag")
	send("game:hp")
	send("game:story-status")
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
	send("game:story-status")
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
