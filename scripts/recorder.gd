extends Node
## recorder.gd — recording / scripted-demo concerns, kept out of main.gd.
## Env-driven: THEFORD_RECORD_DIR enables PNG frames + Master-bus WAV audio;
## THEFORD_DEMO_* drives the old scripted screenshot demo. No-ops by default.
var main: Node

func setup(main_node: Node) -> void:
	main = main_node
	_maybe_start_recording()
	if _rec_dir != "":
		_start_audio_capture()

## ------------------------------------------------------------------ debug --
## Scripted demo for recordings/screenshots (no-ops when the env is unset):
##   THEFORD_DEMO_NPC=smith           teleport to the NPC and open the dialog
##   THEFORD_DEMO_TOPICS=village      topic keys to ask, comma-separated;
##                                    the second ask exercises the learned cache
##   THEFORD_SNAPSHOT_DIR=/tmp/x      write numbered PNG shots at key beats
##   THEFORD_DEMO_QUIT=1              quit when the demo ends
func maybe_run_demo() -> void:
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

func close() -> void:
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

func capture_frame(vp: Viewport) -> void:
	if _rec_done:
		return
	var now := Time.get_ticks_msec()
	if now < _rec_next_ms:
		return
	if now > _rec_stop_ms:
		_rec_done = true
		print("[rec] done: %d frames" % _rec_i)
		return
	var vp_tex := vp.get_texture()
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
	var vp_tex := main.get_viewport().get_texture()
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
	main.player.position = npc.position + Vector2(20, 0)
	main.dialog_ui.close()
	main.dialog_ui.open_npc(npc)
	await get_tree().create_timer(1.5).timeout
	_headless_snap(snap_dir)
	# one beat per topic: ask, let the LLM answer, then ask again (cache hit)
	for t in topics:
		main.dialog_ui._choose(t)
		await get_tree().create_timer(10.0).timeout
		_headless_snap(snap_dir)
		main.dialog_ui.close()
		await get_tree().create_timer(1.0).timeout
		main.dialog_ui.open_npc(npc)
		await get_tree().create_timer(1.0).timeout
		main.dialog_ui._choose(t)
		await get_tree().create_timer(5.0).timeout
		_headless_snap(snap_dir)
		await get_tree().create_timer(1.0).timeout
	if quit_when_done:
		get_tree().quit()

