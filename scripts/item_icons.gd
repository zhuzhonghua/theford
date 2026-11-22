extends RefCounted
## item_icons.gd — one catalog-icon cache per item panel.
##
## Scheme maps a row's sprite key ("item:axe", "fixture:chest", ...) through
## data/catalog.scm; this helper turns that reply into a Texture2D (plain or
## an AtlasTexture for sheets) and keeps one request per key. The cache holds
## an empty dictionary while the worker replies, so a repaint never floods the
## VM with the same request.

var _cache := {}

## Texture for `sprite`, or null while it loads (or when there is no icon).
## `on_loaded` is called once the reply lands so the panel can repaint.
func texture_for(sprite: String, on_loaded: Callable) -> Texture2D:
	if sprite == "":
		return null
	if _cache.has(sprite):
		var hit: Dictionary = _cache[sprite]
		return hit.get("texture", null)
	_cache[sprite] = {}
	_resolve(sprite, on_loaded)
	return null

## Sprite keys in `rows` that still have no texture: either loading or a bad
## catalog path. Acceptance fails on a non-empty list.
func missing(rows: Array) -> Array:
	var out: Array = []
	for entry in rows:
		var sprite := str(entry[3])
		if sprite == "" or out.has(sprite):
			continue
		var hit: Dictionary = _cache.get(sprite, {})
		if hit.get("texture", null) == null:
			out.append(sprite)
	return out

func _resolve(sprite: String, on_loaded: Callable) -> void:
	var info: Variant = await Game.call_async("game:catalog-item", [sprite])
	var texture: Texture2D = null
	if info is Array and info.size() >= 1 and str(info[0]) != "":
		var source: Texture2D = load("res://" + str(info[0]))
		if source != null:
			texture = source
			if info.size() >= 5:
				var w := int(info[3])
				var h := int(info[4])
				if w > 0 and h > 0:
					var atlas := AtlasTexture.new()
					atlas.atlas = source
					atlas.region = Rect2(int(info[1]), int(info[2]), w, h)
					texture = atlas
	_cache[sprite] = {"texture": texture}
	if on_loaded.is_valid():
		on_loaded.call()
