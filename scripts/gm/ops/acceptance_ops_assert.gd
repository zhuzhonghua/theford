extends RefCounted
const MOVE_ACTIONS := ["move_up", "move_down", "move_left", "move_right"]
const STEP_PAUSE := 0.45
const ACTION_PAUSE := 0.9
const GM_PAUSE := 0.8
const WALK_PAUSE := 0.4
## Acceptance op handlers (assert). Generated from the former single match;
## ctx is the runner, giving access to main / _current / _pause / helpers.
const OPS := {
	"assert-quest": "op_assert_quest",
	"assert-quest-progress": "op_assert_quest_progress",
	"assert-xp": "op_assert_xp",
	"assert-quest-panel": "op_assert_quest_panel",
	"assert-quest-panel-state": "op_assert_quest_panel_state",
	"assert-quest-panel-text": "op_assert_quest_panel_text",
	"assert-map": "op_assert_map",
	"assert-near": "op_assert_near",
	"assert-npc": "op_assert_npc",
	"assert-last-entity-type": "op_assert_last_entity_type",
	"assert-last-entity-hp": "op_assert_last_entity_hp",
	"assert-scene-entity": "op_assert_scene_entity",
	"assert-near-entity": "op_assert_near_entity",
	"assert-bag": "op_assert_bag",
	"assert-held": "op_assert_held",
	"assert-bag-slots": "op_assert_bag_slots",
	"assert-panel": "op_assert_panel",
	"assert-panel-item": "op_assert_panel_item",
	"assert-panel-slots": "op_assert_panel_slots",
	"assert-panel-icons": "op_assert_panel_icons",
	"assert-container": "op_assert_container",
	"assert-container-item": "op_assert_container_item",
	"assert-container-slots": "op_assert_container_slots",
	"assert-container-icons": "op_assert_container_icons",
	"assert-hp": "op_assert_hp",
	"assert-hp-at-most": "op_assert_hp_at_most",
	"assert-game-over": "op_assert_game_over",
	"assert-creature-count": "op_assert_creature_count",
	"assert-npc-from-creature": "op_assert_npc_from_creature",
	"assert-group-count": "op_assert_group_count",
	"assert-log": "op_assert_log",
	"assert-story-fact": "op_assert_story_fact",
	"assert-hud-message": "op_assert_hud_message",
	"assert-ui-panel": "op_assert_ui_panel",
	"assert-log-panel-text": "op_assert_log_panel_text",
	"assert-map-panel-items": "op_assert_map_panel_items",
	"assert-story-fact-absent": "op_assert_story_fact_absent",
	"assert-story-beat": "op_assert_story_beat",
	"assert-story-panel": "op_assert_story_panel",
	"assert-story-line": "op_assert_story_line",
	"assert-audio": "op_assert_audio",
	"assert-ambience": "op_assert_ambience",
	"assert-volume-panel": "op_assert_volume_panel",
	"assert-volume": "op_assert_volume",
	"assert-volume-saved": "op_assert_volume_saved",
	"assert-ai-quality": "op_assert_ai_quality",
	"assert-start-ai-quality": "op_assert_start_ai_quality",
	"assert-turn-source": "op_assert_turn_source",
	"assert-prompt-contains": "op_assert_prompt_contains",
	"assert-prompt-changed": "op_assert_prompt_changed",
	"assert-save-exists": "op_assert_save_exists",
	"assert-save-text": "op_assert_save_text",
	"assert-clock": "op_assert_clock",
}

func handle(op: String, step: Array, ctx: Object) -> Variant:
	var method: String = OPS.get(op, "")
	if method == "":
		return "__NO_OP__"
	return await call(method, step, ctx)

func op_assert_quest(step: Array, ctx: Object) -> String:
	if step.size() < 3:
		return "assert-quest 需要 quest id 与状态"
	var qid := str(step[1])
	var want_state := str(step[2])
	var qrows: Array = await ctx._quest_rows()
	var have_state := ""
	for row in qrows:
		if row is Array and row.size() >= 3 and str(row[0]) == qid:
			have_state = str(row[2])
	ctx._current.text = "断言：任务 %s = %s" % [qid, want_state]
	if have_state != want_state:
		return "期望 %s，实际 %s" % [want_state, have_state]
	return ""

