extends CanvasLayer
## gm_console.gd — in-game GM console, toggled with F8.
##
## Part of the optional GM module (scripts/gm/). main.gd loads this file by
## path at runtime, so a release build can delete the whole folder without
## touching the game shell. All command logic lives in gm_commands.gd; this
## file is only the panel and input box.

const GmCommands := preload("res://scripts/gm/gm_commands.gd")
const AcceptanceRunner := preload("res://scripts/gm/acceptance_runner.gd")
const MOVE_ACTIONS := ["move_up", "move_down", "move_left", "move_right"]

var main: Node
var is_open := false

var _commands: GmCommands
var _acceptance: CanvasLayer
var _loading := false
var _panel: ColorRect
var _log: RichTextLabel
var _edit: LineEdit

func setup(main_node: Node, font: Font) -> void:
	main = main_node
	_commands = GmCommands.new(main)
	layer = 40
	_acceptance = AcceptanceRunner.new()
	add_child(_acceptance)
	_acceptance.setup(main_node, self, font)
	_acceptance.finished.connect(_on_acceptance_finished)
	_build(font)

## Time multiplier read by main.gd every frame: 1 normal, 0 paused, N = Nx.
func speed() -> float:
	return _commands.tick_rate if _commands != null else 1.0

## `game:people` rows with GM overrides applied, for main.gd's movement pass.
func apply_overrides(rows: Array) -> Array:
	return _commands.apply_overrides(rows) if _commands != null else rows

## Death restart returns time to real speed just like the GM reload command.
func reset_speed() -> void:
	if _commands != null:
		_commands.tick_rate = 1.0

func execute(line: String) -> String:
	return await _commands.execute(line) if _commands != null else ""

func is_gm_command(word: String) -> bool:
	return _commands != null and _commands.is_gm_command(word)

## Dev hook: THEFORD_ACCEPTANCE=<name> plays a script once the bridge is up.
## Headless-friendly; prints the summary so a terminal run carries the result.
func autoplay(script_name: String) -> void:
	var error: String = await _acceptance.load_script(script_name)
	if error != "":
		print("[acceptance] load failed: " + error)
		return
	_acceptance.finished.connect(func(ok: bool, summary: String) -> void:
		print("[acceptance] %s: %s" % ["OK" if ok else "FAIL", summary])
		if OS.get_environment("THEFORD_ACCEPTANCE_QUIT") == "1":
			get_tree().quit(0 if ok else 1))
	_acceptance.start()

func _build(font: Font) -> void:
	_panel = ColorRect.new()
	_panel.color = Color(0.04, 0.05, 0.07, 0.93)
	_panel.anchor_left = 0.0
	_panel.anchor_top = 1.0
	_panel.anchor_right = 1.0
	_panel.anchor_bottom = 1.0
	_panel.offset_left = 12.0
	_panel.offset_top = -360.0
	_panel.offset_right = -12.0
	_panel.offset_bottom = -12.0
	_panel.mouse_filter = Control.MOUSE_FILTER_STOP
	add_child(_panel)

	var margin := MarginContainer.new()
	margin.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	margin.add_theme_constant_override("margin_left", 12)
	margin.add_theme_constant_override("margin_top", 10)
	margin.add_theme_constant_override("margin_right", 12)
	margin.add_theme_constant_override("margin_bottom", 10)
	_panel.add_child(margin)

	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 6)
	margin.add_child(box)

	_log = RichTextLabel.new()
	_log.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_log.scroll_following = true
	_log.add_theme_color_override("default_color", Color(0.88, 0.92, 0.96))
	if font != null:
		_log.add_theme_font_override("normal_font", font)
		_log.add_theme_font_size_override("normal_font_size", 16)
	box.add_child(_log)

	_edit = LineEdit.new()
	_edit.placeholder_text = "输入 GM 指令，help 查看；F8 关闭"
	_edit.keep_editing_on_text_submit = true
	_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	if font != null:
		_edit.add_theme_font_override("font", font)
		_edit.add_theme_font_size_override("font_size", 18)
	_edit.text_submitted.connect(_on_submitted)
	_edit.gui_input.connect(_on_edit_gui)
	box.add_child(_edit)

	_panel.visible = false
	_append(_commands.help_text())

func toggle() -> void:
	is_open = not is_open
	_release_movement()
	_panel.visible = is_open
	if is_open:
		Modals.push(self)
	else:
		Modals.pop(self)
	if is_open:
		_edit.grab_focus()
		_edit.caret_column = _edit.text.length()
	else:
		_edit.release_focus()

## Typing Chinese through an IME can swallow the key-up of letters that also
## map to movement (w/a/s/d), leaving an action "pressed" after the console
## closes and making the player walk by itself. Clear them at the boundary.
func _release_movement() -> void:
	for action in MOVE_ACTIONS:
		Input.action_release(action)

## The console sits on the modal stack so nothing reaches the world while it
## is up. Its LineEdit handles its own Esc/F8; swallowing here just isolates
## the world. (F8 is handled in main.gd's _input, before gui_input.)
func modal_input(_event: InputEvent) -> bool:
	return is_open

func _on_edit_gui(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and event.keycode == KEY_ESCAPE:
		toggle()
		get_viewport().set_input_as_handled()

func _on_submitted(text: String) -> void:
	_submit(text)

func _submit(text: String) -> void:
	var cmd := text.strip_edges()
	_edit.text = ""
	_edit.grab_focus()
	if cmd == "":
		return
	if cmd == "help" or cmd == "?":
		_append(_commands.help_text())
		return
	if cmd == "clear":
		_log.text = ""
		return
	_append("> " + cmd)
	var verb := cmd.split(" ", false)[0].to_lower()
	if verb == "load":
		await _load_acceptance(cmd)
		return
	if _loading:
		_append("验收脚本加载中，请稍候…")
		return
	if not _commands.is_gm_command(verb):
		_append("（LLM 解析中…）")
	var out: String = await _commands.execute(cmd)
	if out != "":
		_append(out)
	# Keep the caret in the box after Enter, including after an LLM round-trip.
	_edit.grab_focus()
	_edit.caret_column = _edit.text.length()

func _load_acceptance(line: String) -> void:
	if _loading:
		_append("验收脚本加载中，请稍候…")
		return
	var args := line.split(" ", false)
	if args.size() != 2:
		_append("用法：load <脚本名>，例如 load portal")
		return
	_loading = true
	_edit.editable = false
	_append("正在加载验收脚本 %s…" % args[1])
	var error: String = await _acceptance.load_script(args[1])
	_loading = false
	_edit.editable = true
	if error != "":
		_append(error)
		_edit.grab_focus()
		return
	_append("已加载 %s，开始自动验收。" % args[1])
	if is_open:
		toggle()
	_acceptance.start()

func _on_acceptance_finished(ok: bool, summary: String) -> void:
	if ok:
		_append("验收通过：%s" % summary)
	elif summary == "用户中止":
		_append("验收已中止，已保留当前现场。")
	else:
		_append("验收失败：%s" % summary)

func _append(line: String) -> void:
	_log.add_text(line + "\n")
