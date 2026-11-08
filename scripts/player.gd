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
