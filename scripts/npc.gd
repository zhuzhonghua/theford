extends Sprite2D
## npc.gd — a village NPC. Sprite: Ninja Adventure 64x112 SpriteSheet
## (same row layout as the player). The NPC never decides anything: its
## lines come from Scheme (async RPC via Game.call_async) on E press.

@export var npc_id := ""
@export var display_name := ""
@export var facing_row := 0

var _name_label: Label

func _ready() -> void:
	add_to_group("npc")
	hframes = 4
	vframes = 7
	frame = facing_row * 4

	# Tiny idle bob so the village feels alive. Values are absolute, so they
	# are derived from the spawn y; a literal 0 would teleport the NPC away.
	var y0 := position.y
	var tw := create_tween().set_loops()
	tw.tween_property(self, "position:y", y0 - 1.5, 1.1) \
		.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
	tw.tween_property(self, "position:y", y0, 1.1) \
		.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)

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

## Face the player when they come talk.
func face_towards(player_pos: Vector2) -> void:
	var d := player_pos - position
	if absf(d.x) > absf(d.y):
		facing_row = 2 if d.x > 0 else 1
	else:
		facing_row = 0 if d.y > 0 else 3
	frame = facing_row * 4
