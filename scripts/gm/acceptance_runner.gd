extends CanvasLayer
## acceptance_runner.gd — plays Scheme-provided acceptance steps in the live game.
## The Scheme file only returns data; this node owns input, timing, assertions
## and the on-screen trace. It never restores the scene: the player can continue
## from the final state after the run.

signal finished(ok: bool, summary: String)

const MOVE_ACTIONS := ["move_up", "move_down", "move_left", "move_right"]
const MAX_LOG_LINES := 7
## Playback pacing: a replay should read like a person playing. Every step keeps
## a short beat after it, and `note` holds long enough to read the Chinese text.
const STEP_PAUSE := 0.45
const ACTION_PAUSE := 0.9
const GM_PAUSE := 0.8
const WALK_PAUSE := 0.4

var main: Node
var gm: CanvasLayer
var _script_name := ""
var _steps: Array = []
var _active := false
var _run_id := 0
var _pace := 1.0
## Headless runs are for CI/terminal verification: skip all presentation tempo
## (note holds, per-step pauses, typewriters). A GM `load <name>` in a windowed
## editor keeps the human-paced playback so it stays readable.
var fast_headless := false
var _lines: Array[String] = []
var _audio_backup := {}   # so a volume replay leaves the player's mix alone
var _last_prompt := ""    # last prompt fetched by an assert-prompt-* step

var _panel: ColorRect
var _title: Label
var _current: Label
var _log: RichTextLabel
var _hint: Label

func setup(main_node: Node, gm_node: CanvasLayer, font: Font) -> void:
	main = main_node
	gm = gm_node
	fast_headless = DisplayServer.get_name() == "headless"
	layer = 35
	_build(font)

func is_running() -> bool:
	return _active

## Load only a named file under scheme/acceptance. The VM remains owned by its
## worker thread; no Scheme parser or VM call happens on the main thread.
func load_script(script_name: String) -> String:
	if _active:
		return "已有验收脚本正在运行"
	var re := RegEx.new()
	re.compile("^[a-z0-9_-]+$")
	if re.search(script_name) == null:
		return "用法：load <脚本名>（仅限字母、数字、下划线、连字符）"
	var path := "res://scheme/acceptance/%s.scm" % script_name
	if not FileAccess.file_exists(path):
		return "找不到验收脚本：%s" % path
	var err: Variant = await Game.load_async(Game.scheme_path(path))
	if not (err is String) or not err.is_empty():
		return "脚本加载失败：%s" % str(err)
	var steps: Variant = await Game.call_async("acceptance:steps", [])
	if not (steps is Array) or steps.is_empty():
		return "acceptance:steps 没有返回步骤列表"
	_script_name = script_name
	_steps = steps
	return ""

func start() -> void:
	if _active or _steps.is_empty():
		return
	_active = true
	_run_id += 1
	_lines.clear()
	_log.text = ""
	_panel.visible = true
	_hint.text = "Esc 中止"
	_run(_run_id)

func _run(id: int) -> void:
	var ok := true
	var summary := "全部 %d 步通过" % _steps.size()
	for i in range(_steps.size()):
		if id != _run_id or not _active:
			return
		var step: Variant = _steps[i]
		_title.text = "验收 %s · %d/%d" % [_script_name, i + 1, _steps.size()]
		print("[acceptance] step %d/%d: %s" % [i + 1, _steps.size(), _step_text(step)])
		var error: String = await _execute(step, id)
		if id != _run_id or not _active:
			return
		if error != "":
			ok = false
			summary = "第 %d 步失败：%s" % [i + 1, error]
			_record("FAIL", summary)
			break
		_record("OK", _step_text(step))
		await _pause(STEP_PAUSE)
		if id != _run_id or not _active:
			return
	_active = false
	_release_movement()
	_title.text = ("验收通过 · " if ok else "验收失败 · ") + _script_name
	_current.text = summary
	_hint.text = "Esc 关闭 · 可继续手动操作"
	finished.emit(ok, summary)

