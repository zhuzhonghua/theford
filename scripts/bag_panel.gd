extends CanvasLayer
## bag_panel.gd — the inventory panel (I key).
##
## Self-contained like the mechanism HUD: it builds its own overlay, listens to
## Game.snapshot_changed, and renders the bag view Scheme already publishes.
## main.gd only creates it and forwards the I key. Counts, stack merging and
## slot capacity all live in scheme/game/inventory.scm — this file never keeps
## a second inventory.
##
## The grid mirrors the bag's shape: three rows of ten slots. Each slot shows
## the item's catalog sprite and its count. A stack larger than one slot spills
## into the next cell, using the per-row slot count Scheme sends, so the panel
## and `bag-slots-used` always agree. Icon paths come from data/catalog.scm via
## game:catalog-item; adding an item needs data only. Tool/weapon cells are clickable: a click
## equips that piece into the hand slot (inventory.scm), or takes the equipped one off — the same
## slot the F verb reads. The gold border and the "装备" label mirror Scheme's held-tool state.

const COLUMNS := 10
const SLOT_COUNT := 30  # keep in sync with inventory.scm bag-slots
const ItemSlots := preload("res://scripts/item_slots.gd")
const ItemIcons := preload("res://scripts/item_icons.gd")

var is_open := false

var _font: Font
var _root: Control
var _title: Label
var _held: Label
var _hand_slot: Panel
var _hand_icon: TextureRect
var _grid: GridContainer
var _slots: Array[Panel] = []
var _icons: Array[TextureRect] = []
var _counts: Array[Label] = []
## sprite key -> Texture2D, shared shape with the container panel.
var _icon_cache: ItemIcons = null
## [[type, amount, name, sprite], ...] as currently painted, for acceptance.
var _slot_rows: Array = []

func setup(font: Font) -> void:
	_font = font
	_icon_cache = ItemIcons.new()
	layer = 25  # above HUD/dialog (10) and the mechanism HUD (20)
	name = "BagPanelLayer"
	_build()
	Game.snapshot_changed.connect(_on_snapshot_changed)
	Game.bridge_ready.connect(_on_bridge_ready)
	visible = false

## ------------------------------------------------------------------ flow --

func open() -> void:
	is_open = true
	visible = true
	Modals.push(self)
	# Ask for a fresh view: the snapshot is already current, but a pickup may
	# have landed between the last refresh and this key press.
	Game.send("game:bag")
	_refresh()

func close() -> void:
	is_open = false
	visible = false
	Modals.pop(self)

## Modality lives here instead of in main.gd: I toggles, Esc closes. The stack
## hands us the key only while we are on top.
func modal_input(event: InputEvent) -> bool:
	if not is_open or not (event is InputEventKey) \
			or not event.pressed or event.echo:
		return false
	if event.keycode == KEY_I or event.keycode == KEY_ESCAPE:
		close()
		return true
	return false

func toggle() -> void:
	if is_open:
		close()
	else:
		open()

## ------------------------------------------------------- read-only for tests --
## Acceptance asserts against what the grid is painting, not the Scheme view,
## so a stale panel fails.

func slot_total(type_id: String) -> int:
	var total := 0
	for entry in _slot_rows:
		if str(entry[0]) == type_id:
			total += int(entry[1])
	return total

func filled_slots() -> int:
	return _slot_rows.size()

## A tool/weapon cell is clickable to equip. Mirrors `piece?` in inventory.scm:
## pieces are the only things the hand slot accepts.
func _is_equippable(type_id: String) -> bool:
	return type_id.begins_with("item/tool") or type_id.begins_with("item/weapon")

