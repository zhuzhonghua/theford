extends Node2D
## main.gd — presentation shell for the village.
## Builds the tilemap from Ninja Adventure (CC0) PNGs, spawns the player,
## NPCs and ore pickups, wires E-key input -> dialog -> Game (Scheme) -> HUD.
## All state lives in the Scheme VM; this script only renders consequences.

const TILE := 16

# The tile map itself is generated in Scheme (scheme/game/map.scm): the map is
# code-generated, not a hand-drawn grid. This shell only turns the returned
# rows (T tree, t bush, . grass, = road, ~ water) into tiles and sprites.

# npc_id -> [tile_pos, sheet_path, display_name]
const NPC_DEFS := {
	"smith":      [Vector2i(22, 12), "res://assets/na/Actor/Character/Villager/SpriteSheet.png",  "老王"],
	"apothecary": [Vector2i(10, 7),  "res://assets/na/Actor/Character/Woman/SpriteSheet.png",     "陈婆"],
	"innkeeper":  [Vector2i(30, 17), "res://assets/na/Actor/Character/Villager2/SpriteSheet.png", "张掌柜"],
}

var map_rows := PackedStringArray()
var map_w := 0
var map_h := 0

var blocked := {}        # Vector2i -> true
var ores_left := {}      # Vector2i -> Sprite2D

# UI lives in main.tscn (HUD + talk panel); the shell only fills text in.
@onready var world: Node2D = $World
@onready var hud_label: Label = $UI/HUD/HUDLabel
@onready var dialog_ui: CanvasLayer = $Dialog

var player: Node2D

func _ready() -> void:
	var font := _load_cjk_font()
	hud_label.add_theme_font_override("font", font)
	dialog_ui.apply_font(font)
	hud_label.text = "……（启动中）"
	_setup_audio()
	Game.snapshot_changed.connect(_refresh_hud)
	if Game.booted:
		_on_bridge_ready(Game.use_llm)
	else:
		Game.bridge_ready.connect(_on_bridge_ready)
	_maybe_run_headless_demo()

## The logic thread boots asynchronously (scheme load + optional model load),
## so the world is built when the bridge reports ready, not in _ready().
## BGM: Ninja Adventure CC0 village theme, wired straight from the import.
## Godot 4 plays Ogg Vorbis natively; no audio bus setup needed for the slice.
func _setup_audio() -> void:
	var theme_stream: AudioStream = load("res://assets/na/Audio/Musics/4 - Village.ogg")
	if theme_stream == null:
		return
	if theme_stream is AudioStreamOggVorbis:
		theme_stream.loop = true
	var bgm := AudioStreamPlayer.new()
	bgm.name = "BGM"
	bgm.stream = theme_stream
	bgm.volume_db = -10.0
	add_child(bgm)
	bgm.play()

func _on_bridge_ready(_llm: bool) -> void:
	map_rows = Game.map_rows
	if map_rows.is_empty():
		push_error("[TheFord] Scheme 没有返回地图（game:map-rows）")
		return
	_build_world()
	_refresh_hud()

## ------------------------------------------------------------------ world --

func _build_world() -> void:
	map_w = map_rows[0].length()
	map_h = map_rows.size()

	var ts := TileSet.new()
	ts.tile_size = Vector2i(TILE, TILE)
	var ground := TileSetAtlasSource.new()
	ground.texture = load("res://assets/na/Backgrounds/Tilesets/TilesetFloor.png")
	ground.texture_region_size = Vector2i(TILE, TILE)
	var water := TileSetAtlasSource.new()
	water.texture = load("res://assets/na/Backgrounds/Tilesets/TilesetWater.png")
	water.texture_region_size = Vector2i(TILE, TILE)
	ts.add_source(ground, 0)
	ts.add_source(water, 1)

	var g_layer := _layer(ts, "Ground", 0)

	for y in map_h:
		for x in map_w:
			var cell := Vector2i(x, y)
			match map_rows[y][x]:
				"T", "t":
					_set_cell(g_layer, cell, ground, 0, _grass(cell))
					blocked[cell] = true
				"~":
					_set_cell(g_layer, cell, water, 1, Vector2i(1, 1))
					blocked[cell] = true
				"=":
					_set_cell(g_layer, cell, ground, 0, Vector2i(0, 5))
				_:
					_set_cell(g_layer, cell, ground, 0, _grass(cell))

	_spawn_trees()
	_spawn_ores()
	_spawn_player()
	_spawn_npcs()

## TilesetNature stores whole objects, not uniform tiles, so a tree is one
## 48x48 region sprite standing on its cell instead of a TileMapLayer cell.
const TREE_REGION := Rect2(0, 32, 48, 48)

