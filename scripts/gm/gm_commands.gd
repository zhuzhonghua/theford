extends RefCounted
## gm_commands.gd — deterministic GM command interpreter.
##
## Part of the optional GM module (scripts/gm/). Everything here is dev-only:
## clock jumps, time scale, weather, NPC overrides, teleport and reload.
## Unrecognised input is translated by the local model into one of these
## commands (game:gm-plan) and then executed through the same deterministic
## path.
##
## This file talks to the rest of the game through a small read-only interface
## on main.gd (npc_node / npc_progress / anchor_names / anchor_position) plus
## the public player, dialog_ui and Game.snapshot. Removing scripts/gm/ leaves
## the shell working unchanged.

const WEATHER_NAMES := {
	"sun": "晴", "cloud": "阴", "rain": "雨", "storm": "暴雨", "fog": "雾",
}

const HELP := "GM 指令（F8 开关）:
  state                     当前时钟 / 天气 / 任务 / 速度 / 覆盖
  time                      查看时间
  time 18:30                跳到 18:30（已过则明天）
  time +90                  前进 90 游戏分钟
  day 2                     跳到第 2 天同一时刻
  speed 10                  时间加速 10 倍；0 暂停，1 正常
  weather rain              强制天气 sun/cloud/rain/storm/fog
  weather auto              恢复按 seed 的天气
  people                    日程、坐标、寻路进度
  npc                       查看 GM 覆盖
  npc smith inn-yard drinking   强制老王去酒馆
  npc smith auto            取消老王的覆盖
  npc clear                 取消全部覆盖
  tp smith                  传送到老王身边
  goto smithy-door          传送到锚点
  anchors                   列出全部锚点
  talk smith                传送到老王身边并打开对话
  reload                    热重载（当前场景一起回到开局；F5 已改为存档）
  save                      快存到 user://save1.scm（等同 F5）
  loadgame                  从存档读档（等同 F9）
  bag                       开关背包面板（等同 I 键）
  bag open / bag close      打开或关闭背包面板
  quest                     查看任务进度 / 开关任务日志（等同 J 键）
  quest open / quest close  打开或关闭任务日志
  volume                    查看主 / 音乐 / 音效三个音量
  volume master 50          设置主音量 0-100（实时生效，存 user://settings.cfg）
  volume music 30 / volume sfx 70
  volume open / close       开关音量滑条面板（等同 O 键）
  volume reload             从 settings.cfg 重读（验证重开保持）
  quality                   查看 AI 档位（low|medium|high）
  quality low               切换 AI 档位（1-3 也接受；没有 off 档）
  prompt smith village      打印该回合送进 LLM 的 prompt（看情境行；改天气/时钟后再打一次对比）
  story                     查看剧情事实 / 最近 beat
  story beat <id>           手动触发一个 beat（验收用；生产时由时钟/位置触发）
  story place <anchor>      覆盖玩家所在锚点（调试用）
  story fact <key> <value>  写一个非保护 fact（调试用）
  give ore 3                往背包塞物品（调试用；ore/log/axe 可简写）
  equip axe                 把背包里的斧头装备到手上（影响 F 动词）
  unequip                   卸下手中工具（物品留在背包里）
  load portal               播放 SCM 验收脚本（Esc 中止/关闭 HUD）
  load fell-tree            验收：开箱拿斧 → 两下砍树 → 树桩 → 再生
  load equipment            验收：装备斧头 F 生效、卸下后 F 无效
  load quests              验收：双任务并行 → J 日志 → xp/奖励
   load read-sign            验收：E 阅读村口木牌
  load inventory-panel      验收：开箱拿斧 → I 开面板 → 入包即时刷新
  load reload-scene         验收：砍树留桩 → reload → 树与场景恢复、站位不变
  nl 让老王去酒馆           强制走 LLM 翻译
  clear                     清屏

直接输入中文也可以（如「把时间调到晚上八点」「让老王去酒馆」），
LLM 会把它翻译成上面的一条指令再执行。"

