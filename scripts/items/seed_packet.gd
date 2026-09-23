class_name SeedPacket
extends Item
## Seed packet bought at the shop and planted into an empty GrowPlot. `strain_id` (synced) picks the SeedDef.
## Visuals: the Blender model art/models/seed_packet.glb instanced as Visual/Packet (Toonify root). The strain
## colour, graded with Toon.grade(), tints every TINT part through Toonify (crimp, icon bud) and the paper Body
## through its own per-instance material_override; the strain name is printed on the front (+Z face, turned
## towards the player when dropped / held).

## Tint used when the strain id is unknown.
const UNKNOWN_COLOR := Color(0.7, 0.7, 0.7)

## Strain id (SeedDef.id), synced (server authority).
var strain_id: StringName = &"":
	set = _set_strain_id

## Per-instance material of the paper Body (a copy of its Toonify conversion), re-tinted in place.
var _tint: StandardMaterial3D = null

@onready var _model: Toonify = $Visual/Packet as Toonify
@onready var _body: MeshInstance3D = $Visual/Packet/Body
@onready var _name_label: Label3D = $Visual/Packet/NameLabel

func get_seed() -> SeedDef:
	return Config.balance.get_seed(strain_id)

func get_strain_name() -> String:
	var def := get_seed()
	return def.display_name if def != null else "Unmarked"

func get_display_name() -> String:
	return "%s Seeds" % get_strain_name()

## props: {"strain_id": StringName}
func apply_props(props: Dictionary) -> void:
	strain_id = StringName(str(props.get("strain_id", strain_id)))

func get_props() -> Dictionary:
	return {"strain_id": String(strain_id)}

func _set_strain_id(value: StringName) -> void:
	if value == strain_id:
		return
	strain_id = value
	_notify_props_changed()

func _refresh_visuals() -> void:
	var def := get_seed()
	# Data colours are mood-graded (STYLE.md): the same colour the plant's buds and the product use.
	var color := Toon.grade(def.color if def != null else UNKNOWN_COLOR)
	if _model != null:
		_model.tint = color # crimp (a darker shade of it) and the icon bud
	if _tint == null:
		_tint = _make_tint(_body, color)
		_body.material_override = _tint
	_tint.albedo_color = color # the paper is TINT at shade 1.0: albedo == the tint
	_name_label.text = get_strain_name()

## Per-instance copy of the mesh's Toonify material for `color` (matte paper, toon shading), so re-tinting
## never touches Toonify's shared cache or a library .tres.
static func _make_tint(mesh: MeshInstance3D, color: Color) -> StandardMaterial3D:
	var src := mesh.mesh.surface_get_material(0) if mesh != null and mesh.mesh != null else null
	var base := Toonify.toon_material(src, -1.0, color) as StandardMaterial3D
	return base.duplicate() as StandardMaterial3D if base != null else Toon.make(color, Toon.Finish.MATTE)
