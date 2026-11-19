extends Node2D
## main.gd — presentation shell for the village.
##
## The map, trees, ores, NPCs and the player are authored by hand in
## scenes/world.tscn (instanced below as $World). This script only wires
## input -> dialog -> Game (Scheme) -> HUD, and enforces walkability.
## All game state lives in the Scheme VM; this script only renders consequences.

const TILE := 16
const TICK_SECONDS := 0.1
const PEOPLE_SECONDS := 1.0
const NPC_SPEED := 40.0
const NIGHT_COLOR := Color(0.46, 0.52, 0.70)
const DAY_COLOR := Color(1.0, 0.98, 0.92)
const WEATHER_NAMES := {
	"sun": "晴", "cloud": "阴", "rain": "雨", "storm": "暴雨", "fog": "雾",
}
const WEATHER_TINTS := {
	"sun": Color.WHITE,
	"cloud": Color(0.88, 0.91, 0.96),
	"rain": Color(0.72, 0.80, 0.92),
	"storm": Color(0.48, 0.56, 0.72),
	"fog": Color(0.88, 0.92, 0.94),
}
const ACTIVITY_NAMES := {
	"smithing": "打铁", "herbs": "晒药", "innkeeping": "看店",
	"lunch": "吃饭", "drinking": "歇脚", "strolling": "闲逛",
	"sleep": "睡觉", "idle": "站着",
}

var map_w := 0
var map_h := 0

var blocked := {}        # Vector2i -> true
const MechHud := preload("res://scripts/mech_hud.gd")
## Optional debug module: loaded by path, so deleting scripts/gm/ ships a
## release build without changing this shell.
const GM_SCRIPT_PATH := "res://scripts/gm/gm_console.gd"
var mech: MechHud = null
var gm: Node = null
var _tick_accumulator := 0.0
var _people_accumulator := 0.0
var _daylight: CanvasModulate = null
var _weather_layer: CanvasLayer = null
var _rain: GPUParticles2D = null
var _fog: ColorRect = null
var _last_weather := ""
var _astar := AStarGrid2D.new()
var _anchors := {}       # anchor name -> world position (from Marker2D nodes)
var _npc_state := {}     # npc id -> {anchor, activity, path, step}
var _portals := {}       # portal id -> world position (Marker2D under $World/Portals)
var _portal_traveling := false
var _portal_wait_release := false
var _scene_path_cache := {}  # map id -> "scenes/xxx.tscn" (populated from Scheme)
var _current_map_id := "village"
var _current_music := ""

# UI lives in main.tscn (HUD + talk panel); the shell only fills text in.
@onready var world: Node2D = $World
@onready var ground: TileMapLayer = $World/Ground
@onready var player: Node2D = $World/Player
@onready var hud_label: Label = $UI/HUD/HUDLabel
@onready var dialog_ui: CanvasLayer = $Dialog

func _ready() -> void:
	var font := _load_cjk_font()
	hud_label.add_theme_font_override("font", font)
	dialog_ui.apply_font(font)
	mech = MechHud.new()
	add_child(mech)
	mech.setup(font)
	_setup_gm(font)
	hud_label.text = "……（启动中）"
	_setup_audio()
	_setup_world()
	_setup_weather()
	Game.snapshot_changed.connect(_refresh_hud)
	if Game.booted:
		_refresh_hud()
		_start_bgm()
		Game.send("game:people")
		_check_anchors()
	else:
		Game.bridge_ready.connect(_on_bridge_ready)
	_maybe_run_headless_demo()

## The world is static now, so it is ready immediately. Only the HUD text
## depends on the Scheme thread (bridge_ready).
func _on_bridge_ready(_llm: bool) -> void:
	_refresh_hud()
	_start_bgm()
	Game.send("game:people")
	_check_anchors()