func op_assert_quest_progress(step: Array, ctx: Object) -> String:
	if step.size() < 4:
		return "assert-quest-progress 需要 id、目标序号与完成数"
	var qid2 := str(step[1])
	var obj_index := int(step[2])
	var want_done := int(step[3])
	var want_need := int(step[4]) if step.size() >= 5 else -1
	var have_done := -1
	var have_need := -1
	for row in await ctx._quest_rows():
		if row is Array and row.size() >= 5 and str(row[0]) == qid2:
			var objs: Variant = row[4]
			if objs is Array and obj_index < objs.size() \
					and objs[obj_index] is Array and objs[obj_index].size() >= 3:
				have_done = int(objs[obj_index][1])
				have_need = int(objs[obj_index][2])
	ctx._current.text = "断言：%s 目标 %d = %d/%d" % [qid2, obj_index, want_done, want_need]
	if have_done != want_done:
		return "完成数期望 %d，实际 %d" % [want_done, have_done]
	if want_need >= 0 and have_need != want_need:
		return "需求数期望 %d，实际 %d" % [want_need, have_need]
	return ""

func op_assert_xp(step: Array, ctx: Object) -> String:
	if step.size() < 2:
		return "assert-xp 缺少经验值"
	var view: Variant = await Game.call_async("game:quests", [])
	var have_xp := int(view[0]) if view is Array and view.size() >= 1 else -1
	var want_xp := int(step[1])
	ctx._current.text = "断言：经验 %d" % want_xp
	if have_xp != want_xp:
		return "经验期望 %d，实际 %d" % [want_xp, have_xp]
	return ""

func op_assert_quest_panel(step: Array, ctx: Object) -> String:
	if step.size() < 2:
		return "assert-quest-panel 需要 open|closed"
	if ctx.main.quest_ui == null:
		return "任务日志面板不可用"
	var want_open := str(step[1]) == "open"
	ctx._current.text = "断言：任务日志%s" % ("打开" if want_open else "关闭")
	if ctx.main.quest_ui.is_open != want_open:
		return "期望%s，实际%s" % [
				"打开" if want_open else "关闭",
				"打开" if ctx.main.quest_ui.is_open else "关闭"]
	return ""

func op_assert_quest_panel_state(step: Array, ctx: Object) -> String:
	if step.size() < 3:
		return "assert-quest-panel-state 需要 id 与状态"
	if ctx.main.quest_ui == null or not ctx.main.quest_ui.is_open:
		return "任务日志面板没有打开"
	var qid3 := str(step[1])
	var want3 := str(step[2])
	var have3: String = str(ctx.main.quest_ui.state_for(qid3))
	ctx._current.text = "断言：日志 %s = %s" % [qid3, want3]
	if have3 != want3:
		return "期望 %s，实际 %s" % [want3, have3]
	return ""

func op_assert_quest_panel_text(step: Array, ctx: Object) -> String:
	if step.size() < 3:
		return "assert-quest-panel-text 需要 id 与文本片段"
	if ctx.main.quest_ui == null or not ctx.main.quest_ui.is_open:
		return "任务日志面板没有打开"
	var qid4 := str(step[1])
	var needle := str(step[2])
	var panel_text: String = str(ctx.main.quest_ui.text_for(qid4))
	ctx._current.text = "断言：日志 %s 含『%s』" % [qid4, needle]
	if not panel_text.contains(needle):
		return "日志没有显示『%s』：%s" % [needle, panel_text]
	return ""

func op_assert_map(step: Array, ctx: Object) -> String:
	if step.size() < 2:
		return "assert-map 缺少地图名"
	var expected := str(step[1])
	ctx._current.text = "断言：当前地图 = " + expected
	if ctx.main.current_map_id() != expected:
		return "期望 %s，实际 %s" % [expected, ctx.main.current_map_id()]
	return ""

func op_assert_near(step: Array, ctx: Object) -> String:
	if step.size() < 2:
		return "assert-near 缺少 anchor"
	return ctx._assert_near(ctx.main.player, str(step[1]), "玩家")
	return ""

func op_assert_npc(step: Array, ctx: Object) -> String:
	if step.size() < 3:
		return "assert-npc 需要 NPC id 与 anchor"
	var id_text := str(step[1])
	var npc: Node2D = ctx.main.npc_node(id_text)
	if npc == null or not npc.visible:
		return "NPC 不存在或不可见：" + id_text
	return ctx._assert_near(npc, str(step[2]), id_text)
	return ""

