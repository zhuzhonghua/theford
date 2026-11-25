extends CanvasLayer
## status_panel.gd — C key: everything the HUD used to whisper, in one place.
## Two aligned columns: fixed-width labels + wrapping values, like the
## reference project's character sheet. Read-only view of Game.snapshot.

const U := preload("res://scripts/panel_util.gd")

const AI_NAMES := {"off": "关", "low": "低", "medium": "中", "high": "高"}
const WEATHER_NAMES := {"sun": "晴", "cloud": "多云", "rain": "下雨", "storm": "暴雨", "fog": "起雾"}

var is_open := false
var toggle_key := KEY_NONE
var main: Node
var _font: Font
var _ui: Dictionary

func setup_with_main(font: Font, main_node: Node) -> void:
	_font = font
	main = main_node
	_ui = U.build_shell(self, font, "StatusLayer", 28, "角色 / 世界状态", 720, 480)
	U.add_close_button(self, font)
	visible = false
	Game.snapshot_changed.connect(_on_snapshot)

func set_toggle_key(key: int) -> void:
	toggle_key = key

func open() -> void:
	if is_open: return
	is_open = true
	visible = true
	Modals.push(self)
	refresh()

func close() -> void:
	if not is_open: return
	is_open = false
	visible = false
	Modals.pop(self)

func modal_input(event: InputEvent) -> bool:
	if not is_open: return false
	if event is InputEventKey and event.pressed and not event.echo \
			and (event.keycode == KEY_ESCAPE or event.keycode == toggle_key):
		close()
	return true

func verb_hint() -> String:
	return "Esc / C 关闭"

func _on_snapshot() -> void:
	if is_open: refresh()

func _row(holder: Node, key: String, value: String) -> void:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 12)
	var k := U.label(_font, key, 18, U.GOLD)
	k.custom_minimum_size = Vector2(84, 0)
	row.add_child(k)
	var v := U.label(_font, value, 18)
	v.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(v)
	holder.add_child(row)

func refresh() -> void:
	var holder: Node = _ui.get("content")
	if holder == null: return
	U.clear(holder)
	var s := Game.snapshot
	var weather := str(s.get("weather", "sun"))
	_row(holder, "生命", "♥ %d / %d" % [int(s.get("hp", 10)), int(s.get("max_hp", 10))])
	_row(holder, "经验", str(int(s.get("xp", 0))))
	_row(holder, "时间", "第 %d 天  %02d:%02d" % [
			int(s.get("day", 1)), int(s.get("hour", 8)), int(s.get("minute", 0))])
	_row(holder, "天气", str(WEATHER_NAMES.get(weather, weather)))
	_row(holder, "地图", main.current_map_id() if main != null else "")
	_row(holder, "位置", str(s.get("story_place", "")))
	_row(holder, "背包", "%d / %d 格" % [
			int(s.get("bag_slots", 0)), int(s.get("bag_capacity", 30))])
	_row(holder, "手持", str(s.get("held", "")))
	var quality := str(s.get("ai_quality", "medium"))
	_row(holder, "AI", "%s（%s）" % [str(AI_NAMES.get(quality, quality)),
			"本地推理" if Game.use_llm else "预置台词"])

	holder.add_child(U.label(_font, "任务", 20, U.GOLD))
	var quest_lines: Array[String] = []
	for row in s.get("quests", []):
		if row is Array and row.size() >= 4:
			quest_lines.append("· %s — %s" % [str(row[1]), str(row[3])])
	if quest_lines.is_empty():
		quest_lines.append("（暂无）")
	for line in quest_lines:
		var l := U.label(_font, line, 16)
		l.custom_minimum_size = Vector2(0, 0)
		holder.add_child(l)

	holder.add_child(U.label(_font, "村民近况", 20, U.GOLD))
	for row in s.get("people", []):
		if row is Array and row.size() >= 3:
			_row(holder, str(row[0]), "%s · %s" % [str(row[1]), str(row[2])])

	var facts: Array = s.get("story_facts", [])
	var notable: Array[String] = []
	for row in facts:
		if row is Array and row.size() >= 2 and str(row[0]).begins_with("ford."):
			notable.append("%s = %s" % [str(row[0]), str(row[1])])
	if not notable.is_empty():
		holder.add_child(U.label(_font, "剧情进展", 20, U.GOLD))
		holder.add_child(U.label(_font, "　".join(notable), 16))