## Optional GM console: the file is the whole debug module (see scripts/gm/).
func _setup_gm(font: Font) -> void:
	if not ResourceLoader.exists(GM_SCRIPT_PATH):
		return
	var script: Script = load(GM_SCRIPT_PATH)
	if script == null:
		return
	gm = script.new()
	add_child(gm)
	gm.setup(self, font)

## BGM player is created early; the stream is loaded from the catalog once
## the Scheme bridge is up (see _start_bgm). This keeps asset paths in
## data/catalog.scm — changing the track needs no GDScript edit.
func _setup_audio() -> void:
	var bgm := AudioStreamPlayer.new()
	bgm.name = "BGM"
	bgm.volume_db = -10.0
	add_child(bgm)

## Kick off BGM for the starting map once the bridge is up.
func _start_bgm() -> void:
	await _play_music_for_map(_current_map_id)

## Switch the BGM stream if `map_id` declares a different track than the one
## currently playing. No-op when the track is unchanged (e.g. the same peaceful
## theme inside the smithy and out in the village).
func _play_music_for_map(map_id: String) -> void:
	var key_v: Variant = await Game.call_async("game:map-music", [map_id])
	var key := str(key_v) if key_v != null else ""
	if key == "" or key == _current_music:
		return
	_current_music = key
	var path: Variant = await Game.call_async("game:catalog-music", [key])
	if path == null or str(path) == "":
		return
	var theme_stream: AudioStream = load("res://" + str(path))
	if theme_stream == null:
		return
	if theme_stream is AudioStreamOggVorbis:
		theme_stream.loop = true
	var bgm: AudioStreamPlayer = get_node_or_null("BGM")
	if bgm == null:
		return
	bgm.stream = theme_stream
	bgm.play()

## ------------------------------------------------------------------ world --

func _setup_world() -> void:
	var used := ground.get_used_rect()
	map_w = maxi(used.end.x, 1)
	map_h = maxi(used.end.y, 1)
	_build_blocked()
	_setup_anchors()
	_setup_portals()
	_setup_astar()
	player.main = self
	_setup_camera()

## Walkability is authored in the editor:
##   * water tiles carry the TileSet custom data flag "blocked"
##   * anything in the "obstacle" group (trees/bushes) blocks the cell it stands on
##   * NPCs block a small circle around themselves
func _build_blocked() -> void:
	blocked.clear()
	for cell in ground.get_used_cells():
		var data := ground.get_cell_tile_data(cell)
		if data != null and bool(data.get_custom_data("blocked")):
			blocked[cell] = true
	for node in get_tree().get_nodes_in_group("obstacle"):
		if node is Node2D:
			blocked[_foot_cell(node.position)] = true

## Anchor markers (world.tscn / Anchors/*) are the only bridge between the
## semantic names Scheme schedules with and actual world pixels.
func _setup_anchors() -> void:
	_anchors.clear()
	var root := world.get_node_or_null("Anchors")
	if root == null:
		return
	for node in root.get_children():
		if node is Node2D:
			_anchors[str(node.name)] = node.position

## Portal markers (world Portals/*): named like the portal id in data/maps.scm.
## Godot owns the pixel; Scheme only knows (target map, target anchor, label).
func _setup_portals() -> void:
	_portals.clear()
	var root := world.get_node_or_null("Portals")
	if root == null:
		return
	for node in root.get_children():
		if node is Node2D:
			_portals[str(node.name)] = node.position

## Static grid for NPC paths. Four-way movement only (DIAGONAL_MODE_NEVER):
## villagers walk the roads instead of cutting through tree corners.
func _setup_astar() -> void:
	_astar.region = Rect2i(0, 0, map_w, map_h)
	_astar.cell_size = Vector2(TILE, TILE)
	_astar.diagonal_mode = AStarGrid2D.DIAGONAL_MODE_NEVER
	_astar.update()
	for cell in blocked.keys():
		if _astar.is_in_boundsv(cell):
			_astar.set_point_solid(cell, true)