func op_assert_last_entity_type(step: Array, ctx: Object) -> String:
	if step.size() < 2:
		return "assert-last-entity-type 缺少类型"
	var want_type := str(step[1])
	var entry: Variant = await Game.call_async("game:debug-entity", [ctx.main.last_used_id])
	if not (entry is Array) or entry.size() < 1:
		return "最近实体不存在：" + str(ctx.main.last_used_id)
	ctx._current.text = "断言：最近实体类型 = " + want_type
	if str(entry[0]) != want_type:
		return "期望 %s，实际 %s" % [want_type, str(entry[0])]
	return ""

func op_assert_last_entity_hp(step: Array, ctx: Object) -> String:
	if step.size() < 2:
		return "assert-last-entity-hp 缺少生命值"
	var want_hp := int(step[1])
	var entry_hp: Variant = await Game.call_async("game:debug-entity", [ctx.main.last_used_id])
	if not (entry_hp is Array) or entry_hp.size() < 2:
		return "最近实体不存在：" + str(ctx.main.last_used_id)
	ctx._current.text = "断言：最近实体 HP = %d" % want_hp
	if int(entry_hp[1]) != want_hp:
		return "期望 %d，实际 %d" % [want_hp, int(entry_hp[1])]
	return ""

func op_assert_scene_entity(step: Array, ctx: Object) -> String:
	# Godot's registry + sprite state, not Scheme's: catches a stump that
	# survived a reload after Scheme already reports a healthy tree.
	if step.size() < 2:
		return "assert-scene-entity 缺少类型"
	var want_scene := str(step[1])
	ctx._current.text = "断言：场景实体类型 = " + want_scene
	var have_scene: String = ctx.main.entity_scene_type(ctx.main.last_used_id)
	if have_scene != want_scene:
		return "期望 %s，实际 %s" % [want_scene, have_scene]
	if want_scene == "fixture/tree" and not ctx.main.entity_visual_is_tree(ctx.main.last_used_id):
		return "场景里还是树桩（精灵图/缩放未恢复）"
	return ""

func op_assert_near_entity(step: Array, ctx: Object) -> String:
	if step.size() < 2:
		return "assert-near-entity 缺少实体 id"
	var near_id := str(step[1])
	if near_id == "last":
		near_id = ctx.main.last_used_id
	var near_node: Node2D = ctx.main.entity_node(near_id)
	if near_node == null:
		return "场景里没有实体：" + near_id
	var near_limit := 48.0
	if step.size() >= 3:
		near_limit = float(step[2])
	ctx._current.text = "断言：玩家仍在 %s 旁" % near_id
	var near_d: float = ctx.main.player.position.distance_to(near_node.position)
	if near_d > near_limit:
		return "距 %s 为 %.1f px（上限 %.1f）" % [near_id, near_d, near_limit]
	return ""

func op_assert_bag(step: Array, ctx: Object) -> String:
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
	ctx._current.text = "断言：背包 %s x%d" % [want_item, want_n]
	if have != want_n:
		return "期望 %s x%d，实际 x%d" % [want_item, want_n, have]
	return ""

func op_assert_held(step: Array, ctx: Object) -> String:
	# The equipped hand-slot tool: "" means nothing in hand, which is
	# exactly the state where F cannot chop. Read from Scheme's view.
	if step.size() < 2:
		return "assert-held 缺少工具类型（空串表示未装备）"
	var want_held := str(step[1])
	var held_view: Variant = await Game.call_async("game:bag", [])
	var have_held := ""
	if held_view is Array and held_view.size() >= 2:
		have_held = str(held_view[1])
	ctx._current.text = "断言：手持装备 = " + (want_held if want_held != "" else "（空）")
	if have_held != want_held:
		return "期望 %s，实际 %s" % [want_held, have_held]
	return ""

func op_assert_bag_slots(step: Array, ctx: Object) -> String:
	if step.size() < 2:
		return "assert-bag-slots 缺少槽位数"
	var want_slots := int(step[1])
	var slots_view: Variant = await Game.call_async("game:bag", [])
	var used_slots := -1
	if slots_view is Array and slots_view.size() >= 4:
		used_slots = int(slots_view[3])
	ctx._current.text = "断言：背包占用 %d 格" % want_slots
	if used_slots != want_slots:
		return "期望 %d 格，实际 %d 格" % [want_slots, used_slots]
	return ""