## Click a tool cell to equip it, or the equipped one to take it off. Both the
## GUI click handler and the acceptance replay go through here, so a scripted
## equip exercises the same panel path a player's mouse does.
func click_slot(type_id: String) -> void:
	if not _is_equippable(type_id):
		return
	# Make sure the hand-slot value we toggle against is current, not a cached
	# one from before a GM command or a container transfer.
	await Game.call_async("game:bag", [])
	var held := str(Game.snapshot.get("held", ""))
	if type_id == held:
		await Game.call_async("game:unequip", [])
	else:
		await Game.call_async("game:equip", [type_id])
	# The equip reply is a boolean, not a bag view: ask Scheme for the view on
	# the same worker queue so the panel repaints from state, not a local guess.
	await Game.call_async("game:bag", [])

func _on_slot_input(event: InputEvent, index: int) -> void:
	if not (event is InputEventMouseButton):
		return
	var mb := event as InputEventMouseButton
	if not mb.pressed or mb.button_index != MOUSE_BUTTON_LEFT:
		return
	if index < 0 or index >= _slot_rows.size():
		return
	click_slot(str(_slot_rows[index][0]))
	get_viewport().set_input_as_handled()

## Clicking the visible hand slot takes the tool off — the same Scheme path as
## clicking the equipped tool's cell in the grid.
func _on_hand_input(event: InputEvent) -> void:
	if not (event is InputEventMouseButton):
		return
	var mb := event as InputEventMouseButton
	if not mb.pressed or mb.button_index != MOUSE_BUTTON_LEFT:
		return
	if str(Game.snapshot.get("held", "")) == "":
		return
	await Game.call_async("game:unequip", [])
	Game.send("game:bag")
	get_viewport().set_input_as_handled()

## Sprite keys the grid is showing without a texture: either still loading or
## the catalog path is wrong. Acceptance fails on a non-empty list, so a bad
## asset path cannot pass as "the grid looks fine".
func missing_icons() -> Array:
	return _icon_cache.missing(_slot_rows)

## ------------------------------------------------------------- rendering --

func _on_snapshot_changed() -> void:
	if is_open:
		_refresh()

func _on_bridge_ready(_llm: bool) -> void:
	if is_open:
		_refresh()

func _refresh() -> void:
	if not is_open or _grid == null:
		return
	var slots := ItemSlots.build_slots(Game.snapshot.get("bag", []))
	_slot_rows = slots
	_title.text = "背包    %d / %d 格" % [
			int(Game.snapshot.get("bag_slots", slots.size())),
			int(Game.snapshot.get("bag_capacity", SLOT_COUNT))]
	var held := str(Game.snapshot.get("held", ""))
	var held_name := ""
	var held_sprite := ""
	for row in Game.snapshot.get("bag", []):
		if row is Array and row.size() >= 3 and str(row[0]) == held:
			held_name = str(row[2])
			held_sprite = str(row[3]) if row.size() >= 4 else ""
	_held.text = ("装备：【" + held_name + "】 · 点击卸下") if held_name != "" else "装备：空 · 点击工具装备"
	# The hand slot is a real, visible box: it shows the equipped tool's icon
	# (or nothing) and its gold/neutral border comes from the same held flag.
	_hand_slot.add_theme_stylebox_override("panel", ItemSlots.slot_style(held != ""))
	_hand_icon.texture = _icon_cache.texture_for(held_sprite, _on_icon_loaded) if held_sprite != "" else null
	for i in range(SLOT_COUNT):
		var entry: Variant = slots[i] if i < slots.size() else null
		if entry == null:
			_icons[i].texture = null
			_counts[i].text = ""
			_slots[i].tooltip_text = ""
			_slots[i].add_theme_stylebox_override("panel", ItemSlots.slot_style(false))
			continue
		var type_id := str(entry[0])
		var amount := int(entry[1])
		var display := str(entry[2])
		var sprite := str(entry[3])
		# A lone piece needs no number; quantities start at two.
		_counts[i].text = str(amount) if amount > 1 else ""
		if _is_equippable(type_id):
			_slots[i].tooltip_text = "%s x%d · %s" % [display, amount,
					"点击卸下" if type_id == held else "点击装备到手上"]
		else:
			_slots[i].tooltip_text = "%s x%d" % [display, amount]
		_slots[i].add_theme_stylebox_override("panel",
				ItemSlots.slot_style(type_id == held))
		_icons[i].texture = _icon_cache.texture_for(sprite, _on_icon_loaded)