## Cross-check both directions once the bridge is up: every map anchor needs a
## Marker2D, and every Marker2D should be named by the map data.
func _check_anchors() -> void:
	var names: Variant = await Game.call_async("game:map-anchors", [])
	if not (names is Array):
		return
	for n in names:
		if not _anchors.has(str(n)):
			push_warning("[anchors] map anchor has no Marker2D: " + str(n))
	for n in _anchors.keys():
		if not names.has(str(n)):
			push_warning("[anchors] Marker2D unused by map data: " + str(n))

func _npc_by_id(id: String) -> Node2D:
	for npc in get_tree().get_nodes_in_group("npc"):
		if npc.npc_id == id:
			return npc
	return null

## Current "map:anchor" for an NPC straight from the people snapshot, or "".
func _sched_at(id: String) -> String:
	for row in Game.snapshot.get("people", []):
		if row is Array and row.size() >= 2 and str(row[0]) == id:
			return str(row[1])
	return ""

## ---- read-only interface for the optional GM module --------------------------
## The game shell never calls these; they keep the debug tool out of core logic.
func npc_node(id: String) -> Node2D:
	return _npc_by_id(id)

func npc_progress(id: String) -> Dictionary:
	return _npc_state.get(id, {})

func anchor_names() -> Array:
	return _anchors.keys()

func anchor_position(name: String) -> Variant:
	return _anchors.get(name, null)

func current_map_id() -> String:
	return _current_map_id

func map_transitioning() -> bool:
	return _portal_traveling

func _cell_center(cell: Vector2i) -> Vector2:
	return Vector2(cell.x * TILE + TILE * 0.5, cell.y * TILE + TILE * 0.5)

## Cell-centre waypoints from the NPC's cell to the anchor, in world pixels.
## Other villagers' cells are temporarily solid so routes do not start by
## walking straight through someone; they are restored right after the query.
func _path_to_anchor(at: String, from_pos: Vector2, self_id: String = "") -> PackedVector2Array:
	var anchor_name := at.get_slice(":", 1) if at.contains(":") else at
	if not _anchors.has(anchor_name):
		return PackedVector2Array()
	var goal: Vector2 = _anchors[anchor_name]
	var from_cell := Vector2i(floori(from_pos.x / TILE), floori(from_pos.y / TILE))
	var goal_cell := Vector2i(floori(goal.x / TILE), floori(goal.y / TILE))
	if not _astar.is_in_boundsv(from_cell) or _astar.is_point_solid(from_cell):
		return PackedVector2Array()
	if not _astar.is_in_boundsv(goal_cell) or _astar.is_point_solid(goal_cell):
		return PackedVector2Array()
	var reserved: Array[Vector2i] = []
	for other in get_tree().get_nodes_in_group("npc"):
		if other.npc_id == self_id or not other.visible:
			continue
		var cell := Vector2i(floori(other.position.x / TILE), floori(other.position.y / TILE))
		if cell == from_cell:
			continue
		if _astar.is_in_boundsv(cell) and not _astar.is_point_solid(cell):
			_astar.set_point_solid(cell, true)
			reserved.append(cell)
	if goal_cell in reserved:
		# Someone is already standing there; still allow arriving next to them.
		_astar.set_point_solid(goal_cell, false)
		reserved.erase(goal_cell)
	var cells := _astar.get_id_path(from_cell, goal_cell)
	for cell in reserved:
		_astar.set_point_solid(cell, false)
	var path := PackedVector2Array()
	for i in range(1, cells.size()):
		path.append(_cell_center(cells[i]))
	if path.is_empty():
		path.append(goal) # already standing on the anchor
	else:
		path[path.size() - 1] = goal
	return path

