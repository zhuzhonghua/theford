extends Node2D
## main.gd — presentation shell for the village.
##
## The map, trees, ores, NPCs and the player are authored by hand in
## scenes/world.tscn (instanced below as $World). This script only wires
## input -> dialog -> Game (Scheme) -> HUD, and enforces walkability.
## All game state lives in the Scheme VM; this script only renders consequences.

const TILE := 16
const SAVE_PATH := "user://save1.scm"
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
const PICKUP_TYPES := {"ore": "item/material/ore", "log": "item/material/log",
		"gel": "item/material/gel", "herb": "item/material/herb"}
## A villager runs from a creature inside this radius (the reference uses a
## sight of four tiles; fleeing starts a little wider so it reads clearly).
const FLEE_RADIUS := 56.0
const FLEE_SPEED := 62.0
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
	"sleep": "睡觉", "idle": "站着", "flee": "逃跑",
}
const AI_QUALITY_NAMES := {"off": "关", "low": "低", "medium": "中", "high": "高"}

var map_w := 0
var map_h := 0

var blocked := {}        # Vector2i -> true
const MechHud := preload("res://scripts/mech_hud.gd")
const BagPanel := preload("res://scripts/bag_panel.gd")
const ContainerPanel := preload("res://scripts/container_panel.gd")
const GameOver := preload("res://scripts/game_over.gd")
const QuestPanel := preload("res://scripts/quest_panel.gd")
const VolumePanel := preload("res://scripts/volume_panel.gd")
const StartMenu := preload("res://scripts/start_menu.gd")
const StoryPanel := preload("res://scripts/story_panel.gd")
const StatusPanel := preload("res://scripts/status_panel.gd")
const LogPanel := preload("res://scripts/log_panel.gd")
const HelpPanel := preload("res://scripts/help_panel.gd")
const MapPanel := preload("res://scripts/map_panel.gd")
const HudBar := preload("res://scripts/hud_bar.gd")
const ModelError := preload("res://scripts/model_error.gd")
const OreScene := preload("res://scenes/ore.tscn")
const HerbScene := preload("res://scenes/herb.tscn")
## Optional debug module: loaded by path, so deleting scripts/gm/ ships a
## release build without changing this shell.
const GM_SCRIPT_PATH := "res://scripts/gm/gm_console.gd"
var mech: MechHud = null
var bag_ui: BagPanel = null
var container_ui: ContainerPanel = null
var game_over_ui: GameOver = null
var quest_ui: QuestPanel = null
var volume_ui: VolumePanel = null
var start_menu: StartMenu = null
var story_ui: StoryPanel = null
var status_panel: StatusPanel = null
var log_panel: LogPanel = null
var help_panel: HelpPanel = null
var map_panel: MapPanel = null
var hud_bar: HudBar = null
var model_error: ModelError = null
var gm: Node = null
var _restarting := false
var _saving := false
var _loading := false
var _tick_accumulator := 0.0
var _people_accumulator := 0.0
var _effects_accumulator := 0.0
var _daylight: CanvasModulate = null
var _weather_layer: CanvasLayer = null
var _rain: GPUParticles2D = null
var _fog: ColorRect = null
var _last_weather := ""
var _last_player_pos := Vector2.ZERO  # footstep cadence tracks real movement
var _step_distance := 0.0
var _last_quest_completions := 0   # for the one-shot completion jingle
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
var _verb_hint := ""
var _effects_polling := false
var _picked_scene_items := {}  # static pickups already taken, kept across map travel
var _reloading := false   # ignore a second reload while one is in flight
var _last_story_place := ""  # nearest named anchor reported to the story engine

# World and talk panel live in main.tscn; the HUD is built by hud_bar.gd.
@onready var world: Node2D = $World
@onready var ground: TileMapLayer = $World/Ground
@onready var player: Node2D = $World/Player
@onready var dialog_ui: CanvasLayer = $Dialog

func _ready() -> void:
	var font := _load_cjk_font()
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
	game_over_ui = GameOver.new()
	add_child(game_over_ui)
	game_over_ui.setup(font, _restart_game)
	quest_ui = QuestPanel.new()
	add_child(quest_ui)
	quest_ui.setup(font)
	volume_ui = VolumePanel.new()
	add_child(volume_ui)
	volume_ui.setup(font)
	start_menu = StartMenu.new()
	add_child(start_menu)
	start_menu.setup(font, _continue_game, _restart_game)
	story_ui = StoryPanel.new()
	add_child(story_ui)
	story_ui.setup(font)
	status_panel = StatusPanel.new()
	add_child(status_panel)
	status_panel.setup_with_main(font, self)
	log_panel = LogPanel.new()
	add_child(log_panel)
	log_panel.setup_with_main(font, self)
	help_panel = HelpPanel.new()
	add_child(help_panel)
	help_panel.setup_ui(font)
	map_panel = MapPanel.new()
	add_child(map_panel)
	map_panel.setup_with_main(font, self)
	status_panel.set_toggle_key(KEY_C)
	log_panel.set_toggle_key(KEY_L)
	map_panel.set_toggle_key(KEY_M)
	help_panel.set_toggle_key(KEY_H)
	hud_bar = HudBar.new()
	add_child(hud_bar)
	hud_bar.setup(font, self)
	model_error = ModelError.new()
	add_child(model_error)
	model_error.setup(font, "")
	# Video capture keeps the gameplay HUD (mini-map, clock, messages); only
	# the replay progress panel and the F1 mechanism panel are hidden by their
	# own scripts.
	_recording_video = OS.get_environment("THEFORD_RECORD_DIR") != ""
	_maybe_start_recording()
	if _recording_video:
		_start_audio_capture()
	_register_effect_handlers()
	_setup_gm(font)
	_setup_audio()
	_setup_world()
	_setup_weather()
	Game.snapshot_changed.connect(_refresh_hud)
	if Game.booted:
		_on_bridge_ready(Game.use_llm)
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
func _on_bridge_ready(llm: bool) -> void:
	# The GGUF is part of the product. If it failed to load there is no
	# dialogue at all, so block entry instead of falling back to canned lines.
	if Game.vm_error != "":
		_block_with_model_error("Scheme 启动失败：\n" + Game.vm_error)
		return
	if not llm:
		_block_with_model_error(
			"找不到或无法加载 GGUF 模型。\n\n" \
			+ "请把 Qwen3-0.6B-Q4_K_M.gguf 放到 models/，\n" \
			+ "或用环境变量 THEFORD_MODEL 指向有效路径。\n" \
			+ "本项目以本地 LLM 驱动 NPC 对话，没有模型不能进入游戏。")
		return
	_after_bridge_ready()

