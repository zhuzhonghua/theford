extends RefCounted
const MOVE_ACTIONS := ["move_up", "move_down", "move_left", "move_right"]
const STEP_PAUSE := 0.45
const ACTION_PAUSE := 0.9
const GM_PAUSE := 0.8
const WALK_PAUSE := 0.4
## Acceptance op handlers (action). Generated from the former single match;
## ctx is the runner, giving access to main / _current / _pause / helpers.
const OPS := {
	"pace": "op_pace",
	"note": "op_note",
	"gm": "op_gm",
	"move": "op_move",
	"wait": "op_wait",
	"goto-map": "op_goto_map",
	"place": "op_place",
	"walk": "op_walk",
	"walk-interact": "op_walk_interact",
	"walk-use": "op_walk_use",
	"use": "op_use",
	"interact": "op_interact",
	"drain": "op_drain",
	"walk-to-creature": "op_walk_to_creature",
	"walk-attack": "op_walk_attack",
	"attack": "op_attack",
}

func handle(op: String, step: Array, ctx: Object) -> Variant:
	var method: String = OPS.get(op, "")
	if method == "":
		return "__NO_OP__"
	return await call(method, step, ctx)

func op_pace(step: Array, ctx: Object) -> String:
	if step.size() < 2:
		return "pace 缺少倍率"
	ctx._pace = maxf(0.2, float(step[1]))
	ctx._current.text = "回放节奏 ×%.2f" % ctx._pace
	return ""

func op_note(step: Array, ctx: Object) -> String:
	if step.size() < 2:
		return "note 缺少说明"
	var text := str(step[1])
	# Read time scales with the text; the script's own value is a floor.
	var hold := clampf(0.9 + float(text.length()) * 0.12, 1.4, 4.5)
	if step.size() >= 3:
		hold = maxf(hold, float(step[2]))
	ctx._current.text = text
	await ctx._pause(hold)
	return ""

func op_gm(step: Array, ctx: Object) -> String:
	if step.size() < 2:
		return "ctx.gm 缺少指令"
	var command := str(step[1])
	ctx._current.text = "GM > " + command
	var out: String = await ctx.gm.execute(command)
	if out != "":
		ctx._current.text += "\n" + out
	# 让用户看到 GM 指令生效的结果，再往下走。
	await ctx._pause(GM_PAUSE)
	return ""

func op_move(step: Array, ctx: Object) -> String:
	if step.size() < 3:
		return "move 需要 action 与目标地图"
	var action := str(step[1])
	var target := str(step[2])
	if not MOVE_ACTIONS.has(action):
		return "move 仅支持方向动作：" + action
	ctx._current.text = "持续输入 %s → %s" % [action, target]
	Input.action_press(action)
	var elapsed := 0.0
	while ctx.main.current_map_id() != target or ctx.main.map_transitioning():
		if not ctx._active:
			Input.action_release(action)
			return "已中止"
		await ctx.get_tree().process_frame
		elapsed += ctx.get_process_delta_time()
		if elapsed > 6.0:
			Input.action_release(action)
			return "移动超时，未到地图 " + target
	Input.action_release(action)
	# Let the normal portal pass observe the release and rearm.
	await ctx._pause(0.2)
	return ""

func op_wait(step: Array, ctx: Object) -> String:
	if step.size() < 2:
		return "wait 缺少秒数"
	var seconds := float(step[1])
	ctx._current.text = "观察画面（%.1f 秒）" % seconds
	if ctx.fast_headless:
		# Keep a short real interval: story beats and timed effects run
		# on game ticks, which still advance at normal wall-clock speed.
		await ctx.get_tree().create_timer(minf(seconds, 1.2)).timeout
	else:
		await ctx._pause(seconds)
	return ""

func op_goto_map(step: Array, ctx: Object) -> String:
	if step.size() < 3:
		return "goto-map 需要地图与锚点"
	var map_id := str(step[1])
	var at := str(step[2])
	if map_id == ctx.main.current_map_id():
		# Same map: walk, do not teleport. Cross-map stays a door cut.
		var gm_bare := at.get_slice(":", 1) if at.contains(":") else at
		var gm_point: Variant = ctx.main.anchor_position(gm_bare)
		if gm_point == null:
			return "当前地图没有锚点：" + at
		ctx._current.text = "走向 %s:%s" % [map_id, at]
		if not await ctx.main.walk_player_to(gm_point, 12.0):
			return "走不到 %s:%s" % [map_id, at]
		await ctx._pause(WALK_PAUSE)
	else:
		ctx._current.text = "切换地图 → %s:%s" % [map_id, at]
		await ctx.main._switch_map(map_id, at)
		await ctx._pause(0.5)
	return ""

func op_place(step: Array, ctx: Object) -> String:
	if step.size() < 3:
		return "place 需要地图与锚点"
	var pmap := str(step[1])
	var pat := str(step[2])
	var pb := pat.get_slice(":", 1) if pat.contains(":") else pat
	if pmap != ctx.main.current_map_id():
		ctx._current.text = "把玩家放到 %s:%s" % [pmap, pat]
		await ctx.main._switch_map(pmap, pat)
	else:
		var pp: Variant = ctx.main.anchor_position(pb)
		if pp == null:
			return "当前地图没有锚点：" + pat
		ctx._current.text = "把玩家放到 %s:%s" % [pmap, pat]
		ctx.main.player.stop_scripted()
		ctx.main.player.position = pp
	await ctx._pause(0.5)
	return ""