func op_assert_panel(step: Array, ctx: Object) -> String:
	if step.size() < 2:
		return "assert-panel 需要 open|closed"
	if ctx.main.bag_ui == null:
		return "背包面板不可用"
	var want_open := str(step[1]) == "open"
	ctx._current.text = "断言：背包面板%s" % ("打开" if want_open else "关闭")
	if ctx.main.bag_ui.is_open != want_open:
		return "期望%s，实际%s" % [
				"打开" if want_open else "关闭",
				"打开" if ctx.main.bag_ui.is_open else "关闭"]
	return ""

func op_assert_panel_item(step: Array, ctx: Object) -> String:
	if step.size() < 3:
		return "assert-panel-item 需要类型与数量"
	if ctx.main.bag_ui == null or not ctx.main.bag_ui.is_open:
		return "背包面板没有打开"
	var pi_type := str(step[1])
	var pi_want := int(step[2])
	var pi_have: int = ctx.main.bag_ui.slot_total(pi_type)
	ctx._current.text = "断言：面板 %s x%d" % [pi_type, pi_want]
	if pi_have != pi_want:
		return "期望 %s x%d，实际 x%d" % [pi_type, pi_want, pi_have]
	return ""

func op_assert_panel_slots(step: Array, ctx: Object) -> String:
	if step.size() < 2:
		return "assert-panel-slots 缺少格数"
	if ctx.main.bag_ui == null or not ctx.main.bag_ui.is_open:
		return "背包面板没有打开"
	var ps_want := int(step[1])
	var ps_have: int = ctx.main.bag_ui.filled_slots()
	ctx._current.text = "断言：面板占用 %d 格" % ps_want
	if ps_have != ps_want:
		return "期望 %d 格，实际 %d 格" % [ps_want, ps_have]
	return ""

func op_assert_panel_icons(step: Array, ctx: Object) -> String:
	if ctx.main.bag_ui == null or not ctx.main.bag_ui.is_open:
		return "背包面板没有打开"
	ctx._current.text = "断言：每个物品都加载出图标"
	# Icons resolve through the logic thread, so give the first round
	# trip a moment instead of depending on one fixed wait in the script.
	var missing: Array = []
	for attempt in range(20):
		missing = ctx.main.bag_ui.missing_icons()
		if missing.is_empty():
			break
		await ctx._pause(0.1)
	if not missing.is_empty():
		return "缺图标：" + ", ".join(missing)
	return ""

func op_assert_container(step: Array, ctx: Object) -> String:
	if step.size() < 2:
		return "assert-container 需要 open|closed"
	if ctx.main.container_ui == null:
		return "容器面板不可用"
	var want_box_open := str(step[1]) == "open"
	ctx._current.text = "断言：容器面板%s" % ("打开" if want_box_open else "关闭")
	if ctx.main.container_ui.is_open != want_box_open:
		return "期望%s，实际%s" % [
				"打开" if want_box_open else "关闭",
				"打开" if ctx.main.container_ui.is_open else "关闭"]
	return ""

func op_assert_container_item(step: Array, ctx: Object) -> String:
	if step.size() < 3:
		return "assert-container-item 需要类型与数量"
	if ctx.main.container_ui == null or not ctx.main.container_ui.is_open:
		return "容器面板没有打开"
	var ci_type := str(step[1])
	var ci_want := int(step[2])
	var ci_have: int = ctx.main.container_ui.slot_total("chest", ci_type)
	ctx._current.text = "断言：箱子 %s x%d" % [ci_type, ci_want]
	if ci_have != ci_want:
		return "期望 %s x%d，实际 x%d" % [ci_type, ci_want, ci_have]
	return ""

func op_assert_container_slots(step: Array, ctx: Object) -> String:
	if step.size() < 2:
		return "assert-container-slots 缺少格数"
	if ctx.main.container_ui == null or not ctx.main.container_ui.is_open:
		return "容器面板没有打开"
	var cs_want := int(step[1])
	var cs_have: int = ctx.main.container_ui.filled_slots("chest")
	ctx._current.text = "断言：箱子占用 %d 格" % cs_want
	if cs_have != cs_want:
		return "期望 %d 格，实际 %d 格" % [cs_want, cs_have]
	return ""