func _block_with_model_error(message: String) -> void:
	if model_error != null:
		model_error.show_error(message)
	if hud_bar != null:
		hud_bar.visible = false

func _after_bridge_ready() -> void:
	_refresh_hud()
	_start_bgm()
	Game.send("game:people")
	Game.send("game:bag")
	Game.send("game:hp")
	Game.send("game:quests")
	Game.send("game:story-status")
	_check_anchors()
	if OS.get_environment("THEFORD_ACCEPTANCE") != "":
		# Headless playback needs the world unobstructed; the menu is mouse-only.
		Game.send("game:story-start")
		_maybe_autoplay_acceptance()
	else:
		start_menu.open(FileAccess.file_exists(SAVE_PATH))

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
	# Be defensive: a scene reload must never leave two BGM players running
	# (that used to sound like the track overlapping itself after a restart).
	for child in get_children():
		if child.name == "BGM":
			child.queue_free()
	var bgm := AudioStreamPlayer.new()
	bgm.name = "BGM"
	bgm.bus = "Music"
	bgm.volume_db = -10.0
	add_child(bgm)
	# One-shot cues, ambience beds and bus routing all live in the Audio
	# autoload. This shell only owns the map's BGM player; everything else is
	# fired by key so the cue table stays in data/catalog.scm.

## Play a catalogued sound effect once. Delegated to the Audio autoload so the
## death/quest jingles and every other cue share one mixer and one bus split.
func _play_sfx(key: String) -> void:
	Audio.play(key)

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
	bgm.stop()  # never let two streams of the same track overlap
	bgm.stream = theme_stream
	bgm.play()

## ------------------------------------------------------------------ world --

## Player-facing words for quest targets; the raw entity id is not useful
## feedback, and "只有一行提示" was exactly the complaint about the winch.
func _target_feedback(target_id: String, moved: bool) -> String:
	if moved:
		match target_id:
			"winch": return "缆绳接好了！去告诉老王，渡船可以下了。"
			"axun": return "阿笋终于说出实情。"
			"river-mud": return "泥印记下了，再去看看断缆。"
			"rope-end": return "断口是刀割的，线索齐了。"
			_: return "任务进展：" + target_id
	match target_id:
		"winch": return "绞盘还缺一截缆绳。先找阿笋问清旧缆绳的事（按 J 看任务）。"
		"axun": return "阿笋把绳头往怀里藏，再跟他搭句话试试。"
		_: return ""

func _pick_key(node: Node2D) -> String:
	return "%s/%s" % [_current_map_id, node.name]

## Pickups are generated, not authored as sprites in the .tscn: the scene
## holds only named Marker2D positions. Godot owns the geometry, Scheme still
## owns the bag; names double as the cross-map "already taken" keys.
func _spawn_pickups() -> void:
	var marks: Array[Node] = []
	var spawns := world.get_node_or_null("SpawnPoints")
	if spawns != null:
		for child in spawns.get_children():
			marks.append(child)
	for name in _anchors.keys():
		# herb-garden is a region name, not a spawn point: herb-1..6 are six chars.
		if str(name).begins_with("herb-") and str(name).length() == 6 \
				and world.has_node("Anchors/" + str(name)):
			marks.append(world.get_node("Anchors/" + str(name)))
	for mark in marks:
		var key := _pick_key(mark as Node2D)
		if _picked_scene_items.has(key):
			continue
		var scene: PackedScene = null
		if str(mark.name).begins_with("ore-"):
			scene = OreScene
		elif str(mark.name).begins_with("herb-"):
			scene = HerbScene
		if scene == null:
			continue
		var item := scene.instantiate() as Node2D
		item.name = mark.name
		item.position = (mark as Node2D).position
		world.add_child(item)

