extends Node
## audio_manager.gd — autoload "Audio": the one place sound is played.
##
## Every sound is a key in the `sfx` table of scheme/game/data/catalog.scm, so
## replacing an asset (or adding a cue) means editing that data file — callers
## just say Audio.play("chop") / Audio.set_ambience("rain", on). Streams are
## resolved through the Scheme bridge once and cached; one-shots share a small
## player pool and ambience beds get their own looping players with a short
## fade so weather changes never pop.
##
## Buses: BGM goes to Music, cues and ambience go to SFX. The split lives here
## so the volume panel only has to set bus volumes (set_volume). All three buses
## (Master / Music / SFX) route through this autoload, and their linear 0..1
## values are kept in user://settings.cfg so a restart sounds the same.

const MUSIC_BUS := "Music"
const SFX_BUS := "SFX"
const MASTER_BUS := "Master"
const CUE_POOL := 8
const SETTINGS_PATH := "user://settings.cfg"
## Panel/GM keys -> actual bus names. Master always exists in Godot; Music and
## SFX are created at startup by _setup_buses.
const BUS_KEYS := {"master": MASTER_BUS, "music": MUSIC_BUS, "sfx": SFX_BUS}

## Per-key volume (dB) and minimum gap (s). Keys absent from these tables use
## 0 dB and no throttle. Keeping the numbers here makes the mix easy to tune
## without touching the event hooks.
const CUE_DB := {
	"footstep": -18.0,
	"type": -24.0,
	"pickup": -8.0,
	"dialog-open": -10.0,
	"dialog-close": -10.0,
	"chop": -4.0,
	"hit": -5.0,
	"kill": -2.0,
	"success": -3.0,
	"gameover": -3.0,
}
const MIN_GAP := {
	"footstep": 0.13,
	"type": 0.055,
}
const AMBIENCE_DB := {"rain": -14.0}
const FADE_SECONDS := 0.8
const SILENT_DB := -48.0

var _cue_players: Array = []
var _cue_index := 0
var _ambient_players := {}   # key -> AudioStreamPlayer (looping)
var _ambient_wanted := {}    # key -> desired on/off (survives a not-ready bridge)
var _ambient_active := {}    # key -> actually playing
var _streams := {}           # key -> AudioStream or null (null = path missing)
var _loading := {}           # key -> true while a catalog lookup is in flight
var _last_played_ms := {}    # key -> msec of the last accepted one-shot
var _fade_tweens := {}       # ambience player -> its current fade Tween
## Read-only views for the acceptance runner and the debug HUD: these count
## cues that actually reached a player, not calls that were throttled/ignored.
var played := {}             # key -> number of times played
var ambience := {}           # key -> currently active (looping)
var _debug := false

## Linear 0..1 volume per bus name; the single source of truth for both the
## slider panel and the on-disk settings. `volume_saved` lets acceptance assert
## that a change really reached the config file.
var volumes := {MASTER_BUS: 1.0, MUSIC_BUS: 1.0, SFX_BUS: 1.0}
var volume_saved := false
var _save_timer: Timer

func _ready() -> void:
	_debug = OS.get_environment("THEFORD_DEBUG_AUDIO") == "1"
	_setup_buses()
	reload_settings()
	# Sliders emit value_changed many times while dragging; coalesce the writes
	# instead of touching the disk on every frame. Closing the panel flushes it.
	_save_timer = Timer.new()
	_save_timer.one_shot = true
	_save_timer.wait_time = 0.4
	_save_timer.timeout.connect(save_settings)
	add_child(_save_timer)
	for i in CUE_POOL:
		var p := AudioStreamPlayer.new()
		p.name = "Cue%d" % i
		p.bus = SFX_BUS
		add_child(p)
		_cue_players.append(p)
	Game.bridge_ready.connect(_on_bridge_ready)

## ------------------------------------------------------------------- buses --

func _setup_buses() -> void:
	_ensure_bus(MUSIC_BUS)
	_ensure_bus(SFX_BUS)

