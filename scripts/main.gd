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
const TREE_TEXTURE := "res://assets/na/Backgrounds/Tilesets/TilesetNature.png"
const TREE_REGION := Rect2(0, 32, 48, 48)
const LOG_REGION := Rect2(208, 208, 32, 16)
const NIGHT_COLOR := Color(0.46, 0.52, 0.70)
const DAY_COLOR := Color(1.0, 0.98, 0.92)
## What the player picks up by walking over it: group -> item type.
const PICKUP_REACH := 2 * TILE
const PICKUP_RETRY_MS := 1000
const PICKUP_TYPES := {"ore": "item/material/ore", "log": "item/material/log"}
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
const BagPanel := preload("res://scripts/bag_panel.gd")
const ContainerPanel := preload("res://scripts/container_panel.gd")
## Optional debug module: loaded by path, so deleting scripts/gm/ ships a
## release build without changing this shell.
const GM_SCRIPT_PATH := "res://scripts/gm/gm_console.gd"
var mech: MechHud = null
var bag_ui: BagPanel = null
var container_ui: ContainerPanel = null
var gm: Node = null
var _tick_accumulator := 0.0
var _people_accumulator := 0.0
var _effects_accumulator := 0.0
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
var _entities := {}         # entity-id string -> Node2D node reference
var _entity_types := {}     # entity-id string -> type id ("fixture/tree", ...)
var last_used_id := ""      # entity targeted by the most recent F, for tests
var _log_history: Array[String] = []
var _last_log := ""
var _verb_hint := ""
var _effects_polling := false
var _reloading := false   # ignore a second F5 while the first reload is in flight

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
	bag_ui = BagPanel.new()
	add_child(bag_ui)
	bag_ui.setup(font)
	container_ui = ContainerPanel.new()
	add_child(container_ui)
	container_ui.setup(font)
	container_ui.close_requested.connect(_close_container)
	_register_effect_handlers()
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
		Game.send("game:bag")
		_check_anchors()
		_maybe_autoplay_acceptance()
	else:
		Game.bridge_ready.connect(_on_bridge_ready)
	_maybe_run_headless_demo()

## Dev hook (GM module only): THEFORD_ACCEPTANCE=<name> auto-plays a script
## once the Scheme bridge is up. Works headless, so a terminal run exercises
## the same steps the F8 console would.
func _maybe_autoplay_acceptance() -> void:
	var script_name := OS.get_environment("THEFORD_ACCEPTANCE")
	if script_name == "" or gm == null:
		return
	gm.autoplay(script_name)

## The world is static now, so it is ready immediately. Only the HUD text
## depends on the Scheme thread (bridge_ready).
func _on_bridge_ready(_llm: bool) -> void:
	_refresh_hud()
	_start_bgm()
	Game.send("game:people")
	Game.send("game:bag")
	_check_anchors()
	_maybe_autoplay_acceptance()

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
	_register_scene_entities()

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

## ---- entity registry -------------------------------------------------------
## Godot scans the active scene for things the rule engine should know about
## (trees, signs, chests, NPCs, ...) and sends a flat list to Scheme via
## `game:register-entities`. Entity ids are generated here so Scheme never
## needs to parse Godot node paths — it just uses symbols like
## "tree:village:0" or "npc:smith". The bridge fires once per scene load
## (at the end of _setup_world) so reloading doesn't accumulate duplicates.