func op_walk(step: Array, ctx: Object) -> String:
	if step.size() < 2:
		return "walk 缺少锚点"
	var anchor := str(step[1])
	var walk_bare := anchor.get_slice(":", 1) if anchor.contains(":") else anchor
	var walk_point: Variant = ctx.main.anchor_position(walk_bare)
	if walk_point == null:
		walk_point = ctx.main.portal_position(walk_bare)
	if walk_point == null:
		return "当前地图没有锚点或 portal：" + anchor
	ctx._current.text = "走向 " + anchor
	if not await ctx.main.walk_player_to(walk_point, 12.0):
		return "走不到 " + anchor
	await ctx._pause(WALK_PAUSE)
	return ""

func op_walk_interact(step: Array, ctx: Object) -> String:
	ctx._current.text = "寻找附近的可互动物体"
	var wi_target: String = ctx.main._nearest_interactable(ctx.main.player.position, 480.0)
	if wi_target == "":
		return "附近没有可互动物体"
	if not await ctx._approach(wi_target):
		return "走不到可互动物体：" + wi_target
	ctx._current.text = "E：与 %s 互动" % wi_target
	await ctx.main._interact_entity(wi_target)
	await ctx._pause(ACTION_PAUSE)
	return ""

func op_walk_use(step: Array, ctx: Object) -> String:
	ctx._current.text = "寻找附近能砍的树"
	var wu_tree: Array = ctx.main._nearest_of_types(ctx.main.player.position, 480.0, ["fixture/tree"])
	if wu_tree[0] == null:
		return "附近没有树"
	if not await ctx._approach(str(wu_tree[0])):
		return "走不到树：" + str(wu_tree[0])
	ctx._current.text = "F：用手持工具砍树"
	await ctx.main._fire_use_action()
	await ctx._pause(ACTION_PAUSE)
	return ""

func op_use(step: Array, ctx: Object) -> String:
	ctx._current.text = "F：使用手持工具"
	var use_tree: Array = ctx.main._nearest_of_types(ctx.main.player.position, 480.0, ["fixture/tree"])
	if use_tree[0] == null:
		return "附近没有树"
	if ctx.main.player.position.distance_to(use_tree[1].position) > 48.0:
		if not await ctx._approach(str(use_tree[0])):
			return "走不到树：" + str(use_tree[0])
	await ctx.main._fire_use_action()
	await ctx._pause(ACTION_PAUSE)
	return ""

func op_interact(step: Array, ctx: Object) -> String:
	ctx._current.text = "E：与最近的可互动物体互动"
	var in_target: String = ctx.main._nearest_interactable(ctx.main.player.position, 480.0)
	if in_target == "":
		return "附近没有可互动物体"
	var in_node: Node2D = ctx.main.entity_node(in_target)
	if in_node != null and ctx.main.player.position.distance_to(in_node.position) > 48.0:
		if not await ctx._approach(in_target):
			return "走不到可互动物体：" + in_target
	await ctx.main._interact_entity(in_target)
	await ctx._pause(ACTION_PAUSE)
	return ""

func op_drain(step: Array, ctx: Object) -> String:
	ctx._current.text = "取回规则引擎排队的延时效果"
	var drained: Variant = await Game.call_async("game:drain-effects", [])
	ctx.main._apply_effects(drained)
	await ctx._pause(0.3)
	return ""

func op_walk_to_creature(step: Array, ctx: Object) -> String:
	# Approach the nearest slime without swinging — used to let it bite.
	var approach_foe: Node2D = ctx.main._nearest_creature(ctx.main.player.position, 480.0)
	if approach_foe == null:
		return "附近没有史莱姆"
	var approach_id: String = ctx.main._creature_entity_id(approach_foe)
	if approach_id == "":
		return "史莱姆没有注册到实体表"
	ctx._current.text = "走向史莱姆"
	if not await ctx._approach(approach_id):
		return "走不到史莱姆：" + approach_id
	await ctx._pause(WALK_PAUSE)
	return ""

func op_walk_attack(step: Array, ctx: Object) -> String:
	# Find the nearest slime, walk to it like a player would, then swing.
	var foe: Node2D = ctx.main._nearest_creature(ctx.main.player.position, 480.0)
	if foe == null:
		return "附近没有史莱姆"
	var foe_id: String = ctx.main._creature_entity_id(foe)
	if foe_id == "":
		return "史莱姆没有注册到实体表：" + str(foe.name)
	ctx._current.text = "走向史莱姆并攻击"
	if not await ctx._approach(foe_id):
		return "走不到史莱姆：" + foe_id
	await ctx.main._fire_use_action()
	await ctx._pause(ACTION_PAUSE)
	return ""

func op_attack(step: Array, ctx: Object) -> String:
	# Swing at a slime already in reach (walk-attack handles approach).
	var near_foe: Node2D = ctx.main._nearest_creature(ctx.main.player.position, 48.0)
	if near_foe == null:
		return "手边没有史莱姆"
	ctx._current.text = "F：攻击史莱姆"
	await ctx.main._fire_use_action()
	await ctx._pause(ACTION_PAUSE)
	return ""

