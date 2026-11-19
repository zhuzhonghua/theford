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
  reload                    热重载数据（等同 F5）
  load portal               播放 SCM 验收脚本（Esc 中止/关闭 HUD）
  load fell-tree            验收：开箱拿斧 → 两下砍树 → 树桩 → 再生
  load read-sign            验收：E 阅读村口木牌
  nl 让老王去酒馆           强制走 LLM 翻译
  clear                     清屏

直接输入中文也可以（如「把时间调到晚上八点」「让老王去酒馆」），
LLM 会把它翻译成上面的一条指令再执行。"

const GM_COMMANDS := ["state", "time", "day", "speed", "weather", "people", "npc",
		"tp", "goto", "anchors", "talk", "reload", "nl"]

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
	return "第 %d 天 %02d:%02d   天气：%s\n%s   矿石 x%d\n时间速度：x%.1f\nGM 覆盖：%s" % [
			int(s.get("day", 1)), int(s.get("hour", 8)), int(s.get("minute", 0)),
			_weather_name(str(s.get("weather", "sun"))),
			str(s.get("quest_text", "")), int(s.get("carried", 0)),
			tick_rate, override]

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
	if main.dialog_ui.is_open:
		main.dialog_ui.close()
	await main.dialog_ui.open_npc(npc)
	return "已打开 %s 的对话" % npc.display_name

func _reload() -> String:
	overrides.clear()
	tick_rate = 1.0
	await Game.reload_data()
	return "已热重载，时钟回到 08:00"