func _register_scene_entities() -> void:
	_entities.clear()
	_entity_types.clear()
	var rows: Array = []
	# Trees: Sprite2D nodes in the "obstacle" group. Health comes from the type
	# data, so the row carries only per-instance tags/props (empty here).
	var tree_idx: int = 0
	for node in get_tree().get_nodes_in_group("obstacle"):
		if node is Sprite2D:
			var eid := "tree:%s:%d" % [_current_map_id, tree_idx]
			_entities[eid] = node
			_entity_types[eid] = "fixture/tree"
			rows.append([eid, "fixture/tree", [], []])
			tree_idx += 1
	# Authored interactables (signs, chests) carry their type and per-instance
	# props as scene metadata; the rule engine receives them as plain data.
	var inter_idx: int = 0
	for node in get_tree().get_nodes_in_group("interactable"):
		if not (node is Node2D):
			continue
		var etype := str(node.get_meta("entity_type", ""))
		if etype == "":
			continue
		var eid := "%s:%s:%d" % [etype.replace("/", "-"), _current_map_id, inter_idx]
		inter_idx += 1
		_entities[eid] = node
		_entity_types[eid] = etype
		var tags: Array = node.get_meta("entity_tags", [])
		var props: Array = node.get_meta("entity_props", [])
		rows.append([eid, etype, tags, props])
	# NPCs — already known to Scheme via people.scm; add the entity layer
	# so rules can match "actor/person/villager" as a host type.
	for npc in get_tree().get_nodes_in_group("npc"):
		if npc is Node2D and npc.has_method("get") and str(npc.get("npc_id")) != "":
			var eid := "npc:" + str(npc.get("npc_id"))
			_entities[eid] = npc
			_entity_types[eid] = "actor/person/villager"
			rows.append([eid, "actor/person/villager", ["person"], []])
	if rows.size() == 0:
		return
	# Fire-and-forget: Scheme has its own registry, nothing to absorb.
	Game.send("game:register-entities", [rows])

## Nearest entity whose registered type is one of `types`, within `max_dist`.
## Returns [entity-id, node] or [null, null].
func _nearest_of_types(pos: Vector2, max_dist: float, types: Array) -> Array:
	var best_id := ""
	var best: Node2D = null
	var best_d: float = max_dist
	for eid in _entities.keys():
		if not types.has(str(_entity_types.get(eid, ""))):
			continue
		var node: Variant = _entities[eid]
		if not is_instance_valid(node):
			continue
		var d: float = pos.distance_to(node.position)
		if d < best_d:
			best_d = d
			best_id = str(eid)
			best = node
	if best != null:
		return [best_id, best]
	return [null, null]

## Find the nearest entity to `pos` within `max_dist`. Skips entities whose
## node has been freed. Returns (entity-id, node) or (null, null).
func _nearest_entity(pos: Vector2, max_dist: float) -> Array:
	var best_id := ""
	var best: Node2D = null
	var best_d: float = max_dist
	for eid in _entities.keys():
		var node: Variant = _entities[eid]
		if not is_instance_valid(node):
			continue
		var d: float = pos.distance_to(node.position)
		if d < best_d:
			best_d = d
			best_id = str(eid)
			best = node
	if best != null:
		return [best_id, best]
	return [null, null]

## Nearest sign/chest in reach, or "".
func _nearest_interactable(pos: Vector2, max_dist: float) -> String:
	var hit: Array = _nearest_of_types(pos, max_dist,
			["fixture/sign", "fixture/container/chest"])
	return str(hit[0]) if hit[0] != null else ""

## HUD verb hint for whatever is in reach. Recomputed every frame and only
## repainted when it changes, so walking past a tree/sign updates the line
## without a snapshot round trip.
func _update_verb_hint() -> void:
	var hint := ""
	if player != null and Game.booted:
		hint = Modals.verb_hint()
		if hint == "":
			var tree: Array = _nearest_of_types(player.position, 48.0, ["fixture/tree"])
			if tree[0] != null:
				hint = "F 砍树" if str(Game.snapshot.get("held", "")) != "" else "F 需要斧头"
			else:
				var inter := _nearest_interactable(player.position, 48.0)
				if inter != "":
					var itype := str(_entity_types.get(inter, ""))
					if itype == "fixture/sign":
						hint = "E 阅读木牌"
					elif itype == "fixture/container/chest":
						hint = "E 打开箱子"
				else:
					var npc := _nearest_npc(player.position, 30.0)
					if npc != null:
						hint = "E 交谈"
	if hint != _verb_hint:
		_verb_hint = hint
		_refresh_hud()

