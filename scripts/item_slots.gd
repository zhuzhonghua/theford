extends RefCounted
## item_slots.gd — item grid math shared by the bag and container panels.
##
## The slot rules live in scheme/game/inventory.scm: a piece takes one cell,
## anything else one cell per stack-max. Scheme sends each row's cell count
## (`row[4]`), so the panels only expand rows into cells and never duplicate
## the capacity rules. Keeping this here means the bag panel and the container
## panel cannot drift apart.

const COLUMNS := 10
const SLOT_COUNT := 30  # keep in sync with inventory.scm bag-slots
const STACK_MAX := 999  # keep in sync with inventory.scm stack-max

## Expand Scheme's stack rows into one entry per grid cell. `row[4]` is the
## number of cells the row takes: a tool with 3 pieces yields three cells of
## one; a 1000-ore stack yields 999 + 1. The rule matches inventory.scm's
## row-slots exactly, including the "slots == count means pieces" case.
static func build_slots(rows: Array) -> Array:
	var out: Array = []
	for row in rows:
		if not (row is Array and row.size() >= 3):
			continue
		var type_id := str(row[0])
		var count := int(row[1])
		if count <= 0:
			continue
		var display := str(row[2])
		var sprite := str(row[3]) if row.size() >= 4 else ""
		var cells := int(row[4]) if row.size() >= 5 else 1
		if cells >= count:
			for i in range(count):
				out.append([type_id, 1, display, sprite])
		else:
			var left := count
			while left > 0:
				var amount := mini(left, STACK_MAX)
				out.append([type_id, amount, display, sprite])
				left -= amount
	return out

static func slot_style(held: bool) -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.13, 0.11, 0.09, 0.92)
	sb.border_color = Color(0.85, 0.68, 0.30) if held else Color(0.36, 0.28, 0.18)
	sb.set_border_width_all(3 if held else 2)
	sb.set_corner_radius_all(4)
	return sb

## A cell the container has but its capacity does not reach (an 8-slot chest
## drawn on a ten-column grid): visible as a frame, but not a place for items.
static func off_slot_style() -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.08, 0.07, 0.06, 0.55)
	sb.border_color = Color(0.22, 0.18, 0.13)
	sb.set_border_width_all(1)
	sb.set_corner_radius_all(4)
	return sb