const GM_COMMANDS := ["state", "time", "day", "speed", "weather", "people", "npc",
		"tp", "goto", "anchors", "talk", "reload", "bag", "give", "equip", "unequip",
		"hp", "hurt", "heal", "restart", "slime", "quest", "volume", "quality", "nl", "prompt",
		"save", "loadgame", "story"]

## Short names the GM `give` command accepts; anything else is treated as a
## full type id ("item/material/ore").
const ITEM_ALIASES := {
	"ore": "item/material/ore",
	"log": "item/material/log",
	"stone": "item/material/stone",
	"gel": "item/material/gel",
	"herb": "item/material/herb",
	"meat": "item/food/meat",
	"sword": "item/weapon/iron-sword",
	"axe": "item/tool/axe",
}

var main: Node
var tick_rate := 1.0     # 1 normal, 0 paused, 20 = 20x
var overrides := {}      # npc id -> {anchor, activity}, applied over game:people

func _init(main_node: Node) -> void:
	main = main_node

func help_text() -> String:
	return HELP

func is_gm_command(word: String) -> bool:
	return GM_COMMANDS.has(word.to_lower())

## Rewrite one `game:people` row with any active GM override. Called by main
## before it repaths or displays villagers, so overriding never mutates state
## inside the shell itself.
func apply_overrides(rows: Array) -> Array:
	if overrides.is_empty():
		return rows
	var out: Array = []
	for row in rows:
		if row is Array and row.size() == 3:
			var ov: Dictionary = overrides.get(str(row[0]), {})
			if not ov.is_empty():
				row = [row[0], ov.get("anchor", row[1]), ov.get("activity", row[2])]
		out.append(row)
	return out

func execute(line: String) -> String:
	var args := line.strip_edges().split(" ", false)
	if args.is_empty():
		return ""
	var cmd := args[0].to_lower()
	var rest := args.slice(1)
	if cmd == "nl":
		return await _natural(" ".join(rest))
	if not GM_COMMANDS.has(cmd):
		return await _natural(line.strip_edges())
	return await _direct(cmd, rest)

func _direct(cmd: String, rest: PackedStringArray) -> String:
	match cmd:
		"state": return _state()
		"time": return await _time(rest)
		"day": return await _day(rest)
		"speed": return _speed(rest)
		"weather": return await _weather(rest)
		"people": return _people()
		"npc": return _npc(rest)
		"tp": return _teleport(rest, false)
		"goto": return _teleport(rest, true)
		"anchors": return _anchors()
		"talk": return await _talk(rest)
		"reload": return await _reload()
		"save": return await _save_game()
		"loadgame": return await _load_game()
		"bag": return _bag(rest)
		"quest": return _quest(rest)
		"volume": return await _volume(rest)
		"quality": return await _quality(rest)
		"story": return await _story(rest)
		"prompt": return await _prompt(rest)
		"give": return await _give(rest)
		"equip": return await _equip(rest)
		"unequip": return await _unequip()
		"hp": return await _hp()
		"hurt": return await _hurt(rest)
		"heal": return await _heal()
		"restart": return await _restart()
		"slime": return _move_slime(rest)
	return "未知指令：%s（help 查看）" % cmd

## Free-form Chinese -> one command via the local model. Scheme builds the
## prompt, grammar-constrains the output, and returns a command line; this
## side only validates the verb and runs it through the deterministic path.
func _natural(text: String) -> String:
	if text.strip_edges() == "":
		return "用法：nl <自然语言>"
	var plan: Variant = await Game.call_async("game:gm-plan", [text])
	var line := str(plan).strip_edges() if plan != null else ""
	if line == "":
		return "LLM 没有给出指令（模型未加载或生成失败）；可以直接输入 help 查看指令"
	var head := line.split(" ", false)
	if head.is_empty() or not GM_COMMANDS.has(head[0].to_lower()):
		return "LLM 返回了无法执行的指令：%s" % line
	var out: String = await _direct(head[0].to_lower(), head.slice(1))
	return "LLM → %s\n%s" % [line, out]

