extends CanvasLayer
## help_panel.gd — H key: controls and panel index. Replaces the long key list
## that used to sit in the HUD footer.

const U := preload("res://scripts/panel_util.gd")

var is_open := false
var toggle_key := KEY_NONE

func setup_ui(font: Font) -> void:
	var ui := U.build_shell(self, font, "HelpLayer", 28, "帮助 / 键位", 720, 500)
	var holder: Node = ui.get("content")
	var box := U.rich_text(font)
	holder.add_child(box)
	U.add_close_button(self, font)
	box.text = "\n".join([
		"移动　WASD / 方向键",
		"E　主动词：交谈 / 开箱 / 读牌 / 查看线索",
		"F　使用手里的工具（砍树 / 打史莱姆）",
		"数字键 1-9　选择对话话题",
		"",
		"面板",
		"  C　角色 / 世界状态",
		"  L　消息日志",
		"  M　世界地图（当前图的锚点、NPC、传送点）",
		"  I　背包（点工具格装备，点手槽卸下）",
		"  J　任务日志",
		"  O　音量设置",
		"  H　本帮助",
		"  F1　机制 HUD（LLM 提议 → Scheme 决断）",
		"",
		"系统",
		"  F5　快存　　F9　快读",
		"  F8　GM 控制台（调试模块，发布版可删）",
		"  Esc　关闭当前面板 / 中止验收回放",
		"",
		"提示：走到小箭头标记上按方向键可以切换地图。",
	])
	visible = false

func set_toggle_key(key: int) -> void:
	toggle_key = key

func open() -> void:
	if is_open: return
	is_open = true
	visible = true
	Modals.push(self)

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
	return "Esc / H 关闭"
