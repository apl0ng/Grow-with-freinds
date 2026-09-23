class_name Toonify
extends Node3D
## Toon conversion for Blender-authored models (res://art/models/*.glb). Owner: pipeline agent.
## Workflow + conventions: MODELING.md. Palette/finishes: STYLE.md (this reuses Toon.make, so models match
## the hand-built library exactly).
##
## Every model is imported with THIS script as its root script (tools/blender/build.py writes
## `nodes/root_script` into each .glb.import), so an instanced model converts itself in _ready():
##   [node name="Model" parent="Visual" instance=ExtResource("3_drum")]   # nothing else needed
##   tint = Color(0.35, 0.45, 0.6, 1)      # optional: recolours TINT* materials (graded colour!)
##   outline_width = 0.025                 # optional: ink outline hull (0.025 normal, 0.012 thin)
## From code: `($Visual/Model as Toonify).tint = Toon.grade(seed.color)` (recolours live).
##
## Static helpers work on any subtree (hand-built primitives with material_override are left alone):
##   Toonify.toonify($Visual)                                  # convert every StandardMaterial3D below
##   Toonify.toonify($Visual, -1.0, Toon.grade(seed.color))    # + recolour TINT* materials
##   Toonify.outline($Visual, 0.012)                           # thin ink outline on opaque meshes
##
## Material rules (by the Blender material name; a ".001" suffix is ignored):
##   toon_<x>   -> the library material res://art/materials/toon_<x>.tres itself (shared, never copied),
##                 so art-agent retunes reach every model without re-exporting.
##   TINT*      -> recoloured with `tint`: albedo = tint * (base luminance / TINT_NEUTRAL luminance), so
##                 the neutral grey #d9d9d9 gives exactly the tint and darker greys give darker shades.
##                 Without a tint (alpha 0) the part keeps its neutral grey.
##   FLAT*      -> unshaded sticker colour (eyes, painted signs, screens). glTF "unlit" works too.
##   anything else -> Toon.make(albedo, finish) with the finish picked from the roughness:
##                 >= 0.65 MATTE, <= 0.3 GLOSSY, else SOFT; roughness (capped at 0.9), emission, alpha
##                 and cull mode are kept. `rim` >= 0 overrides the finish's rim amount.
## Converted materials are cached per (source material, tint, rim): all instances share them.

## TINT* parts painted this grey show exactly the tint colour.
const TINT_NEUTRAL := Color("d9d9d9")
const LIB_DIR := "res://art/materials/"
const OUTLINE_NODE := &"ToonOutline"
const MAX_ROUGHNESS := 0.9

## Colour for TINT* materials (alpha 0 = keep the neutral grey). Pass graded colours (Toon.grade(c)).
@export var tint := Color(0, 0, 0, 0):
	set(value):
		tint = value
		if is_node_ready():
			toonify(self, rim, tint)
## Rim override for converted materials (-1 = the library finish's own rim).
@export_range(-1.0, 1.0, 0.01) var rim := -1.0
## Ink outline thickness in metres (0 = none). 0.025 = toon_outline, 0.012 = toon_outline_thin.
@export_range(0.0, 0.1, 0.001) var outline_width := 0.0:
	set(value):
		outline_width = value
		if is_node_ready():
			outline(self, outline_width)

static var _cache: Dictionary = {}          # source Material -> {"tint|rim": Material}
static var _produced: Dictionary = {}       # Material -> true (everything toonify() ever assigned)
static var _hull_cache: Dictionary = {}     # Mesh -> {surface mask: ArrayMesh}
static var _outline_mats: Dictionary = {}   # thickness -> Material


func _ready() -> void:
	toonify(self, rim, tint)
	if outline_width > 0.0:
		outline(self, outline_width)


## Converts the materials of every MeshInstance3D under `node` (and `node` itself) to toon materials by
## setting surface override materials. Idempotent and cheap: call it again with another tint to recolour.
## Skips mesh instances that have a material_override and surfaces someone else overrode by hand.
static func toonify(node: Node, rim_amount: float = -1.0, tint_color: Color = Color(0, 0, 0, 0)) -> void:
	for mi in _mesh_instances(node):
		if mi.material_override != null or mi.mesh == null:
			continue
		for s in mi.mesh.get_surface_count():
			var current := mi.get_surface_override_material(s)
			if current != null and not _produced.has(current):
				continue # a deliberate hand-set override wins
			var src := mi.mesh.surface_get_material(s)
			var toon := toon_material(src, rim_amount, tint_color)
			mi.set_surface_override_material(s, toon if toon != src else null)