func _execute(step: Variant, id: int) -> String:
	if not (step is Array) or step.is_empty():
		return "非法步骤（应为非空列表）"
	var op := str(step[0])
	# A story cutscene is a real modal panel: it locks walking and swallows
	# keys by design. Replays that are not asserting the cutscene itself must
	# dismiss it first (a GM time jump can fire a beat mid-script). Story
	# assertions and `story-skip` are the only ops allowed while it is up.
	if not (op in ["note", "wait", "pace", "story-skip", "story-beat",
			"assert-story-panel", "assert-story-line", "assert-story-fact",
			"assert-story-fact-absent", "assert-story-beat"]):
		if main.story_ui != null and main.story_ui.is_open:
			main.story_ui.close()
	# Human-paced runs get a `game:people` refresh every real second before a
	# walk, so NPCs have already reached their schedule anchors. A fast replay
	# compresses those seconds away; force one refresh + a frame here so the
	# pathfinder does not route around NPCs still standing at authored spots.
	if fast_headless and (op in ["walk", "walk-interact", "walk-use",
			"walk-to-creature", "walk-attack"]):
		await Game.call_async("game:people", [])
		# Human-paced runs let villagers walk to their schedule anchors during
		# the step pauses; a fast replay has no such time, so place them there
		# directly (the same helper a map switch uses).
		main._place_npcs_on_entry()
		# Drain queued beat effects now instead of letting the shell's 1s poll
		# pop a cutscene in the middle of a scripted walk.
		await main._poll_effects()
		if main.story_ui != null and main.story_ui.is_open:
			main.story_ui.close()
		await get_tree().process_frame
	match op:
		"pace":
			if step.size() < 2:
				return "pace 缺少倍率"
			_pace = maxf(0.2, float(step[1]))
			_current.text = "回放节奏 ×%.2f" % _pace
		"note":
			if step.size() < 2:
				return "note 缺少说明"
			var text := str(step[1])
			# Read time scales with the text; the script's own value is a floor.
			var hold := clampf(0.9 + float(text.length()) * 0.12, 1.4, 4.5)
			if step.size() >= 3:
				hold = maxf(hold, float(step[2]))
			_current.text = text
			await _pause(hold)
		"gm":
			if step.size() < 2:
				return "gm 缺少指令"
			var command := str(step[1])
			_current.text = "GM > " + command
			var out: String = await gm.execute(command)
			if out != "":
				_current.text += "\n" + out
			# 让用户看到 GM 指令生效的结果，再往下走。
			await _pause(GM_PAUSE)
		"key":
			if step.size() < 3:
				return "key 需要 action 与秒数"
			var action := str(step[1])
			if not InputMap.has_action(action):
				return "未知输入动作：" + action
			var seconds := float(step[2])
			_current.text = "模拟按键：%s（%.2f 秒）" % [action, seconds]
			Input.action_press(action)
			# Key hold is gameplay input, not playback tempo: never scale it.
			await get_tree().create_timer(seconds).timeout
			Input.action_release(action)
			await _pause(0.3)
		"move":
			if step.size() < 3:
				return "move 需要 action 与目标地图"
			var action := str(step[1])
			var target := str(step[2])
			if not MOVE_ACTIONS.has(action):
				return "move 仅支持方向动作：" + action
			_current.text = "持续输入 %s → %s" % [action, target]
			Input.action_press(action)
			var elapsed := 0.0
			while main.current_map_id() != target or main.map_transitioning():
				if id != _run_id or not _active:
					Input.action_release(action)
					return "已中止"
				await get_tree().process_frame
				elapsed += get_process_delta_time()
				if elapsed > 6.0:
					Input.action_release(action)
					return "移动超时，未到地图 " + target
			Input.action_release(action)
			# Let the normal portal pass observe the release and rearm.
			await _pause(0.2)
		"wait":
			if step.size() < 2:
				return "wait 缺少秒数"
			var seconds := float(step[1])
			_current.text = "观察画面（%.1f 秒）" % seconds
			if fast_headless:
				# Keep a short real interval: story beats and timed effects run
				# on game ticks, which still advance at normal wall-clock speed.
				await get_tree().create_timer(minf(seconds, 1.2)).timeout
			else:
				await _pause(seconds)
		"topic":
			# Choose a dialogue topic the way a player clicks it: dialog.gd's
			# own _choose() runs the same game:talk call and rebuilds the menu.
			if step.size() < 2:
				return "topic 缺少话题键"
			if not main.dialog_ui.is_open:
				return "对话面板没有打开"
			_current.text = "选择话题：" + str(step[1])
			main.dialog_ui._choose(str(step[1]))
			await _pause(1.0)
		"assert-quest":
			if step.size() < 3:
				return "assert-quest 需要 quest id 与状态"
			var qid := str(step[1])
			var want_state := str(step[2])
			var qrows: Array = await _quest_rows()
			var have_state := ""
			for row in qrows:
				if row is Array and row.size() >= 3 and str(row[0]) == qid:
					have_state = str(row[2])
			_current.text = "断言：任务 %s = %s" % [qid, want_state]
			if have_state != want_state:
				return "期望 %s，实际 %s" % [want_state, have_state]
		"assert-quest-progress":
			if step.size() < 4:
				return "assert-quest-progress 需要 id、目标序号与完成数"
			var qid2 := str(step[1])
			var obj_index := int(step[2])
			var want_done := int(step[3])
			var want_need := int(step[4]) if step.size() >= 5 else -1
			var have_done := -1
			var have_need := -1
			for row in await _quest_rows():
				if row is Array and row.size() >= 5 and str(row[0]) == qid2:
					var objs: Variant = row[4]
					if objs is Array and obj_index < objs.size() \
							and objs[obj_index] is Array and objs[obj_index].size() >= 3:
						have_done = int(objs[obj_index][1])
						have_need = int(objs[obj_index][2])
			_current.text = "断言：%s 目标 %d = %d/%d" % [qid2, obj_index, want_done, want_need]
			if have_done != want_done:
				return "完成数期望 %d，实际 %d" % [want_done, have_done]
			if want_need >= 0 and have_need != want_need:
				return "需求数期望 %d，实际 %d" % [want_need, have_need]
		"assert-xp":
			if step.size() < 2:
				return "assert-xp 缺少经验值"
			var view: Variant = await Game.call_async("game:quests", [])
			var have_xp := int(view[0]) if view is Array and view.size() >= 1 else -1
			var want_xp := int(step[1])
			_current.text = "断言：经验 %d" % want_xp
			if have_xp != want_xp:
				return "经验期望 %d，实际 %d" % [want_xp, have_xp]
		"assert-quest-panel":
			if step.size() < 2:
				return "assert-quest-panel 需要 open|closed"
			if main.quest_ui == null:
				return "任务日志面板不可用"
			var want_open := str(step[1]) == "open"
			_current.text = "断言：任务日志%s" % ("打开" if want_open else "关闭")
			if main.quest_ui.is_open != want_open:
				return "期望%s，实际%s" % [
						"打开" if want_open else "关闭",
						"打开" if main.quest_ui.is_open else "关闭"]
		"assert-quest-panel-state":
			if step.size() < 3:
				return "assert-quest-panel-state 需要 id 与状态"
			if main.quest_ui == null or not main.quest_ui.is_open:
				return "任务日志面板没有打开"
			var qid3 := str(step[1])
			var want3 := str(step[2])
			var have3: String = str(main.quest_ui.state_for(qid3))
			_current.text = "断言：日志 %s = %s" % [qid3, want3]
			if have3 != want3:
				return "期望 %s，实际 %s" % [want3, have3]
		"assert-quest-panel-text":
			if step.size() < 3:
				return "assert-quest-panel-text 需要 id 与文本片段"
			if main.quest_ui == null or not main.quest_ui.is_open:
				return "任务日志面板没有打开"
			var qid4 := str(step[1])
			var needle := str(step[2])
			var panel_text: String = str(main.quest_ui.text_for(qid4))
			_current.text = "断言：日志 %s 含『%s』" % [qid4, needle]
			if not panel_text.contains(needle):
				return "日志没有显示『%s』：%s" % [needle, panel_text]
		"assert-map":
			if step.size() < 2:
				return "assert-map 缺少地图名"
			var expected := str(step[1])
			_current.text = "断言：当前地图 = " + expected
			if main.current_map_id() != expected:
				return "期望 %s，实际 %s" % [expected, main.current_map_id()]
		"assert-near":
			if step.size() < 2:
				return "assert-near 缺少 anchor"
			return _assert_near(main.player, str(step[1]), "玩家")
		"assert-npc":
			if step.size() < 3:
				return "assert-npc 需要 NPC id 与 anchor"
			var id_text := str(step[1])
			var npc: Node2D = main.npc_node(id_text)
			if npc == null or not npc.visible:
				return "NPC 不存在或不可见：" + id_text
			return _assert_near(npc, str(step[2]), id_text)
		"goto-map":
			if step.size() < 3:
				return "goto-map 需要地图与锚点"
			var map_id := str(step[1])
			var at := str(step[2])
			if map_id == main.current_map_id():
				# Same map: walk, do not teleport. Cross-map stays a door cut.
				var gm_bare := at.get_slice(":", 1) if at.contains(":") else at
				var gm_point: Variant = main.anchor_position(gm_bare)
				if gm_point == null:
					return "当前地图没有锚点：" + at
				_current.text = "走向 %s:%s" % [map_id, at]
				if not await main.walk_player_to(gm_point, 12.0):
					return "走不到 %s:%s" % [map_id, at]
				await _pause(WALK_PAUSE)
			else:
				_current.text = "切换地图 → %s:%s" % [map_id, at]
				await main._switch_map(map_id, at)
				await _pause(0.5)
		"place":
			if step.size() < 3:
				return "place 需要地图与锚点"
			var pmap := str(step[1])
			var pat := str(step[2])
			var pb := pat.get_slice(":", 1) if pat.contains(":") else pat
			if pmap != main.current_map_id():
				_current.text = "把玩家放到 %s:%s" % [pmap, pat]
				await main._switch_map(pmap, pat)
			else:
				var pp: Variant = main.anchor_position(pb)
				if pp == null:
					return "当前地图没有锚点：" + pat
				_current.text = "把玩家放到 %s:%s" % [pmap, pat]
				main.player.stop_scripted()
				main.player.position = pp
			await _pause(0.5)
		"walk":
			if step.size() < 2:
				return "walk 缺少锚点"
			var anchor := str(step[1])
			var walk_bare := anchor.get_slice(":", 1) if anchor.contains(":") else anchor
			var walk_point: Variant = main.anchor_position(walk_bare)
			if walk_point == null:
				walk_point = main.portal_position(walk_bare)
			if walk_point == null:
				return "当前地图没有锚点或 portal：" + anchor
			_current.text = "走向 " + anchor
			if not await main.walk_player_to(walk_point, 12.0):
				return "走不到 " + anchor
			await _pause(WALK_PAUSE)
		"walk-interact":
			_current.text = "寻找附近的可互动物体"
			var wi_target: String = main._nearest_interactable(main.player.position, 480.0)
			if wi_target == "":
				return "附近没有可互动物体"
			if not await _approach(wi_target):
				return "走不到可互动物体：" + wi_target
			_current.text = "E：与 %s 互动" % wi_target
			await main._interact_entity(wi_target)
			await _pause(ACTION_PAUSE)
		"walk-use":
			_current.text = "寻找附近能砍的树"
			var wu_tree: Array = main._nearest_of_types(main.player.position, 480.0, ["fixture/tree"])
			if wu_tree[0] == null:
				return "附近没有树"
			if not await _approach(str(wu_tree[0])):
				return "走不到树：" + str(wu_tree[0])
			_current.text = "F：用手持工具砍树"
			await main._fire_use_action()
			await _pause(ACTION_PAUSE)
		"use":
			_current.text = "F：使用手持工具"
			var use_tree: Array = main._nearest_of_types(main.player.position, 480.0, ["fixture/tree"])
			if use_tree[0] == null:
				return "附近没有树"
			if main.player.position.distance_to(use_tree[1].position) > 48.0:
				if not await _approach(str(use_tree[0])):
					return "走不到树：" + str(use_tree[0])
			await main._fire_use_action()
			await _pause(ACTION_PAUSE)
		"interact":
			_current.text = "E：与最近的可互动物体互动"
			var in_target: String = main._nearest_interactable(main.player.position, 480.0)
			if in_target == "":
				return "附近没有可互动物体"
			var in_node: Node2D = main.entity_node(in_target)
			if in_node != null and main.player.position.distance_to(in_node.position) > 48.0:
				if not await _approach(in_target):
					return "走不到可互动物体：" + in_target
			await main._interact_entity(in_target)
			await _pause(ACTION_PAUSE)
		"drain":
			_current.text = "取回规则引擎排队的延时效果"
			var drained: Variant = await Game.call_async("game:drain-effects", [])
			main._apply_effects(drained)
			await _pause(0.3)
		"assert-last-entity-type":
			if step.size() < 2:
				return "assert-last-entity-type 缺少类型"
			var want_type := str(step[1])
			var entry: Variant = await Game.call_async("game:debug-entity", [main.last_used_id])
			if not (entry is Array) or entry.size() < 1:
				return "最近实体不存在：" + str(main.last_used_id)
			_current.text = "断言：最近实体类型 = " + want_type
			if str(entry[0]) != want_type:
				return "期望 %s，实际 %s" % [want_type, str(entry[0])]
		"assert-last-entity-hp":
			if step.size() < 2:
				return "assert-last-entity-hp 缺少生命值"
			var want_hp := int(step[1])
			var entry_hp: Variant = await Game.call_async("game:debug-entity", [main.last_used_id])
			if not (entry_hp is Array) or entry_hp.size() < 2:
				return "最近实体不存在：" + str(main.last_used_id)
			_current.text = "断言：最近实体 HP = %d" % want_hp
			if int(entry_hp[1]) != want_hp:
				return "期望 %d，实际 %d" % [want_hp, int(entry_hp[1])]
		"assert-scene-entity":
			# Godot's registry + sprite state, not Scheme's: catches a stump that
			# survived a reload after Scheme already reports a healthy tree.
			if step.size() < 2:
				return "assert-scene-entity 缺少类型"
			var want_scene := str(step[1])
			_current.text = "断言：场景实体类型 = " + want_scene
			var have_scene: String = main.entity_scene_type(main.last_used_id)
			if have_scene != want_scene:
				return "期望 %s，实际 %s" % [want_scene, have_scene]
			if want_scene == "fixture/tree" and not main.entity_visual_is_tree(main.last_used_id):
				return "场景里还是树桩（精灵图/缩放未恢复）"
		"assert-near-entity":
			if step.size() < 2:
				return "assert-near-entity 缺少实体 id"
			var near_id := str(step[1])
			if near_id == "last":
				near_id = main.last_used_id
			var near_node: Node2D = main.entity_node(near_id)
			if near_node == null:
				return "场景里没有实体：" + near_id
			var near_limit := 48.0
			if step.size() >= 3:
				near_limit = float(step[2])
			_current.text = "断言：玩家仍在 %s 旁" % near_id
			var near_d: float = main.player.position.distance_to(near_node.position)
			if near_d > near_limit:
				return "距 %s 为 %.1f px（上限 %.1f）" % [near_id, near_d, near_limit]
		"assert-bag":
			if step.size() < 3:
				return "assert-bag 需要类型与数量"
			var want_item := str(step[1])
			var want_n := int(step[2])
			var bag_view: Variant = await Game.call_async("game:bag", [])
			var have := 0
			if bag_view is Array and bag_view.size() >= 1 and bag_view[0] is Array:
				for row in bag_view[0]:
					if row is Array and row.size() >= 2 and str(row[0]) == want_item:
						have = int(row[1])
			_current.text = "断言：背包 %s x%d" % [want_item, want_n]
			if have != want_n:
				return "期望 %s x%d，实际 x%d" % [want_item, want_n, have]
		"assert-held":
			# The equipped hand-slot tool: "" means nothing in hand, which is
			# exactly the state where F cannot chop. Read from Scheme's view.
			if step.size() < 2:
				return "assert-held 缺少工具类型（空串表示未装备）"
			var want_held := str(step[1])
			var held_view: Variant = await Game.call_async("game:bag", [])
			var have_held := ""
			if held_view is Array and held_view.size() >= 2:
				have_held = str(held_view[1])
			_current.text = "断言：手持装备 = " + (want_held if want_held != "" else "（空）")
			if have_held != want_held:
				return "期望 %s，实际 %s" % [want_held, have_held]
		"click-bag-item":
			# Click a tool cell in the open bag panel to equip/unequip it. Goes
			# through bag_panel.click_slot, the same path a mouse click uses.
			if step.size() < 2:
				return "click-bag-item 缺少物品类型"
			if main.bag_ui == null or not main.bag_ui.is_open:
				return "背包面板没有打开"
			_current.text = "点击背包里的 " + str(step[1])
			await main.bag_ui.click_slot(str(step[1]))
			await _pause(0.4)
		"assert-bag-slots":
			if step.size() < 2:
				return "assert-bag-slots 缺少槽位数"
			var want_slots := int(step[1])
			var slots_view: Variant = await Game.call_async("game:bag", [])
			var used_slots := -1
			if slots_view is Array and slots_view.size() >= 4:
				used_slots = int(slots_view[3])
			_current.text = "断言：背包占用 %d 格" % want_slots
			if used_slots != want_slots:
				return "期望 %d 格，实际 %d 格" % [want_slots, used_slots]
		"press":
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
			_current.text = "按键：" + key_name
			var down := InputEventKey.new()
			down.keycode = keycode
			down.physical_keycode = keycode
			down.pressed = true
			Input.parse_input_event(down)
			await _pause(0.12)
			var up := InputEventKey.new()
			up.keycode = keycode
			up.physical_keycode = keycode
			up.pressed = false
			Input.parse_input_event(up)
			await _pause(0.3)
		"assert-panel":
			if step.size() < 2:
				return "assert-panel 需要 open|closed"
			if main.bag_ui == null:
				return "背包面板不可用"
			var want_open := str(step[1]) == "open"
			_current.text = "断言：背包面板%s" % ("打开" if want_open else "关闭")
			if main.bag_ui.is_open != want_open:
				return "期望%s，实际%s" % [
						"打开" if want_open else "关闭",
						"打开" if main.bag_ui.is_open else "关闭"]
		"assert-panel-item":
			if step.size() < 3:
				return "assert-panel-item 需要类型与数量"
			if main.bag_ui == null or not main.bag_ui.is_open:
				return "背包面板没有打开"
			var pi_type := str(step[1])
			var pi_want := int(step[2])
			var pi_have: int = main.bag_ui.slot_total(pi_type)
			_current.text = "断言：面板 %s x%d" % [pi_type, pi_want]
			if pi_have != pi_want:
				return "期望 %s x%d，实际 x%d" % [pi_type, pi_want, pi_have]
		"assert-panel-slots":
			if step.size() < 2:
				return "assert-panel-slots 缺少格数"
			if main.bag_ui == null or not main.bag_ui.is_open:
				return "背包面板没有打开"
			var ps_want := int(step[1])
			var ps_have: int = main.bag_ui.filled_slots()
			_current.text = "断言：面板占用 %d 格" % ps_want
			if ps_have != ps_want:
				return "期望 %d 格，实际 %d 格" % [ps_want, ps_have]
		"assert-panel-icons":
			if main.bag_ui == null or not main.bag_ui.is_open:
				return "背包面板没有打开"
			_current.text = "断言：每个物品都加载出图标"
			# Icons resolve through the logic thread, so give the first round
			# trip a moment instead of depending on one fixed wait in the script.
			var missing: Array = []
			for attempt in range(20):
				missing = main.bag_ui.missing_icons()
				if missing.is_empty():
					break
				await _pause(0.1)
			if not missing.is_empty():
				return "缺图标：" + ", ".join(missing)
		"assert-container":
			if step.size() < 2:
				return "assert-container 需要 open|closed"
			if main.container_ui == null:
				return "容器面板不可用"
			var want_box_open := str(step[1]) == "open"
			_current.text = "断言：容器面板%s" % ("打开" if want_box_open else "关闭")
			if main.container_ui.is_open != want_box_open:
				return "期望%s，实际%s" % [
						"打开" if want_box_open else "关闭",
						"打开" if main.container_ui.is_open else "关闭"]
		"assert-container-item":
			if step.size() < 3:
				return "assert-container-item 需要类型与数量"
			if main.container_ui == null or not main.container_ui.is_open:
				return "容器面板没有打开"
			var ci_type := str(step[1])
			var ci_want := int(step[2])
			var ci_have: int = main.container_ui.slot_total("chest", ci_type)
			_current.text = "断言：箱子 %s x%d" % [ci_type, ci_want]
			if ci_have != ci_want:
				return "期望 %s x%d，实际 x%d" % [ci_type, ci_want, ci_have]
		"assert-container-slots":
			if step.size() < 2:
				return "assert-container-slots 缺少格数"
			if main.container_ui == null or not main.container_ui.is_open:
				return "容器面板没有打开"
			var cs_want := int(step[1])
			var cs_have: int = main.container_ui.filled_slots("chest")
			_current.text = "断言：箱子占用 %d 格" % cs_want
			if cs_have != cs_want:
				return "期望 %d 格，实际 %d 格" % [cs_want, cs_have]
		"assert-container-icons":
			if main.container_ui == null or not main.container_ui.is_open:
				return "容器面板没有打开"
			_current.text = "断言：箱子里的物品都加载出图标"
			var box_missing: Array = []
			for attempt in range(20):
				box_missing = main.container_ui.missing_icons("chest")
				if box_missing.is_empty():
					break
				await _pause(0.1)
			if not box_missing.is_empty():
				return "缺图标：" + ", ".join(box_missing)
		"click-item":
			# A real left click on the painted cell (Shift for one), so the
			# replay exercises the panel's own handler, not a back door.
			if step.size() < 3:
				return "click-item 需要 chest|bag 与物品类型"
			var click_side := str(step[1])
			if click_side != "chest" and click_side != "bag":
				return "click-item 的侧别只能是 chest|bag"
			var click_one: bool = step.size() >= 4 and str(step[3]) == "one"
			var click_error: String = await _click_container_slot(
					click_side, str(step[2]), click_one)
			if click_error != "":
				return click_error
			await _pause(0.4)
		"walk-to-creature":
			# Approach the nearest slime without swinging — used to let it bite.
			var approach_foe: Node2D = main._nearest_creature(main.player.position, 480.0)
			if approach_foe == null:
				return "附近没有史莱姆"
			var approach_id: String = main._creature_entity_id(approach_foe)
			if approach_id == "":
				return "史莱姆没有注册到实体表"
			_current.text = "走向史莱姆"
			if not await _approach(approach_id):
				return "走不到史莱姆：" + approach_id
			await _pause(WALK_PAUSE)
		"walk-attack":
			# Find the nearest slime, walk to it like a player would, then swing.
			var foe: Node2D = main._nearest_creature(main.player.position, 480.0)
			if foe == null:
				return "附近没有史莱姆"
			var foe_id: String = main._creature_entity_id(foe)
			if foe_id == "":
				return "史莱姆没有注册到实体表：" + str(foe.name)
			_current.text = "走向史莱姆并攻击"
			if not await _approach(foe_id):
				return "走不到史莱姆：" + foe_id
			await main._fire_use_action()
			await _pause(ACTION_PAUSE)
		"attack":
			# Swing at a slime already in reach (walk-attack handles approach).
			var near_foe: Node2D = main._nearest_creature(main.player.position, 48.0)
			if near_foe == null:
				return "手边没有史莱姆"
			_current.text = "F：攻击史莱姆"
			await main._fire_use_action()
			await _pause(ACTION_PAUSE)
		"assert-hp":
			if step.size() < 2:
				return "assert-hp 缺少生命值"
			var hp_view: Variant = await Game.call_async("game:hp", [])
			var have_hp := int(hp_view[0]) if hp_view is Array and hp_view.size() >= 1 else -1
			_current.text = "断言：生命 = " + str(step[1])
			if have_hp != int(step[1]):
				return "期望生命 %s，实际 %s" % [str(step[1]), str(have_hp)]
		"assert-hp-at-most":
			if step.size() < 2:
				return "assert-hp-at-most 缺少上限"
			var cap_view: Variant = await Game.call_async("game:hp", [])
			var cap_have := int(cap_view[0]) if cap_view is Array and cap_view.size() >= 1 else -1
			_current.text = "断言：生命 ≤ " + str(step[1])
			if cap_have > int(step[1]):
				return "生命 %d 高于上限 %s" % [cap_have, str(step[1])]
		"assert-game-over":
			if step.size() < 2:
				return "assert-game-over 需要 open|closed"
			if main.game_over_ui == null:
				return "结束画面不可用"
			var want_death := str(step[1]) == "open"
			_current.text = "断言：结束画面%s" % ("出现" if want_death else "未出现")
			if main.game_over_ui.is_open != want_death:
				return "结束画面状态不符"
		"assert-creature-count":
			if step.size() < 2:
				return "assert-creature-count 缺少数量"
			var live := 0
			for c in get_tree().get_nodes_in_group("creature"):
				if is_instance_valid(c):
					live += 1
			_current.text = "断言：史莱姆数量 = " + str(step[1])
			if live != int(step[1]):
				return "期望 %s 只，实际 %d 只" % [str(step[1]), live]
		"assert-npc-from-creature":
			# Threat flee: the villager must end up at least `min` px away from
			# the nearest live slime.
			if step.size() < 3:
				return "assert-npc-from-creature 需要 npc-id 与距离"
			var flee_npc: Node2D = main.npc_node(str(step[1]))
			if flee_npc == null:
				return "找不到 NPC：" + str(step[1])
			var flee_foe: Node2D = main._nearest_creature(flee_npc.position, 9999.0)
			if flee_foe == null:
				return "附近没有史莱姆"
			var flee_d: float = flee_npc.position.distance_to(flee_foe.position)
			_current.text = "断言：%s 距史莱姆 ≥ %s px" % [str(step[1]), str(step[2])]
			if flee_d < float(step[2]):
				return "距离只有 %.1f px" % flee_d
		"assert-group-count":
			if step.size() < 3:
				return "assert-group-count 需要组名与数量"
			var group := str(step[1])
			var want_cnt := int(step[2])
			var have_cnt := get_tree().get_nodes_in_group(group).size()
			_current.text = "断言：组 %s 数量 = %d" % [group, want_cnt]
			if have_cnt != want_cnt:
				return "期望 %d，实际 %d" % [want_cnt, have_cnt]
		"assert-log":
			if step.size() < 2:
				return "assert-log 缺少文本"
			var needle := str(step[1])
			_current.text = "断言：消息出现 → " + needle
			var found := false
			for line_text in main._log_history:
				if needle in str(line_text):
					found = true
					break
			if not found:
				return "消息未出现：" + needle
		"assert-story-fact":
			# (assert-story-fact key [value]) — read Scheme's fact bag through
			# the bridge mirror, not a shell-local copy.
			if step.size() < 2:
				return "assert-story-fact 缺少 fact id"
			var fact_key := str(step[1])
			var facts_v: Variant = await Game.call_async("game:story-facts", [])
			var found_v: Variant = null
			var found_fact := false
			if facts_v is Array:
				for row in facts_v:
					if row is Array and row.size() >= 2 and str(row[0]) == fact_key:
						found_v = row[1]
						found_fact = true
						break
			_current.text = "断言：剧情 fact " + fact_key
			if not found_fact:
				return "fact 不存在：" + fact_key
			if step.size() >= 3 and str(found_v) != str(step[2]):
				return "fact 期望 %s，实际 %s" % [str(step[2]), str(found_v)]
		"assert-story-fact-absent":
			if step.size() < 2:
				return "assert-story-fact-absent 缺少 fact id"
			var absent_key := str(step[1])
			var facts_absent: Variant = await Game.call_async("game:story-facts", [])
			var present_absent := false
			if facts_absent is Array:
				for row in facts_absent:
					if row is Array and row.size() >= 1 and str(row[0]) == absent_key:
						present_absent = true
						break
			_current.text = "断言：剧情 fact 不存在 " + absent_key
			if present_absent:
				return "fact 仍存在：" + absent_key
		"assert-story-beat":
			if step.size() < 2:
				return "assert-story-beat 缺少 beat id"
			var beat_v: Variant = await Game.call_async("game:story-status", [])
			var last_beat := str(beat_v[2]) if beat_v is Array and beat_v.size() >= 3 else ""
			_current.text = "断言：最近 beat " + str(step[1])
			if last_beat != str(step[1]):
				return "最近 beat 期望 %s，实际 %s" % [str(step[1]), last_beat]
		"assert-story-panel":
			if step.size() < 2:
				return "assert-story-panel 需要 open|closed"
			if main.story_ui == null:
				return "剧情演出面板不可用"
			var want_story_open := str(step[1]) == "open"
			_current.text = "断言：剧情面板%s" % ("打开" if want_story_open else "关闭")
			if main.story_ui.is_open != want_story_open:
				return "期望%s，实际%s" % [
						"打开" if want_story_open else "关闭",
						"打开" if main.story_ui.is_open else "关闭"]
		"assert-story-line":
			if step.size() < 2:
				return "assert-story-line 缺少文本"
			if main.story_ui == null or not main.story_ui.is_open:
				return "剧情面板没有打开"
			var needle_story := str(step[1])
			var line_story: String = main.story_ui.current_line()
			_current.text = "断言：剧情台词包含 " + needle_story
			if not needle_story in line_story:
				return "台词不匹配：" + line_story
		"story-skip":
			# Dismiss a cutscene through the panel's own close path (the same one
			# the GM console and a player's Esc use), not a Scheme backdoor.
			if main.story_ui != null and main.story_ui.is_open:
				main.story_ui.close()
			_current.text = "跳过剧情演出"
			await _pause(0.2)
		"story-beat":
			# Manual trigger for a deterministic beat test. The same effect path
			# plays as a naturally fired beat; only the trigger is scripted.
			if step.size() < 2:
				return "story-beat 缺少 beat id"
			var fired: Variant = await Game.call_async("game:debug-story-beat", [str(step[1])])
			Game.send("game:story-status")
			main._poll_effects()
			_current.text = "触发剧情 beat：" + str(step[1])
			if not bool(fired):
				return "beat 未触发：" + str(step[1])
			await _pause(0.4)
		"story-place":
			if step.size() < 2:
				return "story-place 缺少锚点名"
			await Game.call_async("game:story-place", [str(step[1])])
			_current.text = "剧情位置：" + str(step[1])
		"assert-audio":
			# Counts cues that actually reached a player. Cue paths resolve on
			# the logic worker the first time a key is used, so a short pause
			# before the assertion lets an in-flight lookup land.
			if step.size() < 2:
				return "assert-audio 缺少音效键"
			var cue := str(step[1])
			var want_cue := int(step[2]) if step.size() >= 3 else 1
			var have_cue := int(Audio.played.get(cue, 0))
			_current.text = "断言：音效 %s 播放 ≥ %d 次" % [cue, want_cue]
			if have_cue < want_cue:
				return "期望 %s 至少 %d 次，实际 %d 次" % [cue, want_cue, have_cue]
		"assert-ambience":
			if step.size() < 3:
				return "assert-ambience 需要键与 on|off"
			var amb_key := str(step[1])
			var want_on := str(step[2]).to_lower() == "on"
			var have_on := bool(Audio.ambience.get(amb_key, false))
			_current.text = "断言：环境音 %s = %s" % [amb_key, "on" if want_on else "off"]
			if have_on != want_on:
				return "期望 %s=%s，实际 %s" % [amb_key, want_on, have_on]
		"backup-audio-settings":
			_audio_backup = Audio.volume_snapshot()
			_current.text = "记下当前音量，验收结束后恢复"
		"restore-audio-settings":
			Audio.apply_volumes(_audio_backup)
			if main.volume_ui != null:
				main.volume_ui.refresh()
			_current.text = "恢复验收前的音量"
		"assert-volume-panel":
			if step.size() < 2:
				return "assert-volume-panel 需要 open|closed"
			if main.volume_ui == null:
				return "音量面板不可用"
			var want_vol_open := str(step[1]).to_lower() == "open"
			_current.text = "断言：音量面板%s" % ("打开" if want_vol_open else "关闭")
			if main.volume_ui.is_open != want_vol_open:
				return "期望%s，实际%s" % [
						"打开" if want_vol_open else "关闭",
						"打开" if main.volume_ui.is_open else "关闭"]
		"set-volume":
			# Drive the actual HSlider: value_changed fires and the Audio bus is
			# updated by the same handler a mouse drag uses.
			if step.size() < 3:
				return "set-volume 需要通道与 0-1 的值"
			if main.volume_ui == null or not main.volume_ui.is_open:
				return "音量面板没有打开"
			var vol_key := str(step[1]).to_lower()
			if Audio.bus_for_key(vol_key) == "":
				return "未知音量通道：" + vol_key
			var vol_value := clampf(float(step[2]), 0.0, 1.0)
			_current.text = "拖动 %s 滑条 → %d%%" % [vol_key, roundi(vol_value * 100.0)]
			main.volume_ui.set_slider(vol_key, vol_value)
			Audio.save_settings()  # flush the debounce so the disk assert is stable
			await _pause(0.3)
		"assert-volume":
			if step.size() < 3:
				return "assert-volume 需要通道与 0-1 的值"
			var av_key := str(step[1]).to_lower()
			var av_bus := Audio.bus_for_key(av_key)
			if av_bus == "":
				return "未知音量通道：" + av_key
			var av_want := clampf(float(step[2]), 0.0, 1.0)
			var av_have := Audio.get_bus_volume(av_bus)
			_current.text = "断言：%s 音量 = %d%%" % [av_key, roundi(av_want * 100.0)]
			if absf(av_have - av_want) > 0.02:
				return "期望 %s=%.2f，实际 %.2f" % [av_key, av_want, av_have]
			var av_text: String = str(main.volume_ui.percent_text(av_key)) if main.volume_ui != null else ""
			if av_text != "" and av_text != ("%d%%" % roundi(av_want * 100.0)):
				return "滑条显示 %s，期望 %d%%" % [av_text, roundi(av_want * 100.0)]
		"reload-audio-settings":
			# Same code path a fresh process runs at startup.
			Audio.reload_settings()
			if main.volume_ui != null:
				main.volume_ui.refresh()
			_current.text = "从 user://settings.cfg 重读音量（等价于重开游戏）"
		"assert-volume-saved":
			Audio.save_settings()
			var vol_cfg := ConfigFile.new()
			if vol_cfg.load("user://settings.cfg") != OK:
				return "读不到 user://settings.cfg"
			if not Audio.volume_saved:
				return "音量写入配置失败"
			for vol_pair in [["master", "Master"], ["music", "Music"], ["sfx", "SFX"]]:
				var saved := float(vol_cfg.get_value("audio", vol_pair[0], -1.0))
				var live := Audio.get_bus_volume(str(vol_pair[1]))
				if absf(saved - live) > 0.001:
					return "%s 存盘 %.3f，实际 %.3f" % [vol_pair[0], saved, live]
			_current.text = "断言：三个音量都已写入 settings.cfg 且与总线一致"
		"assert-ai-quality":
			if step.size() < 2:
				return "assert-ai-quality 缺少档位"
			var want_ai := str(step[1]).to_lower()
			var have_ai := str(Game.snapshot.get("ai_quality", ""))
			_current.text = "断言：AI 档位 = %s" % want_ai
			if have_ai != want_ai:
				return "期望 %s，实际 %s" % [want_ai, have_ai]
		"assert-start-ai-quality":
			# The startup level comes from THEFORD_AI_QUALITY; empty means
			# medium. Checking it here (before any GM switch) proves the env
			# var was applied, without hard-coding which level the run uses.
			var env_raw := OS.get_environment("THEFORD_AI_QUALITY").strip_edges().to_lower()
			var want_start := "medium"
			match env_raw:
				"", "2", "medium": want_start = "medium"
				"0", "off": want_start = "off"
				"1", "low": want_start = "low"
				"3", "high": want_start = "high"
			var have_start := str(Game.snapshot.get("ai_quality", ""))
			_current.text = "断言：启动档位与环境变量一致（%s）" % want_start
			if have_start != want_start:
				return "THEFORD_AI_QUALITY=%s 应得到 %s，实际 %s" % [env_raw, want_start, have_start]
		"assert-turn-source":
			if step.size() < 2:
				return "assert-turn-source 缺少来源（llm|cache|canned|fallback）"
			var want_src := str(step[1]).to_lower()
			var turn: Dictionary = Game.snapshot.get("last_turn", {})
			var have_src := str(turn.get("source", "")) if turn is Dictionary else ""
			_current.text = "断言：上一轮台词来源 = %s" % want_src
			if have_src != want_src:
				return "期望 %s，实际 %s" % [want_src, have_src if have_src != "" else "（还没有对话）"]
		"assert-prompt-contains":
			# Phase 10.5: the prompt is assembled on the logic thread. Fetch the
			# exact string a turn would build, without running the model.
			if step.size() < 4:
				return "assert-prompt-contains 需要 npc、topic 与文本片段"
			var prompt: Variant = await Game.call_async("game:debug-talk-prompt",
					[str(step[1]), str(step[2])])
			if not (prompt is String):
				return "没有取到 prompt（%s）" % str(prompt)
			_last_prompt = prompt
			var want_frag := str(step[3])
			_current.text = "断言：prompt 含「%s」" % want_frag
			if not prompt.contains(want_frag):
				return "prompt 里没有「%s」\n%s" % [want_frag, _prompt_context(prompt)]
		"assert-prompt-changed":
			# Same npc/topic, new clock or weather: the injected situation line
			# must differ, otherwise a cached reply could never mention it.
			if step.size() < 3:
				return "assert-prompt-changed 需要 npc 与 topic"
			var prompt2: Variant = await Game.call_async("game:debug-talk-prompt",
					[str(step[1]), str(step[2])])
			if not (prompt2 is String):
				return "没有取到 prompt（%s）" % str(prompt2)
			var before := _prompt_context(_last_prompt)
			var after := _prompt_context(prompt2)
			_last_prompt = prompt2
			_current.text = "断言：情境行已变化\n%s → %s" % [before, after]
			if before == "" or before == after:
				return "情境行没有变化（%s）" % after
		"assert-save-exists":
			var save_path := "user://save1.scm"
			if step.size() >= 2:
				save_path = str(step[1])
			_current.text = "断言：存档存在 " + save_path
			if not FileAccess.file_exists(save_path):
				return "存档不存在：" + save_path
		"assert-save-text":
			if step.size() < 2:
				return "assert-save-text 需要片段"
			var sf := FileAccess.open("user://save1.scm", FileAccess.READ)
			if sf == null:
				return "读不到存档"
			var save_text := sf.get_as_text()
			sf.close()
			var fragment := str(step[1])
			_current.text = "断言：存档源码含「%s」" % fragment
			if not save_text.contains(fragment):
				return "存档里没有「%s」" % fragment
		"delete-save":
			var dir := DirAccess.open("user://")
			if dir != null and dir.file_exists("save1.scm"):
				dir.remove("save1.scm")
			_current.text = "删除存档（模拟从未玩过）"
		"assert-clock":
			if step.size() < 2:
				return "assert-clock 缺少时间"
			var wd := -1
			var wh := -1
			var wm := -1
			if step.size() >= 4:
				wd = int(step[1]); wh = int(step[2]); wm = int(step[3])
			else:
				var parts := str(step[1]).split(":")
				if parts.size() >= 2:
					wh = int(parts[0]); wm = int(parts[1])
				else:
					# Hour-only check: GM reload briefly resumes time before a
					# later `speed 0` lands, so the minute may have ticked on.
					wh = int(parts[0])
				if step.size() >= 3:
					wd = int(step[2])
			var hd := int(Game.snapshot.get("day", 1))
			var hh := int(Game.snapshot.get("hour", 0))
			var hm := int(Game.snapshot.get("minute", 0))
			_current.text = "断言：时钟 = 第 %d 天 %02d:%02d" % [hd, hh, hm]
			if wd >= 0 and hd != wd:
				return "期望第 %d 天，实际第 %d 天" % [wd, hd]
			if wh >= 0 and hh != wh:
				return "期望 %d 点，实际 %d 点" % [wh, hh]
			if wm >= 0 and hm != wm:
				return "期望 %d 分，实际 %d 分" % [wm, hm]
		_:
			return "未知操作：" + op
	return ""

