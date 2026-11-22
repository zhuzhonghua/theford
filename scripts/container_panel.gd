extends CanvasLayer
## container_panel.gd — the container panel (E on a chest).
##
## Two grids: the container's contents on top, the bag below. Clicking a stack
## moves the whole stack to the other side; Shift+click moves one. Counts,
## capacities and the transfer itself live in scheme/game/containers.scm — this
## file only paints the view Scheme publishes and asks it to move stacks.
##
## The panel is modal like the bag: while it is open the player does not walk
## and E/Esc close it (main.gd owns that flow and clears the container's open
## state in Scheme).

signal close_requested

const ItemSlots := preload("res://scripts/item_slots.gd")
const ItemIcons := preload("res://scripts/item_icons.gd")
const COLUMNS := 10
const SLOT_COUNT := 30  # keep in sync with inventory.scm bag-slots
const SLOT_SIZE := 58.0

var is_open := false
var container_id := ""

var _font: Font
var _root: Control
var _title: Label
var _bag_title: Label
var _held: Label
var _chest_grid: GridContainer
var _bag_grid: GridContainer
var _chest_slots: Array[Panel] = []
var _chest_icons: Array[TextureRect] = []
var _chest_counts: Array[Label] = []
var _bag_slots: Array[Panel] = []
var _bag_icons: Array[TextureRect] = []
var _bag_counts: Array[Label] = []
var _icons := {}  # "chest"/"bag" -> ItemIcons
## side -> [[type, amount, name, sprite], ...] as currently painted.
var _rows := {"chest": [], "bag": []}
## One transfer in flight: a second click waits for the reply.
var _busy := false

func setup(font: Font) -> void:
	_font = font
	_icons = {"chest": ItemIcons.new(), "bag": ItemIcons.new()}
	layer = 26  # above the bag panel (25) and the mechanism HUD (20)
	name = "ContainerPanelLayer"
	_build()
	Game.snapshot_changed.connect(_on_snapshot_changed)
	visible = false

## ------------------------------------------------------------------ flow --

func open(id: String) -> void:
	container_id = id
	is_open = true
	visible = true
	Modals.push(self)
	Game.send("game:bag")
	_refresh()

func close() -> void:
	is_open = false
	visible = false
	container_id = ""
	_busy = false
	Modals.pop(self)

## The HUD asks the stack for a hint, so the panel owns its own wording.
func verb_hint() -> String:
	return "E / Esc 关闭箱子" if is_open else ""

## E / Esc close the panel. Emitting close_requested lets main.gd clear the
## container's `open` prop in Scheme — the panel itself only owns presentation.
func modal_input(event: InputEvent) -> bool:
	if not is_open or not (event is InputEventKey) \
			or not event.pressed or event.echo:
		return false
	if event.keycode == KEY_E or event.keycode == KEY_ESCAPE:
		close_requested.emit()
		return true
	return false

## ------------------------------------------------------- read-only for tests --

func slot_index(side: String, type_id: String) -> int:
	var rows: Array = _rows.get(side, [])
	for i in range(rows.size()):
		if str(rows[i][0]) == type_id:
			return i
	return -1

func slot_total(side: String, type_id: String) -> int:
	var total := 0
	for entry in _rows.get(side, []):
		if str(entry[0]) == type_id:
			total += int(entry[1])
	return total

func filled_slots(side: String) -> int:
	return int(_rows.get(side, []).size())

## Sprite keys the grid is showing without a texture.
func missing_icons(side: String) -> Array:
	return _icons[side].missing(_rows.get(side, []))

## Viewport-space center of a painted cell, for the acceptance click step.
func slot_center(side: String, index: int) -> Vector2:
	var slots: Array = _chest_slots if side == "chest" else _bag_slots
	if index < 0 or index >= slots.size():
		return Vector2.ZERO
	return (slots[index] as Control).get_global_rect().get_center()

## ------------------------------------------------------------- rendering --

func _on_snapshot_changed() -> void:
	if is_open:
		_refresh()

func _on_icon_loaded() -> void:
	if is_open:
		_refresh()

