extends CanvasLayer
## dialog.gd — the Talk Panel: portrait box at the bottom, topic menu above.
## The panel / portrait / labels / menu are authored in main.tscn; this script
## only fills them and owns the open-close flow.
## Line source: Game (Scheme VM on its own thread). Recipe:
##   玩家选话题 → Scheme 查状态（LLM 可用时生成台词）→ 确定性状态更新
## All calls are async RPC (Game.call_async), so the main thread keeps
## rendering while the logic thread thinks.

# npc_id -> lsw Faceset directory for the portrait
const PORTRAITS := {
	"smith":      "Villager",
	"apothecary": "Woman",
	"innkeeper":  "Villager2",
}
# The npc_id keys must match scheme/game/main.scm.

var cjk_font: Font

@onready var _portrait: TextureRect = $Box/Portrait
@onready var _name_label: Label = $Box/NameLabel
@onready var _text: RichTextLabel = $Box/Text
@onready var _menu_vbox: VBoxContainer = $Menu/MenuVBox

var is_open := false
var _npc_id := ""
var _typing := false
var _type_speed := 40.0  # visible ratio per second
# True-token streaming: while `game:talk` is in flight, pieces arrive via
# Game.stream_pieces (worker thread -> bridge poll) and are appended live.
var _stream_live := false
var _stream_buf := ""

func _ready() -> void:
	visible = false
	Game.stream_pieces.connect(_on_stream_pieces)

## Called by main.gd once it has picked the system CJK font.
func apply_font(f: Font) -> void:
	cjk_font = f
	_name_label.add_theme_font_override("font", f)
	_text.add_theme_font_override("normal_font", f)

## ------------------------------------------------------------------ flow --

func open_npc(npc: Node2D) -> void:
	_npc_id = npc.npc_id
	_set_portrait(_npc_id)
	_name_label.text = npc.display_name
	npc.face_towards(position_of_player())
	_clear_menu()
	_text.text = ""
	visible = true
	is_open = true
	# Canned greeting (no LLM), then topics straight from Scheme data.
	var greet: Variant = await Game.call_async("game:greet", [_npc_id])
	if not is_open:
		return
	var line: String = "……"
	if greet is Array and greet.size() >= 1:
		line = str(greet[0])
	_type_out_free(line)
	var topics: Variant = await Game.call_async("game:topics", [_npc_id])
	if not is_open:
		return
	var i := 1
	if topics is Array:
		for t in topics:
			if t is Array and t.size() == 2:
				_add_choice(str(t[1]), str(t[0]), i)
				i += 1

func close() -> void:
	visible = false
	is_open = false
	_typing = false
	_text.text = ""

func _clear_menu() -> void:
	# queue_free, not free: a choice button is often inside its own pressed
	# signal when this runs, and a locked object cannot be freed.
	for child in _menu_vbox.get_children():
		_menu_vbox.remove_child(child)
		child.queue_free()

func _add_choice(label: String, topic_key: String, hotkey: int) -> void:
	var b := Button.new()
	b.text = "%d. %s" % [hotkey, label]
	b.alignment = HORIZONTAL_ALIGNMENT_LEFT
	if cjk_font:
		b.add_theme_font_override("font", cjk_font)
		b.add_theme_font_size_override("font_size", 24)
	b.pressed.connect(func() -> void: _choose(topic_key))
	_menu_vbox.add_child(b)

func _add_choices_after_reply() -> void:
	_clear_menu()
	var leave := Button.new()
	leave.text = "1. 再见"
	if cjk_font:
		leave.add_theme_font_override("font", cjk_font)
		leave.add_theme_font_size_override("font_size", 24)
	leave.pressed.connect(close)
	_menu_vbox.add_child(leave)

func _choose(topic: String) -> void:
	_clear_menu()
	_stream_live = true
	_stream_buf = ""
	_text.text = "……（思考中）"
	_text.visible_ratio = 1.0
	var out: Variant = await Game.call_async("game:talk", [_npc_id, topic])
	_stream_live = false
	if not is_open:
		return
	var reply: String = "……（不知为何沉默了）"
	var learned := false
	if out is Array and out.size() >= 3:
		reply = str(out[0])
		if out.size() >= 4:
			learned = bool(out[3])
	_stream_live = false
	_stream_buf = ""
	if learned:
		# "learned" line: this exact (NPC, topic, village state) hit the Scheme
		# cache, so the answer is stable — mark it on the name plate.
		_name_label.text += "  📖 记住了"
	var shown_live: bool = _text.text != "" and _text.visible_ratio >= 1.0
	if shown_live:
		# The token stream already revealed this line; just finalize it
		# (the panel strips the "老王：" prefix) without re-typing.
		_text.text = _strip_name(reply)
		_text.visible_ratio = 1.0
	else:
		_type_out_free(reply)
	_add_choices_after_reply()

## Live stream from the worker: replace the "thinking" placeholder with real
## text the moment the first token lands, then keep appending. The retrievable
## final reply replaces this afterwards (same text, so no visible jump).
func _on_stream_pieces(pieces: PackedStringArray) -> void:
	if not _stream_live or not is_open:
		return
	for p in pieces:
		_stream_buf += p
	if _stream_buf.is_empty():
		return
	if _text.text == "……（思考中）" or _text.text == "……":
		_text.text = ""
	_typing = false
	_text.text = _stream_buf
	_text.visible_ratio = 1.0

## Fire-and-forget typewriter for lines already known (greeting / reply).
func _type_out_free(line: String) -> void:
	_text.text = _strip_name(line)
	_text.visible_ratio = 0.0
	_typing = true
	_run_typewriter(_text.text)

## Lines from Scheme are authored as "老王：……"; the panel already shows the
## name above the text, so drop the duplicated prefix.
func _strip_name(line: String) -> String:
	for sep in ["：", ":"]:
		var prefix: String = _name_label.text + str(sep)
		if line.begins_with(prefix):
			return line.substr(prefix.length())
	return line

func _run_typewriter(line: String) -> void:
	var t := 0.0
	while t < 8.0:  # safety cap so a long LLM line still completes
		var dt := get_process_delta_time()
		t += dt
		_text.visible_ratio = clampf(
			_text.visible_ratio + dt * _type_speed / maxf(1.0, line.length()),
			0.0, 1.0)
		await get_tree().process_frame
		if _text.visible_ratio >= 1.0:
			break
	_typing = false

func _unhandled_input(event: InputEvent) -> void:
	if not is_open:
		return
	if event.is_action_pressed("interact"):
		if _typing:
			_text.visible_ratio = 1.0
		else:
			close()
	elif event is InputEventKey and event.pressed and not event.echo:
		var idx: int = event.keycode - KEY_1 + 1
		if idx >= 1 and idx <= 9:
			var buttons := _menu_vbox.get_children()
			if idx <= buttons.size():
				var b: Button = buttons[idx - 1]
				b.pressed.emit()

func position_of_player() -> Vector2:
	var main: Node = get_parent()
	return main.player.position if main and main.player else Vector2.ZERO

func _set_portrait(npc_id: String) -> void:
	var dir: String = PORTRAITS.get(npc_id, "Villager")
	var path: String = "res://assets/lsw/Faces/Actor/Character/%s/Faceset.png" % dir
	var at := AtlasTexture.new()
	at.atlas = load(path)
	at.region = Rect2(0, 0, 38, 38)
	_portrait.texture = at
