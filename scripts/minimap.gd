extends Control
## minimap.gd — top-left canvas mini-map, same idea as the reference project's
## .minimap: terrain/blocked cells + colour dots for entities, click to open the
## full map panel. Geometry is read from the shell; nothing is copied to Scheme.

var main: Node
var _cache: Dictionary = {}

func setup(main_node: Node) -> void:
	main = main_node
	mouse_filter = Control.MOUSE_FILTER_STOP
	gui_input.connect(_on_gui_input)

func refresh() -> void:
	if main == null: return
	_cache = main.minimap_data()
	queue_redraw()

func _on_gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.pressed \
			and event.button_index == MOUSE_BUTTON_LEFT:
		if main != null and main.has_method("open_panel"):
			main.open_panel("map")

func _draw() -> void:
	if _cache.is_empty():
		return
	var r := get_rect()
	var cells: Array = _cache.get("blocked", [])
	var anchors: Array = _cache.get("anchors", [])
	var npcs: Array = _cache.get("npcs", [])
	var portals: Array = _cache.get("portals", [])
	var player: Variant = _cache.get("player", null)
	var min_x := 0; var max_x := 40; var min_y := 0; var max_y := 30
	for c in cells:
		min_x = mini(min_x, c.x); max_x = maxi(max_x, c.x)
		min_y = mini(min_y, c.y); max_y = maxi(max_y, c.y)
	var span_x := maxf(1.0, float(max_x - min_x + 1))
	var span_y := maxf(1.0, float(max_y - min_y + 1))
	var scale := minf(r.size.x / span_x, r.size.y / span_y)
	var ox := (r.size.x - span_x * scale) * 0.5
	var oy := (r.size.y - span_y * scale) * 0.5
	draw_rect(Rect2(Vector2.ZERO, r.size), Color(0.973, 0.875, 0.671, 1.0))
	for c in cells:
		var p := Vector2(ox + (c.x - min_x) * scale, oy + (c.y - min_y) * scale)
		draw_rect(Rect2(p, Vector2(scale, scale)), Color(0.36, 0.46, 0.28, 0.85))
	for a in anchors:
		var p: Vector2 = a["pos"]
		var s := Vector2(ox + (p.x / 16.0 - min_x) * scale, oy + (p.y / 16.0 - min_y) * scale)
		draw_rect(Rect2(s - Vector2(1.5, 1.5), Vector2(3, 3)), Color(0.77, 0.55, 0.21))
	for p2 in portals:
		var p: Vector2 = p2
		var s := Vector2(ox + (p.x / 16.0 - min_x) * scale, oy + (p.y / 16.0 - min_y) * scale)
		draw_circle(s, 3.0, Color(0.37, 0.94, 1.0))
	for n in npcs:
		var p: Vector2 = n["pos"]
		var s := Vector2(ox + (p.x / 16.0 - min_x) * scale, oy + (p.y / 16.0 - min_y) * scale)
		draw_circle(s, 2.5, Color(0.35, 0.63, 1.0))
	if player != null:
		var p: Vector2 = player
		var s := Vector2(ox + (p.x / 16.0 - min_x) * scale, oy + (p.y / 16.0 - min_y) * scale)
		draw_circle(s, 4.0, Color(0, 0, 0))
		draw_circle(s, 3.0, Color(1, 1, 1))
