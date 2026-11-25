extends RefCounted
## panel_util.gd — shared chrome for the product UI, following the reference
## project's visual language: wood frame, parchment body, square corners,
## hard 2px edges, 36px icon close button. No inheritance; panels stay
## standalone CanvasLayers like the rest of the project.

const WOOD := "res://assets/na/Ui/Theme/Theme Wood/nine_path_panel.png"
const WOOD_FRAME := "res://assets/na/Ui/Theme/Theme Wood/nine_path_panel_2.png"
const PAPER := Color(0.973, 0.875, 0.671)      # #f8dfab
const PAPER_LIGHT := Color(1.0, 0.941, 0.78)   # #fff0c7
const INK := Color(0.318, 0.208, 0.122)        # #51351f
const FRAME := Color(0.549, 0.298, 0.169)      # #8c4c2b
const GOLD := Color(0.769, 0.545, 0.212)       # #c48b36
const GREEN := Color(0.427, 0.545, 0.271)      # #6d8b45

static func close_style() -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.949, 0.812, 0.553, 1.0)  # opaque, covers text behind
	sb.border_color = FRAME
	sb.set_border_width_all(2)
	sb.content_margin_left = 6
	sb.content_margin_right = 6
	sb.content_margin_top = 6
	sb.content_margin_bottom = 6
	return sb

static func wood_style(modulate: Color) -> StyleBoxTexture:
	var sb := StyleBoxTexture.new()
	sb.texture = load(WOOD)
	sb.texture_margin_left = 8
	sb.texture_margin_top = 8
	sb.texture_margin_right = 8
	sb.texture_margin_bottom = 8
	sb.modulate_color = modulate
	sb.content_margin_left = 6
	sb.content_margin_right = 6
	sb.content_margin_top = 4
	sb.content_margin_bottom = 6
	return sb

static func make_button(text: String, font: Font, icon: Texture2D = null) -> Button:
	var button := Button.new()
	button.text = text
	button.add_theme_font_override("font", font)
	button.add_theme_font_size_override("font_size", 15)
	button.add_theme_color_override("font_color", INK)
	button.add_theme_stylebox_override("normal", wood_style(Color(1, 1, 1, 1)))
	button.add_theme_stylebox_override("hover", wood_style(Color(1.12, 1.05, 0.92, 1)))
	button.add_theme_stylebox_override("pressed", wood_style(Color(0.82, 0.78, 0.72, 1)))
	button.add_theme_stylebox_override("focus", wood_style(Color(1, 1, 1, 1)))
	if icon != null:
		var rect := TextureRect.new()
		rect.texture = icon
		rect.expand_mode = TextureRect.EXPAND_FIT_WIDTH_PROPORTIONAL
		rect.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		rect.custom_minimum_size = Vector2(20, 20)
		rect.set_anchors_and_offsets_preset(Control.PRESET_CENTER)
		rect.offset_left = -12.0
		rect.offset_top = -12.0
		rect.offset_right = 12.0
		rect.offset_bottom = 12.0
		rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
		button.add_child(rect)
	return button

static func pixel_icon(name: String) -> Texture2D:
	var image := Image.create(12, 12, false, Image.FORMAT_RGBA8)
	image.fill(Color(0, 0, 0, 0))
	var ink := INK
	var gold := GOLD
	var green := GREEN
	var rects: Array = []
	match name:
		"status":
			rects = [[2, 2, 3, 2], [7, 2, 3, 2], [1, 4, 10, 3], [2, 7, 8, 2], [4, 9, 4, 2], [5, 11, 2, 1]]
		"log":
			rects = [[2, 3, 3, 1], [2, 6, 5, 1], [2, 9, 8, 1], [2, 4, 1, 1], [2, 7, 1, 1]]
		"map":
			rects = [[2, 2, 8, 1], [2, 3, 1, 7], [9, 3, 1, 7], [2, 10, 8, 1],
					[5, 2, 1, 8], [3, 4, 2, 1], [7, 7, 2, 1]]
		"help":
			rects = [[3, 2, 6, 2], [8, 4, 2, 2], [6, 6, 3, 2], [5, 8, 2, 1], [5, 10, 2, 2]]
		"bag":
			rects = [[4, 1, 4, 2], [2, 3, 8, 7], [3, 5, 6, 4], [5, 6, 2, 2]]
		"quest":
			rects = [[3, 2, 6, 8], [4, 4, 4, 1], [5, 6, 2, 3]]
		"volume":
			rects = [[1, 5, 2, 2], [3, 4, 2, 4], [5, 2, 2, 8], [8, 4, 1, 4], [10, 3, 1, 6]]
		"mech":
			rects = [[5, 1, 2, 3], [5, 8, 2, 3], [1, 5, 3, 2], [8, 5, 3, 2], [3, 3, 6, 6], [5, 5, 2, 2]]
		"gm":
			rects = [[5, 1, 2, 10], [1, 5, 10, 2], [3, 3, 6, 6]]
		_:
			rects = [[2, 5, 8, 2]]
	for r in rects:
		var color: Color = gold if name == "help" else (green if name == "status" else ink)
		for dy in range(r[3]):
			for dx in range(r[2]):
				image.set_pixel(r[0] + dx, r[1] + dy, color)
	return ImageTexture.create_from_image(image)

static func close_icon() -> Texture2D:
	var image := Image.create(12, 12, false, Image.FORMAT_RGBA8)
	image.fill(Color(0, 0, 0, 0))
	var ink := INK
	for i in range(8):
		for dy in range(2):
			for dx in range(2):
				image.set_pixel(2 + i + dx, 2 + i + dy, ink)
				image.set_pixel(9 - i + dx, 2 + i + dy, ink)
	return ImageTexture.create_from_image(image)

