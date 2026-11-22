extends Sprite2D
## herb.gd — a herb pickup in the apothecary's garden.
## Like ore.gd it is presentation-only: main.gd notices the player in reach and
## asks Scheme (`game:take`) to put it in the bag. The herb count a quest needs
## is read from that same bag stack, so picking one up advances the log at once.

func _ready() -> void:
	add_to_group("herb")
	var y0 := position.y
	var tw := create_tween().set_loops()
	tw.tween_property(self, "position:y", y0 - 2.0, 0.9) \
		.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
	tw.tween_property(self, "position:y", y0, 0.9) \
		.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
