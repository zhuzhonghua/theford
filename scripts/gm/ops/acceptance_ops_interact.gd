extends RefCounted
const MOVE_ACTIONS := ["move_up", "move_down", "move_left", "move_right"]
const STEP_PAUSE := 0.45
const ACTION_PAUSE := 0.9
const GM_PAUSE := 0.8
const WALK_PAUSE := 0.4
## Acceptance op handlers (interact). Generated from the former single match;
## ctx is the runner, giving access to main / _current / _pause / helpers.
const OPS := {
	"key": "op_key",
	"topic": "op_topic",
	"click-bag-item": "op_click_bag_item",
	"press": "op_press",
	"click-item": "op_click_item",
	"click-hud-button": "op_click_hud_button",
	"click-panel-close": "op_click_panel_close",
	"close-dialog": "op_close_dialog",
	"story-skip": "op_story_skip",
	"story-beat": "op_story_beat",
	"story-place": "op_story_place",
	"backup-audio-settings": "op_backup_audio_settings",
	"restore-audio-settings": "op_restore_audio_settings",
	"set-volume": "op_set_volume",
	"reload-audio-settings": "op_reload_audio_settings",
	"delete-save": "op_delete_save",
}

func handle(op: String, step: Array, ctx: Object) -> Variant:
	var method: String = OPS.get(op, "")
	if method == "":
		return "__NO_OP__"
	return await call(method, step, ctx)

func op_key(step: Array, ctx: Object) -> String:
	if step.size() < 3:
		return "key 需要 action 与秒数"
	var action := str(step[1])
	if not InputMap.has_action(action):
		return "未知输入动作：" + action
	var seconds := float(step[2])
	ctx._current.text = "模拟按键：%s（%.2f 秒）" % [action, seconds]
	Input.action_press(action)
	# Key hold is gameplay input, not playback tempo: never scale it.
	await ctx.get_tree().create_timer(seconds).timeout
	Input.action_release(action)
	await ctx._pause(0.3)
	return ""

func op_topic(step: Array, ctx: Object) -> String:
	# Choose a dialogue topic the way a player clicks it: dialog.gd's
	# own _choose() runs the same game:talk call and rebuilds the menu.
	if step.size() < 2:
		return "topic 缺少话题键"
	if not ctx.main.dialog_ui.is_open:
		return "对话面板没有打开"
	ctx._current.text = "选择话题：" + str(step[1])
	ctx.main.dialog_ui._choose(str(step[1]))
	await ctx._pause(1.0)
	return ""

func op_click_bag_item(step: Array, ctx: Object) -> String:
	# Click a tool cell in the open bag panel to equip/unequip it. Goes
	# through bag_panel.click_slot, the same path a mouse click uses.
	if step.size() < 2:
		return "click-bag-item 缺少物品类型"
	if ctx.main.bag_ui == null or not ctx.main.bag_ui.is_open:
		return "背包面板没有打开"
	ctx._current.text = "点击背包里的 " + str(step[1])
	await ctx.main.bag_ui.click_slot(str(step[1]))
	await ctx._pause(0.4)
	return ""

func op_press(step: Array, ctx: Object) -> String:
	# Real key event (not an InputMap action): exercises the same
	# _unhandled_input path a player's keyboard uses, e.g. I for the bag.
	if step.size() < 2:
		return "press 缺少按键"
	var key_name := str(step[1])
	var keycode: int = OS.find_keycode_from_string(key_name)
	if keycode == KEY_NONE:
		keycode = OS.find_keycode_from_string(key_name.capitalize())
	if keycode == KEY_NONE:
		keycode = OS.find_keycode_from_string(key_name.to_upper())
	if keycode == KEY_NONE:
		return "未知按键：" + key_name
	ctx._current.text = "按键：" + key_name
	var down := InputEventKey.new()
	down.keycode = keycode
	down.physical_keycode = keycode
	down.pressed = true
	Input.parse_input_event(down)
	await ctx._pause(0.12)
	var up := InputEventKey.new()
	up.keycode = keycode
	up.physical_keycode = keycode
	up.pressed = false
	Input.parse_input_event(up)
	await ctx._pause(0.3)
	return ""

func op_click_item(step: Array, ctx: Object) -> String:
	# A real left click on the painted cell (Shift for one), so the
	# replay exercises the panel's own handler, not a back door.
	if step.size() < 3:
		return "click-item 需要 chest|bag 与物品类型"
	var click_side := str(step[1])
	if click_side != "chest" and click_side != "bag":
		return "click-item 的侧别只能是 chest|bag"
	var click_one: bool = step.size() >= 4 and str(step[3]) == "one"
	var click_error: String = await ctx._click_container_slot(
			click_side, str(step[2]), click_one)
	if click_error != "":
		return click_error
	await ctx._pause(0.4)
	return ""