func _ensure_bus(bus_name: String) -> void:
	if AudioServer.get_bus_index(bus_name) >= 0:
		return
	AudioServer.add_bus()
	var idx := AudioServer.get_bus_count() - 1
	AudioServer.set_bus_name(idx, bus_name)
	AudioServer.set_bus_send(idx, MASTER_BUS)

## Volume helpers for the (future) settings panel. Values are linear 0..1 so
## the UI can use a plain slider; -80 dB is Godot's silence floor.
func set_bus_volume(bus_name: String, value: float) -> void:
	var idx := AudioServer.get_bus_index(bus_name)
	if idx < 0:
		return
	var v := clampf(value, 0.0, 1.0)
	var db: float = -80.0 if v <= 0.0 else linear_to_db(v)
	AudioServer.set_bus_volume_db(idx, db)

func get_bus_volume(bus_name: String) -> float:
	var idx := AudioServer.get_bus_index(bus_name)
	if idx < 0:
		return 0.0
	return db_to_linear(AudioServer.get_bus_volume_db(idx))

## --------------------------------------------------------------- settings --
## A slider (or the GM `volume` command) calls set_volume with a panel key such
## as "music"; the effect is immediate on the bus and the write is debounced.

func bus_for_key(key: String) -> String:
	return str(BUS_KEYS.get(key.to_lower(), ""))

func set_volume(bus_name: String, value: float) -> void:
	if not volumes.has(bus_name):
		return
	var v := clampf(value, 0.0, 1.0)
	volumes[bus_name] = v
	set_bus_volume(bus_name, v)
	if _save_timer != null:
		_save_timer.start()
	else:
		save_settings()

func volume_snapshot() -> Dictionary:
	return volumes.duplicate()

func apply_volumes(snapshot: Dictionary) -> void:
	for key in BUS_KEYS:
		var bus_name: String = BUS_KEYS[key]
		if snapshot.has(bus_name):
			set_volume(bus_name, float(snapshot[bus_name]))
	save_settings()

## Read the three volumes back from disk and apply them to the live buses.
## Called at startup (after the buses exist) and by GM `volume reload`, which
## doubles as the acceptance check that a restart would keep the settings.
func reload_settings() -> void:
	var cfg := ConfigFile.new()
	var loaded := cfg.load(SETTINGS_PATH) == OK
	volume_saved = loaded
	if loaded:
		for key in BUS_KEYS:
			var bus_name: String = BUS_KEYS[key]
			var saved: Variant = cfg.get_value("audio", key, volumes[bus_name])
			if saved is float or saved is int:
				volumes[bus_name] = clampf(float(saved), 0.0, 1.0)
	for bus_name in volumes.keys():
		set_bus_volume(bus_name, float(volumes[bus_name]))

func save_settings() -> void:
	var cfg := ConfigFile.new()
	# Keep unrelated sections (if any) instead of overwriting the whole file.
	cfg.load(SETTINGS_PATH)
	for key in BUS_KEYS:
		cfg.set_value("audio", key, float(volumes[BUS_KEYS[key]]))
	var err := cfg.save(SETTINGS_PATH)
	volume_saved = err == OK
	if err != OK:
		push_warning("[Audio] 音量设置写入失败：" + SETTINGS_PATH)
	elif _debug:
		print("[Audio] 音量已保存 ", volumes)

## --------------------------------------------------------------- one-shots --

## Fire a catalogued cue. Safe to call fire-and-forget; paths resolve on the
## logic worker the first time a key is used, then stay cached on this thread.
## `rate` shifts pitch for variation (walking and voice cues would otherwise
## sound like a machine gun); footsteps get a small random spread by default.
func play(key: String, rate := 1.0) -> void:
	if not Game.booted:
		return
	var gap := float(MIN_GAP.get(key, 0.0))
	if gap > 0.0:
		var now := Time.get_ticks_msec()
		if now - int(_last_played_ms.get(key, -100000)) < int(gap * 1000.0):
			return
		_last_played_ms[key] = now
	var stream := await _stream(key)
	if stream == null or _cue_players.is_empty():
		return
	var player: AudioStreamPlayer = _cue_players[_cue_index]
	_cue_index = (_cue_index + 1) % _cue_players.size()
	player.stream = stream
	player.bus = SFX_BUS
	player.volume_db = float(CUE_DB.get(key, 0.0))
	var effective_rate := rate
	if key == "footstep" and effective_rate == 1.0:
		effective_rate = randf_range(0.9, 1.1)
	player.pitch_scale = effective_rate
	player.play()
	played[key] = int(played.get(key, 0)) + 1
	if _debug:
		print("[Audio] cue ", key, " rate=", snappedf(effective_rate, 0.01))

