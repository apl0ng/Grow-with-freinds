extends SceneTree
## Room architecture (environment modeler, architecture pass): the Blender-built shell of scenes/world/room.tscn.
## Headless, exit code 0 = pass:
##   godot --headless --path . -s res://tools/tests/models_arch_test.gd [-- --room=res://path/to/variant.tscn]
## 1. Models (tools/blender/models/{wall_panel,floor_slab,ceiling_panel,ceiling_beam,hole_rim}.py): every GLB loads
##    as a Toonify root with ONE mesh (segment_run.gd tiles its first MeshInstance3D), within its triangle budget,
##    at its module size and contact point (walls 5 m wide + a mortar tuck, 6 m tall on the floor; slabs 5 x 5 with
##    the top on the origin; deck panels 5 x 5 hanging 0.1 m of ribs below the origin; beams 5 m x 0.4 m).
## 2. Hook-up in the room: the Floor / Walls / Ceiling bodies keep their box colliders; every visual under them is
##    a segment_run MultiMesh (plus Ceiling/HoleVoid), shadowless; the copies tile the room EXACTLY: 4 + 3 + 4 + 3
##    wall panels whose widths sum to each wall's length (no gap, no overlap), their faces on the colliders' inner
##    faces looking into the room; 4 x 3 floor slabs on the floor collider's top; 4 x 3 deck panels whose crests sit
##    on the ceiling collider's face; 3 beam lines of 3 segments on the panel seams; the hole rim on the void box.
## 3. M14 (level agent): the same for the grow hall (3 + 3 + 3 + 3 panels, 3 x 3 slabs and deck panels, beam lines at
##    x 15 and 20) and the loading dock (3 + 3 + 2 + 2, 3 x 2, the main room's beam lines x -5 and 0 run on over it);
##    the south and east wall colliders are cut round the dock passage and the two hall doorways; the walk-through
##    panels (tools/blender/models/wall_opening.py) stand back to back on every doorway; the roller door stands in
##    wall_panel_door_c on the dock's outer wall; every barred window sits in a window panel.

const MODELS := "res://art/models/"
const ROOM := "res://scenes/world/room.tscn"
const SEGMENT_RUN := "res://scenes/world/props/segment_run.gd"
const TOONIFY := "res://scripts/art/toonify.gd"
const PANEL := 5.0
const ROOM_SIZE := Vector3(20.0, 6.0, 15.0)
const DECK_RIB := 0.1                          # deck valleys (the panel origin) sit this far above the crests
const TUCK := 0.038                            # wall mortar plane runs this far past each panel end (hidden)
## model -> [triangle budget, kind]
const BUDGETS := {
	"wall_panel": [4500, "wall"], "wall_panel_b": [4500, "wall"], "wall_panel_window": [4500, "wall"],
	"wall_panel_door": [4500, "wall"], "wall_panel_door_b": [4500, "wall"],
	# M14 (tools/blender/models/wall_opening.py): walk-through doorways, the dock passage, the dock's roller-door panel
	"wall_panel_doorway": [4500, "wall"], "wall_panel_doorway_b": [4500, "wall"], "wall_panel_pass": [4500, "wall"],
	"wall_panel_pass_b": [4500, "wall"], "wall_panel_door_c": [4500, "wall"],
	"floor_slab": [1000, "floor"], "floor_slab_b": [1000, "floor"], "floor_slab_drain": [1000, "floor"],
	"ceiling_panel": [2600, "deck"], "ceiling_panel_b": [2600, "deck"], "ceiling_panel_hole": [2600, "deck"],
	"ceiling_beam": [1500, "beam"], "hole_rim": [2600, "rim"],
}
## Upper bound for the whole shell (all copies), so the architecture stays cheap next to the props.
## (M14: 110000 for the main room alone; with the grow hall and the loading dock the shell is 36 wall panels, 27 slabs and 27 deck panels.)
const SHELL_TRIS_MAX := 200000
## M14: the annexes (Room-local). Wall lines: where each annex's panels stand, by the side they are on; the ranges
## their panels tile along the wall (the hall's north / south runs and the dock's side runs end outside, behind the
## wall they meet: three whole 5 m modules cover a 12 m hall, two cover a 7.5 m dock).
const AREA_NAMES: PackedStringArray = ["main", "hall", "dock"]
const ANNEX_LINES := {
	"hall": {"north": -7.5, "south": 7.5, "west": 10.6, "east": 22.0},
	"dock": {"north": 8.1, "south": 15.6, "west": -10.0, "east": 5.0},
}
const ANNEX_SPANS := {
	"hall": {"north": Vector2(10.0, 25.0), "south": Vector2(10.0, 25.0), "west": Vector2(-7.5, 7.5), "east": Vector2(-7.5, 7.5)},
	"dock": {"north": Vector2(-10.0, 5.0), "south": Vector2(-10.0, 5.0), "west": Vector2(8.1, 18.1), "east": Vector2(8.1, 18.1)},
}
## Opening centre in the panel's own coordinates (x) for the walk-through variants.
const OPENING_X := {"wall_panel_doorway": -1.25, "wall_panel_doorway_b": 1.25, "wall_panel_pass": -2.5, "wall_panel_pass_b": 2.5}

