extends CanvasLayer
## story_panel.gd — story scene presentation (cutscene / narration lines).
##
## Scheme decides which beat fires and writes its facts; Godot owns the pacing.
## This panel is a modal stack member: while it is up the world receives no
## input and the player cannot walk, the same contract every other panel uses.
## Lines arrive as [speaker, text] tuples from the "scene" effect. E / Enter /
## Space advances, Esc skips the rest. The panel tells Scheme to pause beat
## evaluation while it owns the keyboard so two scenes can never stack up.

var is_open := false

var _font: Font
var _root: Control
var _title: Label
var _speaker: Label
var _text: RichTextLabel
var _hint: Label
var _queue: Array = []
var _index := 0
var _typing := false
var _speed := 38.0  # visible ratio per second

func setup(font: Font) -> void:
	_font = font
	layer = 28  # above bag (25), container (26), volume (27)
	name = "StoryLayer"
	_build()
	visible = false

## ------------------------------------------------------------------ flow --

func open(title: String, lines: Array) -> void:
	if is_open:
		# A later beat queued its scene while this one was on screen: append
		# rather than stacking a second modal panel.
		for line in lines:
			_queue.append(line)
		return
	is_open = true
	visible = true
	_queue = []
	for line in lines:
		_queue.append(line)
	_index = -1
	if not title.is_empty():
		_title.text = title
	Modals.push(self)
	Game.send("game:story-pause", [true])
	Audio.play("dialog-open")
	await _next()

func close() -> void:
	if not is_open:
		return
	is_open = false
	visible = false
	_queue.clear()
	_typing = false
	Modals.pop(self)
	Game.send("game:story-pause", [false])

func modal_input(event: InputEvent) -> bool:
	if not is_open:
		return false
	if not (event is InputEventKey) or not event.pressed or event.echo:
		return true  # swallow mouse / release keys while a scene is up
	if event.keycode == KEY_ESCAPE:
		close()
		return true
	if event.keycode == KEY_E or event.keycode == KEY_ENTER \
			or event.keycode == KEY_KP_ENTER or event.keycode == KEY_SPACE \
			or event.is_action_pressed("interact"):
		if _typing:
			_text.visible_ratio = 1.0
			_typing = false
		else:
			_next()
		return true
	return true

func verb_hint() -> String:
	return "E / Enter 继续　Esc 跳过"

## Read-only view used by acceptance to assert what is on screen.
func current_line() -> String:
	if _index < 0 or _index >= _queue.size():
		return ""
	var row: Variant = _queue[_index]
	if row is Array and row.size() >= 2:
		return str(row[0]) + "：" + str(row[1])
	return ""

func remaining_lines() -> int:
	return max(0, _queue.size() - _index - 1)

## ------------------------------------------------------------ presentation --

func _next() -> void:
	_index += 1
	if _index >= _queue.size():
		close()
		return
	var row: Variant = _queue[_index]
	var speaker := ""
	var line := ""
	if row is Array and row.size() >= 2:
		speaker = str(row[0])
		line = str(row[1])
	_speaker.text = speaker if not speaker.is_empty() else "旁白"
	_text.text = line
	_text.visible_ratio = 0.0
	_hint.text = "E / Enter 继续　Esc 跳过"
	_typing = true
	Audio.play("type")
	_run_typewriter(line)

func _run_typewriter(line: String) -> void:
	# Headless playback shows the full line immediately; a windowed run keeps
	# the typewriter for the person watching the replay.
	if DisplayServer.get_name() == "headless":
		_text.visible_ratio = 1.0
		_typing = false
		Audio.play("type")
		return
	var t := 0.0
	while is_open and t < 8.0 and _typing:
		t += get_process_delta_time()
		_text.visible_ratio = clampf(
			_text.visible_ratio + get_process_delta_time() * _speed / maxf(1.0, line.length()),
			0.0, 1.0)
		await get_tree().process_frame
		if _text.visible_ratio >= 1.0:
			break
	_typing = false

## ------------------------------------------------------------------ build --

func _build() -> void:
	_root = Control.new()
	_root.name = "StoryRoot"
	_root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_root.mouse_filter = Control.MOUSE_FILTER_STOP
	add_child(_root)

	var dim := ColorRect.new()
	dim.color = Color(0.02, 0.03, 0.05, 0.62)
	dim.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	dim.mouse_filter = Control.MOUSE_FILTER_STOP
	_root.add_child(dim)

	var frame := NinePatchRect.new()
	frame.texture = load("res://assets/na/Ui/Theme/Theme Wood/nine_path_panel_2.png")
	frame.patch_margin_left = 8
	frame.patch_margin_top = 8
	frame.patch_margin_right = 8
	frame.patch_margin_bottom = 8
	frame.anchor_left = 0.5
	frame.anchor_top = 0.5
	frame.anchor_right = 0.5
	frame.anchor_bottom = 0.5
	frame.offset_left = -420.0
	frame.offset_top = -170.0
	frame.offset_right = 420.0
	frame.offset_bottom = 170.0
	frame.mouse_filter = Control.MOUSE_FILTER_STOP
	_root.add_child(frame)

	var margin := MarginContainer.new()
	margin.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	for side in ["margin_left", "margin_top", "margin_right", "margin_bottom"]:
		margin.add_theme_constant_override(side, 22)
	frame.add_child(margin)

	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 10)
	margin.add_child(box)

	_title = _make_label(24, Color(0.30, 0.17, 0.08))
	box.add_child(_title)
	_speaker = _make_label(22, Color(0.42, 0.24, 0.10))
	box.add_child(_speaker)
	_text = RichTextLabel.new()
	_text.fit_content = true
	_text.scroll_active = false
	_text.add_theme_font_override("normal_font", _font)
	_text.add_theme_font_size_override("normal_font_size", 22)
	_text.add_theme_color_override("default_color", Color(0.12, 0.09, 0.06))
	_text.size_flags_vertical = Control.SIZE_EXPAND_FILL
	box.add_child(_text)
	_hint = _make_label(16, Color(0.42, 0.34, 0.22))
	box.add_child(_hint)

func _make_label(size: int, color: Color) -> Label:
	var label := Label.new()
	label.add_theme_font_override("font", _font)
	label.add_theme_font_size_override("font_size", size)
	label.add_theme_color_override("font_color", color)
	return label