func _spawn_trees() -> void:
	var tex: Texture2D = load("res://assets/na/Backgrounds/Tilesets/TilesetNature.png")
	for y in map_h:
		for x in map_w:
			var c := map_rows[y][x]
			if c != "T" and c != "t":
				continue
			var s := 1.0 if c == "T" else 0.62
			var tree := Sprite2D.new()
			tree.texture = tex
			tree.region_enabled = true
			tree.region_rect = TREE_REGION
			tree.centered = false
			tree.offset = Vector2(-24, -48)  # feet at the node origin
			tree.scale = Vector2(s, s)
			tree.position = Vector2(x * TILE + TILE * 0.5, y * TILE + TILE)
			world.add_child(tree)

func _layer(ts: TileSet, name: String, z: int) -> TileMapLayer:
	var l := TileMapLayer.new()
	l.name = name
	l.tile_set = ts
	l.z_index = z
	world.add_child(l)
	return l

# Alternate between the two solid grass tones for texture.
func _grass(cell: Vector2i) -> Vector2i:
	return Vector2i(0, 12) if (cell.x + cell.y) % 5 == 0 else Vector2i(11, 12)

func _set_cell(layer: TileMapLayer, cell: Vector2i, src: TileSetAtlasSource,
		source_id: int, coords: Vector2i) -> void:
	# get_tile_at_coords() returns (-1, -1) when the tile is missing, not null.
	if not src.has_tile(coords):
		src.create_tile(coords)
	layer.set_cell(cell, source_id, coords)

func _spawn_ores() -> void:
	for pos in [Vector2i(4, 3), Vector2i(38, 7), Vector2i(41, 22)]:
		if blocked.get(pos, false):
			continue
		var ore := Sprite2D.new()
		ore.texture = load("res://assets/na/Items/Resource/Rock.png")
		ore.position = _px(pos)
		ore.z_index = 0
		var tw := ore.create_tween().set_loops()
		tw.tween_property(ore, "position:y", ore.position.y - 3.0, 0.7) \
			.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
		tw.tween_property(ore, "position:y", ore.position.y, 0.7) \
			.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
		ore.set_meta("tile", pos)
		world.add_child(ore)
		ores_left[pos] = ore

func _spawn_player() -> void:
	player = preload("res://scripts/player.gd").new()
	player.texture = load("res://assets/na/Actor/Character/NinjaRed/SpriteSheet.png")
	player.position = _px(Vector2i(24, 17))
	player.z_index = 0
	player.main = self
	world.add_child(player)

	var cam := Camera2D.new()
	var z := _fit_zoom()
	cam.zoom = Vector2(z, z)
	cam.limit_left = 0
	cam.limit_top = 0
	cam.limit_right = map_w * TILE
	cam.limit_bottom = map_h * TILE
	cam.position_smoothing_enabled = false
	player.add_child(cam)

## fitZoom: the view always shows at least 20 x 13 tiles.
func _fit_zoom() -> float:
	var vp := get_viewport().get_visible_rect().size
	return clampf(floorf(minf(vp.y / (TILE * 13.0), vp.x / (TILE * 20.0))), 2.0, 4.0)

func _spawn_npcs() -> void:
	var npc_script := preload("res://scripts/npc.gd")
	for npc_id in NPC_DEFS:
		var def: Array = NPC_DEFS[npc_id]
		var npc: Node2D = npc_script.new()
		npc.npc_id = npc_id
		npc.display_name = def[2]
		npc.texture = load(def[1])
		npc.position = _px(def[0])
		npc.z_index = 0
		world.add_child(npc)

## Reads the bridge's cached snapshot only — the main thread never touches
## the Scheme VM.
func _refresh_hud() -> void:
	if hud_label == null:
		return
	hud_label.text = "%s\n铁矿石背包 x%d   %s" % [
			str(Game.snapshot.get("quest_text", "")),
			int(Game.snapshot.get("carried", 0)),
			("LLM：本地推理" if Game.use_llm else "LLM：无模型·预置台词")]

## ------------------------------------------------------------------ input --

func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("interact") and not dialog_ui.is_open:
		var npc := _nearest_npc(player.position, 30.0)
		if npc != null:
			dialog_ui.open_npc(npc)

func _process(_delta: float) -> void:
	# walk-over ore pickup (copy keys: we may erase during the loop)
	for pos in ores_left.keys().duplicate():
		var ore: Sprite2D = ores_left.get(pos)
		if ore and player and player.position.distance_to(ore.position) < 10.0:
			ores_left.erase(pos)
			ore.queue_free()
			# Fire-and-forget; the HUD updates when the reply lands.
			Game.send("game:take-ore")