var _checks := 0
var _fails: PackedStringArray = []
var _tris := {}


func _initialize() -> void:
	_run.call_deferred()


func _check(ok: bool, what: String) -> bool:
	_checks += 1
	if not ok:
		_fails.append(what)
		print("  FAIL: ", what)
	return ok


func _near(a: float, b: float, tol: float = 0.005) -> bool:
	return absf(a - b) <= tol


func _run() -> void:
	var t0 := Time.get_ticks_msec()
	for m: String in BUDGETS:
		_model(m)
	await _room()
	print("models_arch_test: %d checks, %d failures (%d ms)" % [_checks, _fails.size(), Time.get_ticks_msec() - t0])
	quit(1 if _fails.size() > 0 else 0)


# ------------------------------------------------------------------------------------------------- models
func _mesh_of(n: Node) -> MeshInstance3D:
	if n is MeshInstance3D:
		return n
	var found := n.find_children("*", "MeshInstance3D", true, false)
	return found[0] as MeshInstance3D if not found.is_empty() else null


func _triangles(mesh: Mesh) -> int:
	var t := 0
	for s in mesh.get_surface_count():
		var arrays := mesh.surface_get_arrays(s)
		var idx: PackedInt32Array = arrays[Mesh.ARRAY_INDEX]
		t += idx.size() / 3 if idx.size() > 0 else (arrays[Mesh.ARRAY_VERTEX] as PackedVector3Array).size() / 3
	return t


