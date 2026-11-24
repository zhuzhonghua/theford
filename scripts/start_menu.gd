extends CanvasLayer
## start_menu.gd — the boot screen: continue a saved trip or start a new one.
##
## The world scene is already instantiated when this opens; pushing the panel
## onto the modal stack freezes the player and routes input here (the same
## mechanism as the death screen). main.gd owns the two callbacks, so this file
## knows nothing about maps, reloads or the save file format.

var is_open := false

var _font: Font
var _on_continue: Callable
var _on_new: Callable
var _root: Control
var _continue_button: Button

func setup(font: Font, on_continue: Callable, on_new: Callable) -> void:
	_font = font
	_on_continue = on_continue
	_on_new = on_new
	layer = 45  # above the GM console (40) and acceptance runner (35)
	name = "StartMenuLayer"
	_build()
	visible = false

func open(has_save: bool) -> void:
	if is_open:
		return
	is_open = true
	_continue_button.disabled = not has_save
	_continue_button.text = "继续游戏" if has_save else "继续游戏（无存档）"
	visible = true
	Modals.push(self)

func close() -> void:
	if not is_open:
		return
	is_open = false
	visible = false
	Modals.pop(self)

## Swallow every key while the choice is up; a stray E/F or hotkey must not
## reach the world underneath. The buttons are the only way through.
func modal_input(event: InputEvent) -> bool:
	return is_open

func verb_hint() -> String:
	return "选择「继续游戏」或「新游戏」"

func _build() -> void:
	_root = ColorRect.new()
	_root.color = Color(0.04, 0.05, 0.08, 0.92)
	_root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_root.mouse_filter = Control.MOUSE_FILTER_STOP
	add_child(_root)

	var center := CenterContainer.new()
	center.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_root.add_child(center)

	var box := VBoxContainer.new()
	box.alignment = BoxContainer.ALIGNMENT_CENTER
	box.custom_minimum_size = Vector2(420, 0)
	center.add_child(box)

	var title := Label.new()
	title.text = "渡 口"
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.add_theme_font_size_override("font_size", 56)
	title.add_theme_color_override("font_color", Color(0.96, 0.90, 0.72))
	if _font != null:
		title.add_theme_font_override("font", _font)
	box.add_child(title)

	var sub := Label.new()
	sub.text = "THE FORD · 一封送过河的信"
	sub.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	sub.add_theme_font_size_override("font_size", 14)
	sub.add_theme_color_override("font_color", Color(0.82, 0.84, 0.88))
	if _font != null:
		sub.add_theme_font_override("font", _font)
	box.add_child(sub)

	var gap := Control.new()
	gap.custom_minimum_size = Vector2(0, 28)
	box.add_child(gap)

	_continue_button = Button.new()
	_continue_button.text = "继续游戏"
	_continue_button.custom_minimum_size = Vector2(0, 44)
	_continue_button.focus_mode = Control.FOCUS_NONE
	_continue_button.pressed.connect(_choose_continue)
	if _font != null:
		_continue_button.add_theme_font_override("font", _font)
	box.add_child(_continue_button)

	var new_button := Button.new()
	new_button.text = "新游戏"
	new_button.custom_minimum_size = Vector2(0, 44)
	new_button.focus_mode = Control.FOCUS_NONE
	new_button.pressed.connect(_choose_new)
	if _font != null:
		new_button.add_theme_font_override("font", _font)
	box.add_child(new_button)

	var tip := Label.new()
	tip.text = "F5 存档 · F9 读档 · F8 控制台（reload 可热重载）"
	tip.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	tip.add_theme_font_size_override("font_size", 12)
	tip.add_theme_color_override("font_color", Color(0.70, 0.72, 0.78))
	if _font != null:
		tip.add_theme_font_override("font", _font)
	box.add_child(tip)

func _choose_continue() -> void:
	if not is_open or _continue_button.disabled:
		return
	close()
	_on_continue.call()

func _choose_new() -> void:
	if not is_open:
		return
	close()
	_on_new.call()
