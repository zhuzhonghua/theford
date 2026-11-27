extends CanvasLayer
## acceptance_runner.gd — plays Scheme-provided acceptance steps in the live game.
## The Scheme file only returns data; this node owns input, timing, assertions
## and the on-screen trace. It never restores the scene: the player can continue
## from the final state after the run.

signal finished(ok: bool, summary: String)

const OpsAssert := preload("res://scripts/gm/ops/acceptance_ops_assert.gd")
const OpsInteract := preload("res://scripts/gm/ops/acceptance_ops_interact.gd")
const OpsAction := preload("res://scripts/gm/ops/acceptance_ops_action.gd")

const MOVE_ACTIONS := ["move_up", "move_down", "move_left", "move_right"]
const MAX_LOG_LINES := 7
## Playback pacing: a replay should read like a person playing. Every step keeps
## a short beat after it, and `note` holds long enough to read the Chinese text.
const STEP_PAUSE := 0.45
const ACTION_PAUSE := 0.9
const GM_PAUSE := 0.8
const WALK_PAUSE := 0.4

var main: Node
var gm: CanvasLayer
var _script_name := ""
var _steps: Array = []
var _active := false
var _run_id := 0
var _pace := 1.0
## Headless runs are for CI/terminal verification: skip all presentation tempo
## (note holds, per-step pauses, typewriters). A GM `load <name>` in a windowed
## editor keeps the human-paced playback so it stays readable.
var fast_headless := false
var hide_panel := false  # video capture: keep the replay HUD out of the frame
var _lines: Array[String] = []
var _op_handlers: Array = []
var _audio_backup := {}   # so a volume replay leaves the player's mix alone
var _last_prompt := ""    # last prompt fetched by an assert-prompt-* step

var _panel: ColorRect
var _title: Label
var _current: Label
var _log: RichTextLabel
var _hint: Label

func setup(main_node: Node, gm_node: CanvasLayer, font: Font) -> void:
	main = main_node
	gm = gm_node
	fast_headless = DisplayServer.get_name() == "headless" \
			and OS.get_environment("THEFORD_ACCEPTANCE_VIDEO") != "1"
	hide_panel = OS.get_environment("THEFORD_RECORD_DIR") != ""
	_op_handlers = [OpsAssert.new(), OpsInteract.new(), OpsAction.new()]
	layer = 35
	_build(font)
	if hide_panel:
		_panel.visible = false

func is_running() -> bool:
	return _active

## Load only a named file under scheme/acceptance. The VM remains owned by its
## worker thread; no Scheme parser or VM call happens on the main thread.
func load_script(script_name: String) -> String:
	if _active:
		return "已有验收脚本正在运行"
	var re := RegEx.new()
	re.compile("^[a-z0-9_-]+$")
	if re.search(script_name) == null:
		return "用法：load <脚本名>（仅限字母、数字、下划线、连字符）"
	var path := "res://scheme/acceptance/%s.scm" % script_name
	if not FileAccess.file_exists(path):
		return "找不到验收脚本：%s" % path
	var err: Variant = await Game.load_async(Game.scheme_path(path))
	if not (err is String) or not err.is_empty():
		return "脚本加载失败：%s" % str(err)
	var steps: Variant = await Game.call_async("acceptance:steps", [])
	if not (steps is Array) or steps.is_empty():
		return "acceptance:steps 没有返回步骤列表"
	_script_name = script_name
	_steps = steps
	return ""

func start() -> void:
	if _active or _steps.is_empty():
		return
	_active = true
	_run_id += 1
	_lines.clear()
	_log.text = ""
	_panel.visible = not hide_panel
	_hint.text = "Esc 中止"
	_run(_run_id)