func _refresh() -> void:
	if not is_open or _root == null:
		return
	var box: Dictionary = Game.snapshot.get("container", {})
	if box.is_empty() or str(box.get("id", "")) != container_id:
		# Scheme closed the container (or a reload cleared it): leave the panel.
		close()
		return
	var cap := int(box.get("capacity", 0))
	var rows: Array = box.get("rows", [])
	var cells := maxi(rows.size(), cap)
	cells = int(ceil(float(cells) / COLUMNS)) * COLUMNS
	if cells <= 0:
		cells = COLUMNS
	_ensure_chest_slots(cells)
	var chest_entries := ItemSlots.build_slots(rows)
	_rows["chest"] = chest_entries
	var chest_name := str(box.get("name", "箱子"))
	_title.text = "%s    %d / %d 格" % [
			chest_name, int(box.get("slots", chest_entries.size())), cap]
	for i in range(_chest_slots.size()):
		var active := i < cells and i < cap
		var entry: Variant = chest_entries[i] if i < chest_entries.size() else null
		_paint_slot("chest", i, entry, active, false)

	var bag_entries := ItemSlots.build_slots(Game.snapshot.get("bag", []))
	_rows["bag"] = bag_entries
	var held := str(Game.snapshot.get("held", ""))
	var held_name := ""
	for row in Game.snapshot.get("bag", []):
		if row is Array and row.size() >= 3 and str(row[0]) == held:
			held_name = str(row[2])
	_bag_title.text = "背包    %d / %d 格" % [
			int(Game.snapshot.get("bag_slots", bag_entries.size())),
			int(Game.snapshot.get("bag_capacity", SLOT_COUNT))]
	_held.text = ("装备：" + held_name) if held_name != "" else ""
	for i in range(SLOT_COUNT):
		var bag_entry: Variant = bag_entries[i] if i < bag_entries.size() else null
		var is_held := bag_entry != null and str(bag_entry[0]) == held
		_paint_slot("bag", i, bag_entry, true, is_held)

func _paint_slot(side: String, i: int, entry: Variant, active: bool,
		held: bool) -> void:
	var slots: Array = _chest_slots if side == "chest" else _bag_slots
	var icons: Array = _chest_icons if side == "chest" else _bag_icons
	var counts: Array = _chest_counts if side == "chest" else _bag_counts
	if entry == null:
		icons[i].texture = null
		counts[i].text = ""
		slots[i].tooltip_text = ""
		slots[i].add_theme_stylebox_override("panel",
				ItemSlots.slot_style(false) if active else ItemSlots.off_slot_style())
		return
	var type_id := str(entry[0])
	var amount := int(entry[1])
	var display := str(entry[2])
	var sprite := str(entry[3])
	# A lone piece needs no number; quantities start at two.
	counts[i].text = str(amount) if amount > 1 else ""
	slots[i].tooltip_text = "%s x%d" % [display, amount]
	slots[i].add_theme_stylebox_override("panel", ItemSlots.slot_style(held))
	icons[i].texture = _icons[side].texture_for(sprite, _on_icon_loaded)

## ---------------------------------------------------------------- transfers --

func _on_slot_input(event: InputEvent, side: String, index: int) -> void:
	if not (event is InputEventMouseButton):
		return
	var mb := event as InputEventMouseButton
	if not mb.pressed or mb.button_index != MOUSE_BUTTON_LEFT:
		return
	var rows: Array = _rows.get(side, [])
	if index < 0 or index >= rows.size():
		return
	# Click: the whole stack across. Shift+click: one.
	click_slot(side, str(rows[index][0]), not mb.shift_pressed)
	get_viewport().set_input_as_handled()

## Move a stack by type on one side. Both the GUI click handler and the
## acceptance replay go through here, so a scripted transfer exercises the
## panel's own path instead of calling Scheme directly.
func click_slot(side: String, type_id: String, all: bool) -> void:
	_transfer(side, type_id, all)

func _transfer(side: String, type_id: String, all: bool) -> void:
	if _busy or container_id == "":
		return
	_busy = true
	var view: Variant = await Game.call_async(
			"game:transfer", [container_id, side, type_id, all])
	_busy = false
	Game.send("game:bag")
	if view == null:
		close()
	elif is_open:
		_refresh()

## ------------------------------------------------------------------ build --