## F key — use whatever tool the player carries on the nearest tree. Scheme
## decides whether the bag holds an axe; without one no rule matches and the
## effect list comes back empty (the "no axe, no effect" check is structural).
func _fire_use_action() -> void:
	if player == null:
		return
	var hit: Array = _nearest_of_types(player.position, 48.0, ["fixture/tree"])
	var target_id: String = str(hit[0]) if hit[0] != null else ""
	if target_id == "":
		return
	last_used_id = target_id
	var effects: Variant = await Game.call_async("game:use", ["player", target_id])
	_apply_effects(effects)

## E helper: fire impulse/handle on a sign or chest. The rule decides whether
## that means reading or opening.
func _interact_entity(target_id: String) -> void:
	last_used_id = target_id
	var effects: Variant = await Game.call_async("game:handle", ["player", target_id])
	_apply_effects(effects)

## Bind each effect kind to the system that renders it. Adding an effect no
## longer means editing a match in this file — the owning system registers its
## handler, and the bus routes payloads to it.
func _register_effect_handlers() -> void:
	Effects.register("hit", _effect_hit)
	Effects.register("transform", _effect_transform)
	Effects.register("spawn", _effect_spawn)
	Effects.register("vfx", _effect_vfx)
	Effects.register("log", _effect_log)
	Effects.register("container", _effect_container)

## Execute a list of effect tuples returned by the rule engine. Scheme has
## already updated its state; the registered handlers only render.
func _apply_effects(effects: Variant) -> void:
	Effects.dispatch(effects, _after_effects)

## Shared post-effect refresh: held-tool hints and bag rows live in Scheme.
func _after_effects() -> void:
	Game.send("game:bag")

## --- effect adapters: (payload args) -> the existing render helpers -----------

func _effect_hit(args: Array) -> void:
	if args.is_empty():
		return
	_vfx_hit(str(args[0]))
	if args.size() >= 3:
		_log_line("受到 %d 点伤害，剩余 %d" % [int(args[1]), int(args[2])])

func _effect_transform(args: Array) -> void:
	if args.size() >= 2:
		_transform_entity(str(args[0]), str(args[1]))

func _effect_spawn(args: Array) -> void:
	if args.size() >= 2:
		_spawn_entity(str(args[0]), str(args[1]))

func _effect_vfx(args: Array) -> void:
	if args.size() >= 2:
		_vfx_play(str(args[0]), str(args[1]))

func _effect_log(args: Array) -> void:
	if not args.is_empty():
		_log_line(str(args[0]))

func _effect_container(args: Array) -> void:
	if args.size() >= 2:
		_apply_container_effect(str(args[0]), str(args[1]))

## `open` effect from the rule engine: show or hide the container panel. The
## container's `open` prop is already set/cleared in Scheme.
func _apply_container_effect(eid: String, state: String) -> void:
	if state == "closed":
		if container_ui != null:
			container_ui.close()
		_set_chest_open_sprite(eid, false)
		return
	_open_container(eid)

## Ask Scheme for the open container's view, then paint both sides. The reply
## lands in Game.snapshot before this await returns, so the panel can read it.
func _open_container(eid: String) -> void:
	if container_ui == null:
		return
	if bag_ui != null and bag_ui.is_open:
		bag_ui.close()
	var view: Variant = await Game.call_async("game:container", [eid])
	if view == null:
		return
	_set_chest_open_sprite(eid, true)
	container_ui.open(eid)

## Close the panel from the shell side (Esc / E / the ✕ button) and clear the
## container's open state in Scheme.
func _close_container() -> void:
	if container_ui == null or not container_ui.is_open:
		return
	var eid := container_ui.container_id
	container_ui.close()
	_set_chest_open_sprite(eid, false)
	Game.send("game:close-container", [eid])

## The chest sprite has two frames (closed/open) in its sheet.
func _set_chest_open_sprite(eid: String, open: bool) -> void:
	var ref: Variant = _entities.get(eid, null)
	if is_instance_valid(ref) and ref is Sprite2D:
		(ref as Sprite2D).frame = 1 if open else 0

