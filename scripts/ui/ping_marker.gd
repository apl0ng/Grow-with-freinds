class_name PingMarker
extends Node3D
## World marker for a ping (scenes/ui/ping_marker.tscn): a small diamond in the pinger's colour HEIGHT above the
## pinged point plus a billboard name label, drawn on top so a ping behind a tray still reads. Pops in, bobs, pops
## out and frees itself LIFETIME_SEC after place(). Pure local cosmetics: the HUD spawns one under Game.world on
## Comms.ping_received (a new ping by the same worker replaces their previous marker).

const LIFETIME_SEC: float = 4.0
const POP_OUT_SEC: float = 0.2
const HEIGHT: float = 0.4
const BOB_AMPLITUDE: float = 0.06
const BOB_PERIOD_SEC: float = 1.6
const LABEL_FONT_SIZE: int = 48
const LABEL_OUTLINE: int = 12

var peer_id: int = 0
var _age: float = 0.0
var _closing: bool = false
var _placed: bool = false

@onready var visual: Node3D = %Visual
@onready var top_mesh: MeshInstance3D = %Top
@onready var bottom_mesh: MeshInstance3D = %Bottom
@onready var name_label: Label3D = %NameLabel


func _ready() -> void:
	var font := FontVariation.new()
	font.variation_embolden = 0.9
	name_label.font = font
	name_label.font_size = LABEL_FONT_SIZE
	name_label.outline_size = LABEL_OUTLINE
	name_label.outline_modulate = Toon.INK
	name_label.pixel_size = 0.005
	name_label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	name_label.no_depth_test = true
	name_label.render_priority = 10
	name_label.outline_render_priority = 9
	name_label.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	for mesh in [top_mesh, bottom_mesh]:
		mesh.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	if not _placed:
		_apply_peer()


## Marks `point` (world space) for `peer` (name + colour from Net). Call once the marker is in the tree.
func place(peer: int, point: Vector3) -> void:
	peer_id = peer
	_placed = true
	if is_inside_tree():
		global_position = point + Vector3.UP * HEIGHT
	else:
		position = point + Vector3.UP * HEIGHT
	_age = 0.0
	_closing = false
	if is_node_ready():
		_apply_peer()
		if is_inside_tree():
			Juice.pop_in(visual, 0.3)


func _process(delta: float) -> void:
	_age += delta
	if visual != null:
		visual.position.y = sin(_age * TAU / BOB_PERIOD_SEC) * BOB_AMPLITUDE
	if not _closing and _age >= LIFETIME_SEC - POP_OUT_SEC:
		_closing = true
		Juice.pop_out(self, POP_OUT_SEC, true)
	elif _age > LIFETIME_SEC + 1.0 and not is_queued_for_deletion():
		queue_free() # safety net if the pop-out tween never finished


func _apply_peer() -> void:
	var color: Color = Net.get_player_color(peer_id)
	var mat := Toon.tint(color)
	top_mesh.material_override = mat
	bottom_mesh.material_override = mat
	name_label.text = Net.get_player_name(peer_id)
	name_label.modulate = Toon.lighter(Toon.grade(color), 0.35)