## Apply one `game:people` reply: repath only when the anchor changed, so an
## NPC keeps walking when a per-second refresh lands mid-route.
func _apply_people(rows: Array) -> void:
	if gm != null:
		rows = gm.apply_overrides(rows)
	for row in rows:
		if not (row is Array and row.size() == 3) or row[1] == null:
			continue
		var id := str(row[0])
		var at := str(row[1])
		var activity := str(row[2])
		var row_map := at.get_slice(":", 0) if at.contains(":") else _current_map_id
		if row_map != _current_map_id:
			# Scheduled on another map: leave its state alone; _move_npcs hides
			# the node from the live snapshot, and re-entry repath it fresh.
			continue
		var npc := _npc_by_id(id)
		if npc == null:
			continue
		var state: Dictionary = _npc_state.get(id, {})
		if str(state.get("anchor", "")) != at:
			state["anchor"] = at
			state["path"] = _path_to_anchor(at, npc.position, id)
			state["step"] = 0
		state["activity"] = activity
		_npc_state[id] = state

## Walk every villager along its cached path. A villager being talked to holds
## still and resumes afterwards; one whose `sleep` anchor has been reached
## disappears (no interiors yet, so the doorway stands in for the inside).
func _move_npcs(delta: float) -> void:
	for npc in get_tree().get_nodes_in_group("npc"):
		# Map membership comes from the live schedule snapshot, not cached state:
		# a villager whose routine moved to another map is dormant here.
		var at := _sched_at(npc.npc_id)
		var row_map := at.get_slice(":", 0) if at.contains(":") else _current_map_id
		if row_map != _current_map_id:
			npc.visible = false
			npc.set_walking(false)
			continue
		var state: Dictionary = _npc_state.get(npc.npc_id, {})
		if state.is_empty():
			continue
		var activity := str(state.get("activity", "idle"))
		var path: PackedVector2Array = state.get("path", PackedVector2Array())
		var step: int = int(state.get("step", 0))
		var talking: bool = dialog_ui.is_open and dialog_ui.current_npc_id() == npc.npc_id
		if step < path.size() and not talking:
			var target := path[step]
			var d: Vector2 = target - npc.position
			var travel := NPC_SPEED * delta
			if d.length() <= travel:
				npc.position = target
				step += 1
				state["step"] = step
			else:
				npc.position += d.normalized() * travel
				npc.face_dir(d)
			npc.set_walking(true)
		else:
			npc.set_walking(false)
		var hide := step >= path.size() and activity == "sleep"
		if hide:
			# Only vanish once actually home. A sleep anchor that is unknown or
			# unreachable yields an empty path, and hiding immediately would make
			# villagers pop out of existence wherever they happen to stand.
			var home: Variant = anchor_position(str(state.get("anchor", "")).get_slice(":", 1))
			hide = home != null and npc.position.distance_to(home) < 12.0
		npc.visible = not hide

## -------------------------------------------------------------- map travel --
## Portals are walkable spots; stepping onto one asks Scheme where it leads and
## swaps the whole map instance. The old map's villagers are simply unloaded
## (dormant); on the new map each villager is placed at its schedule anchor.

func _enter_portal(portal_id: String) -> void:
	if dialog_ui.is_open:
		dialog_ui.close()
	var result: Variant = await Game.call_async("game:enter-portal", [portal_id])
	if not (result is Array and result.size() >= 2):
		push_warning("[portal] bad reply for " + portal_id)
		_portal_traveling = false
		_portal_wait_release = true
		return
	var target_map := str(result[0])
	var target_at := str(result[1])
	await _switch_map(target_map, target_at)
	# Do not bounce straight back while a direction is still held. Releasing the
	# movement keys rearms portals; no timing-dependent cooldown is involved.
	_portal_wait_release = true
	_portal_traveling = false