## --- effect helpers ----------------------------------------------------------

func _transform_entity(eid: String, new_type: String) -> void:
	var ref: Variant = _entities.get(eid, null)
	if not is_instance_valid(ref) or not (ref is Node2D):
		return
	var node: Node2D = ref
	var cell: Vector2i = _foot_cell(node.position)
	match new_type:
		"fixture/stump":
			# A squat, dark trunk base instead of the dropped-log art: the log
			# sprite reads as "wood still on the ground", which is confusing
			# next to the two logs that really did get picked up.
			var sprite := node as Sprite2D
			if sprite != null:
				sprite.region_enabled = true
				sprite.region_rect = LOG_REGION
				sprite.centered = true
				sprite.offset = Vector2(0, -7)
				sprite.scale = Vector2(0.45, 0.9)
				sprite.modulate = Color(0.62, 0.50, 0.40)
				sprite.z_index = 0
			_release_cell(node, cell)
			_entity_types[eid] = "fixture/stump"
		"fixture/tree":
			# A stump growing back: restore the canopy and the blocking cell.
			var sprite := node as Sprite2D
			if sprite != null:
				sprite.region_enabled = true
				sprite.region_rect = TREE_REGION
				sprite.centered = false
				sprite.offset = Vector2(-24, -48)
				sprite.scale = Vector2.ONE
				sprite.modulate = Color.WHITE
			_block_cell(node, cell)
			_entity_types[eid] = "fixture/tree"
		_:
			_entity_types[eid] = new_type

func _release_cell(node: Node2D, cell: Vector2i) -> void:
	blocked.erase(cell)
	if _astar != null and _astar.is_in_boundsv(cell):
		_astar.set_point_solid(cell, false)
	if node.is_in_group("obstacle"):
		node.remove_from_group("obstacle")

func _block_cell(node: Node2D, cell: Vector2i) -> void:
	blocked[cell] = true
	if _astar != null and _astar.is_in_boundsv(cell):
		_astar.set_point_solid(cell, true)
	if not node.is_in_group("obstacle"):
		node.add_to_group("obstacle")

func _spawn_entity(type_str: String, at_id: String) -> void:
	var at_node: Variant = _entities.get(at_id, null)
	var pos: Vector2 = at_node.position if is_instance_valid(at_node) \
			else (player.position if player != null else Vector2.ZERO)
	if type_str == "item/material/log":
		# A log is the same cut-wood graphic, drawn smaller at the tree base.
		var log := Sprite2D.new()
		log.name = "Log"
		log.texture = load(TREE_TEXTURE)
		log.region_enabled = true
		log.region_rect = LOG_REGION
		log.centered = false
		log.offset = Vector2(-16, -16)
		log.scale = Vector2(0.7, 0.7)
		log.position = pos + Vector2(randf_range(-10.0, 10.0), randf_range(0.0, 8.0))
		log.add_to_group("log")
		if world != null:
			world.add_child(log)
		else:
			add_child(log)
		return
	var scene := _spawn_scene_for_type(type_str)
	if scene == null:
		_log_line("[TODO] spawn: no scene for " + type_str)
		return
	var new_node: Node2D = scene.instantiate()
	new_node.position = pos
	if world != null:
		world.add_child(new_node)
	else:
		add_child(new_node)

func _spawn_scene_for_type(type_str: String) -> PackedScene:
	match type_str:
		"item/material/ore":
			return load("res://scenes/ore.tscn")
		_:
			return null

func _vfx_hit(eid: String) -> void:
	var ref: Variant = _entities.get(eid, null)
	if not is_instance_valid(ref) or not (ref is Node2D):
		return
	var node: Node2D = ref
	# Tiny horizontal shake as impact cue — good enough for Phase 5.
	var orig: Vector2 = node.position
	var tween := create_tween()
	tween.set_parallel(true)
	tween.tween_property(node, "position:x", orig.x + 4.0, 0.05) \
			.set_trans(Tween.TRANS_QUAD)
	tween.tween_property(node, "position:x", orig.x - 4.0, 0.05) \
			.set_trans(Tween.TRANS_QUAD)
	tween.tween_property(node, "position:x", orig.x, 0.05)

