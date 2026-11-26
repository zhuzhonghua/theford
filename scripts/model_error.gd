extends CanvasLayer
## model_error.gd — hard stop when the local LLM cannot boot.
## The game ships with its GGUF and is LLM-driven by design: without a model
## there is no dialogue, so we do not let the player enter the world at all.

const U := preload("res://scripts/panel_util.gd")

var is_open := false
var _font: Font

func setup(font: Font, message: String) -> void:
	_font = font
	layer = 60  # above every panel, including the start menu
	name = "ModelErrorLayer"
	var root := Control.new()
	root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	root.mouse_filter = Control.MOUSE_FILTER_STOP
	add_child(root)

	var dim := ColorRect.new()
	dim.color = Color(0.06, 0.08, 0.10, 0.92)
	dim.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	root.add_child(dim)

	var frame := PanelContainer.new()
	frame.add_theme_stylebox_override("panel", U.wood_style(Color(1, 1, 1, 1)))
	frame.anchor_left = 0.5
	frame.anchor_top = 0.5
	frame.anchor_right = 0.5
	frame.anchor_bottom = 0.5
	frame.offset_left = -360
	frame.offset_top = -200
	frame.offset_right = 360
	frame.offset_bottom = 200
	root.add_child(frame)

	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 16)
	frame.add_child(box)
	var title := U.label(font, "无法启动本地模型", 28, U.FRAME)
	box.add_child(title)
	var body := U.label(font, message, 18)
	body.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	box.add_child(body)
	var quit := U.make_button("退出游戏", font)
	quit.custom_minimum_size = Vector2(160, 40)
	quit.pressed.connect(func() -> void: get_tree().quit())
	box.add_child(quit)
	visible = false

func show_error(message: String) -> void:
	print("[TheFord] 阻止进入游戏：模型/启动失败")
	is_open = true
	visible = true
	var labels: Array[Label] = []
	_collect(self, labels)
	if labels.size() >= 2:
		labels[1].text = message

func _collect(node: Node, out: Array[Label]) -> void:
	for child in node.get_children():
		if child is Label:
			out.append(child)
		_collect(child, out)