## Replace the live map instance with `map_id`'s scene and drop the player at
## `at` ("map:anchor"). Rebuilds all per-map state (walkability, anchors,
## portals, nav grid, camera) and re-seeds NPC positions from the schedule.
func _switch_map(map_id: String, at: String) -> void:
	_current_map_id = map_id
	var scene_path: String = _scene_path_cache.get(map_id, "")
	if scene_path == "":
		scene_path = str(await Game.call_async("game:map-scene", [map_id]))
		if scene_path == "":
			push_error("[map] no scene declared for " + map_id)
			return
		_scene_path_cache[map_id] = scene_path
	if is_instance_valid(world):
		# Group membership must end now, not at the frame's deferred free: the new
		# map rebuilds collision/NPC state from scene-tree groups immediately.
		remove_child(world)
		world.queue_free()
	var packed: PackedScene = load("res://" + scene_path)
	if packed == null:
		push_error("[map] cannot load scene " + scene_path)
		return
	var new_world: Node2D = packed.instantiate()
	new_world.name = "World"
	add_child(new_world)
	world = new_world
	ground = new_world.get_node_or_null("Ground")
	player = new_world.get_node_or_null("Player")
	_setup_world()
	# Drop the player at the destination anchor (e.g. "smithy:door").
	var anchor_name := at.get_slice(":", 1) if at.contains(":") else at
	if player != null and _anchors.has(anchor_name):
		player.position = _anchors[anchor_name]
	_place_npcs_on_entry()
	_check_anchors()
	Game.send("game:people")
	await _play_music_for_map(map_id)

## On entering a map, teleport every villager whose schedule is here onto their
## anchor and seed their state so they stay put until the schedule changes.
## Anyone scheduled elsewhere is hidden by _move_npcs.
func _place_npcs_on_entry() -> void:
	for row in Game.snapshot.get("people", []):
		if not (row is Array and row.size() == 3) or row[1] == null:
			continue
		var id := str(row[0])
		var at := str(row[1])
		var row_map := at.get_slice(":", 0) if at.contains(":") else _current_map_id
		if row_map != _current_map_id:
			continue
		var npc := _npc_by_id(id)
		if npc == null:
			continue
		var anchor_name := at.get_slice(":", 1) if at.contains(":") else at
		npc.visible = _anchors.has(anchor_name)
		if _anchors.has(anchor_name):
			npc.position = _anchors[anchor_name]
		_npc_state[id] = {
			"anchor": at,
			"activity": str(row[2]),
			"path": PackedVector2Array(),
			"step": 0,
		}

func _setup_camera() -> void:
	var cam: Camera2D = player.get_node_or_null("Camera2D")
	if cam == null:
		cam = Camera2D.new()
		cam.name = "Camera2D"
		player.add_child(cam)
	var z := _fit_zoom()
	cam.zoom = Vector2(z, z)
	cam.limit_left = 0
	cam.limit_top = 0
	cam.limit_right = map_w * TILE
	cam.limit_bottom = map_h * TILE
	cam.position_smoothing_enabled = false

## fitZoom: the view always shows at least 20 x 13 tiles.
func _fit_zoom() -> float:
	var vp := get_viewport().get_visible_rect().size
	return clampf(floorf(minf(vp.y / (TILE * 13.0), vp.x / (TILE * 20.0))), 2.0, 4.0)

## Reads the bridge's cached snapshot only — the main thread never touches
## the Scheme VM.
func _refresh_hud() -> void:
	if hud_label == null:
		return
	var weather := str(Game.snapshot.get("weather", "sun"))
	var hint := ""
	if not (mech != null and mech.is_showing()):
		hint = "F1 机制   F5 热重载" + ("   F8 GM 指令" if gm != null else "")
	hud_label.text = "第 %d 天  %02d:%02d   天气：%s\n%s\n%s\n铁矿石背包 x%d   %s\n%s" % [
			int(Game.snapshot.get("day", 1)),
			int(Game.snapshot.get("hour", 8)),
			int(Game.snapshot.get("minute", 0)),
			str(WEATHER_NAMES.get(weather, weather)),
			str(Game.snapshot.get("quest_text", "")),
			_activity_line(),
			int(Game.snapshot.get("carried", 0)),
			("LLM：本地推理" if Game.use_llm else "LLM：无模型·预置台词"),
			hint]
	_refresh_weather()

