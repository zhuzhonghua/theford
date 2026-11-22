extends CanvasLayer
## game_over.gd — the death screen.
##
## Scheme decides the death (game:hp carries a `down` flag); this panel is only
## presentation. It pushes itself onto the modal stack, which freezes the world
## and routes all input here until the player restarts. Restart is a callback
## owned by main.gd so this file knows nothing about maps, reloads or timers.

var is_open := false

var _font: Font
var _restart: Callable
var _root: Control

func setup(font: Font, on_restart: Callable) -> void:
	_font = font
	_restart = on_restart
	layer = 30  # above panels, below the GM console (40) and acceptance (35)
	name = "GameOverLayer"
	_build()
	visible = false

func open() -> void:
	if is_open:
		return
	is_open = true
	visible = true
	Modals.push(self)

func close() -> void:
	if not is_open:
		return
	is_open = false
	visible = false
	Modals.pop(self)

## While death is on screen nothing else gets the keyboard — including F5, so
## a player cannot skip the screen with a hotkey. R / Enter restarts.
func modal_input(event: InputEvent) -> bool:
	if not is_open:
		return false
	if event is InputEventKey and event.pressed and not event.echo:
		if event.keycode == KEY_R or event.keycode == KEY_ENTER:
			_restart.call()
		return true
	return true

func verb_hint() -> String:
	return "按 R 重新开始"

func _build() -> void:
	_root = ColorRect.new()
	_root.color = Color(0.04, 0.05, 0.08, 0.86)
	_root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_root.mouse_filter = Control.MOUSE_FILTER_STOP
	add_child(_root)

	var center := CenterContainer.new()
	center.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_root.add_child(center)

	var box := VBoxContainer.new()
	box.alignment = BoxContainer.ALIGNMENT_CENTER
	box.set_anchors_and_offsets_preset(Control.PRESET_CENTER)
	box.custom_minimum_size = Vector2(360, 0)
	center.add_child(box)

	var title := Label.new()
	title.text = "GAME OVER"
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.add_theme_font_size_override("font_size", 40)
	title.add_theme_color_override("font_color", Color(0.95, 0.35, 0.32))
	title.add_theme_color_override("font_outline_color", Color(0.1, 0.05, 0.05))
	title.add_theme_constant_override("outline_size", 4)
	if _font != null:
		title.add_theme_font_override("font", _font)
	box.add_child(title)

	var why := Label.new()
	why.text = "你在渡口边倒下了……"
	why.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	why.add_theme_font_size_override("font_size", 14)
	why.add_theme_color_override("font_color", Color(0.92, 0.90, 0.84))
	if _font != null:
		why.add_theme_font_override("font", _font)
	box.add_child(why)

	var button := Button.new()
	button.text = "重新开始（R）"
	button.focus_mode = Control.FOCUS_NONE
	button.pressed.connect(func(): _restart.call())
	if _font != null:
		button.add_theme_font_override("font", _font)
	box.add_child(button)
