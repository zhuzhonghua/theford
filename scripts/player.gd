extends Sprite2D
## player.gd — free 4-direction movement over the built tilemap.
## Collision is data, not physics: main.is_walkable() implements "read any,
## write own" style grid rules in Scheme-land; the shell just enforces them.
## Sprite layout: Ninja Adventure SpriteSheet.png — 16px cells, 4 columns
## (walk frames), rows: 0 down / 1 left / 2 right / 3 up.

const TILE := 16
const SPEED := 70.0

var main: Node2D
var facing := "down"
## Acceptance/demo walking drives the sprite through walk_to(). While true,
## manual input is ignored so a scripted walk cannot fight the keyboard.
var scripted := false
var _scripted_target := Vector2.ZERO
var _scripted_dir := Vector2.ZERO

# body half-extents for the collision test box
const HW := 5.0
const HH_TOP := 3.0   # smaller on top so movement under trees feels right
const HH_BOT := 3.0

var _anim_t := 0.0

func _ready() -> void:
	hframes = 4
	vframes = 7

func _physics_process(delta: float) -> void:
	if main and main.dialog_ui and main.dialog_ui.is_open:
		_animate(delta, false)
		return
	if main and main.gm and main.gm.is_open:
		_animate(delta, false)
		return
	# Any focused text field owns the keyboard: typing w/a/s/d must never walk.
	var focus := get_viewport().gui_get_focus_owner()
	if focus is LineEdit or focus is TextEdit:
		_animate(delta, false)
		return
	if scripted:
		_step_scripted(delta)
		return
	var dir := Vector2.ZERO
	if Input.is_action_pressed("move_left"):
		dir.x -= 1
		facing = "left"
	elif Input.is_action_pressed("move_right"):
		dir.x += 1
		facing = "right"
	if Input.is_action_pressed("move_up"):
		dir.y -= 1
		facing = "up"
	elif Input.is_action_pressed("move_down"):
		dir.y += 1
		facing = "down"

	var moving := dir != Vector2.ZERO
	if moving:
		dir = dir.normalized()
		_move_with_collision(dir * SPEED * delta)
	_animate(delta, moving)

## Scripted walking for acceptance/demo playback: same 4-direction movement,
## collision and walk frames as the keyboard path, so a replay reads as a
## person playing instead of a teleport. Lands exactly on the point: a
## sub-pixel shortfall would drag the feet box into the next row.
func walk_to(point: Vector2, timeout := 8.0) -> bool:
	scripted = true
	_scripted_target = point
	var elapsed := 0.0
	var stuck := 0.0
	var last := position
	while position.distance_to(point) > 0.6:
		await get_tree().physics_frame
		elapsed += get_physics_process_delta_time()
		if position.distance_to(last) < 0.05:
			stuck += get_physics_process_delta_time()
		else:
			stuck = 0.0
			last = position
		if elapsed >= timeout or stuck >= 0.5:
			break
	_scripted_dir = Vector2.ZERO
	scripted = false
	_animate(0.0, false)
	return position.distance_to(point) <= 0.6

func stop_scripted() -> void:
	scripted = false
	_scripted_target = position
	_scripted_dir = Vector2.ZERO

func _step_scripted(delta: float) -> void:
	var remaining := _scripted_target - position
	if remaining.length() <= 0.6:
		_scripted_dir = Vector2.ZERO
		_animate(delta, false)
		return
	if absf(remaining.x) >= absf(remaining.y):
		_scripted_dir = Vector2(signf(remaining.x), 0.0)
	else:
		_scripted_dir = Vector2(0.0, signf(remaining.y))
	if _scripted_dir.x < 0.0:
		facing = "left"
	elif _scripted_dir.x > 0.0:
		facing = "right"
	elif _scripted_dir.y < 0.0:
		facing = "up"
	else:
		facing = "down"
	# Clamp the step to the waypoint so scripted walking never overshoots and
	# oscillates around a target the keyboard path would simply walk onto.
	var step := SPEED * delta
	var disp := Vector2.ZERO
	if _scripted_dir.x != 0.0:
		disp.x = signf(_scripted_dir.x) * minf(step, absf(remaining.x))
	if _scripted_dir.y != 0.0:
		disp.y = signf(_scripted_dir.y) * minf(step, absf(remaining.y))
	_move_with_collision(disp)
	_animate(delta, true)

func _move_with_collision(disp: Vector2) -> void:
	# Move axis by axis, testing the leading edge of the feet/body box.
	var y_off := 4.0  # collision box sits at the feet, below the visual center
	if disp.x != 0:
		var nx: Vector2 = position + Vector2(disp.x, 0)
		var sx: float = HW if disp.x > 0 else -HW
		var edge: Vector2 = nx + Vector2(sx, 0) + Vector2(0, y_off)
		var a: Vector2 = edge + Vector2(0, -HH_TOP)
		var b: Vector2 = edge + Vector2(0, HH_BOT)
		if main.is_walkable(a) and main.is_walkable(b):
			position = nx
	if disp.y != 0:
		var ny: Vector2 = position + Vector2(0, disp.y)
		var sy: float = HH_BOT if disp.y > 0 else -HH_BOT
		var edge_y: Vector2 = ny + Vector2(0, sy) + Vector2(0, y_off)
		var a2: Vector2 = edge_y + Vector2(-HW, 0)
		var b2: Vector2 = edge_y + Vector2(HW, 0)
		if main.is_walkable(a2) and main.is_walkable(b2):
			position = ny

func _animate(delta: float, moving: bool) -> void:
	var row: int = {"down": 0, "left": 1, "right": 2, "up": 3}[facing]
	if moving:
		_anim_t += delta * 9.0
		frame = row * 4 + int(_anim_t) % 4
	else:
		_anim_t = 0.0
		frame = row * 4  # standing frame