## The toon version of one source material (cached, shared: never modify the result).
## Returns `src` itself when it is already a toon/unshaded material or not a BaseMaterial3D.
static func toon_material(src: Material, rim_amount: float = -1.0, tint_color: Color = Color(0, 0, 0, 0)) -> Material:
	if src == null:
		return _remember(Toon.material(Toon.PEBBLE)) # no material in Blender: visible neutral grey
	var base := src as BaseMaterial3D
	if base == null:
		return src # ShaderMaterial etc.: the author knows what they are doing
	var nm := material_name(src)
	var tinted := is_tint(src) and tint_color.a > 0.0
	if not tinted:
		if nm.begins_with("toon_"):
			var lib := _library(nm)
			if lib != null:
				return _remember(lib)
		if base.diffuse_mode == BaseMaterial3D.DIFFUSE_TOON:
			return src # already toon (library material assigned in a scene, or converted before)
	var key := "%s|%.3f" % [tint_color.to_html(true) if tinted else "-", rim_amount]
	var per_src: Dictionary = _cache.get(src, {})
	if per_src.has(key):
		return per_src[key]
	var out := _convert(base, nm, rim_amount, tint_color if tinted else Color(0, 0, 0, 0))
	out.resource_name = nm + ("_tinted" if tinted else "_toon")
	per_src[key] = out
	_cache[src] = per_src
	return _remember(out)


## Material name without Blender's ".001" duplicate suffix.
static func material_name(m: Material) -> String:
	if m == null:
		return ""
	var nm := m.resource_name
	var dot := nm.rfind(".")
	if dot > 0 and nm.substr(dot + 1).is_valid_int():
		nm = nm.substr(0, dot)
	return nm


static func is_tint(m: Material) -> bool:
	return material_name(m).begins_with("TINT")


## Adds (or updates / removes with thickness <= 0) an ink outline hull under every opaque, shaded mesh
## below `node`. The hull is the same mesh with welded, averaged normals (cached per mesh), so it does not
## tear on hard edges the way `material_overlay = toon_outline` does on imported meshes. Call after
## toonify() (transparent and unshaded surfaces are skipped based on the active material).
static func outline(node: Node, thickness: float = 0.025) -> void:
	for mi in _mesh_instances(node):
		var existing := mi.get_node_or_null(NodePath(OUTLINE_NODE)) as MeshInstance3D
		if thickness <= 0.0 or mi.mesh == null:
			if existing:
				existing.queue_free()
			continue
		var hull := _hull(mi)
		if hull == null:
			if existing:
				existing.queue_free()
			continue
		if existing == null:
			existing = MeshInstance3D.new()
			existing.name = OUTLINE_NODE
			existing.set_meta(&"toonify_outline", true)
			existing.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
			existing.gi_mode = GeometryInstance3D.GI_MODE_DISABLED
			mi.add_child(existing, false, Node.INTERNAL_MODE_BACK)
		existing.layers = mi.layers
		existing.mesh = hull
		existing.material_override = _outline_material(thickness)


## Drops every cached conversion (tests; after regenerating the material library in a running editor).
static func clear_cache() -> void:
	_cache.clear()
	_produced.clear()
	_hull_cache.clear()
	_outline_mats.clear()


# --------------------------------------------------------------------------------------------- internals
static func _mesh_instances(node: Node) -> Array[MeshInstance3D]:
	var out: Array[MeshInstance3D] = []
	if node == null:
		return out
	if node is MeshInstance3D and not node.has_meta(&"toonify_outline"):
		out.append(node)
	for n in node.find_children("*", "MeshInstance3D", true, false):
		if not n.has_meta(&"toonify_outline"):
			out.append(n as MeshInstance3D)
	return out


static func _remember(m: Material) -> Material:
	_produced[m] = true
	return m


static func _library(nm: String) -> Material:
	var path := LIB_DIR + nm + ".tres"
	if not ResourceLoader.exists(path):
		push_warning("Toonify: material '%s' has no library file %s; converting it instead" % [nm, path])
		return null
	return load(path) as Material