func _pause(seconds: float) -> void:
	if fast_headless:
		# One frame is enough for injected input / RPC replies to be processed,
		# without making a 40-step replay take a minute of wall-clock time.
		await get_tree().process_frame
		return
	var wait := seconds * _pace
	if wait > 0.0:
		await get_tree().create_timer(wait).timeout

## Pull the injected situation line out of a built prompt; keeps a failed
## assertion readable instead of dumping the whole (long) LLM prompt.
func _prompt_context(prompt: String) -> String:
	var i := prompt.find("当前情境：")
	if i < 0:
		return "（没有情境行）"
	var tail := prompt.substr(i)
	var end := tail.find("\n")
	return tail if end < 0 else tail.substr(0, end)

## Transfer a painted container/bag cell by calling the panel's own handler.
## A real player clicks the cell (container_panel.gd :: _on_slot_input); in a
## headless run the display server has no window, so injected mouse events never
## reach a Control's gui_input. Going through click_slot exercises the same
## panel path — and the same game:transfer call — without depending on a screen.
func _click_container_slot(side: String, type_id: String, one: bool) -> String:
	if main.container_ui == null or not main.container_ui.is_open:
		return "容器面板没有打开"
	var idx: int = main.container_ui.slot_index(side, type_id)
	if idx < 0:
		return "容器面板里没有 %s：%s" % [side, type_id]
	_current.text = "点击%s的 %s%s" % [side, type_id, "（一个）" if one else ""]
	main.container_ui.click_slot(side, type_id, not one)
	await _pause(0.4)
	return ""