func _clock_text(result: Variant) -> String:
	if result is Array and result.size() == 6:
		return "第 %d 天 %02d:%02d  天气：%s" % [
			int(result[2]), int(result[3]), int(result[4]),
			_weather_name(str(result[5]))]
	return "（无回复）"

func _weather_name(w: String) -> String:
	return str(WEATHER_NAMES.get(w, w))

func _state() -> String:
	var s := Game.snapshot
	var override := "无"
	if not overrides.is_empty():
		var ids: Array = overrides.keys()
		ids.sort()
		var bits: PackedStringArray = []
		for id in ids:
			var o: Dictionary = overrides[id]
			bits.append("%s=%s" % [id, o.get("anchor", "")])
		override = ", ".join(bits)
	return "第 %d 天 %02d:%02d   天气：%s\n%s   矿石 x%d\n时间速度：x%.1f\nGM 覆盖：%s\nAI 档位：%s" % [
			int(s.get("day", 1)), int(s.get("hour", 8)), int(s.get("minute", 0)),
			_weather_name(str(s.get("weather", "sun"))),
			str(s.get("quest_text", "")), int(s.get("carried", 0)),
			tick_rate, override, _quality_name()]

func _time(args: PackedStringArray) -> String:
	var s := Game.snapshot
	var now_day := int(s.get("day", 1))
	var now_h := int(s.get("hour", 8))
	var now_m := int(s.get("minute", 0))
	if args.is_empty():
		return "第 %d 天 %02d:%02d   时间速度 x%.1f（time HH:MM / time +分钟）" % [
			now_day, now_h, now_m, tick_rate]
	var a := args[0]
	if a.begins_with("+"):
		var minutes := int(a.substr(1))
		if minutes <= 0:
			return "用法：time +90"
		var advanced: Variant = await Game.call_async("game:debug-advance", [minutes])
		return "时间前进 %d 分钟 → %s" % [minutes, _clock_text(advanced)]
	if not a.contains(":"):
		return "用法：time [HH:MM | +分钟]"
	var hm := a.split(":")
	var h := int(hm[0])
	var m := int(hm[1]) if hm.size() > 1 else 0
	if h < 0 or h > 23 or m < 0 or m > 59:
		return "时间不合法：%s" % a
	var day := now_day
	if h * 60 + m <= now_h * 60 + now_m:
		day += 1
	var result: Variant = await Game.call_async("game:debug-set-time", [day, h, m])
	return "跳到 %s" % _clock_text(result)

func _day(args: PackedStringArray) -> String:
	if args.is_empty():
		return "用法：day 2"
	var d := int(args[0])
	if d < 1:
		return "天从 1 开始"
	var s := Game.snapshot
	var result: Variant = await Game.call_async("game:debug-set-time",
			[d, int(s.get("hour", 8)), int(s.get("minute", 0))])
	return "跳到 %s" % _clock_text(result)

func _speed(args: PackedStringArray) -> String:
	if args.is_empty():
		return "时间速度 x%.1f（1 正常，0 暂停）" % tick_rate
	tick_rate = clampf(float(args[0]), 0.0, 60.0)
	return "时间速度 x%.1f%s" % [tick_rate, "（暂停）" if tick_rate == 0.0 else ""]

func _weather(args: PackedStringArray) -> String:
	if args.is_empty():
		return "用法：weather sun|cloud|rain|storm|fog|auto"
	var w := args[0].to_lower()
	if w == "auto":
		w = ""
	if w != "" and not WEATHER_NAMES.has(w):
		return "未知天气：%s" % w
	var result: Variant = await Game.call_async("game:debug-set-weather", [w])
	return "天气 → %s" % _clock_text(result)

