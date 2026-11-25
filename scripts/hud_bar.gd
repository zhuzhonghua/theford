extends CanvasLayer
## hud_bar.gd — four-corner product HUD, following the reference project's
## layout instead of a single top-left text card:
##   top-left     clickable mini-map
##   top-right    clock box + clickable objective box
##   bottom-centre hearts/XP/held tool + the current verb tip
##   bottom-right 40px wood icon buttons (no save/load — use F5/F9 or GM)
##   bottom-left  auto-fading message stack (the old log toast, done properly)

const U := preload("res://scripts/panel_util.gd")
const Minimap := preload("res://scripts/minimap.gd")

const AI_NAMES := {"off": "关", "low": "低", "medium": "中", "high": "高"}
const WEATHER_NAMES := {"sun": "晴", "cloud": "多云", "rain": "下雨", "storm": "暴雨", "fog": "起雾"}
const BUTTONS := ["status", "log", "map", "help", "bag", "quest", "volume", "mech"]

var main: Node
var _font: Font
var _buttons := {}
var _mini: Minimap
var _clock: Label
var _objective: Label
var _objective_scroll: ScrollContainer
var _objective_folded := false
var _vitals: Label
var _hint: Label
var _messages: VBoxContainer

func setup(font: Font, main_node: Node) -> void:
	_font = font
	main = main_node
	layer = 15
	name = "HudLayer"
	_build()
	Game.snapshot_changed.connect(refresh)
	Game.bridge_ready.connect(_on_bridge_ready)
	refresh()

func _on_bridge_ready(_llm: bool) -> void:
	refresh()

func set_hint(text: String) -> void:
	if _hint != null:
		_hint.text = text

## Same path as the reference's .msgs stack: dedupe the last line, keep 6,
## start fading at 5s and remove at 6s (animation replaced by a 1s dim).
func push_message(text: String) -> void:
	if text == "" or _messages == null:
		return
	if _messages.get_child_count() > 0:
		var last: Label = _messages.get_child(_messages.get_child_count() - 1) as Label
		if last != null and last.text == text:
			_last_message_at[last] = Time.get_ticks_msec()
			last.modulate = Color(1, 1, 1, 1)
			return
	var msg := U.label(_font, "• " + text, 13, U.PAPER_LIGHT)
	msg.modulate = Color(1, 1, 1, 1)
	msg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_messages.add_child(msg)
	var ts := Time.get_ticks_msec()
	_last_message_at[msg] = ts
	while _messages.get_child_count() > 6:
		_messages.remove_child(_messages.get_child(0))
	_call_delayed(_dim_message.bind(msg, ts), 5.0)
	_call_delayed(_erase_message.bind(msg, ts), 6.0)

var _last_message_at := {}

func _dim_message(msg: Label, ts: int) -> void:
	if is_instance_valid(msg) and _last_message_at.get(msg, -1) == ts:
		msg.modulate = Color(1, 1, 1, 0.45)

func _erase_message(msg: Label, ts: int) -> void:
	if _last_message_at.get(msg, -1) != ts:
		return  # a newer identical message refreshed this entry
	if is_instance_valid(msg):
		msg.queue_free()
	_last_message_at.erase(msg)

func _call_delayed(callable: Callable, seconds: float) -> void:
	get_tree().create_timer(seconds).timeout.connect(callable)

func refresh() -> void:
	if _clock == null:
		return
	var s := Game.snapshot
	var weather := str(WEATHER_NAMES.get(str(s.get("weather", "sun")), s.get("weather", "sun")))
	_clock.text = "第 %d 天  %02d:%02d  %s" % [
			int(s.get("day", 1)), int(s.get("hour", 8)), int(s.get("minute", 0)), weather]
	var quest_text := _quest_lines(s.get("quests", []))
	_objective.text = quest_text
	if _objective_scroll != null and not _objective_folded:
		var lines: int = quest_text.count("\n") + 1
		_objective_scroll.custom_minimum_size.y = clampi(lines * 30 + 12, 64, 260)
	_vitals.text = "♥ %d/%d    经验 %d    %s" % [
			int(s.get("hp", 10)), int(s.get("max_hp", 10)), int(s.get("xp", 0)),
			str(s.get("held", "空手"))]
	if _mini != null:
		_mini.refresh()

