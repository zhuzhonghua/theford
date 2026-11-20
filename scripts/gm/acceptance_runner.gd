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
var _lines: Array[String] = []

var _panel: ColorRect
var _title: Label
var _current: Label
var _log: RichTextLabel
var _hint: Label

func setup(main_node: Node, gm_node: CanvasLayer, font: Font) -> void:
	main = main_node
	gm = gm_node
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
	var err: Variant = await Game.load_async(ProjectSettings.globalize_path(path))
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
			await _pause(seconds)
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
			var key_name := str(step[1]).to_upper()
			var keycode: int = OS.find_keycode_from_string(key_name)
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
		_:
			return "未知操作：" + op
	return ""

func _pause(seconds: float) -> void:
	var wait := seconds * _pace
	if wait > 0.0:
		await get_tree().create_timer(wait).timeout

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