func _vfx_play(eid: String, fx_name: String) -> void:
	# Phase 5: visual effects are placeholders. Print so the log trace shows
	# them; a particle pass lands later.
	print("[vfx] %s on %s" % [fx_name, eid])

func _log_line(text: String) -> void:
	if text == "":
		return
	_last_log = text
	_log_history.append(text)
	while _log_history.size() > 20:
		_log_history.pop_front()
	Game.snapshot_changed.emit()
	# Clear after a few seconds so the hint line returns.
	get_tree().create_timer(5.0).timeout.connect(func():
			if _last_log == text:
				_last_log = ""
				Game.snapshot_changed.emit())

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

func entity_node(id: String) -> Node2D:
	var ref: Variant = _entities.get(id, null)
	return ref if ref is Node2D else null

func portal_position(id: String) -> Variant:
	return _portals.get(id, null)

## A cell centre from which the player can reach `target` (an entity's origin):
## the target cell when walkable, otherwise the nearest walkable cell within
## `radius`. Returns null when nothing in reach is walkable.
func approach_point(target: Vector2, radius := 48.0) -> Variant:
	var base := Vector2i(floori(target.x / TILE), floori(target.y / TILE))
	var offsets: Array[Vector2i] = [Vector2i(0, 0), Vector2i(0, 1), Vector2i(-1, 0),
			Vector2i(1, 0), Vector2i(0, -1)]
	for r in range(2, 4):
		for dy in range(-r, r + 1):
			for dx in range(-r, r + 1):
				if absi(dx) != r and absi(dy) != r:
					continue
				offsets.append(Vector2i(dx, dy))
	for off in offsets:
		var cell: Vector2i = base + off
		if not _astar.is_in_boundsv(cell) or _astar.is_point_solid(cell):
			continue
		if _is_portal_cell(cell):
			continue
		var point := _cell_center(cell)
		if point.distance_to(target) <= radius:
			return point
	return null

func _is_portal_cell(cell: Vector2i) -> bool:
	for pid in _portals.keys():
		var p: Vector2 = _portals[pid]
		if Vector2i(floori(p.x / TILE), floori(p.y / TILE)) == cell:
			return true
	return false

## Walk the player along the grid route villagers use. Acceptance/demo only:
## the caller awaits this, so steps stay visually paced instead of teleporting.
func walk_player_to(goal: Vector2, timeout := 10.0) -> bool:
	if player == null:
		return false
	if player.position.distance_to(goal) <= 1.5:
		return true
	var path := _path_between(goal, player.position, "", true)
	if path.is_empty():
		return false
	for waypoint in path:
		if not await player.walk_to(waypoint, timeout):
			return false
	return player.position.distance_to(goal) <= 2.0

func _cell_center(cell: Vector2i) -> Vector2:
	return Vector2(cell.x * TILE + TILE * 0.5, cell.y * TILE + TILE * 0.5)

## Cell-centre waypoints from the NPC's cell to the anchor, in world pixels.
## Other villagers' cells are temporarily solid so routes do not start by
## walking straight through someone; they are restored right after the query.
func _path_to_anchor(at: String, from_pos: Vector2, self_id: String = "") -> PackedVector2Array:
	var anchor_name := at.get_slice(":", 1) if at.contains(":") else at
	if not _anchors.has(anchor_name):
		return PackedVector2Array()
	return _path_between(_anchors[anchor_name], from_pos, self_id)

