extends Sprite2D
## creature.gd — a wild creature (the slime).
##
## Split of responsibilities mirrors the villagers: Scheme owns the creature's
## hp and decides what a blow or a bite means (rules.scm); this script owns the
## body — wandering, chasing, keeping to its home range and the bite cadence.
## It never touches the VM directly except to hand a bite to game:creature-bite.
##
## Behaviour follows the reference creature loop: wander near home, chase a
## player that comes into sight while the creature is still on its leash, bite
## at melee range on a cooldown, and return home if it strays too far.

@export var creature_id := ""
@export var speed := 28.0        # pixels / second (type prop speed 7 * 4)
@export var sight := 64.0        # 4 tiles
@export var leash := 80.0        # 5 tiles from the spawn cell
@export var bite_reach := 18.0   # adjacent
@export var bite_cooldown := 1.4 # ~14 ticks at 10 ticks / minute

var main: Node2D
var home := Vector2.ZERO

var _state := "wander"   # wander | chase | return
var _target := Vector2.ZERO
var _pause := 0.0
var _bite_ready_at := 0.0
var _biting := false
var _anim_t := 0.0

func _ready() -> void:
	add_to_group("creature")
	add_to_group("slime")
	hframes = 4
	vframes = 4
	home = position
	_target = position

func _process(delta: float) -> void:
	if main == null:
		return
	# A modal panel or the death screen freezes the world, just like player.gd.
	if Modals.is_modal_open() or bool(Game.snapshot.get("game_over", false)):
		_animate(delta, false)
		return
	var player: Node2D = main.player if is_instance_valid(main.player) else null
	if player == null:
		return
	var to_player: Vector2 = player.position - position
	var dist_player: float = to_player.length()
	var from_home: float = position.distance_to(home)

	if from_home > leash:
		_state = "return"
		_target = home
	elif dist_player <= sight and from_home <= leash:
		_state = "chase"
		_target = player.position
	else:
		_state = "wander"

	if _state == "chase" and dist_player <= bite_reach:
		_try_bite()
		_animate(delta, false)
		return

	if _pause > 0.0:
		_pause -= delta
		_animate(delta, false)
		return
	if _target_settled():
		if _state == "wander":
			_pause = randf_range(0.4, 1.2)
			_target = _wander_point()
		else:
			_animate(delta, false)
			return
	var step := speed * delta if _state == "chase" else speed * 0.6 * delta
	if not _move_towards(_target, step):
		# Blocked by a tree/wall: give up this waypoint and pick another.
		_pause = 0.3
		_target = _wander_point()
	_animate(delta, true)

func _target_settled() -> bool:
	return position.distance_to(_target) <= 1.0

## A random walkable cell within two tiles of home. Keeps the creature near
## its spawn without Scheme ever learning a coordinate.
func _wander_point() -> Vector2:
	for _i in range(12):
		var cell := Vector2i(floori(home.x / 16.0), floori(home.y / 16.0))
		cell += Vector2i(randi_range(-2, 2), randi_range(-2, 2))
		var p := Vector2(cell.x * 16.0 + 8.0, cell.y * 16.0 + 8.0)
		if p.distance_to(home) <= leash and main.is_walkable(p):
			return p
	return home

## Axis-separated step, the same "read before write" walkability the player
## uses. Returns false when neither axis could advance.
func _move_towards(goal: Vector2, amount: float) -> bool:
	var delta: Vector2 = goal - position
	if delta.length_squared() < 0.001:
		return false
	var moved := false
	if absf(delta.x) >= absf(delta.y):
		moved = _try_axis(Vector2(signf(delta.x) * amount, 0.0))
		moved = _try_axis(Vector2(0.0, signf(delta.y) * amount)) or moved
	else:
		moved = _try_axis(Vector2(0.0, signf(delta.y) * amount))
		moved = _try_axis(Vector2(signf(delta.x) * amount, 0.0)) or moved
	return moved

func _try_axis(disp: Vector2) -> bool:
	if disp == Vector2.ZERO:
		return false
	var next := position + disp
	if main.is_walkable(next):
		position = next
		return true
	return false

func _try_bite() -> void:
	if _biting or Time.get_ticks_msec() < _bite_ready_at:
		return
	_biting = true
	_bite_ready_at = Time.get_ticks_msec() + int(bite_cooldown * 1000.0)
	var effects: Variant = await Game.call_async(
			"game:creature-bite", [creature_id, "player"])
	_biting = false
	main._apply_effects(effects)
	# Hurt / death live in Scheme; pull the fresh health into the snapshot.
	Game.send("game:hp")

func _animate(delta: float, moving: bool) -> void:
	if moving:
		_anim_t += delta * 8.0
		frame = int(_anim_t) % 16
	else:
		_anim_t = 0.0
		frame = 0