func _model(m: String) -> void:
	var ps := load(MODELS + m + ".glb") as PackedScene
	if not _check(ps != null and ps.can_instantiate(), m + ": loads"):
		return
	var inst := ps.instantiate() as Node3D
	_check(inst is Toonify and (inst.get_script() as Script).resource_path == TOONIFY, m + ": Toonify root")
	var meshes := inst.find_children("*", "MeshInstance3D", true, false)
	_check(meshes.size() == 1, m + ": exactly one mesh (segment_run tiles the first one), got %d" % meshes.size())
	var mi := _mesh_of(inst)
	if mi == null or mi.mesh == null:
		_check(false, m + ": has a mesh")
		inst.free()
		return
	var tris := _triangles(mi.mesh)
	_tris[m] = tris
	var budget: int = BUDGETS[m][0]
	_check(tris <= budget, m + ": %d tris <= budget %d" % [tris, budget])
	_check(mi.mesh.get_surface_count() <= 10, m + ": <= 10 materials (draw calls per run), got %d" % mi.mesh.get_surface_count())
	var b: AABB = mi.transform * mi.mesh.get_aabb()
	match String(BUDGETS[m][1]):
		"wall":
			_check(_near(b.size.x, PANEL + 2.0 * TUCK, 0.004) and _near(b.get_center().x, 0.0, 0.002),
					m + ": 5 m module wide (+%.3f mortar tuck each end), centred (%s)" % [TUCK, b])
			_check(_near(b.position.y, 0.0, 0.002) and _near(b.end.y, ROOM_SIZE.y, 0.002),
					m + ": stands on the floor, reaches the 6 m ceiling (y %.3f..%.3f)" % [b.position.y, b.end.y])
			_check(b.position.z >= -0.32 and b.end.z <= 0.4,
					m + ": sits on the wall line: <= 0.3 m behind it, details <= 0.4 m in front (z %.3f..%.3f)"
					% [b.position.z, b.end.z])
		"floor":
			_check(_near(b.size.x, PANEL) and _near(b.size.z, PANEL) and _near(b.get_center().x, 0.0) and _near(b.get_center().z, 0.0),
					m + ": 5 x 5 m slab centred on its origin (%s)" % b)
			_check(b.end.y > 0.0 and b.end.y <= 0.008 and b.position.y >= -0.2,
					m + ": top on the origin (decals <= 8 mm proud: players' feet stay on it) (y %.3f..%.3f)"
					% [b.position.y, b.end.y])
		"deck":
			_check(_near(b.size.x, PANEL) and _near(b.size.z, PANEL) and _near(b.get_center().x, 0.0) and _near(b.get_center().z, 0.0),
					m + ": 5 x 5 m deck panel centred on its origin (%s)" % b)
			_check(_near(b.end.y, 0.0, 0.002) and b.position.y <= -DECK_RIB + 0.001 and b.position.y > -0.25,
					m + ": valleys on the origin, crests %.1f m below, nothing hangs far (y %.3f..%.3f)"
					% [DECK_RIB, b.position.y, b.end.y])
		"beam":
			_check(_near(b.size.x, PANEL) and _near(b.get_center().x, 0.0) and _near(b.end.y, 0.0, 0.002)
					and b.position.y <= -0.4 + 0.001 and b.size.z < 0.3,
					m + ": 5 m segment along X, top flange on the origin, >= 0.4 m deep, < 0.3 m wide (%s)" % b)
		"rim":
			_check(b.end.y <= 0.006 and b.position.y > -2.2, m + ": hangs from its origin (y %.3f..%.3f)" % [b.position.y, b.end.y])
	inst.free()


# --------------------------------------------------------------------------------------------------- room
class Copy:
	var model := ""
	var node := ""
	var xf := Transform3D.IDENTITY


## Copies of the architecture models tiled by the body's segment_run children (other runs under the same body,
## e.g. the ceiling pipes and cable tray, are props and are skipped).
func _copies(body: Node3D, room: Node3D) -> Array[Copy]:
	var out: Array[Copy] = []
	for c in body.get_children():
		if not (c is MultiMeshInstance3D):
			continue
		var scr := c.get_script() as Script
		var model := (c.get(&"model") as PackedScene) if scr != null and scr.resource_path == SEGMENT_RUN else null
		var model_name := model.resource_path.get_file().get_basename() if model != null else ""
		if not BUDGETS.has(model_name):
			continue
		var mm := c as MultiMeshInstance3D
		_check(mm.cast_shadow == GeometryInstance3D.SHADOW_CASTING_SETTING_OFF, "%s/%s casts no shadow" % [body.name, c.name])
		_check((c.get(&"tint") as Color).a == 0.0, "%s/%s: no tint (architecture has no TINT parts)" % [body.name, c.name])
		_check(mm.multimesh != null and mm.multimesh.instance_count == int(c.get(&"count")),
				"%s/%s built its MultiMesh (%d copies)" % [body.name, c.name, int(c.get(&"count"))])
		var to_room: Transform3D = room.global_transform.affine_inverse() * mm.global_transform
		for i in int(c.get(&"count")):
			var cp := Copy.new()
			cp.model = model_name
			cp.node = "%s/%s#%d" % [body.name, c.name, i]
			cp.xf = to_room * (c.call(&"copy_transform", i) as Transform3D)
			out.append(cp)
	return out


