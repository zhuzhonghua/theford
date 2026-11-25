extends CanvasLayer
## map_panel.gd — M key: schematic map on the left, a clickable list of the
## same anchors/NPCs/portals on the right. Clicking a row highlights it on the
## canvas (the old static label list could not be interacted with at all).

const U := preload("res://scripts/panel_util.gd")
const MapCanvas := preload("res://scripts/map_canvas.gd")

var is_open := false
var toggle_key := KEY_NONE
var _font: Font
var main: Node
var _canvas: MapCanvas
var _legend: VBoxContainer
var _legend_map := ""

func setup_with_main(font: Font, main_node: Node) -> void:
	_font = font
	main = main_node
	var ui := U.build_shell(self, font, "MapLayer", 28, "世界地图 · 当前区域", 820, 500)
	var holder: Node = ui.get("content")
	var split := HSplitContainer.new()
	split.add_theme_constant_override("separation", 14)
	split.size_flags_vertical = Control.SIZE_EXPAND_FILL
	split.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	holder.add_child(split)

	_canvas = MapCanvas.new()
	_canvas.setup(font, main_node)
	_canvas.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_canvas.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_canvas.size_flags_vertical = Control.SIZE_EXPAND_FILL
	split.add_child(_canvas)

	var side := PanelContainer.new()
	side.add_theme_stylebox_override("panel", U.wood_style(Color(1, 1, 1, 1)))
	side.custom_minimum_size = Vector2(250, 0)
	split.add_child(side)
	var side_margin := MarginContainer.new()
	for s in ["margin_left", "margin_top", "margin_right", "margin_bottom"]:
		side_margin.add_theme_constant_override(s, 10)
	side.add_child(side_margin)
	var scroll := ScrollContainer.new()
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	side_margin.add_child(scroll)
	_legend = VBoxContainer.new()
	_legend.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_legend.add_theme_constant_override("separation", 4)
	scroll.add_child(_legend)

	U.add_close_button(self, font)
	visible = false
	Game.snapshot_changed.connect(_on_snapshot)

func set_toggle_key(key: int) -> void:
	toggle_key = key

func open() -> void:
	if is_open: return
	is_open = true
	visible = true
	Modals.push(self)
	refresh()

func close() -> void:
	if not is_open: return
	is_open = false
	visible = false
	Modals.pop(self)

func modal_input(event: InputEvent) -> bool:
	if not is_open: return false
	if event is InputEventKey and event.pressed and not event.echo \
			and (event.keycode == KEY_ESCAPE or event.keycode == toggle_key):
		close()
	return true

func verb_hint() -> String:
	return "Esc / M 关闭"

func _on_snapshot() -> void:
	if not is_open:
		return
	# Game.snapshot_changed fires ~10x/second. Rebuilding the legend buttons
	# every time makes hover flicker; only refresh the canvas dots here. The
	# legend is rebuilt on open and when the player changes map.
	var map_id: String = main.current_map_id() if main != null else ""
	if map_id != _legend_map:
		_legend_map = map_id
		refresh()
	else:
		_canvas.refresh()

func refresh() -> void:
	if _canvas == null: return
	_legend_map = str(main.current_map_id()) if main != null else ""
	_canvas.refresh()
	U.clear(_legend)
	for row in _canvas.legend_rows():
		var label := str(row.get("label", ""))
		var kind := str(row.get("kind", ""))
		var pos: Vector2 = row.get("pos", Vector2.ZERO)
		var button := Button.new()
		button.text = "%s %s  (%d,%d)" % [
				"◈" if kind == "portal" else ("●" if kind == "npc" else "·"),
				label, int(pos.x), int(pos.y)]
		button.alignment = HORIZONTAL_ALIGNMENT_LEFT
		button.add_theme_font_override("font", _font)
		button.add_theme_font_size_override("font_size", 14)
		button.add_theme_color_override("font_color", U.INK)
		button.add_theme_stylebox_override("normal", U.close_style())
		button.pressed.connect(_on_legend_pressed.bind(label))
		_legend.add_child(button)

func _on_legend_pressed(label: String) -> void:
	_canvas.focus(label)

func item_count() -> int:
	return _canvas.item_count() if _canvas != null else 0