## A catalog reply landed: repaint so the new icon appears without a new key.
func _on_icon_loaded() -> void:
	if is_open:
		_refresh()

## ------------------------------------------------------------------ build --

func _build() -> void:
	_root = Control.new()
	_root.name = "BagRoot"
	_root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_root.mouse_filter = Control.MOUSE_FILTER_STOP
	add_child(_root)

	var dim := ColorRect.new()
	dim.color = Color(0.02, 0.03, 0.05, 0.55)
	dim.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	dim.mouse_filter = Control.MOUSE_FILTER_STOP
	_root.add_child(dim)

	# A flat nine-patch panel: it tiles cleanly at any size, unlike the
	# portrait dialog box whose thick top rim turns into a stripe when
	# stretched. The bag is a grid, so the frame stays out of the way.
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
	frame.offset_top = -170.0
	frame.offset_right = 344.0
	frame.offset_bottom = 170.0
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

	var head := HBoxContainer.new()
	head.add_theme_constant_override("separation", 16)
	box.add_child(head)
	_title = _make_label(26, Color(0.28, 0.16, 0.08))
	_title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	head.add_child(_title)

	# A visible hand/equipment slot. Clicking it unequips; clicking a tool cell
	# in the grid below equips. The box is the same size as a grid cell so the
	# icon scale and border match exactly what the F verb reads.
	var hand_box := HBoxContainer.new()
	hand_box.add_theme_constant_override("separation", 8)
	head.add_child(hand_box)
	var hand_cap := _make_label(17, Color(0.38, 0.27, 0.16))
	hand_cap.text = "手："
	hand_box.add_child(hand_cap)
	_hand_slot = Panel.new()
	_hand_slot.custom_minimum_size = Vector2(46, 46)
	_hand_slot.mouse_filter = Control.MOUSE_FILTER_STOP
	_hand_slot.tooltip_text = "装备槽 · 点击卸下"
	_hand_slot.gui_input.connect(_on_hand_input)
	_hand_slot.add_theme_stylebox_override("panel", ItemSlots.slot_style(false))
	hand_box.add_child(_hand_slot)
	_hand_icon = TextureRect.new()
	_hand_icon.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_hand_icon.offset_left = 5.0
	_hand_icon.offset_top = 5.0
	_hand_icon.offset_right = -5.0
	_hand_icon.offset_bottom = -5.0
	_hand_icon.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_hand_icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	_hand_icon.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	_hand_icon.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_hand_slot.add_child(_hand_icon)

	_held = _make_label(20, Color(0.35, 0.24, 0.12))
	_held.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	head.add_child(_held)

	_grid = GridContainer.new()
	_grid.columns = COLUMNS
	_grid.add_theme_constant_override("h_separation", 6)
	_grid.add_theme_constant_override("v_separation", 6)
	box.add_child(_grid)

	for i in range(SLOT_COUNT):
		var slot := Panel.new()
		slot.custom_minimum_size = Vector2(58, 58)
		slot.mouse_filter = Control.MOUSE_FILTER_STOP
		slot.gui_input.connect(_on_slot_input.bind(i))
		slot.add_theme_stylebox_override("panel", ItemSlots.slot_style(false))
		_grid.add_child(slot)
		_slots.append(slot)

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
		_icons.append(icon)

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
		_counts.append(count)

	var hint := _make_label(16, Color(0.38, 0.27, 0.16))
	hint.text = "点工具格装备 · 点手槽卸下（影响 F）   ·   I 关闭"
	hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	box.add_child(hint)

func _make_label(size: int, color: Color) -> Label:
	var label := Label.new()
	label.add_theme_color_override("font_color", color)
	label.add_theme_font_size_override("font_size", size)
	if _font != null:
		label.add_theme_font_override("font", _font)
	return label
