extends Sprite2D
## ore.gd — a mineable rock pickup placed on the map.
## The pickup itself is presentation-only: main.gd notices the player walking
## over it and asks Scheme (`game:take-ore`) to update the carried count.

func _ready() -> void:
	add_to_group("ore")
	# Gentle bob so the ore reads as an interactive item.
	var y0 := position.y
	var tw := create_tween().set_loops()
	tw.tween_property(self, "position:y", y0 - 3.0, 0.7) \
		.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
	tw.tween_property(self, "position:y", y0, 0.7) \
		.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