## Compact schedule readout: "老王：打铁   陈婆：晒药   张掌柜：看店".
func _activity_line() -> String:
	var parts: Array = []
	for row in Game.snapshot.get("people", []):
		if not (row is Array and row.size() == 3):
			continue
		var npc := _npc_by_id(str(row[0]))
		var who: String = npc.display_name if npc != null else str(row[0])
		var state: Dictionary = _npc_state.get(str(row[0]), {})
		var activity := str(state.get("activity", row[2]))
		parts.append("%s：%s" % [who, str(ACTIVITY_NAMES.get(activity, activity))])
	return "   ".join(parts)

## ----------------------------------------------------------- time / weather --

func _setup_weather() -> void:
	_daylight = CanvasModulate.new()
	_daylight.name = "Daylight"
	add_child(_daylight)

	_weather_layer = CanvasLayer.new()
	_weather_layer.name = "WeatherFX"
	_weather_layer.layer = 5 # above the world, below HUD and dialog (layer 10)
	add_child(_weather_layer)

	_fog = ColorRect.new()
	_fog.name = "Fog"
	_fog.color = Color(0.72, 0.80, 0.86, 0.24)
	_fog.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_weather_layer.add_child(_fog)

	_rain = GPUParticles2D.new()
	_rain.name = "Rain"
	_rain.texture = _make_rain_texture()
	_rain.process_material = _make_rain_material()
	_rain.lifetime = 1.4
	_rain.preprocess = 1.0
	_rain.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	_rain.emitting = false
	_weather_layer.add_child(_rain)

	get_viewport().size_changed.connect(_layout_weather)
	_layout_weather()
	_refresh_weather()

func _make_rain_texture() -> GradientTexture2D:
	var gradient := Gradient.new()
	gradient.set_color(0, Color(0.75, 0.86, 1.0, 0.0))
	gradient.set_color(1, Color(0.75, 0.86, 1.0, 0.8))
	var texture := GradientTexture2D.new()
	texture.gradient = gradient
	texture.width = 2
	texture.height = 14
	texture.fill_from = Vector2.ZERO
	texture.fill_to = Vector2(0.0, 1.0)
	return texture

func _make_rain_material() -> ParticleProcessMaterial:
	var material := ParticleProcessMaterial.new()
	material.direction = Vector3(0.18, 1.0, 0.0).normalized()
	material.spread = 3.0
	material.initial_velocity_min = 420.0
	material.initial_velocity_max = 540.0
	material.gravity = Vector3(40.0, 180.0, 0.0)
	material.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_BOX
	material.emission_box_extents = Vector3(640.0, 4.0, 0.0)
	material.scale_min = 0.8
	material.scale_max = 1.3
	return material

func _layout_weather() -> void:
	if _rain == null or _fog == null:
		return
	var size := get_viewport().get_visible_rect().size
	_fog.size = size
	_rain.position = Vector2(size.x * 0.5, -16.0)
	_rain.visibility_rect = Rect2(-size.x, -64.0, size.x * 3.0, size.y + 256.0)
	var material := _rain.process_material as ParticleProcessMaterial
	if material != null:
		material.emission_box_extents = Vector3(size.x * 0.65, 4.0, 0.0)

func _refresh_weather() -> void:
	if _daylight == null or _rain == null or _fog == null:
		return
	var weather := str(Game.snapshot.get("weather", "sun"))
	var hour := float(Game.snapshot.get("hour", 8)) \
			+ float(Game.snapshot.get("minute", 0)) / 60.0
	var tint: Color = WEATHER_TINTS.get(weather, Color.WHITE)
	_daylight.color = _daylight_color(hour) * tint
	_fog.visible = weather == "fog"
	if weather == _last_weather:
		return
	_last_weather = weather
	var raining := weather == "rain" or weather == "storm"
	_rain.amount = 420 if weather == "storm" else 180
	_rain.speed_scale = 1.3 if weather == "storm" else 1.0
	_rain.emitting = raining
	_rain.visible = raining

