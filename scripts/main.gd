extends Node2D
## main.gd — presentation shell for the village.
##
## The map, trees, ores, NPCs and the player are authored by hand in
## scenes/world.tscn (instanced below as $World). This script only wires
## input -> dialog -> Game (Scheme) -> HUD, and enforces walkability.
## All game state lives in the Scheme VM; this script only renders consequences.

const TILE := 16

var map_w := 0
var map_h := 0

var blocked := {}        # Vector2i -> true
const MechHud := preload("res://scripts/mech_hud.gd")
var mech: MechHud = null

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
	hud_label.text = "……（启动中）"
	_setup_audio()
	_setup_world()
	Game.snapshot_changed.connect(_refresh_hud)
	if Game.booted:
		_refresh_hud()
	else:
		Game.bridge_ready.connect(_on_bridge_ready)
	_maybe_run_headless_demo()

## The world is static now, so it is ready immediately. Only the HUD text
## depends on the Scheme thread (bridge_ready).
func _on_bridge_ready(_llm: bool) -> void:
	_refresh_hud()

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

## ------------------------------------------------------------------ world --

func _setup_world() -> void:
	var used := ground.get_used_rect()
	map_w = maxi(used.end.x, 1)
	map_h = maxi(used.end.y, 1)
	_build_blocked()
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
	var hint := "" if (mech != null and mech.is_showing()) else "   F1 机制"
	hud_label.text = "%s\n铁矿石背包 x%d   %s%s" % [
			str(Game.snapshot.get("quest_text", "")),
			int(Game.snapshot.get("carried", 0)),
			("LLM：本地推理" if Game.use_llm else "LLM：无模型·预置台词"),
			hint]

## ------------------------------------------------------------------ input --

func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo:
		if event.keycode == KEY_F1:
			if mech != null:
				mech.toggle_visible()
			get_viewport().set_input_as_handled()
			return
	if event.is_action_pressed("interact") and not dialog_ui.is_open:
		var npc := _nearest_npc(player.position, 30.0)
		if npc != null:
			dialog_ui.open_npc(npc)

func _process(_delta: float) -> void:
	_maybe_capture_frame()
	# walk-over ore pickup
	for ore in get_tree().get_nodes_in_group("ore"):
		if not is_instance_valid(ore) or player == null:
			continue
		if player.position.distance_to(ore.position) < 10.0:
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