static func build_shell(host: CanvasLayer, font: Font, panel_name: String,
		layer_index: int, title_text: String, width: int, height: int) -> Dictionary:
	host.name = panel_name
	host.layer = layer_index
	var root := Control.new()
	root.name = panel_name + "Root"
	root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	root.mouse_filter = Control.MOUSE_FILTER_STOP
	host.add_child(root)

	var dim := ColorRect.new()
	dim.color = Color(0.114, 0.145, 0.169, 0.70)  # #1d252bb3
	dim.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	dim.mouse_filter = Control.MOUSE_FILTER_STOP
	root.add_child(dim)

	var frame := NinePatchRect.new()
	frame.texture = load(WOOD_FRAME)
	frame.patch_margin_left = 8
	frame.patch_margin_top = 8
	frame.patch_margin_right = 8
	frame.patch_margin_bottom = 8
	frame.anchor_left = 0.5
	frame.anchor_top = 0.5
	frame.anchor_right = 0.5
	frame.anchor_bottom = 0.5
	frame.offset_left = -width * 0.5
	frame.offset_top = -height * 0.5
	frame.offset_right = width * 0.5
	frame.offset_bottom = height * 0.5
	frame.mouse_filter = Control.MOUSE_FILTER_STOP
	root.add_child(frame)

	var paper := ColorRect.new()
	paper.color = PAPER
	paper.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	paper.mouse_filter = Control.MOUSE_FILTER_IGNORE
	frame.add_child(paper)

	var column := VBoxContainer.new()
	column.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	column.add_theme_constant_override("separation", 0)
	frame.add_child(column)

	var head := HBoxContainer.new()
	head.add_theme_constant_override("separation", 8)
	var head_margin := MarginContainer.new()
	for side in ["margin_left", "margin_top", "margin_right", "margin_bottom"]:
		head_margin.add_theme_constant_override(side, 10)
	head_margin.add_child(head)
	column.add_child(head_margin)

	var title := label(font, title_text, 24, INK)
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	head.add_child(title)

	var close := Button.new()
	close.custom_minimum_size = Vector2(36, 36)
	close.icon = close_icon()
	close.expand_icon = true
	close.icon_alignment = HORIZONTAL_ALIGNMENT_CENTER
	close.add_theme_stylebox_override("normal", close_style())
	head.add_child(close)
	if host.has_method("close"):
		close.pressed.connect(Callable(host, "close"))

	var rule := ColorRect.new()
	rule.color = GOLD
	rule.custom_minimum_size = Vector2(0, 2)
	column.add_child(rule)

	var body_margin := MarginContainer.new()
	for side in ["margin_left", "margin_top", "margin_right", "margin_bottom"]:
		body_margin.add_theme_constant_override(side, 16)
	body_margin.size_flags_vertical = Control.SIZE_EXPAND_FILL
	column.add_child(body_margin)
	# ScrollContainer gives children a bounded width, so long labels wrap inside
	# the frame instead of stretching it off-screen.
	var scroll := ScrollContainer.new()
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	scroll.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_AUTO
	scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	body_margin.add_child(scroll)
	var content := VBoxContainer.new()
	content.add_theme_constant_override("separation", 8)
	content.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	content.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.add_child(content)
	return {"root": root, "title": title, "content": content, "close": close, "frame": frame, "scroll": scroll}

static func find_frame(node: Node) -> Control:
	for child in node.get_children():
		if child is NinePatchRect:
			return child
		var found := find_frame(child)
		if found != null:
			return found
	return null

static func find_close_button(node: Node) -> Button:
	for child in node.get_children():
		if child is Button and child.custom_minimum_size == Vector2(36, 36):
			return child
		var found := find_close_button(child)
		if found != null:
			return found
	return null

## Older panels built their own frame; attach a matching close icon to it.
static func add_close_button(host: CanvasLayer, font: Font, parent: Control = null) -> Button:
	var existing := find_close_button(host)
	if existing != null:
		return existing  # the panel already owns one (e.g. container panel)
	var frame := parent if parent != null else find_frame(host)
	var close := Button.new()
	close.custom_minimum_size = Vector2(36, 36)
	close.icon = close_icon()
	close.expand_icon = true
	close.icon_alignment = HORIZONTAL_ALIGNMENT_CENTER
	close.add_theme_stylebox_override("normal", close_style())
	close.anchor_left = 1.0
	close.anchor_top = 0.0
	close.anchor_right = 1.0
	close.anchor_bottom = 0.0
	close.offset_left = -48.0
	close.offset_top = 8.0
	close.offset_right = -12.0
	close.offset_bottom = 44.0
	if frame != null:
		frame.add_child(close)
	else:
		host.add_child(close)
	if host.has_method("close"):
		close.pressed.connect(Callable(host, "close"))
	return close

static func press_close(host: CanvasLayer) -> bool:
	var button := find_close_button(host)
	if button != null:
		button.pressed.emit()
		return true
	return false

static func clear(container: Node) -> void:
	for child in container.get_children():
		container.remove_child(child)
		child.queue_free()

static func label(font: Font, text: String, size := 20, color := INK) -> Label:
	var label := Label.new()
	label.text = text
	label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	label.add_theme_font_override("font", font)
	label.add_theme_font_size_override("font_size", size)
	label.add_theme_color_override("font_color", color)
	return label

static func rich_text(font: Font, size := 19) -> RichTextLabel:
	var box := RichTextLabel.new()
	box.fit_content = false
	box.scroll_active = true
	box.add_theme_font_override("normal_font", font)
	box.add_theme_font_size_override("normal_font_size", size)
	box.add_theme_color_override("default_color", INK)
	box.size_flags_vertical = Control.SIZE_EXPAND_FILL
	return box