func _setup_world() -> void:
	# A static pickup taken earlier must not respawn when Godot rebuilds the
	# map on a portal trip — the scene is re-instantiated from the .tscn.
	for group in PICKUP_TYPES.keys():
		for node in get_tree().get_nodes_in_group(group):
			if is_instance_valid(node) and _picked_scene_items.has(_pick_key(node as Node2D)):
				node.queue_free()
	var used := ground.get_used_rect()
	map_w = maxi(used.end.x, 1)
	map_h = maxi(used.end.y, 1)
	_build_blocked()
	_setup_anchors()
	_spawn_pickups()
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
	# Spawn markers are named places too, so walks/acceptance can target them.
	var spawns := world.get_node_or_null("SpawnPoints")
	if spawns != null:
		for node in spawns.get_children():
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
		# Authored clues carry a stable id: quests track them by name, so the
		# registry must not renumber them when another interactable is added.
		var eid := str(node.get_meta("entity_id", ""))
		if eid == "":
			eid = "%s:%s:%d" % [etype.replace("/", "-"), _current_map_id, inter_idx]
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
	# The player is a real actor so a slime bite is just a strike aimed at an
	# entity. entities.scm keeps its hp across map travel; a reload restores it.
	if is_instance_valid(player):
		_entities["player"] = player
		_entity_types["player"] = "actor/person/player"
		rows.append(["player", "actor/person/player", ["person", "player"], []])
	# Creatures — authored in the scene with the slime sprite. Godot owns their
	# bodies; Scheme gets hp/atk tags so the same rule path can hit and kill them.
	var creature_idx: int = 0
	for node in get_tree().get_nodes_in_group("creature"):
		if not (node is Node2D):
			continue
		var eid := "creature:%s:%d" % [_current_map_id, creature_idx]
		creature_idx += 1
		_entities[eid] = node
		_entity_types[eid] = "actor/creature/slime"
		node.set("main", self)
		node.set("creature_id", eid)
		# Nudge a spawn that landed on a tree/water cell to the nearest open
		# one, so a hand-placed sprite can never make the creature stuck.
		var cell := _foot_cell(node.position)
		if _astar.is_in_boundsv(cell) and _astar.is_point_solid(cell):
			for off in [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1),
					Vector2i(0, -1), Vector2i(1, 1), Vector2i(-1, -1)]:
				var near: Vector2i = cell + (off as Vector2i)
				if _astar.is_in_boundsv(near) and not _astar.is_point_solid(near):
					node.position = _cell_center(near)
					break
		rows.append([eid, "actor/creature/slime", ["slime", "faction:wild"], []])
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
func _fact_true(key: String) -> bool:
	for row in Game.snapshot.get("story_facts", []):
		if row is Array and row.size() >= 2 and str(row[0]) == key:
			return bool(row[1]) or str(row[1]) == "1"
	return false

func _facing_vector() -> Vector2:
	if player == null:
		return Vector2.DOWN
	match player.facing:
		"left": return Vector2.LEFT
		"right": return Vector2.RIGHT
		"up": return Vector2.UP
		_: return Vector2.DOWN

## One E target for everything nearby. NPCs and authored interactables compete
## on distance, with a small bonus for whatever the player is facing — so a
## villager standing beside a sign no longer steals (or loses) the E press.
func _e_target() -> Dictionary:
	var best := {}
	var best_score := INF
	if player == null:
		return best
	var front := _facing_vector()
	for eid in _entities.keys():
		var etype := str(_entity_types.get(eid, ""))
		if not (etype == "fixture/sign" or etype == "fixture/container/chest" \
				or etype.begins_with("fixture/clue")):
			continue
		var node: Variant = _entities[eid]
		if not is_instance_valid(node) or not (node is Node2D):
			continue
		var delta: Vector2 = (node as Node2D).position - player.position
		var d := delta.length()
		if d > 48.0:
			continue
		var score := d
		if d > 0.1 and front.dot(delta.normalized()) > 0.3:
			score -= 6.0
		if score < best_score:
			best_score = score
			best = {"kind": "entity", "id": str(eid)}
	for npc in get_tree().get_nodes_in_group("npc"):
		if not (npc is Node2D) or not npc.visible:
			continue
		var delta: Vector2 = npc.position - player.position
		var d := delta.length()
		if d > 36.0:
			continue
		var score := d - 3.0  # talking beats a clue at the same distance
		if d > 0.1 and front.dot(delta.normalized()) > 0.3:
			score -= 8.0
		if score < best_score:
			best_score = score
			best = {"kind": "npc", "id": str(npc.get("npc_id")), "node": npc}
	return best

func _nearest_interactable(pos: Vector2, max_dist: float) -> String:
	var hit: Array = _nearest_of_types(pos, max_dist,
			["fixture/sign", "fixture/container/chest",
			 "fixture/clue/mud", "fixture/clue/rope", "fixture/clue/winch"])
	return str(hit[0]) if hit[0] != null else ""

## Nearest live creature within `radius`, or null. Uses the creature group so
## a despawned slime (freed at the end of the frame) is skipped safely.
func _nearest_creature(pos: Vector2, radius: float) -> Node2D:
	var best: Node2D = null
	var best_d := radius
	for node in get_tree().get_nodes_in_group("creature"):
		if not is_instance_valid(node):
			continue
		var d: float = pos.distance_to(node.position)
		if d < best_d:
			best_d = d
			best = node
	return best

## The registry id of a creature node, or "". Needed because F hands Scheme an
## entity id, while the AI only knows its own node.
func _creature_entity_id(node: Node2D) -> String:
	for eid in _entities.keys():
		if _entities[eid] == node:
			return str(eid)
	return ""