func op_assert_container_icons(step: Array, ctx: Object) -> String:
	if ctx.main.container_ui == null or not ctx.main.container_ui.is_open:
		return "容器面板没有打开"
	ctx._current.text = "断言：箱子里的物品都加载出图标"
	var box_missing: Array = []
	for attempt in range(20):
		box_missing = ctx.main.container_ui.missing_icons("chest")
		if box_missing.is_empty():
			break
		await ctx._pause(0.1)
	if not box_missing.is_empty():
		return "缺图标：" + ", ".join(box_missing)
	return ""

func op_assert_hp(step: Array, ctx: Object) -> String:
	if step.size() < 2:
		return "assert-hp 缺少生命值"
	var hp_view: Variant = await Game.call_async("game:hp", [])
	var have_hp := int(hp_view[0]) if hp_view is Array and hp_view.size() >= 1 else -1
	ctx._current.text = "断言：生命 = " + str(step[1])
	if have_hp != int(step[1]):
		return "期望生命 %s，实际 %s" % [str(step[1]), str(have_hp)]
	return ""

func op_assert_hp_at_most(step: Array, ctx: Object) -> String:
	if step.size() < 2:
		return "assert-hp-at-most 缺少上限"
	var cap_view: Variant = await Game.call_async("game:hp", [])
	var cap_have := int(cap_view[0]) if cap_view is Array and cap_view.size() >= 1 else -1
	ctx._current.text = "断言：生命 ≤ " + str(step[1])
	if cap_have > int(step[1]):
		return "生命 %d 高于上限 %s" % [cap_have, str(step[1])]
	return ""

func op_assert_game_over(step: Array, ctx: Object) -> String:
	if step.size() < 2:
		return "assert-game-over 需要 open|closed"
	if ctx.main.game_over_ui == null:
		return "结束画面不可用"
	var want_death := str(step[1]) == "open"
	ctx._current.text = "断言：结束画面%s" % ("出现" if want_death else "未出现")
	if ctx.main.game_over_ui.is_open != want_death:
		return "结束画面状态不符"
	return ""

func op_assert_creature_count(step: Array, ctx: Object) -> String:
	if step.size() < 2:
		return "assert-creature-count 缺少数量"
	var live := 0
	for c in ctx.get_tree().get_nodes_in_group("creature"):
		if is_instance_valid(c):
			live += 1
	ctx._current.text = "断言：史莱姆数量 = " + str(step[1])
	if live != int(step[1]):
		return "期望 %s 只，实际 %d 只" % [str(step[1]), live]
	return ""

func op_assert_npc_from_creature(step: Array, ctx: Object) -> String:
	# Threat flee: the villager must end up at least `min` px away from
	# the nearest live slime.
	if step.size() < 3:
		return "assert-npc-from-creature 需要 npc-id 与距离"
	var flee_npc: Node2D = ctx.main.npc_node(str(step[1]))
	if flee_npc == null:
		return "找不到 NPC：" + str(step[1])
	var flee_foe: Node2D = ctx.main._nearest_creature(flee_npc.position, 9999.0)
	if flee_foe == null:
		return "附近没有史莱姆"
	var flee_d: float = flee_npc.position.distance_to(flee_foe.position)
	ctx._current.text = "断言：%s 距史莱姆 ≥ %s px" % [str(step[1]), str(step[2])]
	if flee_d < float(step[2]):
		return "距离只有 %.1f px" % flee_d
	return ""

func op_assert_group_count(step: Array, ctx: Object) -> String:
	if step.size() < 3:
		return "assert-group-count 需要组名与数量"
	var group := str(step[1])
	var want_cnt := int(step[2])
	var have_cnt: int = ctx.get_tree().get_nodes_in_group(group).size()
	ctx._current.text = "断言：组 %s 数量 = %d" % [group, want_cnt]
	if have_cnt != want_cnt:
		return "期望 %d，实际 %d" % [want_cnt, have_cnt]
	return ""

func op_assert_log(step: Array, ctx: Object) -> String:
	if step.size() < 2:
		return "assert-log 缺少文本"
	var needle := str(step[1])
	ctx._current.text = "断言：消息出现 → " + needle
	var found := false
	for line_text in ctx.main._log_history:
		if needle in str(line_text):
			found = true
			break
	if not found:
		return "消息未出现：" + needle
	return ""

