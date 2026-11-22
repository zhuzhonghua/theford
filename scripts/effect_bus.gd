extends Node
## effect_bus.gd — route rule-engine effects to their handlers by kind.
##
## Scheme returns flat ("kind" payload...) tuples. A registry maps each kind to
## a Callable, so a new effect is one register() call by the system that owns
## it, not a new arm in main.gd's match. The bus also emits `dispatched` so
## cross-cutting listeners (telemetry, acceptance, future save system) can
## observe effects without being wired into the renderer.
##
## Handlers receive the effect's payload as one Array, so an adapter keeps a
## stable signature even when an effect gains another field.

signal dispatched(kind: String, effect: Array)

var _handlers := {}

func register(kind: String, handler: Callable) -> void:
	_handlers[kind] = handler

func unregister(kind: String) -> void:
	_handlers.erase(kind)

func has_handler(kind: String) -> bool:
	return _handlers.has(kind)

## Dispatch every tuple. `after` is an optional hook for the shared post-effect
## refresh (the bag view), which is not tied to any one effect kind.
func dispatch(effects: Variant, after: Callable = Callable()) -> void:
	if not (effects is Array):
		return
	for eff in effects:
		if not (eff is Array) or eff.size() < 2:
			continue
		var kind := str(eff[0])
		dispatched.emit(kind, eff)
		var handler: Callable = _handlers.get(kind, Callable())
		if handler.is_valid():
			handler.call(eff.slice(1))
	if after.is_valid():
		after.call()