static func _convert(src: BaseMaterial3D, nm: String, rim_amount: float, tint_color: Color) -> StandardMaterial3D:
	var color := src.albedo_color
	if tint_color.a > 0.0:
		var k := color.get_luminance() / TINT_NEUTRAL.get_luminance()
		color = Color(clampf(tint_color.r * k, 0, 1), clampf(tint_color.g * k, 0, 1), clampf(tint_color.b * k, 0, 1), color.a)
	var flat := nm.begins_with("FLAT") or src.shading_mode == BaseMaterial3D.SHADING_MODE_UNSHADED
	var finish := Toon.Finish.FLAT
	if not flat:
		if src.roughness >= 0.65:
			finish = Toon.Finish.MATTE
		elif src.roughness <= 0.3:
			finish = Toon.Finish.GLOSSY
		else:
			finish = Toon.Finish.SOFT
	var m := Toon.make(color, finish)
	if not flat:
		m.roughness = minf(src.roughness, MAX_ROUGHNESS)
		if rim_amount >= 0.0:
			m.rim = rim_amount
		if src.emission_enabled:
			m.emission_enabled = true
			m.emission = src.emission
			m.emission_energy_multiplier = src.emission_energy_multiplier
			if tint_color.a > 0.0:
				m.emission = color
	if src.transparency != BaseMaterial3D.TRANSPARENCY_DISABLED or color.a < 1.0:
		m.transparency = src.transparency if src.transparency != BaseMaterial3D.TRANSPARENCY_DISABLED else BaseMaterial3D.TRANSPARENCY_ALPHA
		m.albedo_color.a = color.a
	m.cull_mode = src.cull_mode
	return m


static func _outline_material(thickness: float) -> Material:
	var key := snappedf(thickness, 0.0001)
	if _outline_mats.has(key):
		return _outline_mats[key]
	var m: Material
	if is_equal_approx(key, 0.025):
		m = Toon.outline(false)
	elif is_equal_approx(key, 0.012):
		m = Toon.outline(true)
	else:
		var base := Toon.outline(false)
		m = base.duplicate() if base else StandardMaterial3D.new()
		if m is BaseMaterial3D:
			(m as BaseMaterial3D).grow = true
			(m as BaseMaterial3D).grow_amount = key
	_outline_mats[key] = m
	return m


## Opaque, shaded surfaces of `mi` welded into one surface with smooth averaged normals (cached per mesh
## + surface selection). Returns null when no surface qualifies.
static func _hull(mi: MeshInstance3D) -> ArrayMesh:
	var mesh := mi.mesh
	var mask := 0
	for s in mesh.get_surface_count():
		var m := mi.get_active_material(s) as BaseMaterial3D
		if m == null or (m.transparency == BaseMaterial3D.TRANSPARENCY_DISABLED
				and m.shading_mode != BaseMaterial3D.SHADING_MODE_UNSHADED
				and not material_name(m).begins_with("FLAT")):
			mask |= 1 << s
	if mask == 0:
		return null
	var per_mesh: Dictionary = _hull_cache.get(mesh, {})
	if per_mesh.has(mask):
		return per_mesh[mask]
	var index_of := {}                     # Vector3i (0.1 mm grid) -> welded vertex index
	var positions := PackedVector3Array()
	var normals: Array[Vector3] = []
	var tris := PackedInt32Array()
	for s in mesh.get_surface_count():
		if (mask & (1 << s)) == 0 or mesh.surface_get_primitive_type(s) != Mesh.PRIMITIVE_TRIANGLES:
			continue
		var arr := mesh.surface_get_arrays(s)
		var verts: PackedVector3Array = arr[Mesh.ARRAY_VERTEX]
		var idx: PackedInt32Array = arr[Mesh.ARRAY_INDEX]
		if idx.is_empty():
			idx.resize(verts.size())
			for i in verts.size():
				idx[i] = i
		var remap := PackedInt32Array()
		remap.resize(verts.size())
		for i in verts.size():
			var v := verts[i]
			var k := Vector3i(roundi(v.x * 10000.0), roundi(v.y * 10000.0), roundi(v.z * 10000.0))
			var w: int = index_of.get(k, -1)
			if w < 0:
				w = positions.size()
				index_of[k] = w
				positions.append(v)
				normals.append(Vector3.ZERO)
			remap[i] = w
		for t in range(0, idx.size() - 2, 3):
			var a := remap[idx[t]]
			var b := remap[idx[t + 1]]
			var c := remap[idx[t + 2]]
			if a == b or b == c or a == c:
				continue
			# Godot winds front faces clockwise: this cross product points outwards (area weighted).
			var n := (positions[c] - positions[a]).cross(positions[b] - positions[a])
			normals[a] += n
			normals[b] += n
			normals[c] += n
			tris.append(a)
			tris.append(b)
			tris.append(c)
	if tris.is_empty():
		return null
	var nrm := PackedVector3Array()
	nrm.resize(normals.size())
	for i in normals.size():
		nrm[i] = normals[i].normalized() if normals[i].length_squared() > 0.0 else Vector3.UP
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = positions
	arrays[Mesh.ARRAY_NORMAL] = nrm
	arrays[Mesh.ARRAY_INDEX] = tris
	var hull := ArrayMesh.new()
	hull.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	hull.resource_name = mesh.resource_name + "_outline"
	per_mesh[mask] = hull
	_hull_cache[mesh] = per_mesh
	return hull
