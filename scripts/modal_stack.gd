extends Node
## modal_stack.gd — modal UI input routing.
##
## A panel pushes itself when it opens and pops itself when it closes, and
## implements `modal_input(event) -> bool`. Input is tried from the top of the
## stack down; the first panel that consumes it returns true, and the world
## never sees it. An empty stack means the world gets every key.
##
## This is the piece that keeps new panels out of main.gd's input lifecycle:
## adding a panel no longer means editing _unhandled_input, _switch_map and
## hot_reload to teach main.gd about it.

signal stack_changed

var _stack: Array[Node] = []

func push(modal: Node) -> void:
	if _stack.has(modal):
		return
	_stack.append(modal)
	stack_changed.emit()

func pop(modal: Node) -> void:
	if not _stack.has(modal):
		return
	_stack.erase(modal)
	stack_changed.emit()

func top() -> Node:
	return _stack.back() if not _stack.is_empty() else null

func is_modal_open() -> bool:
	return not _stack.is_empty()

func has(modal: Node) -> bool:
	return _stack.has(modal)

## Offer the event to each open panel, top first. True means consumed.
func handle_input(event: InputEvent) -> bool:
	for i in range(_stack.size() - 1, -1, -1):
		var modal: Node = _stack[i]
		if is_instance_valid(modal) and modal.has_method("modal_input") \
				and bool(modal.modal_input(event)):
			return true
	return false

## A modal may supply a verb hint that replaces the world hint while it is up
## (e.g. "E / Esc 关闭箱子"). Empty means the world hint stands.
func verb_hint() -> String:
	for i in range(_stack.size() - 1, -1, -1):
		var modal: Node = _stack[i]
		if is_instance_valid(modal) and modal.has_method("verb_hint"):
			var hint := str(modal.verb_hint())
			if hint != "":
				return hint
	return ""

## Closing every panel is one call at map travel / reload / console boundaries.
## Clear first so a panel's close() -> pop() does not re-emit stack_changed.
func close_all() -> void:
	var all: Array[Node] = _stack.duplicate()
	_stack.clear()
	stack_changed.emit()
	for modal in all:
		if is_instance_valid(modal) and modal.has_method("close"):
			modal.close()
