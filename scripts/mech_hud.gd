extends CanvasLayer
## mech_hud.gd — the F1 mechanism HUD panel.
##
## Self-contained: it creates its own Panel + RichTextLabel, listens to
## Game.snapshot_changed, and renders the most recent game:trace. main.gd
## only instantiates it and forwards F1 keystrokes.
##
##   THEFORD_MECHANISM=1   force on (e.g. demos / recordings)
##   THEFORD_MECHANISM=0   force off regardless of demo flags

var _panel: Panel
var _text: RichTextLabel
var _visible := false

func setup(font: Font) -> void:
	layer = 20
	name = "MechanismHUDLayer"

	_panel = Panel.new()
	_panel.name = "Panel"
	_panel.anchor_left = 1.0
	_panel.anchor_right = 1.0
	_panel.offset_left = -552.0
	_panel.offset_top = 8.0
	_panel.offset_right = -8.0
	_panel.offset_bottom = 226.0
	_panel.self_modulate = Color(1, 1, 1, 0.92)
	_panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_panel)

	_text = RichTextLabel.new()
	_text.bbcode_enabled = true
	_text.fit_content = true
	_text.scroll_active = false
	_text.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_text.anchor_left = 0.0
	_text.anchor_top = 0.0
	_text.anchor_right = 1.0
	_text.anchor_bottom = 1.0
	_text.offset_left = 14.0
	_text.offset_top = 10.0
	_text.offset_right = -14.0
	_text.offset_bottom = -10.0
	_text.add_theme_font_override("normal_font", font)
	_text.add_theme_font_override("bold_font", font)
	_text.add_theme_font_size_override("normal_font_size", 17)
	_text.add_theme_font_size_override("bold_font_size", 17)
	_panel.add_child(_text)

	var force := OS.get_environment("THEFORD_MECHANISM")
	var auto_on: bool = (
			force == "1"
			or OS.get_environment("THEFORD_DEMO_NPC") != ""
			or OS.get_environment("THEFORD_RECORD_DIR") != ""
			or OS.get_environment("THEFORD_SNAPSHOT_DIR") != "")
	if force == "0":
		auto_on = false
	show_panel(auto_on)

	Game.snapshot_changed.connect(_refresh)
	# bridge_ready fires once, after the model/version are known, but without
	# emitting snapshot_changed; without this the model line stays "未加载".
	Game.bridge_ready.connect(_on_bridge_ready)

func _on_bridge_ready(_llm: bool) -> void:
	_refresh()

func is_showing() -> bool:
	return _visible

func show_panel(on: bool) -> void:
	_visible = on
	if _panel != null:
		_panel.visible = on
	if on:
		_refresh()

func toggle_visible() -> void:
	show_panel(not _visible)

## ------------------------------------------------------------- private --

func _topic_label(raw: String) -> String:
	match raw:
		"greet": return "打招呼"
		"village": return "村子"
		"work":    return "活计"
		"quest":   return "接任务"
		"give":    return "交矿石"
		_:         return raw

func _intent_label(raw: String) -> String:
	match raw:
		"accept": return "ACCEPT · 接任务"
		"give":   return "GIVE · 交矿石"
		"chat":   return "CHAT · 闲聊"
		_:        return raw.to_upper()

func _verdict_label(raw: String) -> String:
	match raw:
		"accepted": return "接受"
		"rejected": return "拒绝"
		"ignored":  return "忽略"
		_:          return raw

func _refresh() -> void:
	if _text == null or not _visible:
		return
	var lines := PackedStringArray()
	lines.append("[b]机制 HUD[/b]  [color=#8b949e]· F1 隐藏[/color]")
	var turn: Dictionary = Game.snapshot.get("last_turn", {})
	if turn.is_empty():
		lines.append("[color=#8b949e]还没有对话。找 NPC 聊一句，这里会显示 Scheme 的判定。[/color]")
	else:
		var topic := _topic_label(str(turn.get("topic", "")))
		var intent := _intent_label(str(turn.get("intent", "")))
		var verdict := _verdict_label(str(turn.get("verdict", "")))
		var reason := str(turn.get("reason", ""))
		var source := str(turn.get("source", ""))
		var learned := bool(turn.get("learned", false))
		var prefill_tps := float(turn.get("prefill_tps", 0.0))
		var decode_tps := float(turn.get("decode_tps", 0.0))
		lines.append("话题 [b]%s[/b]  →  意图 [b]%s[/b]" % [topic, intent])
		lines.append("Scheme 判定  [b]%s[/b] · %s" % [verdict, reason])
		match source:
			"llm":
				lines.append("台词来源  [color=#7ee787]LLM 生成[/color]")
				lines.append("速度  prefill ≈ %.0f tok/s · decode ≈ %.0f tok/s" % [prefill_tps, decode_tps])
				lines.append("learned   [color=#8b949e]MISS → 已写入缓存[/color]")
			"cache":
				lines.append("台词来源  [color=#79c0ff]Scheme 缓存命中[/color] · 无模型开销")
				lines.append("learned   [color=#79c0ff]HIT[/color] · 这个回答已经属于村庄")
			"canned":
				if Game.use_llm:
					lines.append("台词来源  [color=#d2a8ff]剧本台词[/color] · 无需 LLM 的确定回复")
				else:
					lines.append("台词来源  [color=#ffa657]预置台词[/color] · 未加载模型")
				lines.append("learned   [color=#8b949e]—[/color]")
			"fallback":
				lines.append("台词来源  [color=#ffa657]预置台词[/color] · 模型没有产出")
				lines.append("learned   [color=#8b949e]—[/color]")
			_:
				lines.append("台词来源  [color=#8b949e]%s[/color]" % source)
		if learned and source != "cache":
			lines.append("[color=#79c0ff]📖 记住了[/color]")
	lines.append("[color=#8b949e]意图＝话题菜单的确定性映射 · LLM 只负责台词[/color]")
	var model := str(Game.snapshot.get("model", ""))
	if model == "":
		lines.append("[color=#8b949e]模型 未加载 · 使用预置台词[/color]")
	else:
		lines.append("[color=#8b949e]模型 %s · llama.cpp %s[/color]" % [
				model, str(Game.snapshot.get("llm_version", "?"))])
	_text.text = "\n".join(lines)