func _build() -> void:
	_root = Control.new()
	_root.name = "ContainerRoot"
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
	frame.offset_left = -344.0
	frame.offset_top = -268.0
	frame.offset_right = 344.0
	frame.offset_bottom = 268.0
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

	# ---- the container ----
	var chest_head := HBoxContainer.new()
	chest_head.add_theme_constant_override("separation", 12)
	box.add_child(chest_head)
	_title = _make_label(24, Color(0.28, 0.16, 0.08))
	_title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	chest_head.add_child(_title)
	var close_button := Button.new()
	close_button.text = "✕"
	close_button.custom_minimum_size = Vector2(36, 36)
	close_button.tooltip_text = "关闭（E / Esc）"
	if _font != null:
		close_button.add_theme_font_override("font", _font)
		close_button.add_theme_font_size_override("font_size", 20)
	close_button.pressed.connect(func() -> void: close_requested.emit())
	chest_head.add_child(close_button)

	_chest_grid = _make_grid()
	box.add_child(_chest_grid)

	var chest_hint := _make_label(15, Color(0.38, 0.27, 0.16))
	chest_hint.text = "点击：整堆移到背包 · Shift+点击：移一个"
	box.add_child(chest_hint)

	# ---- the bag ----
	var bag_head := HBoxContainer.new()
	bag_head.add_theme_constant_override("separation", 12)
	box.add_child(bag_head)
	_bag_title = _make_label(24, Color(0.28, 0.16, 0.08))
	_bag_title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	bag_head.add_child(_bag_title)
	_held = _make_label(18, Color(0.35, 0.24, 0.12))
	_held.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	bag_head.add_child(_held)

	_bag_grid = _make_grid()
	box.add_child(_bag_grid)
	for i in range(SLOT_COUNT):
		_add_slot(_bag_grid, "bag", i, _bag_slots, _bag_icons, _bag_counts)

	var hint := _make_label(16, Color(0.38, 0.27, 0.16))
	hint.text = "点击背包里的物品：放进箱子 · E / Esc 关闭"
	hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	box.add_child(hint)

func _make_grid() -> GridContainer:
	var grid := GridContainer.new()
	grid.columns = COLUMNS
	grid.add_theme_constant_override("h_separation", 6)
	grid.add_theme_constant_override("v_separation", 6)
	return grid

## The container grid is sized by its capacity (an 8-slot chest still draws
## ten columns: two cells are visibly out of reach).
func _ensure_chest_slots(n: int) -> void:
	while _chest_slots.size() < n:
		_add_slot(_chest_grid, "chest", _chest_slots.size(),
				_chest_slots, _chest_icons, _chest_counts)
	for i in range(_chest_slots.size()):
		_chest_slots[i].visible = i < n

func _add_slot(grid: GridContainer, side: String, index: int,
		slots: Array[Panel], icons: Array[TextureRect],
		counts: Array[Label]) -> void:
	var slot := Panel.new()
	slot.custom_minimum_size = Vector2(SLOT_SIZE, SLOT_SIZE)
	slot.mouse_filter = Control.MOUSE_FILTER_STOP
	slot.add_theme_stylebox_override("panel", ItemSlots.slot_style(false))
	slot.gui_input.connect(_on_slot_input.bind(side, index))
	grid.add_child(slot)
	slots.append(slot)

	var icon := TextureRect.new()
	icon.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	icon.offset_left = 7.0
	icon.offset_top = 7.0
	icon.offset_right = -7.0
	icon.offset_bottom = -7.0
	icon.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	icon.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	icon.mouse_filter = Control.MOUSE_FILTER_IGNORE
	slot.add_child(icon)
	icons.append(icon)

	var count := Label.new()
	count.set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_RIGHT)
	count.offset_left = -40.0
	count.offset_top = -24.0
	count.offset_right = -4.0
	count.offset_bottom = -1.0
	count.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	count.vertical_alignment = VERTICAL_ALIGNMENT_BOTTOM
	count.add_theme_color_override("font_color", Color(1.0, 0.95, 0.82))
	count.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.9))
	count.add_theme_constant_override("outline_size", 4)
	if _font != null:
		count.add_theme_font_override("font", _font)
		count.add_theme_font_size_override("font_size", 17)
	count.mouse_filter = Control.MOUSE_FILTER_IGNORE
	slot.add_child(count)
	counts.append(count)

func _make_label(size: int, color: Color) -> Label:
	var label := Label.new()
	label.add_theme_color_override("font_color", color)
	label.add_theme_font_size_override("font_size", size)
	if _font != null:
		label.add_theme_font_override("font", _font)
	return label