## HUD verb hint for whatever is in reach. Recomputed every frame and only
## repainted when it changes, so walking past a tree/sign updates the line
## without a snapshot round trip.
func _update_verb_hint() -> void:
	var hint := ""
	if player != null and Game.booted:
		hint = Modals.verb_hint()
		if hint == "":
			var tool_in_hand := str(Game.snapshot.get("held", "")) != ""
			var creature := _nearest_creature(player.position, 40.0)
			if creature != null:
				hint = "F 攻击史莱姆" if tool_in_hand else "F 需要装备武器（I 装备）"
			else:
				var tree: Array = _nearest_of_types(player.position, 48.0, ["fixture/tree"])
				if tree[0] != null:
					hint = "F 砍树" if tool_in_hand else "F 需要装备斧头（I 装备）"
				else:
					# Same target as the real E press, so the hint never lies.
					var pick := _e_target()
					match pick.get("kind", ""):
						"entity":
							var inter := str(pick.get("id", ""))
							var itype := str(_entity_types.get(inter, ""))
							if itype == "fixture/sign":
								hint = "E 阅读木牌"
							elif itype == "fixture/container/chest":
								hint = "E 打开箱子"
							elif inter == "winch":
								hint = "E 查看渡船" if _fact_true("ford.ferry-open") else "E 接缆绳"
							elif inter == "axun":
								hint = "E 问阿笋"
							else:
								hint = "E 查看线索"
						"npc":
							var npc: Node2D = pick.get("node") as Node2D
							if npc != null:
								var display := str(npc.get("display_name"))
								hint = "E 与%s交谈" % display if display != "" else "E 交谈"
	if hint != _verb_hint:
		_verb_hint = hint
		_refresh_hud()
		if hud_bar != null:
			hud_bar.set_hint(hint)

## F key — use whatever tool the player carries on the nearest tree. Scheme
## decides whether the bag holds an axe; without one no rule matches and the
## effect list comes back empty (the "no axe, no effect" check is structural).
func _fire_use_action() -> void:
	if player == null:
		return
	# A creature in melee range takes priority over a tree: in a fight F means
	# "swing at the thing that is biting you". Otherwise the verb is unchanged.
	var target_id := ""
	var creature := _nearest_creature(player.position, 48.0)
	if creature != null:
		target_id = _creature_entity_id(creature)
	if target_id == "":
		var hit: Array = _nearest_of_types(player.position, 48.0, ["fixture/tree"])
		target_id = str(hit[0]) if hit[0] != null else ""
	if target_id == "":
		return
	last_used_id = target_id
	var effects: Variant = await Game.call_async("game:use", ["player", target_id])
	_apply_effects(effects)
	# A blow may have killed the creature (spawning loot); refresh the bag view.
	Game.send("game:bag")

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
	Effects.register("despawn", _effect_despawn)
	Effects.register("scene", _effect_scene)
	Effects.register("say", _effect_say)

## Execute a list of effect tuples returned by the rule engine. Scheme has
## already updated its state; the registered handlers only render.
func _apply_effects(effects: Variant) -> void:
	Effects.dispatch(effects, _after_effects)

## Shared post-effect refresh: held-tool hints and bag rows live in Scheme.
func _after_effects() -> void:
	Game.send("game:bag")

## --- effect adapters: (payload args) -> the existing render helpers -----------

## Hits need to be felt, not just read: flash the target and nudge the camera
## when the player is hit. Tweens touch only visual properties (modulate /
## camera offset), never gameplay positions owned by player/creature scripts.
func _impact_flash(id: String) -> void:
	var ref: Variant = _entities.get(id, null)
	if ref == null or not is_instance_valid(ref) or not (ref is CanvasItem):
		return
	var node := ref as CanvasItem
	var base := node.modulate
	var tween := create_tween()
	tween.set_parallel(false)
	tween.tween_property(node, "modulate", Color(1.0, 0.28, 0.24, 1.0), 0.04)
	tween.tween_property(node, "modulate", base, 0.18)

func _camera_shake() -> void:
	if player == null:
		return
	var camera: Variant = player.get_node_or_null("Camera2D")
	if camera == null or not (camera is Camera2D):
		return
	var cam := camera as Camera2D
	var base := cam.offset
	var tween := create_tween()
	for i in range(3):
		tween.tween_property(cam, "offset", base + Vector2(randf_range(-4, 4), randf_range(-3, 3)), 0.03)
		tween.tween_property(cam, "offset", base, 0.03)
	tween.tween_property(cam, "offset", base, 0.01)

func _effect_hit(args: Array) -> void:
	if args.is_empty():
		return
	var id := str(args[0])
	_vfx_hit(id)
	_impact_flash(id)
	if id == "player":
		_camera_shake()
	# A swing at a tree has its own whoosh; every other blow gets the impact
	# cue. The target's type is still the tree here (transform runs later).
	Audio.play("chop" if _entity_types.get(id, "") == "fixture/tree" else "hit")
	if args.size() >= 3:
		if id == "player":
			_log_line("你受到 %d 点伤害，剩余 %d" % [int(args[1]), int(args[2])])
		else:
			_log_line("命中 %s：-%d（剩余 %d）" % [id, int(args[1]), int(args[2])])
	# Player health lives in Scheme; pull it into the snapshot after any blow.
	if id == "player":
		Game.send("game:hp")

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

