extends CanvasLayer
## volume_panel.gd — the three-bus volume mixer (O key).
##
## Self-contained like the bag panel: it builds its own overlay, pushes itself
## onto the modal stack, and owns its keys. One HSlider per bus (Master / Music /
## SFX) writes straight through Audio.set_volume, so dragging is the live mix —
## there is no second volume state here. The Audio autoload debounces the write
## to user://settings.cfg and also flushes it when this panel closes.
##
## Acceptance drives the same sliders through set_slider(), not a backend
## shortcut, so a scripted drag exercises the same signal path as a mouse drag.

const ROWS := [
	{"key": "master", "name": "主音量"},
	{"key": "music", "name": "音乐"},
	{"key": "sfx", "name": "音效"},
]

var is_open := false

var _font: Font
var _sliders := {}     # panel key -> HSlider
var _percents := {}    # panel key -> Label
var _building := true  # suppress value_changed while the sliders are created

func setup(font: Font) -> void:
	_font = font
	layer = 27  # above bag (25) / container (26), below game-over / GM / acceptance
	name = "VolumePanelLayer"
	_build()
	visible = false

## ------------------------------------------------------------------ flow --

func open() -> void:
	if is_open:
		return
	is_open = true
	visible = true
	Modals.push(self)
	refresh()

func close() -> void:
	if not is_open:
		return
	is_open = false
	visible = false
	Modals.pop(self)
	# A drag may still be inside the debounce window when Esc is pressed.
	Audio.save_settings()

func toggle() -> void:
	if is_open:
		close()
	else:
		open()

func modal_input(event: InputEvent) -> bool:
	if not is_open or not (event is InputEventKey) \
			or not event.pressed or event.echo:
		return false
	if event.keycode == KEY_O or event.keycode == KEY_ESCAPE:
		close()
		return true
	return false

func verb_hint() -> String:
	return "拖动滑条调音量 · O / Esc 关闭" if is_open else ""

## -------------------------------------------------------- read-only for tests --

## Move one slider by the same path a mouse drag takes: HSlider.value_changed
## fires and _on_slider_changed applies it to the bus.
func set_slider(key: String, value: float) -> void:
	var slider: HSlider = _sliders.get(key)
	if slider == null:
		return
	slider.value = clampf(value, 0.0, 1.0)

func percent_text(key: String) -> String:
	var label: Label = _percents.get(key)
	return label.text if label != null else ""

## Repaint from Audio's volumes (which are the only volume state that exists).
func refresh() -> void:
	if _building:
		return
	for row in ROWS:
		var key := str(row["key"])
		var bus: String = Audio.bus_for_key(key)
		var value := Audio.get_bus_volume(bus)
		var slider: HSlider = _sliders[key]
		_building = true
		slider.value = value
		_building = false
		_percents[key].text = _as_percent(value)

## --------------------------------------------------------------- rendering --

func _as_percent(value: float) -> String:
	return "%d%%" % roundi(clampf(value, 0.0, 1.0) * 100.0)

func _on_slider_changed(value: float, key: String) -> void:
	if _building:
		return
	Audio.set_volume(Audio.bus_for_key(key), value)
	_percents[key].text = _as_percent(value)

func _build() -> void:
	var root := Control.new()
	root.name = "VolumeRoot"
	root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	root.mouse_filter = Control.MOUSE_FILTER_STOP
	add_child(root)

	var dim := ColorRect.new()
	dim.color = Color(0.02, 0.03, 0.05, 0.55)
	dim.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	dim.mouse_filter = Control.MOUSE_FILTER_STOP
	root.add_child(dim)

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
	frame.offset_left = -300.0
	frame.offset_top = -156.0
	frame.offset_right = 300.0
	frame.offset_bottom = 156.0
	frame.mouse_filter = Control.MOUSE_FILTER_STOP
	root.add_child(frame)

	var margin := MarginContainer.new()
	margin.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	for side in ["margin_left", "margin_top", "margin_right", "margin_bottom"]:
		margin.add_theme_constant_override(side, 24)
	frame.add_child(margin)

	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 14)
	margin.add_child(box)

	var title := _make_label(26, Color(0.28, 0.16, 0.08))
	title.text = "音量设置"
	box.add_child(title)

	for row in ROWS:
		var key := str(row["key"])
		var line := HBoxContainer.new()
		line.add_theme_constant_override("separation", 12)
		box.add_child(line)

		var caption := _make_label(20, Color(0.32, 0.22, 0.12))
		caption.text = str(row["name"])
		caption.custom_minimum_size = Vector2(80, 0)
		line.add_child(caption)

		var slider := HSlider.new()
		slider.min_value = 0.0
		slider.max_value = 1.0
		slider.step = 0.01
		slider.value = Audio.get_bus_volume(Audio.bus_for_key(key))
		slider.custom_minimum_size = Vector2(300, 28)
		slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		slider.value_changed.connect(_on_slider_changed.bind(key))
		line.add_child(slider)
		_sliders[key] = slider

		var pct := _make_label(20, Color(0.32, 0.22, 0.12))
		pct.text = _as_percent(slider.value)
		pct.custom_minimum_size = Vector2(56, 0)
		pct.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
		line.add_child(pct)
		_percents[key] = pct

	var hint := _make_label(16, Color(0.38, 0.27, 0.16))
	hint.text = "拖动即时生效 · 设置保存在 user://settings.cfg   ·   O / Esc 关闭"
	hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	box.add_child(hint)

	_building = false

func _make_label(size: int, color: Color) -> Label:
	var label := Label.new()
	label.add_theme_color_override("font_color", color)
	label.add_theme_font_size_override("font_size", size)
	if _font != null:
		label.add_theme_font_override("font", _font)
	return label