## --------------------------------------------------------------- ambience --

## Turn a looping ambience bed on/off (currently only "rain"). Weather can be
## refreshed before the bridge is up: the wanted state is remembered and
## applied as soon as the catalog becomes available.
func set_ambience(key: String, on: bool) -> void:
	if _debug and bool(_ambient_wanted.get(key, false)) != on:
		print("[Audio] ambience ", key, " -> ", on)
	_ambient_wanted[key] = on
	if bool(_ambient_active.get(key, false)) == on:
		return
	if not on:
		_ambient_active[key] = false
		ambience[key] = false
		_fade_out(key)
		return
	if not Game.booted:
		return
	_ambient_active[key] = true
	var stream := await _stream(key)
	if stream == null or not bool(_ambient_wanted.get(key, false)):
		return
	var player: AudioStreamPlayer = _ambient_players.get(key)
	if player == null:
		player = AudioStreamPlayer.new()
		player.name = "Ambience_" + key
		player.bus = SFX_BUS
		add_child(player)
		_ambient_players[key] = player
	_make_loop(stream)
	player.stream = stream
	player.volume_db = SILENT_DB
	player.play()
	ambience[key] = true
	_fade_to(player, float(AMBIENCE_DB.get(key, -12.0)))

## Looping is a property of the stream, not the player (Godot 4). Ogg and WAV
## expose it differently; set it once on the cached resource when a bed starts.
func _make_loop(stream: AudioStream) -> void:
	if stream is AudioStreamOggVorbis:
		stream.loop = true
	elif stream is AudioStreamWAV:
		stream.loop_mode = AudioStreamWAV.LOOP_FORWARD
		if stream.loop_end <= 0:
			stream.loop_end = int(stream.get_length() * float(stream.mix_rate))

func _fade_out(key: String) -> void:
	var player: AudioStreamPlayer = _ambient_players.get(key)
	if player != null and player.playing:
		_fade_to(player, SILENT_DB, true)

func _fade_to(player: AudioStreamPlayer, target_db: float, stop_after := false) -> void:
	# A rapid weather flip must not leave two tweens fighting over volume_db.
	var previous: Tween = _fade_tweens.get(player)
	if previous != null and previous.is_valid():
		previous.kill()
	var tw := create_tween()
	tw.tween_property(player, "volume_db", target_db, FADE_SECONDS)
	if stop_after:
		tw.tween_callback(player.stop)
	_fade_tweens[player] = tw

func _on_bridge_ready(_llm: bool) -> void:
	# Apply ambience that was requested before the catalog was reachable.
	for key in _ambient_wanted.keys():
		if bool(_ambient_wanted[key]):
			_ambient_active[key] = false  # force set_ambience's guard through
			set_ambience(key, true)

## ------------------------------------------------------------------ lookup --

## Resolve a cue key to a stream through game:catalog-sfx, once per key. A
## concurrent second request waits for the first instead of queuing a second
## VM call.
func _stream(key: String) -> AudioStream:
	if _streams.has(key):
		return _streams[key]
	if bool(_loading.get(key, false)):
		while bool(_loading.get(key, false)):
			await get_tree().process_frame
		return _streams.get(key)
	_loading[key] = true
	var path_v: Variant = await Game.call_async("game:catalog-sfx", [key])
	var path := str(path_v) if path_v != null else ""
	var stream: AudioStream = null
	if path != "":
		stream = load("res://" + path)
	if stream == null:
		push_warning("[Audio] 无法载入音效 '" + key + "'：" + path)
	_streams[key] = stream
	_loading[key] = false
	return stream