func _daylight_color(hour: float) -> Color:
	if hour < 5.0 or hour >= 20.0:
		return NIGHT_COLOR
	if hour < 8.0:
		return NIGHT_COLOR.lerp(DAY_COLOR, (hour - 5.0) / 3.0)
	if hour < 17.0:
		return DAY_COLOR
	return DAY_COLOR.lerp(NIGHT_COLOR, (hour - 17.0) / 3.0)

## ------------------------------------------------------------------ input --

## GM console toggle. `_input` (not `_unhandled_input`) so the key still closes
## the console while its LineEdit has focus.
func _input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo:
		if event.keycode == KEY_F8:
			if gm != null:
				gm.toggle()
				get_viewport().set_input_as_handled()

func _unhandled_input(event: InputEvent) -> void:
	if gm != null and gm.is_open:
		return
	if event is InputEventKey and event.pressed and not event.echo:
		if event.keycode == KEY_F1:
			if mech != null:
				mech.toggle_visible()
			get_viewport().set_input_as_handled()
			return
		if event.keycode == KEY_F5:
			# Fire-and-forget: state and HUD refresh when the reply lands.
			# An open dialog holds stale menus, so close it first.
			if dialog_ui.is_open:
				dialog_ui.close()
			Game.reload_data()
			get_viewport().set_input_as_handled()
			return
	if event.is_action_pressed("interact") and not dialog_ui.is_open:
		var npc := _nearest_npc(player.position, 30.0)
		if npc != null:
			dialog_ui.open_npc(npc)

func _exit_tree() -> void:
	# Release the grid explicitly: it is the one RefCounted the scene owns.
	_astar = null

func _process(delta: float) -> void:
	_maybe_capture_frame()
	var rate: float = gm.speed() if gm != null else 1.0
	if Game.booted and Game.vm_error == "" and rate > 0.0:
		_tick_accumulator += delta
		var tick_step := TICK_SECONDS / rate
		while _tick_accumulator >= tick_step:
			_tick_accumulator -= tick_step
			Game.send("game:tick")
		_people_accumulator += delta
		while _people_accumulator >= PEOPLE_SECONDS:
			_people_accumulator -= PEOPLE_SECONDS
			Game.send("game:people")
	_apply_people(Game.snapshot.get("people", []))
	_move_npcs(delta)
	if player != null and not _portal_traveling:
		if _portal_wait_release:
			if not _movement_held():
				_portal_wait_release = false
		else:
			var player_cell := Vector2i(floori(player.position.x / TILE), floori(player.position.y / TILE))
			for pid in _portals.keys():
				var portal_cell := Vector2i(floori(_portals[pid].x / TILE), floori(_portals[pid].y / TILE))
				if player_cell == portal_cell:
					_portal_traveling = true
					_enter_portal(pid)
					break
	# walk-over ore pickup
	for ore in get_tree().get_nodes_in_group("ore"):
		if not is_instance_valid(ore) or player == null:
			continue
		if player.position.distance_to(ore.position) < 10.0:
			ore.queue_free()
			# Fire-and-forget; the HUD updates when the reply lands.
			Game.send("game:take-ore")

func _movement_held() -> bool:
	return Input.is_action_pressed("move_left") or Input.is_action_pressed("move_right") \
		or Input.is_action_pressed("move_up") or Input.is_action_pressed("move_down")

func _nearest_npc(from: Vector2, radius: float) -> Node2D:
	var best: Node2D = null
	var best_d := radius
	for npc in get_tree().get_nodes_in_group("npc"):
		if not npc.visible:
			continue
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
		if npc.visible and npc.position.distance_to(world_pos) < 9.0:
			return false
	return true