func _run(id: int) -> void:
	var ok := true
	var summary := "全部 %d 步通过" % _steps.size()
	for i in range(_steps.size()):
		if id != _run_id or not _active:
			return
		var step: Variant = _steps[i]
		_title.text = "验收 %s · %d/%d" % [_script_name, i + 1, _steps.size()]
		print("[acceptance] step %d/%d: %s" % [i + 1, _steps.size(), _step_text(step)])
		var error: String = await _execute(step, id)
		if id != _run_id or not _active:
			return
		if error != "":
			ok = false
			summary = "第 %d 步失败：%s" % [i + 1, error]
			_record("FAIL", summary)
			break
		_record("OK", _step_text(step))
		await _pause(STEP_PAUSE)
		if id != _run_id or not _active:
			return
	_active = false
	_release_movement()
	_title.text = ("验收通过 · " if ok else "验收失败 · ") + _script_name
	_current.text = summary
	_hint.text = "Esc 关闭 · 可继续手动操作"
	finished.emit(ok, summary)

func _execute(step: Variant, id: int) -> String:
	if not (step is Array) or step.is_empty():
		return "非法步骤（应为非空列表）"
	var op := str(step[0])
	# A story cutscene is a real modal panel: it locks walking and swallows
	# keys by design. Replays that are not asserting the cutscene itself must
	# dismiss it first (a GM time jump can fire a beat mid-script). Story
	# assertions and `story-skip` are the only ops allowed while it is up.
	if not (op in ["note", "wait", "pace", "story-skip", "story-beat",
			"assert-story-panel", "assert-story-line", "assert-story-fact",
			"assert-story-fact-absent", "assert-story-beat"]):
		if main.story_ui != null and main.story_ui.is_open:
			main.story_ui.close()
	# Human-paced runs get a `game:people` refresh every real second before a
	# walk, so NPCs have already reached their schedule anchors. A fast replay
	# compresses those seconds away; force one refresh + a frame here so the
	# pathfinder does not route around NPCs still standing at authored spots.
	if fast_headless and (op in ["walk", "walk-interact", "walk-use",
			"walk-to-creature", "walk-attack"]):
		await Game.call_async("game:people", [])
		# Human-paced runs let villagers walk to their schedule anchors during
		# the step pauses; a fast replay has no such time, so place them there
		# directly (the same helper a map switch uses).
		main._place_npcs_on_entry()
		# Drain queued beat effects now instead of letting the shell's 1s poll
		# pop a cutscene in the middle of a scripted walk.
		await main._poll_effects()
		if main.story_ui != null and main.story_ui.is_open:
			main.story_ui.close()
		await get_tree().process_frame
	# Operations live in registered handler scripts; adding an opcode no longer
	# means editing a 1000-line match in this file.
	for handler in _op_handlers:
		var err: String = await handler.handle(op, step, self)
		if err != "__NO_OP__":
			return err
	return "未知操作：" + op

func _pause(seconds: float) -> void:
	if fast_headless:
		# One frame is enough for injected input / RPC replies to be processed,
		# without making a 40-step replay take a minute of wall-clock time.
		await get_tree().process_frame
		return
	var wait := seconds * _pace
	if wait > 0.0:
		await get_tree().create_timer(wait).timeout

## Pull the injected situation line out of a built prompt; keeps a failed
## assertion readable instead of dumping the whole (long) LLM prompt.
func _prompt_context(prompt: String) -> String:
	var i := prompt.find("当前情境：")
	if i < 0:
		return "（没有情境行）"
	var tail := prompt.substr(i)
	var end := tail.find("\n")
	return tail if end < 0 else tail.substr(0, end)

## Transfer a painted container/bag cell by calling the panel's own handler.
## A real player clicks the cell (container_panel.gd :: _on_slot_input); in a
## headless run the display server has no window, so injected mouse events never
## reach a Control's gui_input. Going through click_slot exercises the same
## panel path — and the same game:transfer call — without depending on a screen.
func _click_container_slot(side: String, type_id: String, one: bool) -> String:
	if main.container_ui == null or not main.container_ui.is_open:
		return "容器面板没有打开"
	var idx: int = main.container_ui.slot_index(side, type_id)
	if idx < 0:
		return "容器面板里没有 %s：%s" % [side, type_id]
	_current.text = "点击%s的 %s%s" % [side, type_id, "（一个）" if one else ""]
	main.container_ui.click_slot(side, type_id, not one)
	await _pause(0.4)
	return ""

