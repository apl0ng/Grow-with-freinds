class_name SeedPacket
extends Item
## Seed packet bought at the shop and planted into an empty GrowPlot. `strain_id` (synced) picks the SeedDef.
## Visuals: packet body + bud icon tinted with the strain color (per-instance material), strain name printed
## on the front (+Z face, turned towards the player when dropped / held).

## Tint used when the strain id is unknown.
const UNKNOWN_COLOR := Color(0.7, 0.7, 0.7)

## Strain id (SeedDef.id), synced (server authority).
var strain_id: StringName = &"":
	set = _set_strain_id

var _tint: StandardMaterial3D = null
var _icon_tint: StandardMaterial3D = null

@onready var _tinted: Array[MeshInstance3D] = [$Visual/Packet/Body, $Visual/Packet/EdgeLeft, $Visual/Packet/EdgeRight]
@onready var _icon: MeshInstance3D = $Visual/Packet/Icon/Bud
@onready var _name_label: Label3D = $Visual/Packet/NameLabel

func get_seed() -> SeedDef:
	return Config.balance.get_seed(strain_id)

func get_strain_name() -> String:
	var def := get_seed()
	return def.display_name if def != null else "Mystery"

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
	var color := def.color if def != null else UNKNOWN_COLOR
	if _tint == null:
		_tint = _make_tint(_tinted[0])
		# The packet front is a big flat face: matte it (like Toon's MATTE finish) so the toon specular
		# highlight does not wash the strain color out to white.
		_tint.roughness = maxf(_tint.roughness, 0.8)
		_tint.metallic_specular = minf(_tint.metallic_specular, 0.1)
		for mesh in _tinted:
			mesh.material_override = _tint
		_icon_tint = _make_tint(_icon)
		_icon.material_override = _icon_tint
	_tint.albedo_color = color
	# Icon bud on the white plate: a slightly deeper shade so it reads against the packet color too.
	_icon_tint.albedo_color = color.darkened(0.15)
	if _icon_tint.emission_enabled:
		_icon_tint.emission = _icon_tint.albedo_color
	_name_label.text = get_strain_name()

## Per-instance copy of the mesh's current (library) material, so tinting never touches the shared .tres.
static func _make_tint(mesh: MeshInstance3D) -> StandardMaterial3D:
	var base := mesh.material_override as StandardMaterial3D
	var mat: StandardMaterial3D = base.duplicate() as StandardMaterial3D if base != null else StandardMaterial3D.new()
	return mat