## Trees/bushes are anchored at the bottom edge of their cell, so the tile the
## player collides with is the one just above the node origin.
func _foot_cell(pos: Vector2) -> Vector2i:
	return Vector2i(floori(pos.x / TILE), floori((pos.y - 1.0) / TILE))

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
	_maybe_start_recording()
	_run_headless_demo(npc_id, OS.get_environment("THEFORD_DEMO_TOPICS"),
			snap_dir, OS.get_environment("THEFORD_DEMO_QUIT") == "1")

## ---------------------------------------------------------------- recording --
## Engine-side screen recording: no OS screen-recording permission needed, the
## demo saves JPEG frames straight from the viewport, ffmpeg assembles them.
##   THEFORD_RECORD_DIR=dir          frame directory (required to record)
##   THEFORD_RECORD_START=4.6        seconds after launch to start (default
##                                   4.6 = dialog about to open)
##   THEFORD_RECORD_DURATION=17.6    capture length (covers ask + cache replay)
##   THEFORD_RECORD_FPS=24           pacing; 1920-wide JPEGs, q92
var _rec_dir := ""
var _rec_next_ms := 0
var _rec_stop_ms := 0
var _rec_step_ms := 0
var _rec_i := 0
var _rec_done := false

func _maybe_start_recording() -> void:
	_rec_dir = OS.get_environment("THEFORD_RECORD_DIR")
	if _rec_dir == "":
		return
	var start_s := 4.6
	var dur_s := 17.6
	var fps := 24
	if OS.get_environment("THEFORD_RECORD_START") != "":
		start_s = float(OS.get_environment("THEFORD_RECORD_START"))
	if OS.get_environment("THEFORD_RECORD_DURATION") != "":
		dur_s = float(OS.get_environment("THEFORD_RECORD_DURATION"))
	if OS.get_environment("THEFORD_RECORD_FPS") != "":
		fps = maxi(1, int(float(OS.get_environment("THEFORD_RECORD_FPS"))))
	_rec_step_ms = int(1000.0 / fps)
	var now := Time.get_ticks_msec()
	_rec_next_ms = now + int(start_s * 1000.0)
	_rec_stop_ms = now + int((start_s + dur_s) * 1000.0)
	DirAccess.make_dir_recursive_absolute(_rec_dir)
	print("[rec] start=%.1fs dur=%.1fs fps=%d -> %s" % [start_s, dur_s, fps, _rec_dir])

func _maybe_capture_frame() -> void:
	if _rec_done:
		return
	var now := Time.get_ticks_msec()
	if now < _rec_next_ms:
		return
	if now > _rec_stop_ms:
		_rec_done = true
		print("[rec] done: %d frames" % _rec_i)
		return
	var vp_tex := get_viewport().get_texture()
	var img: Image = vp_tex.get_image() if vp_tex != null else null
	if img == null:
		# --headless has no framebuffer; recording needs a windowed run.
		_rec_done = true
		return
	# Downscale the retina viewport; 1920 keeps 1080p-class upload quality.
	if img.get_width() > 1920:
		img.resize(1920,
				int(img.get_height() * 1920.0 / img.get_width()),
				Image.INTERPOLATE_LANCZOS)
	# JPEG saving fails on this Godot build (quality errors, empty files);
	# PNG is proven via the snapshot hook, just heavier on disk.
	img.save_png("%s/f%06d.png" % [_rec_dir, _rec_i])
	_rec_i += 1
	_rec_next_ms = now + _rec_step_ms

func _headless_snap(snap_dir: String) -> void:
	if snap_dir == "":
		return
	var vp_tex := get_viewport().get_texture()
	var img: Image = vp_tex.get_image() if vp_tex != null else null
	if img == null:
		# --headless has no framebuffer; snapshots need a windowed run.
		return
	_demo_shot_i += 1
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