func messages_text() -> String:
	if _messages == null:
		return ""
	var lines: Array[String] = []
	for child in _messages.get_children():
		if child is Label:
			lines.append(child.text)
	return "\n".join(lines)

func press_button(which: String) -> bool:
	var button: Variant = _buttons.get(which, null)
	if button == null:
		return false
	button.pressed.emit()
	return true

## Compact quest list for the HUD: one quest per line, state + title +
## objective progress. The full text stays in the J panel.
func _quest_lines(rows: Variant) -> String:
	if not (rows is Array) or rows.is_empty():
		return "• 暂无任务（在村里走走看看）"
	var lines: Array[String] = []
	var shown := 0
	for row in rows:
		if not (row is Array) or row.size() < 5 or shown >= 4:
			continue
		var state := str(row[2])
		var mark := "○" if state == "not-offered" else ("◆" if state == "accepted" else "✓")
		var title := str(row[1])
		var progress: Array = row[4] if row[4] is Array else []
		var bits: Array[String] = []
		for obj in progress:
			if obj is Array and obj.size() >= 3:
				bits.append("%s %s/%s" % [str(obj[0]), str(obj[1]), str(obj[2])])
		lines.append("%s %s%s" % [mark, title,
				"  ·  " + "  ".join(bits) if not bits.is_empty() else ""])
		shown += 1
	return "\n".join(lines)

## Fully opaque wood-coloured box: no texture alpha for the world to bleed
## through around the mini-map.
func opaque_wood_box() -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.78, 0.53, 0.28, 1.0)
	sb.border_color = U.FRAME
	sb.set_border_width_all(3)
	sb.content_margin_left = 4
	sb.content_margin_right = 4
	sb.content_margin_top = 4
	sb.content_margin_bottom = 4
	return sb

func _toggle_objective() -> void:
	_objective_folded = not _objective_folded
	if _objective_scroll == null:
		return
	_objective_scroll.custom_minimum_size.y = 26 if _objective_folded else 96
	_objective_scroll.visible = not _objective_folded

func dark_box() -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.16, 0.13, 0.10, 0.90)
	sb.border_color = U.GOLD
	sb.set_border_width_all(2)
	sb.content_margin_left = 6
	sb.content_margin_right = 6
	sb.content_margin_top = 4
	sb.content_margin_bottom = 4
	return sb

