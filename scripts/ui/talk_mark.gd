class_name TalkMark
extends Sprite3D
## M23 social: the small speaker mark over somebody who is talking (CONTRACTS "M23", "Social"; FRIENDSLOP 13, the
## Lethal Company note: who is talking when bodies overlap). A billboard Sprite3D: a speaker and two sound arcs in the
## HUD's off-white with an ink outline, the same texture for every mark (drawn once by mark_texture(), about 12 ms, which
## every Player asks for at _ready so it happens while the world loads; exact distance fields keep the edges clean at
## every mipmap). Unshaded, so a power cut does not hide it.
## Readable at 10 m: the drawing is MARK_HEIGHT (0.30 m) tall, twice the name label's capitals: 13 px at 720p and FOV 80.
## Hidden until set_talking(true). Nothing runs while it is hidden and nothing is allocated per frame.
##
## Two ways to sit:
##   a child of something that stays upright   the player's %NameLabel (Player, "M23 social"): a fixed offset above it,
##                                             no processing at all
##   follow(item, offset)                      an item that tumbles (a radio): top_level, kept `offset` above the item
##                                             in world space while shown; hidden while the item is in this peer's own
##                                             worker's hands (it would float in front of their camera)

## The drawing in texture pixels (y down). The speaker: a box and a cone in one outline; two arcs open to the right.
const TEX_W: int = 82
const TEX_H: int = 72
const SPEAKER: PackedVector2Array = [Vector2(12, 27), Vector2(27, 27), Vector2(43, 13), Vector2(43, 59), Vector2(27, 45), Vector2(12, 45)]
const ARC_CENTER := Vector2(46, 36)
const ARC_RADII: PackedFloat32Array = [13.0, 24.0]
const ARC_HALF_WIDTH: float = 3.0
## Half the angle each arc spans (rad); the ends are round.
const ARC_HALF_SPAN: float = 0.85
const OUTLINE_PX: float = 4.0
## Metres per texture pixel: the drawing (54 px from the top of the cone to its foot, outline included) is ~0.30 m.
const PIXEL_SIZE: float = 0.0056
## The drawing's height in metres (tests: readable at 10 m).
const MARK_HEIGHT: float = 54.0 * PIXEL_SIZE

static var _texture: ImageTexture = null

var _talking: bool = false
var _follow: Node3D = null
var _follow_offset := Vector3.ZERO
## How many times this mark was shown (tests).
var show_count: int = 0


func _init() -> void:
	texture = mark_texture()
	pixel_size = PIXEL_SIZE
	billboard = BaseMaterial3D.BILLBOARD_ENABLED
	shaded = false
	double_sided = true
	transparent = true
	alpha_cut = SpriteBase3D.ALPHA_CUT_DISABLED
	texture_filter = BaseMaterial3D.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS
	cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	visible = false
	set_process(false)


func _ready() -> void:
	set_process(_talking and _follow != null) # the engine turns _process on at ready: only a shown follower runs


## The texture every mark shares (drawn the first time it is asked for).
static func mark_texture() -> Texture2D:
	if _texture == null:
		_texture = ImageTexture.create_from_image(_draw_image())
	return _texture


## Shows (true) or hides the mark.
func set_talking(on: bool) -> void:
	if on and not _talking:
		show_count += 1
	_talking = on
	if _follow != null:
		set_process(on)
		if on:
			_place()
		else:
			visible = false
		return
	visible = on


func is_talking() -> bool:
	return _talking


## Follow `target` (an item that may tumble) at `offset` above it in world space, upright. Call once, after adding the
## mark as the target's child.
func follow(target: Node3D, offset: Vector3) -> void:
	_follow = target
	_follow_offset = offset
	top_level = true
	set_process(_talking)


func _process(_delta: float) -> void:
	_place()


func _place() -> void:
	if _follow == null or not is_instance_valid(_follow) or not _follow.is_inside_tree():
		visible = false
		return
	var item := _follow as Item
	var in_my_hands := item != null and item.holder_id != 0 and multiplayer.has_multiplayer_peer() \
			and item.holder_id == multiplayer.get_unique_id()
	visible = _talking and not in_my_hands
	if visible:
		global_position = _follow.global_position + _follow_offset


# --- the drawing ---------------------------------------------------------------------------------------------------------

static func _draw_image() -> Image:
	var img := Image.create_empty(TEX_W, TEX_H, false, Image.FORMAT_RGBA8)
	for y in TEX_H:
		for x in TEX_W:
			var d := _distance(Vector2(x + 0.5, y + 0.5))
			var a := clampf(OUTLINE_PX + 0.5 - d, 0.0, 1.0)
			if a <= 0.0:
				continue
			var c := Toon.INK.lerp(Toon.TEXT, clampf(0.5 - d, 0.0, 1.0))
			c.a = a
			img.set_pixel(x, y, c)
	img.generate_mipmaps()
	return img


## Signed distance (pixels) from `p` to the drawing: negative inside.
static func _distance(p: Vector2) -> float:
	var d := _polygon_distance(p, SPEAKER)
	for r in ARC_RADII:
		d = minf(d, _arc_distance(p, r))
	return d


## Exact signed distance to a simple polygon (Inigo Quilez's sdPolygon): the nearest edge, the sign by crossings.
static func _polygon_distance(p: Vector2, v: PackedVector2Array) -> float:
	var d := (p - v[0]).length_squared()
	var s := 1.0
	var j := v.size() - 1
	for i in v.size():
		var e := v[j] - v[i]
		var w := p - v[i]
		var b := w - e * clampf(w.dot(e) / e.dot(e), 0.0, 1.0)
		d = minf(d, b.length_squared())
		var c1 := p.y >= v[i].y
		var c2 := p.y < v[j].y
		var c3 := e.x * w.y > e.y * w.x
		if (c1 and c2 and c3) or (not c1 and not c2 and not c3):
			s = -s
		j = i
	return s * sqrt(d)


## Signed distance to an arc of radius `r` round ARC_CENTER, ARC_HALF_WIDTH thick, round ends.
static func _arc_distance(p: Vector2, r: float) -> float:
	var q := p - ARC_CENTER
	if absf(atan2(q.y, q.x)) <= ARC_HALF_SPAN:
		return absf(q.length() - r) - ARC_HALF_WIDTH
	var end := Vector2(cos(ARC_HALF_SPAN), sin(ARC_HALF_SPAN)) * r
	return minf(q.distance_to(end), q.distance_to(Vector2(end.x, -end.y))) - ARC_HALF_WIDTH
