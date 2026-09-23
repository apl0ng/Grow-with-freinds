extends MultiMeshInstance3D
## A run of one Blender segment model (res://art/models/*.glb with a single mesh) tiled `count` times along
## local +X, `step` metres apart, in ONE node (a MultiMesh): ceiling pipe runs, cable trays, repeated hangers.
## (environment modeler; room decor, visual only, no collision.)
##
## The room has a node budget (world_test: <= 360 nodes), and a 20 m pipe made of 2 m GLB instances would cost
## 20 nodes; this costs one. Materials are converted exactly like a Toonify instance (library `toon_*` swap,
## TINT* recoloured with `tint`), and every run of the same model + tint shares one mesh.
## Copy i sits at local (step * i, 0, 0): for a centred 2 m segment covering x = a..b, put the node at a + 1
## with count = (b - a) / 2. Rotate the node to lay the run along another axis (e.g. vertical pipes).

## The segment (an imported .glb scene; its first MeshInstance3D is used, with its transform).
@export var model: PackedScene
@export_range(0, 64) var count: int = 1
@export var step: float = 2.0
## Every other copy is turned 180 degrees about local Y (varies rust, drips and loose cables along a run).
@export var flip_alternate: bool = false
## Colour for the model's TINT* materials (alpha 0 = keep the neutral grey). Palette colours as they are.
@export var tint: Color = Color(0, 0, 0, 0)

static var _meshes: Dictionary = {}   # "path|tint" -> [ArrayMesh with toon surface materials, Transform3D]


func _ready() -> void:
	rebuild()


## (Re)builds the MultiMesh from the exported settings (call it after changing them at runtime).
func rebuild() -> void:
	var entry := toon_mesh(model, tint)
	if entry.is_empty() or count <= 0:
		multimesh = null
		return
	var rel: Transform3D = entry[1]
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.mesh = entry[0]
	mm.instance_count = count
	for i in count:
		var b := Basis.IDENTITY
		if flip_alternate and i % 2 == 1:
			b = Basis(Vector3.UP, PI)
		mm.set_instance_transform(i, Transform3D(b, Vector3(step * float(i), 0.0, 0.0)) * rel)
	multimesh = mm


## [mesh, transform of the mesh node inside the model] for `scene`, the mesh's surfaces set to the toon
## versions of its materials (shared per model + tint). Empty when the scene has no MeshInstance3D.
static func toon_mesh(scene: PackedScene, tint_color: Color = Color(0, 0, 0, 0)) -> Array:
	if scene == null:
		return []
	var key := "%s|%s" % [scene.resource_path, tint_color.to_html(true) if tint_color.a > 0.0 else "-"]
	if _meshes.has(key):
		return _meshes[key]
	var inst := scene.instantiate()
	var mi: MeshInstance3D = inst as MeshInstance3D
	if mi == null:
		var found := inst.find_children("*", "MeshInstance3D", true, false)
		mi = found[0] as MeshInstance3D if not found.is_empty() else null
	var out: Array = []
	if mi != null and mi.mesh is ArrayMesh:
		var rel := Transform3D.IDENTITY
		var n: Node = mi
		while n != null and n != inst:
			rel = (n as Node3D).transform * rel
			n = n.get_parent()
		var mesh := (mi.mesh as ArrayMesh).duplicate() as ArrayMesh
		for s in mesh.get_surface_count():
			mesh.surface_set_material(s, Toonify.toon_material(mi.mesh.surface_get_material(s), -1.0, tint_color))
		out = [mesh, rel]
	inst.free()
	_meshes[key] = out
	return out