func _build() -> void:
	var root := Control.new()
	root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(root)

	# Top-left: mini-map (clickable).
	var mini_frame := PanelContainer.new()
	mini_frame.add_theme_stylebox_override("panel", opaque_wood_box())
	mini_frame.anchor_left = 0.0; mini_frame.anchor_top = 0.0
	mini_frame.anchor_right = 0.0; mini_frame.anchor_bottom = 0.0
	mini_frame.offset_left = 12; mini_frame.offset_top = 12
	mini_frame.offset_right = 168; mini_frame.offset_bottom = 116
	mini_frame.mouse_filter = Control.MOUSE_FILTER_STOP
	root.add_child(mini_frame)
	_mini = Minimap.new()
	_mini.setup(main)
	_mini.custom_minimum_size = Vector2(148, 92)
	mini_frame.add_child(_mini)

	# Top-right: clock + objective.
	var right := VBoxContainer.new()
	right.anchor_left = 1.0; right.anchor_top = 0.0
	right.anchor_right = 1.0; right.anchor_bottom = 0.0
	right.offset_left = -236; right.offset_top = 12
	right.offset_right = -12; right.offset_bottom = 160
	right.add_theme_constant_override("separation", 6)
	root.add_child(right)
	var clock_box := PanelContainer.new()
	clock_box.add_theme_stylebox_override("panel", U.wood_style(Color(1, 1, 1, 1)))
	right.add_child(clock_box)
	_clock = U.label(_font, "", 15)
	clock_box.add_child(_clock)
	var objective_box := PanelContainer.new()
	objective_box.add_theme_stylebox_override("panel", dark_box())
	objective_box.mouse_filter = Control.MOUSE_FILTER_STOP
	objective_box.custom_minimum_size = Vector2(224, 0)
	right.add_child(objective_box)

	var obj_col := VBoxContainer.new()
	obj_col.add_theme_constant_override("separation", 4)
	objective_box.add_child(obj_col)
	var obj_head := HBoxContainer.new()
	obj_col.add_child(obj_head)
	var obj_title := U.label(_font, "任务追踪", 13, U.GOLD)
	obj_title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	obj_head.add_child(obj_title)
	var fold := U.make_button("▾", _font)
	fold.custom_minimum_size = Vector2(28, 26)
	fold.pressed.connect(_toggle_objective)
	obj_head.add_child(fold)
	var open := U.make_button("日志", _font)
	open.custom_minimum_size = Vector2(46, 26)
	open.pressed.connect(func():
		if main != null and main.has_method("open_panel"): main.open_panel("quest"))
	obj_head.add_child(open)

	# Bounded scroll area: a long quest string must not stretch the dark box
	# across the screen. Height adapts to the number of quests, and folds.
	_objective_scroll = ScrollContainer.new()
	_objective_scroll.custom_minimum_size = Vector2(196, 76)
	_objective_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_objective_scroll.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_AUTO
	obj_col.add_child(_objective_scroll)
	_objective = U.label(_font, "", 13, U.PAPER_LIGHT)
	_objective.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_objective_scroll.add_child(_objective)

	# Bottom-centre: vitals + verb tip.
	var bottom := VBoxContainer.new()
	bottom.anchor_left = 0.5; bottom.anchor_top = 1.0
	bottom.anchor_right = 0.5; bottom.anchor_bottom = 1.0
	bottom.offset_left = -210; bottom.offset_top = -96
	bottom.offset_right = 210; bottom.offset_bottom = -12
	bottom.add_theme_constant_override("separation", 4)
	root.add_child(bottom)
	var hint_box := PanelContainer.new()
	hint_box.add_theme_stylebox_override("panel", dark_box())
	bottom.add_child(hint_box)
	_hint = U.label(_font, "", 13, U.PAPER_LIGHT)
	hint_box.add_child(_hint)
	var vitals_box := PanelContainer.new()
	vitals_box.add_theme_stylebox_override("panel", U.wood_style(Color(1, 1, 1, 1)))
	bottom.add_child(vitals_box)
	_vitals = U.label(_font, "", 15)
	vitals_box.add_child(_vitals)

	# Bottom-right: 40px icon buttons, max four per row.
	var corner := HFlowContainer.new()
	corner.anchor_left = 1.0; corner.anchor_top = 1.0
	corner.anchor_right = 1.0; corner.anchor_bottom = 1.0
	corner.offset_left = -192; corner.offset_top = -112
	corner.offset_right = -12; corner.offset_bottom = -12
	corner.custom_minimum_size = Vector2(180, 100)
	corner.add_theme_constant_override("h_separation", 6)
	corner.add_theme_constant_override("v_separation", 6)
	root.add_child(corner)
	for key in BUTTONS:
		var button := U.make_button("", _font, U.pixel_icon(key))
		button.custom_minimum_size = Vector2(40, 40)
		button.tooltip_text = str(key)
		button.pressed.connect(_on_button.bind(str(key)))
		corner.add_child(button)
		_buttons[str(key)] = button
	if main != null and main.gm != null:
		var gm_button := U.make_button("", _font, U.pixel_icon("gm"))
		gm_button.custom_minimum_size = Vector2(40, 40)
		gm_button.pressed.connect(_on_button.bind("gm"))
		corner.add_child(gm_button)
		_buttons["gm"] = gm_button

	# Bottom-left: message stack.
	_messages = VBoxContainer.new()
	_messages.anchor_left = 0.0; _messages.anchor_top = 1.0
	_messages.anchor_right = 0.0; _messages.anchor_bottom = 1.0
	_messages.offset_left = 12; _messages.offset_top = -180
	_messages.offset_right = 340; _messages.offset_bottom = -20
	_messages.add_theme_constant_override("separation", 3)
	_messages.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.add_child(_messages)

func _on_button(which: String) -> void:
	if main != null and main.has_method("open_panel"):
		main.open_panel(which)