func op_click_hud_button(step: Array, ctx: Object) -> String:
	if step.size() < 2:
		return "click-hud-button 缺少按钮名"
	if ctx.main.hud_bar == null:
		return "HUD 按钮条不可用"
	ctx._current.text = "点击 HUD 按钮：" + str(step[1])
	if not ctx.main.hud_bar.press_button(str(step[1])):
		return "没有这个 HUD 按钮：" + str(step[1])
	await ctx._pause(0.2)
	return ""

func op_click_panel_close(step: Array, ctx: Object) -> String:
	if step.size() < 2:
		return "click-panel-close 缺少面板名"
	var close_target: Variant = ctx.main.panel_named(str(step[1]))
	if close_target == null:
		return "未知面板：" + str(step[1])
	if close_target == null:
		return "面板不可用：" + str(step[1])
	ctx._current.text = "点击面板关闭按钮：" + str(step[1])
	var close_util := load("res://scripts/panel_util.gd")
	if not close_util.press_close(close_target):
		return "面板没有关闭按钮：" + str(step[1])
	await ctx._pause(0.2)
	return ""

func op_close_dialog(step: Array, ctx: Object) -> String:
	# Pressing E near an NPC again reopens the dialog (correct gameplay).
	# Replays use this to close deliberately instead of guessing how many
	# E presses are needed with a typewriter in flight.
	if ctx.main.dialog_ui != null and ctx.main.dialog_ui.is_open:
		ctx.main.dialog_ui.close()
	ctx._current.text = "关闭对话面板"
	await ctx._pause(0.1)
	return ""

func op_story_skip(step: Array, ctx: Object) -> String:
	# Dismiss a cutscene through the panel's own close path (the same one
	# the GM console and a player's Esc use), not a Scheme backdoor.
	if ctx.main.story_ui != null and ctx.main.story_ui.is_open:
		ctx.main.story_ui.close()
	ctx._current.text = "跳过剧情演出"
	await ctx._pause(0.2)
	return ""

func op_story_beat(step: Array, ctx: Object) -> String:
	# Manual trigger for a deterministic beat test. The same effect path
	# plays as a naturally fired beat; only the trigger is scripted.
	if step.size() < 2:
		return "story-beat 缺少 beat id"
	var fired: Variant = await Game.call_async("game:debug-story-beat", [str(step[1])])
	Game.send("game:story-status")
	ctx.main._poll_effects()
	ctx._current.text = "触发剧情 beat：" + str(step[1])
	if not bool(fired):
		return "beat 未触发：" + str(step[1])
	await ctx._pause(0.4)
	return ""

func op_story_place(step: Array, ctx: Object) -> String:
	if step.size() < 2:
		return "story-place 缺少锚点名"
	await Game.call_async("game:story-place", [str(step[1])])
	ctx._current.text = "剧情位置：" + str(step[1])
	return ""

func op_backup_audio_settings(step: Array, ctx: Object) -> String:
	ctx._audio_backup = Audio.volume_snapshot()
	ctx._current.text = "记下当前音量，验收结束后恢复"
	return ""

func op_restore_audio_settings(step: Array, ctx: Object) -> String:
	Audio.apply_volumes(ctx._audio_backup)
	if ctx.main.volume_ui != null:
		ctx.main.volume_ui.refresh()
	ctx._current.text = "恢复验收前的音量"
	return ""

func op_set_volume(step: Array, ctx: Object) -> String:
	# Drive the actual HSlider: value_changed fires and the Audio bus is
	# updated by the same handler a mouse drag uses.
	if step.size() < 3:
		return "set-volume 需要通道与 0-1 的值"
	if ctx.main.volume_ui == null or not ctx.main.volume_ui.is_open:
		return "音量面板没有打开"
	var vol_key := str(step[1]).to_lower()
	if Audio.bus_for_key(vol_key) == "":
		return "未知音量通道：" + vol_key
	var vol_value := clampf(float(step[2]), 0.0, 1.0)
	ctx._current.text = "拖动 %s 滑条 → %d%%" % [vol_key, roundi(vol_value * 100.0)]
	ctx.main.volume_ui.set_slider(vol_key, vol_value)
	Audio.save_settings()  # flush the debounce so the disk assert is stable
	await ctx._pause(0.3)
	return ""

func op_reload_audio_settings(step: Array, ctx: Object) -> String:
	# Same code path a fresh process runs at startup.
	Audio.reload_settings()
	if ctx.main.volume_ui != null:
		ctx.main.volume_ui.refresh()
	ctx._current.text = "从 user://settings.cfg 重读音量（等价于重开游戏）"
	return ""

func op_delete_save(step: Array, ctx: Object) -> String:
	var dir := DirAccess.open("user://")
	if dir != null and dir.file_exists("save1.scm"):
		dir.remove("save1.scm")
	ctx._current.text = "删除存档（模拟从未玩过）"
	return ""