func _people() -> String:
	var lines: PackedStringArray = []
	for row in Game.snapshot.get("people", []):
		if not (row is Array and row.size() == 3):
			continue
		var id := str(row[0])
		var at := str(row[1])
		var ov: Dictionary = overrides.get(id, {})
		if not ov.is_empty():
			at = str(ov.get("anchor", at))
		var npc: Node2D = main.npc_node(id)
		var state: Dictionary = main.npc_progress(id)
		var path: PackedVector2Array = state.get("path", PackedVector2Array())
		var pos: Vector2 = npc.position if npc != null else Vector2.ZERO
		var gm_tag := " [GM]" if overrides.has(id) else ""
		lines.append("%s  %s/%s  pos=(%d,%d)  step=%d/%d  vis=%s%s" % [
			id, at, str(state.get("activity", row[2])),
			int(pos.x), int(pos.y), int(state.get("step", 0)), path.size(),
			"是" if npc != null and npc.visible else "否", gm_tag])
	if lines.is_empty():
		return "（还没有 game:people 回复）"
	return "\n".join(lines)

func _npc(args: PackedStringArray) -> String:
	if args.is_empty():
		if overrides.is_empty():
			return "没有 GM 覆盖"
		var lines: PackedStringArray = []
		for id in overrides:
			var o: Dictionary = overrides[id]
			lines.append("%s → %s / %s" % [id, o.get("anchor", ""), o.get("activity", "")])
		return "\n".join(lines)
	if args[0] == "clear":
		overrides.clear()
		return "已清除全部 GM 覆盖"
	var id := args[0]
	if main.npc_node(id) == null:
		return "未知 NPC：%s" % id
	if args.size() >= 2 and args[1] == "auto":
		overrides.erase(id)
		return "%s 恢复日程" % id
	if args.size() < 2:
		return "用法：npc <id> <anchor|auto> [activity]"
	var at := args[1]
	if not at.contains(":"):
		at = "village:" + at
	if main.anchor_position(str(at.get_slice(":", 1))) == null:
		return "未知锚点：%s" % args[1]
	var activity := args[2] if args.size() >= 3 else "idle"
	overrides[id] = {"anchor": at, "activity": activity}
	return "%s → %s / %s" % [id, at, activity]

func _teleport(args: PackedStringArray, anchor_only: bool) -> String:
	if args.is_empty():
		return "用法：%s <npc-id|anchor>" % ("goto" if anchor_only else "tp")
	var target := args[0]
	var anchor: Variant = main.anchor_position(target)
	if anchor != null:
		main.player.position = anchor
		return "传送到锚点 %s" % target
	if not anchor_only:
		var npc: Node2D = main.npc_node(target)
		if npc != null:
			main.player.position = npc.position + Vector2(20, 0)
			return "传送到 %s 身边" % npc.display_name
	return "找不到%s：%s" % ["锚点" if anchor_only else " NPC 或锚点", target]

func _anchors() -> String:
	var names: Array = main.anchor_names()
	names.sort()
	var lines: PackedStringArray = []
	for n in names:
		var p: Vector2 = main.anchor_position(n)
		lines.append("%s (%d,%d)" % [n, int(p.x), int(p.y)])
	return "\n".join(lines)

func _talk(args: PackedStringArray) -> String:
	if args.is_empty():
		return "用法：talk <npc-id>"
	var npc: Node2D = main.npc_node(args[0])
	if npc == null:
		return "未知 NPC：%s" % args[0]
	main.player.position = npc.position + Vector2(20, 0)
	# One stack-wide call: no need to know which panels might be open.
	Modals.close_all()
	await main.dialog_ui.open_npc(npc)
	return "已打开 %s 的对话" % npc.display_name

func _reload() -> String:
	overrides.clear()
	tick_rate = 1.0
	await main.hot_reload()
	return "已热重载：时钟、任务、背包与当前场景都回到开局"

func _save_game() -> String:
	var ok: bool = await main.quick_save()
	return "已存档到 user://save1.scm" if ok else "存档失败"

func _load_game() -> String:
	var ok: bool = await main.quick_load()
	overrides.clear()
	return "已读档" if ok else "读档失败（没有存档或格式不兼容）"