func op_assert_story_fact(step: Array, ctx: Object) -> String:
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
	ctx._current.text = "断言：剧情 fact " + fact_key
	if not found_fact:
		return "fact 不存在：" + fact_key
	if step.size() >= 3 and str(found_v) != str(step[2]):
		return "fact 期望 %s，实际 %s" % [str(step[2]), str(found_v)]
	return ""

func op_assert_hud_message(step: Array, ctx: Object) -> String:
	if step.size() < 2:
		return "assert-hud-message 缺少文本"
	if ctx.main.hud_bar == null:
		return "HUD 不可用"
	var needle_hud := str(step[1])
	ctx._current.text = "断言：消息栈含 " + needle_hud
	if not needle_hud in ctx.main.hud_bar.messages_text():
		return "消息栈未包含：" + needle_hud
	return ""

func op_assert_ui_panel(step: Array, ctx: Object) -> String:
	if step.size() < 3:
		return "assert-ui-panel 需要面板名与 open|closed"
	var which_panel := str(step[1])
	var want_panel_open := str(step[2]) == "open"
	var target_panel: Variant = ctx.main.panel_named(which_panel)
	if target_panel == null:
		return "未知面板：" + which_panel
	if target_panel == null:
		return "面板不可用：" + which_panel
	ctx._current.text = "断言：面板 %s %s" % [which_panel, "打开" if want_panel_open else "关闭"]
	if bool(target_panel.is_open) != want_panel_open:
		return "期望%s，实际%s" % [
			"打开" if want_panel_open else "关闭",
			"打开" if bool(target_panel.is_open) else "关闭"]
	return ""

func op_assert_log_panel_text(step: Array, ctx: Object) -> String:
	if step.size() < 2:
		return "assert-log-panel-text 缺少文本"
	if ctx.main.log_panel == null or not ctx.main.log_panel.is_open:
		return "日志面板没有打开"
	var needle_log := str(step[1])
	ctx._current.text = "断言：日志面板含 " + needle_log
	if not needle_log in ctx.main.log_panel.log_text():
		return "日志面板未包含：" + needle_log
	return ""

func op_assert_map_panel_items(step: Array, ctx: Object) -> String:
	if ctx.main.map_panel == null or not ctx.main.map_panel.is_open:
		return "地图面板没有打开"
	var count_map: int = ctx.main.map_panel.item_count()
	ctx._current.text = "断言：地图上有至少 %d 个标记" % int(step[1]) if step.size() >= 2 else "断言：地图有标记"
	var need_map := int(step[1]) if step.size() >= 2 else 1
	if count_map < need_map:
		return "地图标记不足：%d < %d" % [count_map, need_map]
	return ""

func op_assert_story_fact_absent(step: Array, ctx: Object) -> String:
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
	ctx._current.text = "断言：剧情 fact 不存在 " + absent_key
	if present_absent:
		return "fact 仍存在：" + absent_key
	return ""

func op_assert_story_beat(step: Array, ctx: Object) -> String:
	if step.size() < 2:
		return "assert-story-beat 缺少 beat id"
	var beat_v: Variant = await Game.call_async("game:story-status", [])
	var last_beat := str(beat_v[2]) if beat_v is Array and beat_v.size() >= 3 else ""
	ctx._current.text = "断言：最近 beat " + str(step[1])
	if last_beat != str(step[1]):
		return "最近 beat 期望 %s，实际 %s" % [str(step[1]), last_beat]
	return ""

func op_assert_story_panel(step: Array, ctx: Object) -> String:
	if step.size() < 2:
		return "assert-story-panel 需要 open|closed"
	if ctx.main.story_ui == null:
		return "剧情演出面板不可用"
	var want_story_open := str(step[1]) == "open"
	ctx._current.text = "断言：剧情面板%s" % ("打开" if want_story_open else "关闭")
	if ctx.main.story_ui.is_open != want_story_open:
		return "期望%s，实际%s" % [
				"打开" if want_story_open else "关闭",
				"打开" if ctx.main.story_ui.is_open else "关闭"]
	return ""

