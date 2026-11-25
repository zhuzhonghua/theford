extends Control
## map_canvas.gd — schematic mini-map for the M panel. Godot owns all world
## geometry; this only draws the named anchors, NPCs, portals and the player
## into a fitted rectangle. No world data is copied into Scheme.

var ui_font: Font
var main: Node
var focus_label := ""
var _items: Array = []
var _min := Vector2.ZERO
var _max := Vector2(100, 100)

func setup(font: Font, main_node: Node) -> void:
	ui_font = font
	main = main_node

func item_count() -> int:
	return _items.size()

func focus(label: String) -> void:
	focus_label = label
	queue_redraw()

func refresh() -> void:
	_items.clear()
	if main == null:
		queue_redraw()
		return
	var xs: Array[float] = []
	var ys: Array[float] = []
	for name in main.anchor_names():
		var p: Variant = main.anchor_position(str(name))
		if p != null:
			_items.append({"pos": p, "label": str(name), "kind": "anchor"})
			xs.append(p.x); ys.append(p.y)
	for eid in main.portal_positions().keys():
		var p: Variant = main.portal_positions()[eid]
		if p != null:
			_items.append({"pos": p, "label": str(eid), "kind": "portal"})
			xs.append(p.x); ys.append(p.y)
	for row in main.npc_visual_rows():
		if row is Dictionary and row.has("pos"):
			var p: Vector2 = row["pos"]
			_items.append({"pos": p, "label": str(row.get("id", "")), "kind": "npc"})
			xs.append(p.x); ys.append(p.y)
	if is_instance_valid(main.player):
		var pp: Vector2 = main.player.position
		_items.append({"pos": pp, "label": "你", "kind": "player"})
		xs.append(pp.x); ys.append(pp.y)
	if xs.is_empty():
		_min = Vector2.ZERO
		_max = Vector2(100, 100)
	else:
		var lox := xs[0]; var hix := xs[0]
		var loy := ys[0]; var hiy := ys[0]
		for v in xs:
			lox = minf(lox, v); hix = maxf(hix, v)
		for v in ys:
			loy = minf(loy, v); hiy = maxf(hiy, v)
		_min = Vector2(lox, loy) - Vector2(24, 24)
		_max = Vector2(hix, hiy) + Vector2(24, 24)
	queue_redraw()

func _draw() -> void:
	if _items.is_empty():
		return
	var r := get_rect()
	var span := _max - _min
	var scale := minf((r.size.x - 40.0) / maxf(1.0, span.x),
			(r.size.y - 60.0) / maxf(1.0, span.y))
	var origin := Vector2((r.size.x - span.x * scale) * 0.5,
			(r.size.y - span.y * scale) * 0.5 + 16.0)
	draw_rect(Rect2(origin, span * scale), Color(0.96, 0.93, 0.82, 0.55))
	for item in _items:
		var p: Vector2 = origin + (item["pos"] - _min) * scale
		var kind := str(item["kind"])
		var color := Color(0.43, 0.29, 0.16)
		var radius := 2.0
		if kind == "portal":
			color = Color(0.95, 0.58, 0.16)
			radius = 4.0
		elif kind == "npc":
			color = Color(0.24, 0.55, 0.36)
			radius = 3.5
		elif kind == "player":
			color = Color(0.78, 0.18, 0.18)
			radius = 5.0
		draw_circle(p, radius, color)
		# Anchor names go in the side list; drawing all of them on the canvas
		# made the old map unreadable. Only live things get labels here.
		if kind != "anchor" or str(item["label"]) == focus_label:
			draw_string(ui_font, p + Vector2(6.0, -5.0), str(item["label"]),
					HORIZONTAL_ALIGNMENT_LEFT, -1, 11, Color(0.12, 0.09, 0.06))
		if str(item["label"]) == focus_label:
			draw_arc(p, 9.0, 0.0, TAU, 12, Color(0.77, 0.55, 0.21), 2.0)

func legend_rows() -> Array:
	var rows: Array = []
	for item in _items:
		rows.append({
			"label": str(item["label"]),
			"kind": str(item["kind"]),
			"pos": item["pos"],
		})
	return rows

func summary_text() -> String:
	var anchors: Array[String] = []
	var others: Array[String] = []
	for item in _items:
		var kind := str(item["kind"])
		var p: Vector2 = item["pos"]
		var line := "  %s  (%d, %d)" % [str(item["label"]), int(p.x), int(p.y)]
		if kind == "anchor":
			anchors.append(line)
		elif kind == "portal":
			others.append("传送点 " + line)
		elif kind == "npc":
			others.append("村民 " + line)
		elif kind == "player":
			others.append("你 " + line)
	var out: Array[String] = ["锚点（%d）" % anchors.size()]
	for line in anchors:
		out.append(line)
	out.append("")
	for line in others:
		out.append(line)
	return "\n".join(out)