## Walk to an entity until it is within arm's reach. Uses the same grid route
## villagers take, so a replay shows the player crossing the room first.
func _approach(eid: String) -> bool:
	var node: Node2D = main.entity_node(eid)
	if node == null:
		return false
	if main.player.position.distance_to(node.position) <= 20.0:
		return true
	var point: Variant = main.approach_point(node.position, 48.0)
	if point == null:
		return false
	_current.text = "走向 %s 旁边" % eid
	return await main.walk_player_to(point, 10.0)

## Quest log rows straight from Scheme; a fresh view avoids relying on the
## snapshot's tick cadence during a paused-clock acceptance run.
func _quest_rows() -> Array:
	var view: Variant = await Game.call_async("game:quests", [])
	if view is Array and view.size() >= 3 and view[2] is Array:
		return view[2]
	return []

func _assert_near(node: Node2D, anchor: String, label: String) -> String:
	var point: Variant = main.anchor_position(anchor)
	if point == null:
		return "当前地图没有 anchor：" + anchor
	if node == null:
		return label + "节点不存在"
	_current.text = "断言：%s 位于 %s" % [label, anchor]
	if node.position.distance_to(point) > 12.0:
		return "%s 距 %s 为 %.1f px" % [label, anchor, node.position.distance_to(point)]
	return ""

func _input(event: InputEvent) -> void:
	if not _panel.visible:
		return
	if event is InputEventKey and event.pressed and not event.echo \
			and event.keycode == KEY_ESCAPE:
		if _active:
			cancel()
		else:
			_panel.visible = false
		get_viewport().set_input_as_handled()

func cancel() -> void:
	if not _active:
		return
	_active = false
	_run_id += 1
	_release_movement()
	_title.text = "验收已中止 · " + _script_name
	_current.text = "已释放模拟输入，保留当前现场"
	_hint.text = "Esc 关闭 · 可继续手动操作"
	finished.emit(false, "用户中止")

func _release_movement() -> void:
	for action in MOVE_ACTIONS:
		Input.action_release(action)
	if main != null and main.player != null:
		main.player.stop_scripted()

func _step_text(step: Variant) -> String:
	if not (step is Array) or step.is_empty():
		return "非法步骤"
	var parts: PackedStringArray = []
	for value in step:
		parts.append(str(value))
	return " ".join(parts)

func _record(prefix: String, text: String) -> void:
	_lines.append("[%s] %s" % [prefix, text])
	while _lines.size() > MAX_LOG_LINES:
		_lines.pop_front()
	_log.text = "\n".join(_lines)

func _build(font: Font) -> void:
	_panel = ColorRect.new()
	_panel.color = Color(0.04, 0.05, 0.07, 0.92)
	_panel.anchor_left = 1.0
	_panel.anchor_right = 1.0
	_panel.offset_left = -470.0
	_panel.offset_top = 16.0
	_panel.offset_right = -16.0
	_panel.offset_bottom = 310.0
	_panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_panel)

	var margin := MarginContainer.new()
	margin.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	for side in ["margin_left", "margin_top", "margin_right", "margin_bottom"]:
		margin.add_theme_constant_override(side, 10)
	_panel.add_child(margin)
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 6)
	margin.add_child(box)

	_title = _label(font, 18, Color(1.0, 0.85, 0.35))
	_current = _label(font, 15, Color(0.92, 0.95, 1.0))
	_current.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_current.custom_minimum_size.y = 48
	_log = RichTextLabel.new()
	_log.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_log.add_theme_color_override("default_color", Color(0.75, 0.82, 0.88))
	_hint = _label(font, 13, Color(0.65, 0.72, 0.78))
	if font != null:
		_log.add_theme_font_override("normal_font", font)
		_log.add_theme_font_size_override("normal_font_size", 13)
	box.add_child(_title)
	box.add_child(_current)
	box.add_child(_log)
	box.add_child(_hint)
	_panel.visible = false

func _label(font: Font, size: int, color: Color) -> Label:
	var label := Label.new()
	label.add_theme_color_override("font_color", color)
	label.add_theme_font_size_override("font_size", size)
	if font != null:
		label.add_theme_font_override("font", font)
	return label