func op_assert_story_line(step: Array, ctx: Object) -> String:
	if step.size() < 2:
		return "assert-story-line 缺少文本"
	if ctx.main.story_ui == null or not ctx.main.story_ui.is_open:
		return "剧情面板没有打开"
	var needle_story := str(step[1])
	var line_story: String = ctx.main.story_ui.current_line()
	ctx._current.text = "断言：剧情台词包含 " + needle_story
	if not needle_story in line_story:
		return "台词不匹配：" + line_story
	return ""

func op_assert_audio(step: Array, ctx: Object) -> String:
	# Counts cues that actually reached a player. Cue paths resolve on
	# the logic worker the first time a key is used, so a short pause
	# before the assertion lets an in-flight lookup land.
	if step.size() < 2:
		return "assert-audio 缺少音效键"
	var cue := str(step[1])
	var want_cue := int(step[2]) if step.size() >= 3 else 1
	var have_cue := int(Audio.played.get(cue, 0))
	ctx._current.text = "断言：音效 %s 播放 ≥ %d 次" % [cue, want_cue]
	if have_cue < want_cue:
		return "期望 %s 至少 %d 次，实际 %d 次" % [cue, want_cue, have_cue]
	return ""

func op_assert_ambience(step: Array, ctx: Object) -> String:
	if step.size() < 3:
		return "assert-ambience 需要键与 on|off"
	var amb_key := str(step[1])
	var want_on := str(step[2]).to_lower() == "on"
	var have_on := bool(Audio.ambience.get(amb_key, false))
	ctx._current.text = "断言：环境音 %s = %s" % [amb_key, "on" if want_on else "off"]
	if have_on != want_on:
		return "期望 %s=%s，实际 %s" % [amb_key, want_on, have_on]
	return ""

func op_assert_volume_panel(step: Array, ctx: Object) -> String:
	if step.size() < 2:
		return "assert-volume-panel 需要 open|closed"
	if ctx.main.volume_ui == null:
		return "音量面板不可用"
	var want_vol_open := str(step[1]).to_lower() == "open"
	ctx._current.text = "断言：音量面板%s" % ("打开" if want_vol_open else "关闭")
	if ctx.main.volume_ui.is_open != want_vol_open:
		return "期望%s，实际%s" % [
				"打开" if want_vol_open else "关闭",
				"打开" if ctx.main.volume_ui.is_open else "关闭"]
	return ""

func op_assert_volume(step: Array, ctx: Object) -> String:
	if step.size() < 3:
		return "assert-volume 需要通道与 0-1 的值"
	var av_key := str(step[1]).to_lower()
	var av_bus := Audio.bus_for_key(av_key)
	if av_bus == "":
		return "未知音量通道：" + av_key
	var av_want := clampf(float(step[2]), 0.0, 1.0)
	var av_have := Audio.get_bus_volume(av_bus)
	ctx._current.text = "断言：%s 音量 = %d%%" % [av_key, roundi(av_want * 100.0)]
	if absf(av_have - av_want) > 0.02:
		return "期望 %s=%.2f，实际 %.2f" % [av_key, av_want, av_have]
	var av_text: String = str(ctx.main.volume_ui.percent_text(av_key)) if ctx.main.volume_ui != null else ""
	if av_text != "" and av_text != ("%d%%" % roundi(av_want * 100.0)):
		return "滑条显示 %s，期望 %d%%" % [av_text, roundi(av_want * 100.0)]
	return ""

func op_assert_volume_saved(step: Array, ctx: Object) -> String:
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
	ctx._current.text = "断言：三个音量都已写入 settings.cfg 且与总线一致"
	return ""

func op_assert_ai_quality(step: Array, ctx: Object) -> String:
	if step.size() < 2:
		return "assert-ai-quality 缺少档位"
	var want_ai := str(step[1]).to_lower()
	var have_ai := str(Game.snapshot.get("ai_quality", ""))
	ctx._current.text = "断言：AI 档位 = %s" % want_ai
	if have_ai != want_ai:
		return "期望 %s，实际 %s" % [want_ai, have_ai]
	return ""