## A defeated creature is gone from Scheme already; here we free its sprite and
## drop it from the local registry so F and flee checks stop seeing a corpse.
func _effect_despawn(args: Array) -> void:
	if args.is_empty():
		return
	var eid := str(args[0])
	Audio.play("kill")
	var ref: Variant = _entities.get(eid, null)
	if is_instance_valid(ref):
		ref.queue_free()
	_entities.erase(eid)
	_entity_types.erase(eid)
	if last_used_id == eid:
		last_used_id = ""

## A story beat hands the shell its lines; the panel owns the pacing. The
## payload is ("scene" title ((speaker text) ...)), plus a single-line "say"
## form from beats with only a `say` field.
func _effect_scene(args: Array) -> void:
	if story_ui == null:
		return
	var title := str(args[0]) if args.size() >= 1 else ""
	var lines: Array = []
	if args.size() >= 2 and args[1] is Array:
		for row in args[1]:
			if row is Array and row.size() >= 2:
				lines.append([str(row[0]), str(row[1])])
	if lines.is_empty():
		return
	_log_line(title if not title.is_empty() else str(lines[0][1]))
	# A beat writes facts before its scene is dispatched; refresh the mirror so
	# state-aware verb hints / quest text catch up immediately.
	Game.send("game:story-status")
	story_ui.open(title, lines)

func _effect_say(args: Array) -> void:
	if args.is_empty():
		return
	var speaker := str(args[0])
	var text := str(args[1]) if args.size() >= 2 else ""
	_effect_scene(["", [[speaker, text]]])

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
	if type_str == "item/material/gel":
		# The same 16x16 house-tileset cell the bag icon uses, dropped nearby.
		var gel := Sprite2D.new()
		gel.name = "Gel"
		gel.texture = load("res://assets/na/Backgrounds/Tilesets/TilesetHouse.png")
		gel.region_enabled = true
		gel.region_rect = Rect2(336, 224, 16, 16)
		gel.centered = false
		gel.offset = Vector2(-8, -8)
		gel.position = pos + Vector2(randf_range(-8.0, 8.0), randf_range(0.0, 6.0))
		gel.add_to_group("gel")
		if world != null:
			world.add_child(gel)
		else:
			add_child(gel)
		return
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
	# Messages live in the log panel now; the HUD no longer flashes them for
	# five seconds and discards them.
	_log_history.append(text)
	while _log_history.size() > 20:
		_log_history.pop_front()
	if hud_bar != null:
		hud_bar.push_message(text)
	Game.snapshot_changed.emit()

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

## Read-only views for the product UI panels (no state is duplicated there).
func log_history() -> Array:
	return _log_history.duplicate()

func portal_positions() -> Dictionary:
	return _portals.duplicate()

func minimap_data() -> Dictionary:
	var anchors: Array = []
	for name in _anchors.keys():
		anchors.append({"name": str(name), "pos": _anchors[name]})
	return {
		"blocked": blocked.keys(),
		"anchors": anchors,
		"npcs": npc_visual_rows(),
		"portals": _portals.values(),
		"player": player.position if is_instance_valid(player) else Vector2.ZERO,
	}

func npc_visual_rows() -> Array:
	var rows: Array = []
	for npc in get_tree().get_nodes_in_group("npc"):
		if npc is Node2D and npc.visible:
			rows.append({"id": str(npc.get("npc_id")), "pos": npc.position})
	return rows

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
		var talking: bool = dialog_ui.is_open and dialog_ui.current_npc_id() == npc.npc_id
		var threat := _nearest_creature(npc.position, FLEE_RADIUS)
		var fleeing: bool = threat != null and not talking
		var path: PackedVector2Array
		var step: int
		var travel: float
		if fleeing:
			# A threat overrides the schedule path: run away until the creature
			# is out of sight, then pick the daily route up where it left off.
			if state.get("flee_path") == null or state.get("flee_target") != threat:
				state["flee_path"] = _path_between(
						_flee_point(npc.position, threat.position), npc.position, npc.npc_id)
				state["flee_step"] = 0
				state["flee_target"] = threat
			path = state.get("flee_path", PackedVector2Array())
			step = int(state.get("flee_step", 0))
			travel = FLEE_SPEED * delta
		else:
			if state.has("flee_path"):
				state.erase("flee_path")
				state.erase("flee_step")
				state.erase("flee_target")
			path = state.get("path", PackedVector2Array())
			step = int(state.get("step", 0))
			travel = NPC_SPEED * delta
		if step < path.size() and not talking:
			var target := path[step]
			var d: Vector2 = target - npc.position
			if d.length() <= travel:
				npc.position = target
				step += 1
				if fleeing:
					state["flee_step"] = step
				else:
					state["step"] = step
			else:
				npc.position += d.normalized() * travel
				npc.face_dir(d)
			npc.set_walking(true)
		else:
			npc.set_walking(false)
		var hide := step >= path.size() and activity == "sleep" and not fleeing
		if hide:
			# Only vanish once actually home. A sleep anchor that is unknown or
			# unreachable yields an empty path, and hiding immediately would make
			# villagers pop out of existence wherever they happen to stand.
			var home: Variant = anchor_position(str(state.get("anchor", "")).get_slice(":", 1))
			hide = home != null and npc.position.distance_to(home) < 12.0
		npc.visible = not hide

