extends CanvasLayer
## quest_panel.gd — the quest log (J key).
##
## A read-only view of Scheme's `game:quests` view: quest id, title, stage
## state, current description and one progress line per objective. The panel
## keeps no quest state of its own; it repaints whenever the bridge publishes a
## fresh snapshot, so a pickup or delivery shows up within one tick.
##
## It is a modal-stack member like the bag: it pushes itself on open, pops on
## close, and consumes only J / Esc while it is on top. main.gd needs one hotkey
## branch, and travel / reload / F8 close it through Modals.close_all().

const PanelUtil := preload("res://scripts/panel_util.gd")

const STATE_NAMES := {
	"not-offered": "未接",
	"accepted": "进行中",
	"completed": "已完成",
}

var is_open := false

var _font: Font
var _root: Control
var _title: Label
var _body: RichTextLabel
## quest id -> {state, text, objectives: Array of "text done/need"} for tests.
var _rendered: Dictionary = {}

func setup(font: Font) -> void:
	_font = font
	layer = 25  # same plane as the bag panel; only one is open at a time
	name = "QuestPanelLayer"
	_build()
	PanelUtil.add_close_button(self, font)
	Game.snapshot_changed.connect(_on_snapshot_changed)
	Game.bridge_ready.connect(_on_bridge_ready)
	visible = false

## ------------------------------------------------------------------- flow --

func open() -> void:
	is_open = true
	visible = true
	Modals.push(self)
	_refresh()

func close() -> void:
	is_open = false
	visible = false
	Modals.pop(self)

func toggle() -> void:
	if is_open:
		close()
	else:
		open()

func modal_input(event: InputEvent) -> bool:
	if not is_open or not (event is InputEventKey) \
			or not event.pressed or event.echo:
		return false
	if event.keycode == KEY_J or event.keycode == KEY_ESCAPE:
		close()
		return true
	return false

func verb_hint() -> String:
	return "J / Esc 关闭任务日志"

## ------------------------------------------------------- read-only for tests --

func row_count() -> int:
	return _rendered.size()

func has_quest(id: String) -> bool:
	return _rendered.has(id)

func state_for(id: String) -> String:
	return str(_rendered.get(id, {}).get("state", ""))

func objective_line(id: String, index: int) -> String:
	var lines: Array = _rendered.get(id, {}).get("objectives", [])
	if index < 0 or index >= lines.size():
		return ""
	return str(lines[index])

func text_for(id: String) -> String:
	return str(_rendered.get(id, {}).get("text", ""))

func objective_lines(id: String) -> Array:
	return _rendered.get(id, {}).get("objectives", [])

func all_text() -> String:
	return _body.text if _body != null else ""

## -------------------------------------------------------------- rendering --

func _on_snapshot_changed() -> void:
	if is_open:
		_refresh()

func _on_bridge_ready(_llm: bool) -> void:
	if is_open:
		_refresh()

func _refresh() -> void:
	if not is_open or _body == null:
		return
	_rendered = {}
	_title.text = "任务日志    经验 %d" % int(Game.snapshot.get("xp", 0))
	_body.clear()
	var quests: Variant = Game.snapshot.get("quests", [])
	if not (quests is Array) or quests.is_empty():
		_body.append_text("[color=#6b5238]还没有任务，去村里和村民聊聊。[/color]\n")
		return
	for row in quests:
		if not (row is Array and row.size() >= 5):
			continue
		var id := str(row[0])
		var title := str(row[1])
		var state := str(row[2])
		var text := str(row[3])
		var objectives: Variant = row[4]
		var lines: Array = []
		if objectives is Array:
			for obj in objectives:
				if obj is Array and obj.size() >= 3:
					lines.append("%s   %d / %d" % [str(obj[0]), int(obj[1]), int(obj[2])])
		_rendered[id] = {"state": state, "text": text, "objectives": lines}
		var state_name := str(STATE_NAMES.get(state, state))
		var color := "#3c6a3a" if state == "completed" else "#6b4a20"
		_body.append_text("[color=%s]【%s】%s · %s[/color]\n" % [color, state_name, id, title])
		_body.append_text("  %s\n" % text)
		for line in lines:
			_body.append_text("    · %s\n" % line)
		_body.append_text("\n")

## ------------------------------------------------------------------- build --

func _build() -> void:
	_root = Control.new()
	_root.name = "QuestRoot"
	_root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_root.mouse_filter = Control.MOUSE_FILTER_STOP
	add_child(_root)

	var dim := ColorRect.new()
	dim.color = Color(0.02, 0.03, 0.05, 0.55)
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
	frame.offset_left = -330.0
	frame.offset_top = -230.0
	frame.offset_right = 330.0
	frame.offset_bottom = 230.0
	frame.mouse_filter = Control.MOUSE_FILTER_STOP
	_root.add_child(frame)

	var margin := MarginContainer.new()
	margin.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	for side in ["margin_left", "margin_top", "margin_right", "margin_bottom"]:
		margin.add_theme_constant_override(side, 22)
	frame.add_child(margin)

	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 12)
	margin.add_child(box)

	_title = Label.new()
	_title.add_theme_color_override("font_color", Color(0.28, 0.16, 0.08))
	_title.add_theme_font_size_override("font_size", 26)
	if _font != null:
		_title.add_theme_font_override("font", _font)
	box.add_child(_title)

	_body = RichTextLabel.new()
	_body.bbcode_enabled = true
	_body.scroll_active = true
	_body.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_body.add_theme_color_override("default_color", Color(0.30, 0.21, 0.12))
	_body.add_theme_font_size_override("normal_font_size", 19)
	if _font != null:
		_body.add_theme_font_override("normal_font", _font)
	box.add_child(_body)

	var hint := Label.new()
	hint.text = "J / Esc 关闭 · 目标进度随拾取即时更新"
	hint.add_theme_color_override("font_color", Color(0.38, 0.27, 0.16))
	hint.add_theme_font_size_override("font_size", 16)
	if _font != null:
		hint.add_theme_font_override("font", _font)
	box.add_child(hint)