## Open/close the inventory panel from the console. Same panel the I key
## toggles; useful for acceptance scripts and screenshots.
func _bag(args: PackedStringArray) -> String:
	if main.bag_ui == null:
		return "背包面板不可用"
	var mode := args[0].to_lower() if args.size() >= 1 else "toggle"
	match mode:
		"open":
			Modals.close_all()
			main.bag_ui.open()
			return "背包面板：打开"
		"close":
			main.bag_ui.close()
			return "背包面板：关闭"
		_:
			main.bag_ui.toggle()
			return "背包面板：%s" % ("打开" if main.bag_ui.is_open else "关闭")

## Quest log from the console: no args prints the live snapshot, open/close
## drives the same modal panel the J key toggles.
func _quest(args: PackedStringArray) -> String:
	if main.quest_ui == null:
		return "任务日志不可用"
	var mode := args[0].to_lower() if args.size() >= 1 else "toggle"
	match mode:
		"open":
			Modals.close_all()
			main.quest_ui.open()
			return "任务日志：打开"
		"close":
			main.quest_ui.close()
			return "任务日志：关闭"
	if not args.is_empty():
		main.quest_ui.toggle()
		return "任务日志：%s" % ("打开" if main.quest_ui.is_open else "关闭")
	var lines: PackedStringArray = []
	lines.append("经验 %d" % int(Game.snapshot.get("xp", 0)))
	for row in Game.snapshot.get("quests", []):
		if row is Array and row.size() >= 5:
			var objs: Array = []
			for obj in row[4]:
				if obj is Array and obj.size() >= 3:
					objs.append("%s %d/%d" % [str(obj[0]), int(obj[1]), int(obj[2])])
			lines.append("%s [%s] %s：%s" % [str(row[0]), str(row[2]), str(row[1]), ", ".join(objs)])
	return "\n".join(lines) if lines.size() > 1 else "（还没有任务）"

## Three audio buses share one tiny API on the Audio autoload. This command is
## the deterministic twin of dragging a slider in the O panel; `volume reload`
## re-reads user://settings.cfg, which is also how acceptance proves a restart
## would keep the mix.
func _volume(args: PackedStringArray) -> String:
	if main.volume_ui == null:
		return "音量面板不可用"
	if args.is_empty():
		return _volume_state()
	var mode := args[0].to_lower()
	match mode:
		"open":
			Modals.close_all()
			main.volume_ui.open()
			return "音量设置：打开"
		"close":
			main.volume_ui.close()
			return "音量设置：关闭"
		"toggle":
			main.volume_ui.toggle()
			return "音量设置：%s" % ("打开" if main.volume_ui.is_open else "关闭")
		"reload":
			Audio.reload_settings()
			main.volume_ui.refresh()
			return "已从 settings.cfg 重读音量\n" + _volume_state()
	var bus := Audio.bus_for_key(mode)
	if bus == "":
		return "用法：volume <master|music|sfx> <0-100> | volume open|close|reload"
	if args.size() < 2:
		return "用法：volume %s <0-100>" % mode
	var percent := clampf(float(args[1]), 0.0, 100.0)
	# Go through the slider so a GM change and a mouse drag share one path.
	main.volume_ui.set_slider(mode, percent / 100.0)
	Audio.save_settings()
	return _volume_state()

func _volume_state() -> String:
	var lines: PackedStringArray = []
	for pair in [["master", "主音量"], ["music", "音乐"], ["sfx", "音效"]]:
		var key: String = pair[0]
		var bus: String = Audio.bus_for_key(key)
		lines.append("%s %d%%" % [pair[1], roundi(Audio.get_bus_volume(bus) * 100.0)])
	return "\n".join(lines) + ("（已存盘）" if Audio.volume_saved else "")