## A walkable point several tiles directly away from a threat. Falls back to
## shorter hops when the ideal cell is a wall, water or a portal.
func _flee_point(from_pos: Vector2, threat_pos: Vector2) -> Vector2:
	var away: Vector2 = from_pos - threat_pos
	if away.length_squared() < 0.001:
		away = Vector2.RIGHT
	away = away.normalized()
	for dist in [64.0, 48.0, 32.0, 16.0]:
		var p: Vector2 = from_pos + away * float(dist)
		var cell := Vector2i(floori(p.x / TILE), floori(p.y / TILE))
		if _astar.is_in_boundsv(cell) and not _astar.is_point_solid(cell) \
				and not _is_portal_cell(cell):
			return _cell_center(cell)
	return from_pos

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
	_refresh_rain_ambience()  # rain is audible outside, muffled indoors
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
	Game.send("game:quests")
	await _switch_map(map_id, "")
	if is_instance_valid(player):
		player.position = keep_pos
	# The reload's hp reply lands while the registry is empty; read it again
	# now that the fresh scene has registered a full-health player.
	await Game.call_async("game:hp")
	_refresh_hud()
	_reloading = false

## ---- save / load -----------------------------------------------------------
## The save file is Scheme source written in the project's `table` DSL. Scheme
## owns every gameplay value; the host contributes only the map and body
## positions, which it passes in when saving and reads back with peek before
## rebuilding the map. A failed read reports a message instead of failing quiet.

func _save_host() -> Array:
	var npcs := []
	for id in _npc_state.keys():
		var npc := _npc_by_id(str(id))
		if npc == null or not is_instance_valid(npc):
			continue
		var st: Dictionary = _npc_state[id]
		npcs.append([str(id), npc.position.x, npc.position.y, npc.visible,
				str(st.get("anchor", "")), str(st.get("activity", ""))])
	var pos := Vector2.ZERO if not is_instance_valid(player) else player.position
	return [_current_map_id, [pos.x, pos.y], npcs]

func quick_save() -> bool:
	if _saving or _loading or not Game.booted:
		return false
	_saving = true
	var path := ProjectSettings.globalize_path(SAVE_PATH)
	var ok: Variant = await Game.save_state(path, _save_host())
	if ok == null:
		_log_line("存档失败：Scheme 写入出错")
		_saving = false
		return false
	_log_line("已存档：" + SAVE_PATH)
	_saving = false
	return true

func _restore_npc_positions(rows: Variant) -> void:
	if not (rows is Array):
		return
	for row in rows:
		if not (row is Array) or row.size() < 6:
			continue
		var id := str(row[0])
		var npc := _npc_by_id(id)
		if npc == null or not is_instance_valid(npc):
			continue
		npc.position = Vector2(float(row[1]), float(row[2]))
		npc.visible = bool(row[3])
		_npc_state[id] = {
			"anchor": str(row[4]),
			"activity": str(row[5]),
			"path": PackedVector2Array(),
			"step": 0,
		}

func quick_load() -> bool:
	if _loading or _saving or not Game.booted:
		return false
	if not FileAccess.file_exists(SAVE_PATH):
		_log_line("读档失败：没有存档")
		return false
	var path := ProjectSettings.globalize_path(SAVE_PATH)
	var host: Variant = await Game.peek_save(path)
	if not (host is Array) or (host as Array).size() < 3:
		_log_line("读档失败：存档损坏或版本不兼容")
		return false
	_loading = true
	Modals.close_all()
	# Speed is a debug preference, not world state: a load leaves it as the
	# player set it (a paused run stays paused after reading a save).
	# Rebuild the map first: registering scene entities clears Scheme's registry,
	# so the saved entity state must land afterwards or a cut tree would spring
	# back. Saved body positions go on top of the freshly instantiated scene.
	var host_rows: Array = host
	var map_id := str(host_rows[0])
	await _switch_map(map_id, "")
	var pp: Variant = host_rows[1]
	if pp is Array and (pp as Array).size() >= 2 and is_instance_valid(player):
		player.position = Vector2(float(pp[0]), float(pp[1]))
	_restore_npc_positions(host_rows[2])
	var result: Variant = await Game.load_state(path)
	if not (result is Array) or result.is_empty() or not bool(result[0]):
		_log_line("读档失败：存档内容不兼容")
		_loading = false
		return false
	await Game.call_async("game:hp")
	_refresh_hud()
	_log_line("已读档：第 %d 天 %02d:%02d" % [
		int(Game.snapshot.get("day", 1)), int(Game.snapshot.get("hour", 0)),
		int(Game.snapshot.get("minute", 0))])
	_loading = false
	return true

func _continue_game() -> void:
	Game.send("game:story-start")
	await quick_load()

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
	# The old UI/HUD/HUDLabel scene node was removed: status now lives in
	# scripts/hud_bar.gd, which listens to Game.snapshot_changed directly.
	_refresh_weather()
	_check_game_over()
	_check_quest_jingle()

## A completion counter comes back with the quest log; play the success cue
## only when it actually grows (reload resets it, which must not play a jingle).
func _check_quest_jingle() -> void:
	var n := int(Game.snapshot.get("quest_completions", 0))
	if n > _last_quest_completions:
		_play_sfx("success")
	_last_quest_completions = n