func _tiles(intervals: Array, lo: float, hi: float, what: String) -> void:
	intervals.sort_custom(func(a: Vector2, b: Vector2) -> bool: return a.x < b.x)
	var sum := 0.0
	var ok := not intervals.is_empty() and _near((intervals[0] as Vector2).x, lo, 0.001) \
			and _near((intervals[-1] as Vector2).y, hi, 0.001)
	for i in intervals.size():
		var iv: Vector2 = intervals[i]
		sum += iv.y - iv.x
		if i > 0:
			ok = ok and _near((intervals[i - 1] as Vector2).y, iv.x, 0.001)
	_check(ok and _near(sum, hi - lo, 0.001), "%s: %d panels tile %.1f..%.1f exactly (widths sum %.3f == %.3f, no gap / overlap) %s"
			% [what, intervals.size(), lo, hi, sum, hi - lo, intervals])


func _shape_face(body: Node3D, shape_name: String, room: Node3D, axis: int, sign_to_room: float) -> float:
	## The inner face (towards the room) of one of the body's box colliders, along `axis`.
	var cs := body.get_node_or_null(NodePath(shape_name)) as CollisionShape3D
	if cs == null or not (cs.shape is BoxShape3D):
		return NAN
	var t: Transform3D = room.global_transform.affine_inverse() * cs.global_transform
	return t.origin[axis] + sign_to_room * (cs.shape as BoxShape3D).size[axis] * 0.5