## AI quality is the player's setting, not save state: it comes from
## THEFORD_AI_QUALITY at boot and can be switched here (a deterministic twin of
## the options screens the reference keeps outside saves). There is no off
## tier: the GGUF always loads; switching only changes token budget / tier replay.
func _quality(args: PackedStringArray) -> String:
	if args.is_empty():
		return "AI 档位：%s（quality low|medium|high；1-3 也可）" % _quality_name()
	var q := args[0].to_lower()
	match q:
		"0", "off", "1": q = "low"
		"2": q = "medium"
		"3": q = "high"
	if not ["low", "medium", "high"].has(q):
		return "用法：quality [low|medium|high|1-3]（没有 off 档）"
	var info: Variant = await Game.call_async("game:set-ai-quality", [q])
	if not (info is Array):
		return "AI 档位切换失败"
	var loaded := "模型已加载" if bool(info[1]) else "模型未加载"
	return "AI 档位 → %s（%s）" % [_quality_name(), loaded]

func _quality_name() -> String:
	return str(Game.snapshot.get("ai_quality", "medium"))

## Print the exact prompt a dialogue turn would build. The full text goes to
## the engine console (RichTextLabel would bury it); the GM log keeps just the
## injected situation line so weather/time changes are easy to compare.
func _prompt(args: PackedStringArray) -> String:
	if args.is_empty():
		return "用法：prompt <npc> [topic]（如 prompt smith village）"
	var npc := args[0].to_lower()
	var topic := args[1].to_lower() if args.size() >= 2 else "village"
	var built: Variant = await Game.call_async("game:debug-talk-prompt", [npc, topic])
	if not (built is String):
		return "取不到 prompt：" + str(built)
	print("\n===== talk prompt: %s / %s =====\n%s\n===== end =====" % [npc, topic, built])
	var i: int = built.find("当前情境：")
	var situation := "（prompt 里没有情境行）"
	if i >= 0:
		var tail: String = built.substr(i)
		var e: int = tail.find("\n")
		situation = tail if e < 0 else tail.substr(0, e)
	return "已把完整 prompt 打到控制台。\n%s\n改天气 / 时钟后再输一次，对比这一行" % situation

## Dev-only item injection, so the panel's live refresh can be exercised
## without walking to a pickup. Goes through Scheme's bag-add! like every
## other pickup.
func _give(args: PackedStringArray) -> String:
	if args.is_empty():
		return "用法：give <item-type> [n]（如 give ore 3）"
	var item := str(ITEM_ALIASES.get(args[0].to_lower(), args[0]))
	var n := int(args[1]) if args.size() >= 2 else 1
	if n <= 0:
		return "数量要大于 0"
	var left: Variant = await Game.call_async("game:debug-give", [item, n])
	if not (left is int or left is float):
		return "背包放不下 %s x%d" % [item, n]
	# The panel and HUD read the bridge snapshot, so ask for a fresh bag view.
	Game.send("game:bag")
	return "背包 ← %s x%d（该栈共 %d）" % [item, n, int(left)]

## Equip a carried tool into the hand slot — the deterministic twin of clicking
## a tool cell in the bag panel. Only pieces (tool/weapon) can be equipped; the
## item stays in the bag, the slot just decides what F swings.
func _equip(args: PackedStringArray) -> String:
	if args.is_empty():
		return "用法：equip <item-type>（如 equip axe）"
	var item := str(ITEM_ALIASES.get(args[0].to_lower(), args[0]))
	var ok: Variant = await Game.call_async("game:equip", [item])
	Game.send("game:bag")
	if not bool(ok):
		return "无法装备 %s：背包里没有，或它不是工具" % item
	return "已装备：" + item + "（F 现在可用）"

func _unequip() -> String:
	var old: Variant = await Game.call_async("game:unequip", [])
	Game.send("game:bag")
	var name := str(old) if old != null else ""
	return ("已卸下：" + name + "（物品仍在背包）") if name != "" else "手上没有装备"

## --- story debug ------------------------------------------------------------
## The story engine owns its facts; these commands are read-only except for the
## explicit debug writes. Protected prefixes (seen./ford./...) are refused by
## Scheme, so a console command cannot forge story progress.