## Scheme owns the death decision (game:hp carries a down flag). The shell just
## shows the screen once and freezes the world via the modal stack.
func _check_game_over() -> void:
	if game_over_ui == null:
		return
	if bool(Game.snapshot.get("game_over", false)):
		if not game_over_ui.is_open and not _restarting:
			game_over_ui.open()
			_play_sfx("gameover")
	elif game_over_ui.is_open and not _restarting:
		game_over_ui.close()

## Death restarts from the authored start, not from wherever the body fell:
## clear all state on the worker, rebuild the village and stand at the river.
func _restart_game() -> void:
	if _restarting:
		return
	_restarting = true
	_picked_scene_items.clear()
	Game.send("game:story-start")
	Modals.close_all()
	if gm != null:
		gm.reset_speed()
	await Game.reload_data()
	await _switch_map("village", "village:riverbank")
	# The reload clears the entity registry before the new map re-registers the
	# player, so an in-flight hp reply can still say "down". Read it again now
	# that the player entity is back at full health before releasing the guard.
	await Game.call_async("game:hp")
	# Restart is a clean take: stop the old stream and let the map re-arm BGM.
	var bgm: AudioStreamPlayer = get_node_or_null("BGM")
	if bgm != null:
		bgm.stop()
	_current_music = ""
	await _play_music_for_map(_current_map_id)
	_refresh_hud()
	_restarting = false

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
		line += "   装备：" + held_name
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
	_refresh_rain_ambience()

## Rain ambience follows the same switch as the particles, and goes quiet
## indoors. The Audio autoload
## fades the loop and remembers the request if the bridge is not up yet.
func _refresh_rain_ambience() -> void:
	var weather := str(Game.snapshot.get("weather", "sun"))
	var raining := weather == "rain" or weather == "storm"
	Audio.set_ambience("rain", raining and _current_map_id != "smithy")

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

func verb_hint() -> String:
	return _verb_hint

## The HUD bar's buttons go through here; every destination is the same panel
## the hotkey opens, so there is no button-only code path to keep in sync.
func open_panel(which: String) -> void:
	match which:
		"status": _toggle_panel(status_panel)
		"log": _toggle_panel(log_panel)
		"map": _toggle_panel(map_panel)
		"help": _toggle_panel(help_panel)
		"bag": _toggle_panel(bag_ui)
		"quest": _toggle_panel(quest_ui)
		"volume": _toggle_panel(volume_ui)
		"mech":
			if mech != null:
				mech.toggle_visible()
		"save": quick_save()
		"load": quick_load()
		"gm":
			if gm != null:
				if gm.is_open:
					gm.toggle()
				else:
					Modals.close_all()
					gm.toggle()

## New panels toggle with their own key; an already-open panel consumes that
## key in modal_input() and closes itself, so this only handles the opening half.
func _toggle_panel(panel: Variant) -> void:
	if panel == null:
		return
	if bool(panel.is_open):
		panel.close()
	elif not Modals.is_modal_open():
		panel.open()

func _unhandled_input(event: InputEvent) -> void:
	if model_error != null and model_error.is_open:
		get_viewport().set_input_as_handled()
		return
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
		if event.keycode == KEY_J:
			if not Modals.is_modal_open() and quest_ui != null:
				quest_ui.open()
			get_viewport().set_input_as_handled()
			return
		if event.keycode == KEY_O:
			if not Modals.is_modal_open() and volume_ui != null:
				volume_ui.open()
			get_viewport().set_input_as_handled()
			return
		if event.keycode == KEY_C:
			_toggle_panel(status_panel)
			get_viewport().set_input_as_handled()
			return
		if event.keycode == KEY_L:
			_toggle_panel(log_panel)
			get_viewport().set_input_as_handled()
			return
		if event.keycode == KEY_M:
			_toggle_panel(map_panel)
			get_viewport().set_input_as_handled()
			return
		if event.keycode == KEY_H:
			_toggle_panel(help_panel)
			get_viewport().set_input_as_handled()
			return
		if event.keycode == KEY_F1:
			if mech != null:
				mech.toggle_visible()
			get_viewport().set_input_as_handled()
			return
		if event.keycode == KEY_F5:
			# Fire-and-forget: the file lands on the worker's next batch.
			quick_save()
			get_viewport().set_input_as_handled()
			return
		if event.keycode == KEY_F9:
			quick_load()
			get_viewport().set_input_as_handled()
			return
		if event.keycode == KEY_F and not Modals.is_modal_open():
			_fire_use_action()
			get_viewport().set_input_as_handled()
			return
	if event.is_action_pressed("interact") and not Modals.is_modal_open():
		# One target wins: the closest villager / sign / clue in front of the
		# player. No more "I meant to talk to Lao Wang but got the sign".
		var pick := _e_target()
		var target_id := str(pick.get("id", "")) if pick.has("id") else ""
		if pick.get("kind", "") == "entity" and target_id != "":
			_interact_entity(target_id)
			# Quests may track a world target by its entity id. Wait for the
			# verdict and say so out loud — otherwise "按了 E 只出个提示"
			# makes a quest step feel broken even when it advanced.
			var moved: Variant = await Game.call_async("game:quest-target", [target_id])
			var feedback := _target_feedback(target_id, bool(moved))
			if feedback != "":
				_log_line(feedback)
		elif pick.get("kind", "") == "npc":
			var npc: Node2D = pick.get("node") as Node2D
			if npc != null:
				# A `target` objective may point at an NPC (阿笋 in the finale).
				# The dialog opens just as it always does; Scheme decides
				# whether this interaction advances anything.
				dialog_ui.open_npc(npc)
				# Fire-and-forget: awaiting this RPC would delay the dialog
				# opening by a worker round-trip and scripts pressing E then a
				# topic would race it. Feedback still arrives via the reply.
				var npc_id := str(npc.get("npc_id"))
				# Quest data may name either the dialogue actor (npc:axun) or
				# the authored clue with the bare id (axun); both are cheap no-ops
				# when they do not match the current objective.
				Game.send("game:quest-target", [npc_id])
				Game.send("game:quest-target", ["npc:" + npc_id])
		get_viewport().set_input_as_handled()