## Walk to an entity until it is within arm's reach. Uses the same grid route
## villagers take, so a replay shows the player crossing the room first.
func _approach(eid: String) -> bool:
	var node: Node2D = main.entity_node(eid)
	if node == null:
		return false
	if main.player.position.distance_to(node.position) <= 20.0:
		return true
	var point: Variant = main.approach_point(node.position, 48.0)
	if point == null:
		return false
	_current.text = "走向 %s 旁边" % eid
	return await main.walk_player_to(point, 10.0)

## Quest log rows straight from Scheme; a fresh view avoids relying on the
## snapshot's tick cadence during a paused-clock acceptance run.
func _quest_rows() -> Array:
	var view: Variant = await Game.call_async("game:quests", [])
	if view is Array and view.size() >= 3 and view[2] is Array:
		return view[2]
	return []

func _assert_near(node: Node2D, anchor: String, label: String) -> String:
	var point: Variant = main.anchor_position(anchor)
	if point == null:
		return "当前地图没有 anchor：" + anchor
	if node == null:
		return label + "节点不存在"
	_current.text = "断言：%s 位于 %s" % [label, anchor]
	if node.position.distance_to(point) > 12.0:
		return "%s 距 %s 为 %.1f px" % [label, anchor, node.position.distance_to(point)]
	return ""