## Cell-centre waypoints from `from_pos` to `goal`, in world pixels.
## Other villagers' cells are temporarily solid so routes do not start by
## walking straight through someone; they are restored right after the query.
func _path_between(goal: Vector2, from_pos: Vector2, self_id: String = "",
		avoid_portals := false) -> PackedVector2Array:
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
	# Scripted walking must not fall through a door on the way to something
	# behind it: reserve portal cells so the route steps around them.
	if avoid_portals:
		for pid in _portals.keys():
			var portal_pos: Vector2 = _portals[pid]
			var pcell := Vector2i(floori(portal_pos.x / TILE), floori(portal_pos.y / TILE))
			if pcell == from_cell or pcell == goal_cell:
				continue
			if _astar.is_in_boundsv(pcell) and not _astar.is_point_solid(pcell):
				_astar.set_point_solid(pcell, true)
				reserved.append(pcell)
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
	Modals.close_all()
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
	Modals.close_all()
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

## Hot reload is a fresh boot, not travel: Scheme drops its run-time state, and
## the live map is rebuilt from the authored .tscn so cut trees, emptied chests
## and dropped logs all return to their starting look. Without the scene swap
## the visuals stayed as stumps even though Scheme had been reset. The player
## keeps the spot they were standing on (portal travel is the only thing that
## moves them across a reload).
func hot_reload() -> void:
	if _reloading:
		return
	_reloading = true
	var keep_pos: Vector2 = player.position if is_instance_valid(player) else Vector2.ZERO
	var map_id := _current_map_id
	Modals.close_all()
	# Await the Scheme reset before re-registering: worker calls are queued in
	# order, so the fresh scene rows land on top of the cleared registry.
	await Game.reload_data()
	await _switch_map(map_id, "")
	if is_instance_valid(player):
		player.position = keep_pos
	_refresh_hud()
	_reloading = false

## Godot-side view of an entity, for acceptance. Scheme's view is read through
## game:debug-entity; this one catches a scene that still paints a stump after
## Scheme already says "tree".
func entity_scene_type(eid: String) -> String:
	return str(_entity_types.get(eid, ""))

func entity_visual_is_tree(eid: String) -> bool:
	var ref: Variant = _entities.get(eid, null)
	if not is_instance_valid(ref) or not (ref is Sprite2D):
		return false
	var sprite := ref as Sprite2D
	# Authored trees vary in scale; the stump swap changes the region, pivot and
	# tint, so those three are the reliable "is it still a tree" signal.
	return sprite.region_rect == TREE_REGION and not sprite.centered \
			and sprite.modulate == Color.WHITE

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
	if _last_log != "":
		hint = _last_log
	elif _verb_hint != "":
		hint = _verb_hint
	elif not (mech != null and mech.is_showing()):
		hint = "E 互动 / 开箱 / 读牌   F 砍树   I 背包   F1 机制   F5 热重载" + ("   F8 GM" if gm != null else "")
	hud_label.text = "第 %d 天  %02d:%02d   天气：%s\n%s\n%s\n%s   %s\n%s" % [
			int(Game.snapshot.get("day", 1)),
			int(Game.snapshot.get("hour", 8)),
			int(Game.snapshot.get("minute", 0)),
			str(WEATHER_NAMES.get(weather, weather)),
			str(Game.snapshot.get("quest_text", "")),
			_activity_line(),
			_bag_line(),
			("LLM：本地推理" if Game.use_llm else "LLM：无模型·预置台词"),
			hint]
	_refresh_weather()

## Bag readout: slots used, every carried stack, and the tool in hand. The
## counts come from Scheme's bag view, not from a GDScript inventory copy.
func _bag_line() -> String:
	var parts: PackedStringArray = []
	var held := str(Game.snapshot.get("held", ""))
	var held_name := ""
	for row in Game.snapshot.get("bag", []):
		if not (row is Array and row.size() >= 2):
			continue
		var type_id := str(row[0])
		var display := str(row[2]) if row.size() >= 3 else type_id
		parts.append("%s x%d" % [display, int(row[1])])
		if type_id == held:
			held_name = display
	var line := "背包 %d/%d 格：" % [int(Game.snapshot.get("bag_slots", 0)),
			int(Game.snapshot.get("bag_capacity", 30))]
	line += "，".join(parts) if not parts.is_empty() else "空"
	if held_name != "":
		line += "   手持：" + held_name
	return line

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
				# _input runs before gui_input so the key still works with the
				# console's LineEdit focused. Closing gets one stack-wide call.
				if gm.is_open:
					gm.toggle()
				else:
					Modals.close_all()
					gm.toggle()
				get_viewport().set_input_as_handled()