func _story(args: PackedStringArray) -> String:
	if args.is_empty() or args[0] == "facts":
		var facts: Variant = await Game.call_async("game:story-facts", [])
		var status: Variant = await Game.call_async("game:story-status", [])
		var place := str(status[1]) if status is Array and status.size() >= 2 else ""
		var last := str(status[2]) if status is Array and status.size() >= 3 else ""
		var parts: Array[String] = []
		if facts is Array:
			for row in facts:
				if row is Array and row.size() >= 2:
					parts.append("%s=%s" % [str(row[0]), str(row[1])])
		return "剧情：位置=%s，最近=%s\n事实：%s" % [
				place, last if last != "" else "无",
				"、".join(parts) if not parts.is_empty() else "（暂无）"]
	match args[0]:
		"beat":
			if args.size() < 2:
				return "用法：story beat <arrive|winch-ready|...>"
			var fired: Variant = await Game.call_async("game:debug-story-beat", [args[1]])
			Game.send("game:story-status")
			main._poll_effects()
			return ("已触发 beat：" + args[1]) if bool(fired) else ("beat 不存在或已播过：" + args[1])
		"place":
			if args.size() < 2:
				return "用法：story place <anchor>"
			var place: Variant = await Game.call_async("game:story-place", [args[1]])
			Game.send("game:story-status")
			return "剧情位置：" + str(place)
		"fact":
			if args.size() < 3:
				return "用法：story fact <key> <value>"
			var ok: Variant = await Game.call_async("game:debug-set-fact", [args[1], args[2]])
			Game.send("game:story-status")
			return "写入 fact %s=%s%s" % [args[1], args[2], "" if bool(ok) else "（被拒绝：受保护前缀）"]
	return "用法：story [facts|beat <id>|place <anchor>|fact <key> <value>]"

## --- combat debug -----------------------------------------------------------
## Health lives in Scheme's entity registry; these commands only ask for a view
## or apply a blow through the same path a creature bite uses.

func _hp() -> String:
	var view: Variant = await Game.call_async("game:hp", [])
	if not (view is Array and view.size() >= 2):
		return "还没有生命值状态"
	return "生命 ♥ %d/%d%s" % [int(view[0]), int(view[1]),
			"（已倒下）" if bool(view[2]) else ""]

func _hurt(args: PackedStringArray) -> String:
	if args.is_empty():
		return "用法：hurt <点数>"
	var n := maxi(1, int(args[0]))
	var effects: Variant = await Game.call_async("game:debug-hurt", [n])
	main._apply_effects(effects)
	Game.send("game:hp")
	return "受到 %d 点伤害" % n

func _heal() -> String:
	var view: Variant = await Game.call_async("game:hp", [])
	var max_hp := int(view[1]) if view is Array and view.size() >= 2 else 10
	await Game.call_async("game:debug-heal", [])
	Game.send("game:hp")
	return "生命恢复至 %d/%d" % [max_hp, max_hp]

func _restart() -> String:
	await main._restart_game()
	return "已从渡口重新开始"

## Move a slime next to a named villager (and re-home it there). A deterministic
## setup for the threat-flee acceptance — the same kind of shortcut as `tp` or
## `time`; the villager still has to notice and run on its own.
func _move_slime(args: PackedStringArray) -> String:
	if args.is_empty():
		return "用法：slime <npc-id>（把一只史莱姆引到村民旁）"
	var npc: Node2D = main.npc_node(args[0])
	if npc == null:
		return "未知 NPC：" + args[0]
	var foe: Node2D = null
	var best := 99999.0
	for node in main.get_tree().get_nodes_in_group("creature"):
		if not is_instance_valid(node):
			continue
		var d: float = node.position.distance_to(npc.position)
		if d < best:
			best = d
			foe = node
	if foe == null:
		return "当前地图没有史莱姆"
	var spot := npc.position + Vector2(26.0, 8.0)
	foe.position = spot
	foe.set("home", spot)
	return "史莱姆已引到 %s 身旁" % npc.display_name