func op_assert_start_ai_quality(step: Array, ctx: Object) -> String:
	# The startup level comes from THEFORD_AI_QUALITY; empty means
	# medium. Checking it here (before any GM switch) proves the env
	# var was applied, without hard-coding which level the run uses.
	var env_raw := OS.get_environment("THEFORD_AI_QUALITY").strip_edges().to_lower()
	var want_start := "medium"
	match env_raw:
		"", "2", "medium": want_start = "medium"
		"0", "off", "1", "low": want_start = "low"
		"1", "low": want_start = "low"
		"3", "high": want_start = "high"
	var have_start := str(Game.snapshot.get("ai_quality", ""))
	ctx._current.text = "断言：启动档位与环境变量一致（%s）" % want_start
	if have_start != want_start:
		return "THEFORD_AI_QUALITY=%s 应得到 %s，实际 %s" % [env_raw, want_start, have_start]
	return ""

func op_assert_turn_source(step: Array, ctx: Object) -> String:
	if step.size() < 2:
		return "assert-turn-source 缺少来源（llm|cache|canned|fallback）"
	var want_src := str(step[1]).to_lower()
	var turn: Dictionary = Game.snapshot.get("last_turn", {})
	var have_src := str(turn.get("source", "")) if turn is Dictionary else ""
	ctx._current.text = "断言：上一轮台词来源 = %s" % want_src
	if have_src != want_src:
		return "期望 %s，实际 %s" % [want_src, have_src if have_src != "" else "（还没有对话）"]
	return ""

func op_assert_prompt_contains(step: Array, ctx: Object) -> String:
	# Phase 10.5: the prompt is assembled on the logic thread. Fetch the
	# exact string a turn would build, without running the model.
	if step.size() < 4:
		return "assert-prompt-contains 需要 npc、topic 与文本片段"
	var prompt: Variant = await Game.call_async("game:debug-talk-prompt",
			[str(step[1]), str(step[2])])
	if not (prompt is String):
		return "没有取到 prompt（%s）" % str(prompt)
	ctx._last_prompt = prompt
	var want_frag := str(step[3])
	ctx._current.text = "断言：prompt 含「%s」" % want_frag
	if not prompt.contains(want_frag):
		return "prompt 里没有「%s」\n%s" % [want_frag, ctx._prompt_context(prompt)]
	return ""

func op_assert_prompt_changed(step: Array, ctx: Object) -> String:
	# Same npc/topic, new clock or weather: the injected situation line
	# must differ, otherwise a cached reply could never mention it.
	if step.size() < 3:
		return "assert-prompt-changed 需要 npc 与 topic"
	var prompt2: Variant = await Game.call_async("game:debug-talk-prompt",
			[str(step[1]), str(step[2])])
	if not (prompt2 is String):
		return "没有取到 prompt（%s）" % str(prompt2)
	var before: String = ctx._prompt_context(ctx._last_prompt)
	var after: String = ctx._prompt_context(prompt2)
	ctx._last_prompt = prompt2
	ctx._current.text = "断言：情境行已变化\n%s → %s" % [before, after]
	if before == "" or before == after:
		return "情境行没有变化（%s）" % after
	return ""

func op_assert_save_exists(step: Array, ctx: Object) -> String:
	var save_path := "user://save1.scm"
	if step.size() >= 2:
		save_path = str(step[1])
	ctx._current.text = "断言：存档存在 " + save_path
	if not FileAccess.file_exists(save_path):
		return "存档不存在：" + save_path
	return ""

func op_assert_save_text(step: Array, ctx: Object) -> String:
	if step.size() < 2:
		return "assert-save-text 需要片段"
	var sf := FileAccess.open("user://save1.scm", FileAccess.READ)
	if sf == null:
		return "读不到存档"
	var save_text := sf.get_as_text()
	sf.close()
	var fragment := str(step[1])
	ctx._current.text = "断言：存档源码含「%s」" % fragment
	if not save_text.contains(fragment):
		return "存档里没有「%s」" % fragment
	return ""

func op_assert_clock(step: Array, ctx: Object) -> String:
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
	ctx._current.text = "断言：时钟 = 第 %d 天 %02d:%02d" % [hd, hh, hm]
	if wd >= 0 and hd != wd:
		return "期望第 %d 天，实际第 %d 天" % [wd, hd]
	if wh >= 0 and hh != wh:
		return "期望 %d 点，实际 %d 点" % [wh, hh]
	if wm >= 0 and hm != wm:
		return "期望 %d 分，实际 %d 分" % [wm, hm]
	return ""

