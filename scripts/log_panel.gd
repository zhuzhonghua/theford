extends CanvasLayer
## log_panel.gd — L key: rule-engine and system message history.
## Previously these flashed on the HUD for five seconds and vanished; the
## shell keeps the last 20 in main.log_history().

const U := preload("res://scripts/panel_util.gd")

var is_open := false
var toggle_key := KEY_NONE
var main: Node
var _text: RichTextLabel

func setup_with_main(font: Font, main_node: Node) -> void:
	main = main_node
	var ui := U.build_shell(self, font, "LogLayer", 28, "消息日志", 720, 460)
	var holder: Node = ui.get("content")
	_text = U.rich_text(font)
	holder.add_child(_text)
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
	return "Esc / L 关闭"

func log_text() -> String:
	return _text.text if _text != null else ""

func _on_snapshot() -> void:
	if is_open: refresh()

func refresh() -> void:
	if _text == null or main == null: return
	var history: Array = main.log_history()
	if history.is_empty():
		_text.text = "（还没有消息）"
		return
	var lines: Array[String] = []
	for i in range(history.size() - 1, -1, -1):
		lines.append("· " + str(history[i]))
	_text.text = "\n".join(lines)