func _room() -> void:
	var room_path := ROOM
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--room="):
			room_path = arg.trim_prefix("--room=")  # check a variant of the room (e.g. while iterating on it)
	var ps := load(room_path) as PackedScene
	if not _check(ps != null, "room.tscn loads"):
		return
	var room := ps.instantiate() as Node3D
	root.add_child(room)
	await process_frame
	var floor_body := room.get_node_or_null(^"Floor") as StaticBody3D
	var walls := room.get_node_or_null(^"Walls") as StaticBody3D
	var ceiling := room.get_node_or_null(^"Ceiling") as StaticBody3D
	if not _check(floor_body != null and walls != null and ceiling != null, "Floor / Walls / Ceiling bodies exist"):
		room.queue_free()
		return
	# Colliders untouched: layer 1, the box shapes of the original shell.
	for body: StaticBody3D in [floor_body, walls, ceiling]:
		_check(body.collision_layer == 1 and body.collision_mask == 0, "%s: collision layer 1 / mask 0" % body.name)
		for c in body.get_children():
			if c is MeshInstance3D:
				_check(String(c.name) == "HoleVoid" and body == ceiling,
						"%s/%s: no primitive shell mesh left (only Ceiling/HoleVoid)" % [body.name, c.name])
	# M14: the south and east walls are 0.6 m thick now and cut in pieces round the dock passage and the hall doorways
	# (SouthShape / EastShape keep their names for the longest piece); the annexes add their own boxes.
	var shapes := {"Floor/Shape": Vector3(22, 1, 17), "Walls/NorthShape": Vector3(22, 8, 1), "Walls/SouthShape": Vector3(13.9, 8, 0.6),
			"Walls/EastShape": Vector3(0.6, 8, 6.25), "Walls/WestShape": Vector3(1, 8, 17), "Ceiling/Shape": Vector3(22, 1, 17),
			"Walls/SouthShapeWest": Vector3(3.9, 8, 0.6), "Walls/SouthHead": Vector3(4.2, 3.25, 0.6),
			"Walls/EastShapeMid": Vector3(0.6, 8, 5.5), "Walls/EastShapeSouth": Vector3(0.6, 8, 1.25),
			"Walls/EastHeadPen": Vector3(0.6, 4.5, 2), "Walls/EastHeadSouth": Vector3(0.6, 4.5, 2),
			"Walls/HallNorthShape": Vector3(12, 8, 1), "Walls/HallSouthShape": Vector3(12, 8, 1), "Walls/HallEastShape": Vector3(1, 8, 17),
			"Walls/DockWestShape": Vector3(1, 8, 8.5), "Walls/DockEastShape": Vector3(1, 8, 8.5), "Walls/DockSouthShape": Vector3(17, 8, 1),
			"Floor/HallShape": Vector3(13, 1, 17), "Floor/DockShape": Vector3(17, 1, 9.1),
			"Ceiling/HallShape": Vector3(13, 1, 17), "Ceiling/DockShape": Vector3(17, 1, 9.1)}
	for p: String in shapes:
		var cs := room.get_node_or_null(NodePath(p)) as CollisionShape3D
		_check(cs != null and cs.shape is BoxShape3D and (cs.shape as BoxShape3D).size.is_equal_approx(shapes[p]),
				"%s is still the %s box collider" % [p, shapes[p]])
	var total_tris := 0
	var r := room as Room

	# --- walls: main room 4 + 3 + 4 + 3 on the colliders' inner faces; M14: the hall 3 + 3 + 3 + 3 and the dock
	# 3 + 3 + 2 + 2 on their own wall lines; every panel looks into the area it belongs to
	var wall_copies := _copies(walls, room)
	var sides := {}
	for area in AREA_NAMES:
		sides[area] = {"north": [], "south": [], "east": [], "west": []}
	var inner := {
		"north": _shape_face(walls, "NorthShape", room, 2, 1.0), "south": _shape_face(walls, "SouthShape", room, 2, -1.0),
		"west": _shape_face(walls, "WestShape", room, 0, 1.0), "east": _shape_face(walls, "EastShape", room, 0, -1.0),
	}
	for cp: Copy in wall_copies:
		total_tris += int(_tris.get(cp.model, 0))
		var f := cp.xf.basis.z.normalized()
		var o := cp.xf.origin
		var side := ""
		if f.z > 0.99:
			side = "north"
		elif f.z < -0.99:
			side = "south"
		elif f.x > 0.99:
			side = "west"
		elif f.x < -0.99:
			side = "east"
		if not _check(side != "" and absf(f.y) < 0.001, "%s (%s) faces straight into the room (front %s)" % [cp.node, cp.model, f]):
			continue
		_check(cp.xf.basis.y.is_equal_approx(Vector3.UP) and _near(o.y, 0.0, 0.001), "%s stands upright on the floor" % cp.node)
		# The area a panel belongs to is the one its face looks into (1 m in front of the wall line).
		var area_index := r.get_area_index(room.global_transform * (o + f * 1.0 + Vector3.UP))
		if area_index < 0: # a module whose centre lies past the end of its wall (see ANNEX_SPANS): ask at the near end
			var along := Vector3(1, 0, 0) if side in ["north", "south"] else Vector3(0, 0, 1)
			for end: float in [-2.4, 2.4]:
				area_index = maxi(area_index, r.get_area_index(room.global_transform * (o + along * end + f * 1.0 + Vector3.UP)))
		if not _check(area_index >= 0, "%s looks into a play area" % cp.node):
			continue
		var area: String = AREA_NAMES[area_index]
		var line: float = o.z if side in ["north", "south"] else o.x
		var want: float = inner[side] if area == "main" else float(ANNEX_LINES[area][side])
		_check(_near(line, want, 0.001), "%s sits on the %s wall line of %s (%.3f == %.3f)" % [cp.node, side, area, line, want])
		var c: float = o.x if side in ["north", "south"] else o.z
		(sides[area][side] as Array).append(Vector2(c - PANEL * 0.5, c + PANEL * 0.5))
	var expect := {"main": {"north": 4, "south": 4, "east": 3, "west": 3}, "hall": {"north": 3, "south": 3, "east": 3, "west": 3},
			"dock": {"north": 3, "south": 3, "east": 2, "west": 2}}
	for area: String in sides:
		for side: String in sides[area]:
			var ivs: Array = sides[area][side]
			_check(ivs.size() == expect[area][side], "%s %s wall: %d panels (expected %d)" % [area, side, ivs.size(), expect[area][side]])
			if area == "main":
				var half: float = (ROOM_SIZE.x if side in ["north", "south"] else ROOM_SIZE.z) * 0.5
				_tiles(ivs, -half, half, "main " + side + " wall")
			else:
				var span: Vector2 = ANNEX_SPANS[area][side]
				_tiles(ivs, span.x, span.y, area + " " + side + " wall")
	# Where the variants go (they carry the openings for the door / window props and the doorways).
	var by_model := {}
	for cp: Copy in wall_copies:
		by_model[cp.model] = (by_model.get(cp.model, []) as Array) + [cp]
	# M14: the roller door stands on the dock's outer wall, in the middle of its own panel.
	var door := room.get_node_or_null(^"Decor/RollerDoor") as Node3D
	if _check(door != null and by_model.has("wall_panel_door_c") and (by_model["wall_panel_door_c"] as Array).size() == 1,
			"roller door + its panel (wall_panel_door_c) exist"):
		var d: Copy = by_model["wall_panel_door_c"][0]
		var dl: Vector3 = d.xf.affine_inverse() * door.position
		_check(_near(dl.x, 0.0, 0.01) and _near(dl.y, 0.0, 0.01) and _near(dl.z, 0.0, 0.01),
				"RollerDoor sits in the panel's opening (local %s, expected the panel origin)" % dl)
		_check(door.basis.z.normalized().dot(d.xf.basis.z.normalized()) > 0.999, "RollerDoor faces the same way as its wall")
		_check(r.get_area_index(room.global_transform * (door.position + door.basis.z.normalized() + Vector3.UP)) == 2,
				"RollerDoor closes the loading dock")
	# Every barred window prop sits in a window panel's opening, one each.
	var windows: Array[Node3D] = []
	for path: NodePath in [^"Decor/BarredWindow", ^"Hall/Window", ^"Dock/WindowWest", ^"Dock/WindowEast"]:
		var w := room.get_node_or_null(path) as Node3D
		if _check(w != null, "%s exists" % path):
			windows.append(w)
	var window_panels: Array = by_model.get("wall_panel_window", [])
	_check(window_panels.size() == windows.size(), "%d window panels for %d barred windows" % [window_panels.size(), windows.size()])
	for w in windows:
		var w_pos: Vector3 = room.global_transform.affine_inverse() * w.global_position
		var fits := 0
		for cp: Copy in window_panels:
			var wl: Vector3 = cp.xf.affine_inverse() * w_pos
			if _near(wl.x, -0.8, 0.01) and _near(wl.y, 4.1, 0.01) and _near(wl.z, 0.0, 0.01):
				fits += 1
		_check(fits == 1, "%s sits in a window panel's opening (local (-0.8, 4.1, 0))" % room.get_path_to(w))
	# M14: the walk-through panels stand back to back round each doorway: one on either side of the wall, their
	# openings on the doorway's centre, half the wall's thickness from it.
	var doorways := r.get_doorways()
	var open_models := {"pen_door": ["wall_panel_doorway", "wall_panel_doorway_b"], "corridor_door": ["wall_panel_doorway", "wall_panel_doorway_b"],
			"dock_passage": ["wall_panel_pass", "wall_panel_pass_b"]}
	var used := 0
	for dw in doorways:
		var centre: Vector3 = room.global_transform.affine_inverse() * (dw["center"] as Vector3)
		var axis: Vector3 = dw["axis"]
		var fronts: Array = []
		var models_seen := {}
		for m: String in open_models.get(String(dw["name"]), []):
			for cp: Copy in by_model.get(m, []):
				var opening: Vector3 = cp.xf * Vector3(float(OPENING_X[m]), 0.0, 0.0)
				var delta := opening - centre
				if absf(delta.dot(axis.cross(Vector3.UP))) < 0.01 and _near(absf(delta.dot(axis)), Room.SHARED_WALL * 0.5, 0.01):
					fronts.append(cp.xf.basis.z.normalized().dot(axis))
					models_seen[m] = int(models_seen.get(m, 0)) + 1
					used += 1
		fronts.sort()
		var want_each := 1 if String(dw["name"]) != "dock_passage" else 2
		var ok_pair := models_seen.size() == 2
		for m: String in models_seen:
			ok_pair = ok_pair and int(models_seen[m]) == want_each
		_check(ok_pair and fronts.size() == 2 * want_each and float(fronts[0]) < -0.99 and float(fronts[-1]) > 0.99,
				"doorway %s: its panels stand back to back on both faces of the wall (%s)" % [dw["name"], models_seen])
	var open_copies := 0
	for m: String in OPENING_X:
		open_copies += (by_model.get(m, []) as Array).size()
	_check(used == open_copies and open_copies == 8, "every walk-through panel belongs to a doorway (%d of %d)" % [used, open_copies])
	if _check(by_model.has("wall_panel_window"), "the main room's window panel exists"):
		var window := room.get_node_or_null(^"Decor/BarredWindow") as Node3D
		_check(window != null and r.get_area_index(window.global_position + window.global_basis.z.normalized()) == 0,
				"Decor/BarredWindow is still the main room's west window")

	# --- floor: 4 x 3 slabs in the main room, 3 x 3 in the hall, 3 x 2 on the dock, tops on the colliders' top face
	var floor_top := _shape_face(floor_body, "Shape", room, 1, 1.0)
	var cells := {}
	var floor_copies := _copies(floor_body, room)
	for cp: Copy in floor_copies:
		total_tris += int(_tris.get(cp.model, 0))
		_check(cp.xf.basis.y.is_equal_approx(Vector3.UP) and _near(cp.xf.origin.y, floor_top, 0.001),
				"%s lies flat on the floor collider's top (y %.3f)" % [cp.node, cp.xf.origin.y])
		var k := Vector2i(roundi(cp.xf.origin.x * 2.0), roundi(cp.xf.origin.z * 2.0))
		cells[k] = int(cells.get(k, 0)) + 1
	_grid(cells, "floor slabs")
	for shape_name in ["HallShape", "DockShape"]:
		_check(_near(_shape_face(floor_body, shape_name, room, 1, 1.0), floor_top, 0.001), "Floor/%s: its top is the floor (y %.3f)" % [shape_name, floor_top])

	# --- ceiling: deck panels on the same cells (crests on the collider face), beam lines on the seams, the hole rim
	var ceil_face := _shape_face(ceiling, "Shape", room, 1, -1.0)
	for shape_name in ["HallShape", "DockShape"]:
		_check(_near(_shape_face(ceiling, shape_name, room, 1, -1.0), ceil_face, 0.001), "Ceiling/%s: its face is the ceiling (y %.3f)" % [shape_name, ceil_face])
	cells = {}
	var beams := {}
	var rim: Copy = null
	for cp: Copy in _copies(ceiling, room):
		total_tris += int(_tris.get(cp.model, 0))
		var o := cp.xf.origin
		match cp.model:
			"ceiling_beam":
				var along := cp.xf.basis.x.normalized()
				_check(absf(along.z) > 0.999 and _near(o.y, ceil_face, 0.001) and _near(o.x, roundf(o.x / PANEL) * PANEL, 0.001),
						"%s runs along Z on a panel seam (x %.2f), top flange on the ceiling face (y %.3f)" % [cp.node, o.x, o.y])
				beams[roundi(o.x)] = (beams.get(roundi(o.x), []) as Array) + [Vector2(o.z - PANEL * 0.5, o.z + PANEL * 0.5)]
			"hole_rim":
				rim = cp
			_:
				_check(cp.xf.basis.y.is_equal_approx(Vector3.UP) and _near(o.y - DECK_RIB, ceil_face, 0.001),
						"%s: deck crests on the ceiling collider's face (%.3f == %.3f)" % [cp.node, o.y - DECK_RIB, ceil_face])
				var k := Vector2i(roundi(o.x * 2.0), roundi(o.z * 2.0))
				cells[k] = int(cells.get(k, 0)) + 1
	_grid(cells, "ceiling panels")
	# Beam lines: x -5 and 0 run on over the dock (to z 17.5, past its outer wall), 5 over the main room only, 15 and
	# 20 over the hall.
	var beam_spans := {-5: Vector2(-7.5, 17.5), 0: Vector2(-7.5, 17.5), 5: Vector2(-7.5, 7.5), 15: Vector2(-7.5, 7.5), 20: Vector2(-7.5, 7.5)}
	var beam_keys := beams.keys()
	beam_keys.sort()
	_check(beam_keys == [-5, 0, 5, 15, 20], "beam lines at x = -5, 0, 5 (main, the first two on over the dock) and 15, 20 (hall) (%s)" % [beam_keys])
	for x: int in beams:
		if beam_spans.has(x):
			_tiles(beams[x], (beam_spans[x] as Vector2).x, (beam_spans[x] as Vector2).y, "beam line x=%d" % x)
	# The hole: rim centred on the void box, the void box above the deck, its footprint round the rim.
	var void_box := ceiling.get_node_or_null(^"HoleVoid") as MeshInstance3D
	if _check(rim != null and void_box != null and void_box.mesh is BoxMesh, "hole rim + HoleVoid exist"):
		var vb: AABB = void_box.transform * void_box.mesh.get_aabb()
		_check(_near(rim.xf.origin.x, void_box.position.x, 0.001) and _near(rim.xf.origin.z, void_box.position.z, 0.001)
				and _near(rim.xf.origin.y - DECK_RIB, ceil_face, 0.001),
				"hole rim hangs on the void box's x/z, at the deck (%s)" % rim.xf.origin)
		_check(vb.position.y >= ceil_face + DECK_RIB,
				"HoleVoid's bottom (%.2f) is above the deck valleys (%.2f): no black edge below the deck"
				% [vb.position.y, ceil_face + DECK_RIB])
		var rp := load(MODELS + "hole_rim.glb") as PackedScene
		var ri := rp.instantiate() as Node3D
		var rm := _mesh_of(ri)
		var rb: AABB = rim.xf * (rm.transform * rm.mesh.get_aabb())
		ri.free()
		_check(rb.position.x >= vb.position.x - 0.35 and rb.end.x <= vb.end.x + 0.35 and rb.position.z >= vb.position.z - 0.35
				and rb.end.z <= vb.end.z + 0.35, "the torn rim stays round the void box's footprint (rim %s, void %s)" % [rb, vb])
		var hd := room.get_node_or_null(^"Decor/HoleDust") as Node3D
		var hl := room.get_node_or_null(^"Lights/HoleDustLight") as Node3D
		_check(hd != null and hl != null and _near(hd.position.x, rim.xf.origin.x, 0.01)
				and _near(hl.position.z, rim.xf.origin.z, 0.01),
				"the hole's dust and light still hang over it")
	print("   info: shell = %d wall panels + %d floor slabs + %d deck panels + beams + rim, %d triangles"
			% [wall_copies.size(), floor_copies.size(), cells.size(), total_tris])
	_check(total_tris > 0 and total_tris <= SHELL_TRIS_MAX, "whole shell %d tris <= %d" % [total_tris, SHELL_TRIS_MAX])
	room.queue_free()
	await process_frame