func _unhandled_input(event: InputEvent) -> void:
	# Open panels own their keys, top of the stack first. A new panel only has
	# to push itself and implement modal_input() — there is no branch to add
	# here, and no close call to add to travel/reload below.
	if Modals.handle_input(event):
		get_viewport().set_input_as_handled()
		return
	# System hotkeys stay global; world verbs only when no panel is up.
	if event is InputEventKey and event.pressed and not event.echo:
		if event.keycode == KEY_I:
			if not Modals.is_modal_open() and bag_ui != null:
				bag_ui.open()
			get_viewport().set_input_as_handled()
			return
		if event.keycode == KEY_F1:
			if mech != null:
				mech.toggle_visible()
			get_viewport().set_input_as_handled()
			return
		if event.keycode == KEY_F5:
			# Fire-and-forget: state, scene and HUD refresh when the reply lands.
			hot_reload()
			get_viewport().set_input_as_handled()
			return
		if event.keycode == KEY_F and not Modals.is_modal_open():
			_fire_use_action()
			get_viewport().set_input_as_handled()
			return
	if event.is_action_pressed("interact") and not Modals.is_modal_open():
		# Signs and chests take the active verb; villagers take dialogue.
		var target_id := _nearest_interactable(player.position, 48.0)
		if target_id != "":
			_interact_entity(target_id)
		else:
			var npc := _nearest_npc(player.position, 30.0)
			if npc != null:
				dialog_ui.open_npc(npc)
		get_viewport().set_input_as_handled()

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
	# Timed rule effects (a stump growing back) are pulled once per real second,
	# even while the clock is paused: a GM time jump queues them immediately.
	if Game.booted and Game.vm_error == "":
		_effects_accumulator += delta
		while _effects_accumulator >= PEOPLE_SECONDS:
			_effects_accumulator -= PEOPLE_SECONDS
			_poll_effects()
	_apply_people(Game.snapshot.get("people", []))
	_move_npcs(delta)
	_update_verb_hint()
	if player != null and not _portal_traveling and not player.scripted:
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
	# Magnet pickup: a dropped thing within reach flies into the bag while a
	# slot takes it. Two tiles, the reach the reference's magnet has.
	if player != null:
		for group in PICKUP_TYPES.keys():
			for node in get_tree().get_nodes_in_group(group):
				if not is_instance_valid(node):
					continue
				if player.position.distance_to(node.position) < PICKUP_REACH:
					_try_pick(node, PICKUP_TYPES[group])

## Hand one dropped thing to Scheme; free the node only when the bag took it.
## A full bag leaves the thing lying on the ground and retries a moment later,
## so standing on it does not flood the logic thread with take requests.
func _try_pick(node: Node2D, type_id: String) -> void:
	if node.has_meta("pick_in_flight"):
		return
	if Time.get_ticks_msec() < int(node.get_meta("pick_ready_at", 0)):
		return
	node.set_meta("pick_in_flight", true)
	var ok: Variant = await Game.call_async("game:take", [type_id])
	if not is_instance_valid(node):
		return
	if bool(ok):
		# queue_free waits for the end of the frame, so the in-flight mark stays
		# on: the pickup loop must not take the same node twice.
		node.queue_free()
		Game.send("game:bag")
		return
	node.remove_meta("pick_in_flight")
	node.set_meta("pick_ready_at", Time.get_ticks_msec() + PICKUP_RETRY_MS)

## Pull effects queued by Scheme's tick hook (a stump growing back). Runs at
## the same cadence as the people refresh, not every frame.
func _poll_effects() -> void:
	if _effects_polling or not Game.booted:
		return
	_effects_polling = true
	var effects: Variant = await Game.call_async("game:drain-effects")
	_effects_polling = false
	_apply_effects(effects)

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