func _input(event: InputEvent) -> void:
	if not _panel.visible:
		return
	if event is InputEventKey and event.pressed and not event.echo \
			and event.keycode == KEY_ESCAPE:
		if _active:
			cancel()
		else:
			_panel.visible = false
		get_viewport().set_input_as_handled()

func cancel() -> void:
	if not _active:
		return
	_active = false
	_run_id += 1
	_release_movement()
	_title.text = "验收已中止 · " + _script_name
	_current.text = "已释放模拟输入，保留当前现场"
	_hint.text = "Esc 关闭 · 可继续手动操作"
	finished.emit(false, "用户中止")

func _release_movement() -> void:
	for action in MOVE_ACTIONS:
		Input.action_release(action)
	if main != null and main.player != null:
		main.player.stop_scripted()

func _step_text(step: Variant) -> String:
	if not (step is Array) or step.is_empty():
		return "非法步骤"
	var parts: PackedStringArray = []
	for value in step:
		parts.append(str(value))
	return " ".join(parts)

func _record(prefix: String, text: String) -> void:
	_lines.append("[%s] %s" % [prefix, text])
	while _lines.size() > MAX_LOG_LINES:
		_lines.pop_front()
	_log.text = "\n".join(_lines)

func _build(font: Font) -> void:
	_panel = ColorRect.new()
	_panel.color = Color(0.04, 0.05, 0.07, 0.92)
	_panel.anchor_left = 1.0
	_panel.anchor_right = 1.0
	_panel.offset_left = -470.0
	_panel.offset_top = 16.0
	_panel.offset_right = -16.0
	_panel.offset_bottom = 310.0
	_panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_panel)

	var margin := MarginContainer.new()
	margin.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	for side in ["margin_left", "margin_top", "margin_right", "margin_bottom"]:
		margin.add_theme_constant_override(side, 10)
	_panel.add_child(margin)
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 6)
	margin.add_child(box)

	_title = _label(font, 18, Color(1.0, 0.85, 0.35))
	_current = _label(font, 15, Color(0.92, 0.95, 1.0))
	_current.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_current.custom_minimum_size.y = 48
	_log = RichTextLabel.new()
	_log.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_log.add_theme_color_override("default_color", Color(0.75, 0.82, 0.88))
	_hint = _label(font, 13, Color(0.65, 0.72, 0.78))
	if font != null:
		_log.add_theme_font_override("normal_font", font)
		_log.add_theme_font_size_override("normal_font_size", 13)
	box.add_child(_title)
	box.add_child(_current)
	box.add_child(_log)
	box.add_child(_hint)
	_panel.visible = false

func _label(font: Font, size: int, color: Color) -> Label:
	var label := Label.new()
	label.add_theme_color_override("font_color", color)
	label.add_theme_font_size_override("font_size", size)
	if font != null:
		label.add_theme_font_override("font", font)
	return label