func _nearest_npc(from: Vector2, radius: float) -> Node2D:
	var best: Node2D = null
	var best_d := radius
	for npc in get_tree().get_nodes_in_group("npc"):
		var d: float = npc.position.distance_to(from)
		if d < best_d:
			best_d = d
			best = npc
	return best

## Called by player.gd: blocked tile grid + NPCs as round obstacles.
func is_walkable(world_pos: Vector2) -> bool:
	var tile := Vector2i(floori(world_pos.x / TILE), floori(world_pos.y / TILE))
	if tile.x < 0 or tile.y < 0 or tile.x >= map_w or tile.y >= map_h:
		return false
	if blocked.get(tile, false):
		return false
	for npc in get_tree().get_nodes_in_group("npc"):
		if npc.position.distance_to(world_pos) < 9.0:
			return false
	return true

func _px(cell: Vector2i) -> Vector2:
	return Vector2(cell.x * TILE + TILE * 0.5, cell.y * TILE + TILE * 0.5)

## ------------------------------------------------------------------ debug --
## Scripted demo for recordings/screenshots (no-ops when the env is unset):
##   THEFORD_DEMO_NPC=smith           teleport to the NPC and open the dialog
##   THEFORD_DEMO_TOPICS=village      topic keys to ask, comma-separated;
##                                    the second ask exercises the learned cache
##   THEFORD_SNAPSHOT_DIR=/tmp/x      write numbered PNG shots at key beats
##   THEFORD_DEMO_QUIT=1              quit when the demo ends
func _maybe_run_headless_demo() -> void:
	var npc_id := OS.get_environment("THEFORD_DEMO_NPC")
	var snap_dir := OS.get_environment("THEFORD_SNAPSHOT_DIR")
	if npc_id == "" and snap_dir == "":
		return
	_run_headless_demo(npc_id, OS.get_environment("THEFORD_DEMO_TOPICS"),
			snap_dir, OS.get_environment("THEFORD_DEMO_QUIT") == "1")

func _headless_snap(snap_dir: String) -> void:
	if snap_dir == "":
		return
	_demo_shot_i += 1
	var img := get_viewport().get_texture().get_image()
	img.save_png("%s/shot-%d.png" % [snap_dir, _demo_shot_i])

var _demo_shot_i := 0

func _run_headless_demo(npc_id: String, topics_csv: String, snap_dir: String,
		quit_when_done: bool) -> void:
	var topics: Array = []
	if topics_csv != "":
		for t in topics_csv.split(","):
			topics.append(t.strip_edges())
	# world beat
	await get_tree().create_timer(3.0).timeout
	_headless_snap(snap_dir)
	if npc_id == "":
		if quit_when_done:
			get_tree().quit()
		return
	var npc: Node2D = null
	for n in get_tree().get_nodes_in_group("npc"):
		if n.npc_id == npc_id:
			npc = n
			break
	if npc == null:
		push_error("[TheFord] demo npc not found: " + npc_id)
		return
	# greeting beat
	await get_tree().create_timer(1.0).timeout
	player.position = npc.position + Vector2(20, 0)
	dialog_ui.close()
	dialog_ui.open_npc(npc)
	await get_tree().create_timer(1.5).timeout
	_headless_snap(snap_dir)
	# one beat per topic: ask, let the LLM answer, then ask again (cache hit)
	for t in topics:
		dialog_ui._choose(t)
		await get_tree().create_timer(10.0).timeout
		_headless_snap(snap_dir)
		dialog_ui.close()
		await get_tree().create_timer(1.0).timeout
		dialog_ui.open_npc(npc)
		await get_tree().create_timer(1.0).timeout
		dialog_ui._choose(t)
		await get_tree().create_timer(5.0).timeout
		_headless_snap(snap_dir)
		await get_tree().create_timer(1.0).timeout
	if quit_when_done:
		get_tree().quit()

func _load_cjk_font() -> Font:
	# Bundled pixel CJK font: Fusion Pixel 12px proportional zh-Hans (SIL OFL,
	# see assets/fonts/OFL.txt). Distributed with the game, no system dependency.
	var bundled: Font = load("res://assets/fonts/fusion-pixel-12px-proportional-zh_hans.otf.woff2")
	if bundled != null:
		return bundled
	# Fallback for development: macOS system CJK font.
	for path in ["/System/Library/Fonts/STHeiti Light.ttc",
			"/System/Library/Fonts/STHeiti Medium.ttc",
			"/System/Library/Fonts/PingFang.ttc"]:
		if FileAccess.file_exists(path):
			var f := FontFile.new()
			f.load_dynamic_font(path)
			return f
	return ThemeDB.fallback_font