func _exit_tree() -> void:
	_save_audio_capture()
	# Release the grid explicitly: it is the one RefCounted the scene owns.
	_astar = null

## Footsteps follow distance actually walked, not a timer: standing still or a
## modal panel is silent, scripted walks use the same signal, and a teleport
## (portal / map switch) is ignored instead of firing a burst of steps.
func _track_footsteps() -> void:
	if player == null:
		return
	var moved := player.position.distance_to(_last_player_pos)
	_last_player_pos = player.position
	if not Game.booted or Modals.is_modal_open():
		_step_distance = 0.0
		return
	if moved > 32.0:
		# A portal / map switch moved the node: don't credit that as walking.
		_step_distance = 0.0
		return
	if moved < 0.05:
		# A render frame with no physics step between it and the last one still
		# keeps the accumulated distance, otherwise headless replay (where
		# process frames outnumber physics frames) never reaches a footfall.
		return
	_step_distance += moved
	if _step_distance >= 18.0:
		_step_distance = 0.0
		Audio.play("footstep")

## The story engine uses named places, never pixels: report the nearest anchor
## only when it changes. Same Marker2D names NPC schedules use.
func _track_story_place() -> void:
	if player == null or not Game.booted or _anchors.is_empty():
		return
	var best := ""
	var best_d := 28.0
	for name in _anchors.keys():
		var d: float = player.position.distance_to(_anchors[name] as Vector2)
		if d < best_d:
			best_d = d
			best = str(name)
	if best != _last_story_place:
		_last_story_place = best
		Game.send("game:story-place", [best])

func _process(delta: float) -> void:
	_maybe_capture_frame()
	var rate: float = gm.speed() if gm != null else 1.0
	if Game.booted and Game.vm_error == "" and rate > 0.0:
		_tick_accumulator += delta
		var tick_step := TICK_SECONDS / rate
		while _tick_accumulator >= tick_step:
			_tick_accumulator -= tick_step
			Game.send("game:tick")
			# The quest log + xp share the tick cadence, so pickups, deliveries
			# and rewards appear in the J panel and HUD within 0.1s.
			Game.send("game:quests")
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
	_track_footsteps()
	_track_story_place()
	# The talk panel is authored at layer 10, below this code-built HUD. Hide
	# the HUD while talking so the status cards never sit on top of the dialog.
	if hud_bar != null:
		hud_bar.visible = not dialog_ui.is_open
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
		_picked_scene_items[_pick_key(node)] = true
		Audio.play("pickup")
		# A herb now has a real sprite, so make the moment it vanishes readable
		# too: the HUD hint says what was picked up instead of silently +1.
		if node.is_in_group("herb"):
			_log_line("采到一株草药（已放进背包）")
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
var _recording_video := false
var _audio_recorder: AudioEffectRecord = null
var _rec_next_ms := 0
var _rec_stop_ms := 0
var _rec_step_ms := 0
var _rec_i := 0
var _rec_done := false

## Record the final mix from the Master bus. Screen capture via Godot frames
## has no audio, so ffmpeg muxes this WAV with the PNG sequence afterwards.
func _start_audio_capture() -> void:
	_audio_recorder = AudioEffectRecord.new()
	var master := AudioServer.get_bus_index("Master")
	AudioServer.add_bus_effect(master, _audio_recorder)
	_audio_recorder.set_recording_active(true)

func _save_audio_capture() -> void:
	if _audio_recorder == null:
		return
	_audio_recorder.set_recording_active(false)
	var rec: Variant = _audio_recorder.get_recording()
	if rec is AudioStreamWAV and _rec_dir != "":
		_write_wav(_rec_dir.path_join("audio.wav"), rec as AudioStreamWAV)

func _write_wav(path: String, wav: AudioStreamWAV) -> void:
	var data: PackedByteArray = wav.data
	if data.is_empty():
		return
	var channels := 2 if wav.stereo else 1
	var bits := 16 if wav.format == AudioStreamWAV.FORMAT_16_BITS else 8
	var rate := int(wav.mix_rate)
	var block_align := channels * bits / 8
	var byte_rate := rate * block_align
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		return
	file.store_string("RIFF")
	file.store_32(36 + data.size())
	file.store_string("WAVEfmt ")
	file.store_32(16)
	file.store_16(1)  # PCM
	file.store_16(channels)
	file.store_32(rate)
	file.store_32(byte_rate)
	file.store_16(block_align)
	file.store_16(bits)
	file.store_string("data")
	file.store_32(data.size())
	file.store_buffer(data)
	file.close()

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
