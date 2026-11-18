extends Sprite2D
## npc.gd — a village NPC. Sprite: Ninja Adventure 64x112 SpriteSheet
## (same row layout as the player). The NPC never decides anything: its
## lines come from Scheme (async RPC via Game.call_async) on E press.

@export var npc_id := ""
@export var display_name := ""
@export var facing_row := 0

var _name_label: Label
var _walking := false
var _walk_phase := 0.0
var _bob_time := 0.0

func _ready() -> void:
	add_to_group("npc")
	hframes = 4
	vframes = 7
	frame = facing_row * 4

	_name_label = Label.new()
	_name_label.text = display_name
	_name_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_name_label.size = Vector2(48, 12)
	_name_label.position = Vector2(-24, -22)
	_name_label.add_theme_font_size_override("font_size", 9)
	_name_label.add_theme_color_override("font_color", Color(1, 0.97, 0.9))
	_name_label.add_theme_color_override("font_outline_color", Color(0.1, 0.08, 0.06))
	_name_label.add_theme_constant_override("outline_size", 3)
	add_child(_name_label)

## Tiny idle bob so the village feels alive. It animates the sprite's texture
## offset, not its position, so paths and collisions are unaffected. Walking
## switches to step frames instead.
func _process(delta: float) -> void:
	_bob_time += delta
	if _walking:
		_walk_phase += delta * 7.0
		frame = facing_row * 4 + (int(_walk_phase) % 2) * 2
		offset.y = 0.0
	else:
		offset.y = sin(_bob_time * 2.8) * 0.75

## main.gd calls this while the NPC follows its schedule path.
func set_walking(moving: bool) -> void:
	if moving == _walking:
		return
	_walking = moving
	if moving:
		_walk_phase = 0.0
	else:
		frame = facing_row * 4
		offset.y = 0.0

func face_dir(d: Vector2) -> void:
	if d.length_squared() < 0.001:
		return
	if absf(d.x) > absf(d.y):
		facing_row = 2 if d.x > 0 else 1
	else:
		facing_row = 0 if d.y > 0 else 3
	if not _walking:
		frame = facing_row * 4

## Face the player when they come talk.
func face_towards(player_pos: Vector2) -> void:
	face_dir(player_pos - position)
	frame = facing_row * 4