func _grid(cells: Dictionary, what: String) -> void:
	## cells: (2x, 2z) of each copy's centre -> count. Expect every 5 m cell of the floor plan exactly once: 4 x 3 in
	## the main room, 3 x 3 in the grow hall (x 10..25: the last column ends outside, behind the hall's east wall),
	## 3 x 2 on the loading dock (z 7.5..17.5: the last row ends behind its south wall).
	var missing: Array = []
	var ok := true
	var want: Array[Vector2] = []
	for ix in 4:
		for iz in 3:
			want.append(Vector2(-7.5 + ix * PANEL, -5.0 + iz * PANEL))
	for ix in 3:
		for iz in 3:
			want.append(Vector2(12.5 + ix * PANEL, -5.0 + iz * PANEL))
	for ix in 3:
		for iz in 2:
			want.append(Vector2(-7.5 + ix * PANEL, 10.0 + iz * PANEL))
	for c in want:
		var k := Vector2i(roundi(c.x * 2.0), roundi(c.y * 2.0))
		if int(cells.get(k, 0)) != 1:
			ok = false
			missing.append(c)
	_check(ok and cells.size() == want.size(), "%s: 4 x 3 (main room) + 3 x 3 (hall) + 3 x 2 (dock) modules, once each (%d cells; wrong: %s)"
			% [what, cells.size(), missing])
