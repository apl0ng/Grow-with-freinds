extends RefCounted
## M16 variety: what a cover layout has to keep, measured from the geometry (physics queries against the live world).
## Used by tools/tests/variety_body.gd; no checks of its own, only measurements. Everything is in global space, which
## is Room-local: the Room sits at the origin.
##
##   solid_overlaps()        cover pieces that sit in another piece or in anything solid
##   unsupported()           raised cover pieces with nothing under them
##   blocked_route_edges()   route graph edges a cover piece stands in (ROUTE_MARGIN round the line, and a body's width)
##   blocked_doorways()      doorways a cover piece stands in
##   blocked_spots()         named standing places (spawns, arrivals, markers, station fronts, the Boss's walks, the
##                           collector's walk, the cans) a cover piece crowds
##   lanes()                 every drive-by lane: where it is cut, by what, and the nearest spot behind cover
##   dock_hidden()           the dock's floor cells a bundle can lie on unseen by all three raid eyes
##   dock_map()              the same as text, for a person

const BODY_RADIUS := 0.4
const BODY_HEIGHT := 1.7
const CELL := 0.25
## A bundle on the floor is this big for "does it fit here".
const BUNDLE_RADIUS := 0.12
## How far from a hidden cell a worker may stand to put a bundle there.
const REACH := 0.9
## A spot behind cover counts for a lane when it is this near the lane's line.
const LANE_REACH := 3.0
const CHEST := 1.0

var room: Room
var space: PhysicsDirectSpaceState3D
var _cover: Dictionary = {}       # instance id -> Node3D
var _capsule := CapsuleShape3D.new()
var _sphere := SphereShape3D.new()


func _init(the_room: Room) -> void:
	room = the_room
	space = room.get_world_3d().direct_space_state
	_capsule.radius = BODY_RADIUS
	_capsule.height = BODY_HEIGHT
	_sphere.radius = BUNDLE_RADIUS
	for node in room.get_cover_nodes():
		_cover[node.get_instance_id()] = node


func is_cover(collider: Variant) -> bool:
	return collider is Object and is_instance_valid(collider) and _cover.has((collider as Object).get_instance_id())


## What a standing worker with their feet at `pos` touches on LAYER_WORLD (colliders).
func body_hits(pos: Vector3) -> Array:
	var q := PhysicsShapeQueryParameters3D.new()
	q.shape = _capsule
	q.transform = Transform3D(Basis.IDENTITY, Vector3(pos.x, pos.y + BODY_HEIGHT * 0.5 + 0.1, pos.z))
	q.collision_mask = Const.LAYER_WORLD
	var out: Array = []
	for hit: Dictionary in space.intersect_shape(q, 8):
		out.append(hit.get("collider"))
	return out


func body_free(pos: Vector3) -> bool:
	return body_hits(pos).is_empty()


## The name of a cover piece a standing worker at `pos` touches ("" = none).
func body_in_cover(pos: Vector3) -> String:
	for c: Variant in body_hits(pos):
		if is_cover(c):
			return String((c as Node).name)
	return ""


func bundle_fits(pos: Vector3) -> bool:
	var q := PhysicsShapeQueryParameters3D.new()
	q.shape = _sphere
	q.transform = Transform3D(Basis.IDENTITY, pos + Vector3.UP * (BUNDLE_RADIUS + 0.03))
	q.collision_mask = Const.LAYER_WORLD
	return space.intersect_shape(q, 1).is_empty()


func ray(from: Vector3, to: Vector3) -> Dictionary:
	return space.intersect_ray(PhysicsRayQueryParameters3D.create(from, to, Const.LAYER_WORLD))


# --- the pieces themselves ---------------------------------------------------------------------------------------------

## "CrateA in PalletB" for every cover piece whose collider (2 cm smaller all round) is in another collider.
func solid_overlaps() -> PackedStringArray:
	var out := PackedStringArray()
	for node: Node3D in _cover.values():
		var shape_node := node.get_node_or_null(^"Shape") as CollisionShape3D
		var body := node as CollisionObject3D
		if shape_node == null or body == null or not (shape_node.shape is BoxShape3D):
			out.append("%s has no box" % node.name)
			continue
		var box := BoxShape3D.new()
		box.size = (shape_node.shape as BoxShape3D).size - Vector3.ONE * 0.04
		var q := PhysicsShapeQueryParameters3D.new()
		q.shape = box
		q.transform = shape_node.global_transform
		q.collision_mask = Const.LAYER_WORLD
		q.exclude = [body.get_rid()]
		for hit: Dictionary in space.intersect_shape(q, 4):
			out.append("%s in %s" % [node.name, (hit.get("collider") as Node).name])
	return out


## Every cover piece that stands above the floor without another piece right under its middle and three of four points
## a quarter metre out.
func unsupported() -> PackedStringArray:
	var out := PackedStringArray()
	for node: Node3D in _cover.values():
		var base := node.global_position
		if base.y < 0.01:
			if base.y < -0.001:
				out.append("%s is under the floor" % node.name)
			continue
		var body := node as CollisionObject3D
		var held := 0
		var middle := false
		for offset: Vector3 in [Vector3.ZERO, Vector3(0.25, 0, 0.25), Vector3(-0.25, 0, 0.25), Vector3(0.25, 0, -0.25), Vector3(-0.25, 0, -0.25)]:
			var p := node.global_transform * offset
			var q := PhysicsRayQueryParameters3D.create(p + Vector3.UP * 0.05, p - Vector3.UP * 0.2, Const.LAYER_WORLD)
			q.exclude = [body.get_rid()]
			var hit := space.intersect_ray(q)
			if not hit.is_empty() and is_cover(hit.get("collider")) and absf((hit["position"] as Vector3).y - base.y) < 0.02:
				held += 1
				if offset == Vector3.ZERO:
					middle = true
		if not middle or held < 4:
			out.append("%s at %.2f m rests on %d of 5 points" % [node.name, base.y, held])
	return out


# --- ways through ------------------------------------------------------------------------------------------------------

## Route graph edges (as "3-4 CrateX") a cover piece stands in: its footprint grown by ROUTE_MARGIN on the line, or a
## walking body touching it anywhere along the edge.
func blocked_route_edges() -> PackedStringArray:
	var out := PackedStringArray()
	var nodes := room.get_cover_nodes()
	var rects := room.get_cover_footprints()
	for e in Room.ROUTE_EDGES:
		var a: Vector2 = Room.ROUTE_POINTS[e.x]
		var b: Vector2 = Room.ROUTE_POINTS[e.y]
		for i in rects.size():
			if Room._segment_hits_rect(a, b, rects[i].grow(Room.ROUTE_MARGIN)):
				out.append("%d-%d %s (margin)" % [e.x, e.y, nodes[i].name])
		var hit := _walk_in_cover(Vector3(a.x, 0.0, a.y), Vector3(b.x, 0.0, b.y))
		if hit != "":
			out.append("%d-%d %s (body)" % [e.x, e.y, hit])
	return out


## Doorways a cover piece stands in: a body anywhere across the opening, from 1.5 m before the wall to 1.5 m behind.
func blocked_doorways() -> PackedStringArray:
	var out := PackedStringArray()
	for d: Dictionary in room.get_doorways():
		var centre: Vector3 = d["center"]
		var axis: Vector3 = d["axis"]
		var side := Vector3(-axis.z, 0.0, axis.x)
		var half := maxf(float(d["width"]) * 0.5 - BODY_RADIUS - 0.05, 0.0)
		var steps := int(ceil(half * 2.0 / 0.3))
		for i in range(0, steps + 1):
			var across := -half + (half * 2.0) * float(i) / float(maxi(steps, 1))
			var hit := _walk_in_cover(centre + side * across - axis * 1.5, centre + side * across + axis * 1.5)
			if hit != "":
				out.append("%s %s" % [d["name"], hit])
				break
	return out


## The first cover piece a body walking the straight line a-b touches ("" = none), sampled every 0.2 m.
func _walk_in_cover(a: Vector3, b: Vector3) -> String:
	var steps := int(ceil(a.distance_to(b) / 0.2))
	for i in range(0, steps + 1):
		var hit := body_in_cover(a.lerp(b, float(i) / float(maxi(steps, 1))))
		if hit != "":
			return hit
	return ""


# --- places somebody stands ------------------------------------------------------------------------------------------------

## Every named standing place a cover piece crowds: "Spawn 2: CrateA". `players` up to this many spawns / arrivals.
func blocked_spots(players: int = 8) -> PackedStringArray:
	var out := PackedStringArray()
	for i in players:
		_spot(out, "spawn %d" % i, room.get_spawn_transform(i).origin)
		_spot(out, "arrival %d" % i, room.get_arrival_transform(i).origin)
	_spot(out, "the head count line", room.get_headcount_spot())
	var line := room.get_headcount_spot()
	for i in 8:
		var angle := TAU * float(i) / 8.0
		_spot(out, "the head count line + %d" % i, line + Vector3(cos(angle), 0.0, sin(angle)) * 1.5)
	var collector := room.get_collector_spot().origin
	_spot(out, "the collector", collector)
	var door := room.get_roller_door_position()
	_walk(out, "the collector's walk", door + (collector - door).normalized() * 0.8, collector)
	# Whoever pays him stands in front of him (he faces -Z) or at one of his sides.
	_spot(out, "in front of the collector", collector + Vector3(0.0, 0.0, -1.2))
	if body_in_cover(collector + Vector3(1.2, 0.0, 0.0)) != "" and body_in_cover(collector + Vector3(-1.2, 0.0, 0.0)) != "":
		out.append("both sides of the collector are crowded")
	_route(out, "the inspection", room.get_inspection_route())
	_route(out, "the head count", room.get_headcount_route())
	var stations := room.get_node_or_null(^"Stations")
	if stations != null:
		for child in stations.get_children():
			var station := child as Node3D
			if station == null:
				continue
			var front := station.global_transform.basis.z
			front.y = 0.0
			front = front.normalized()
			var at := Vector3(station.global_position.x, 0.0, station.global_position.z)
			for distance: float in [0.9, 1.3, 1.7]:
				_spot(out, "%s front %.1f" % [station.name, distance], at + front * distance)
			# The interaction side: a hand reaching from 1.3 m at chest height meets the station, not a crate.
			var hit := ray(at + front * 1.3 + Vector3.UP * CHEST, at + Vector3.UP * CHEST)
			if not hit.is_empty() and is_cover(hit.get("collider")):
				out.append("%s reach: %s" % [station.name, (hit["collider"] as Node).name])
	var w := room.get_parent() as World
	if w != null and w.items != null:
		for item in w.items.get_items():
			if item.holder_id == 0 and room.is_in_cover(item.global_position, 0.15):
				out.append("%s lies in cover" % item.name)
	return out


func _spot(out: PackedStringArray, what: String, pos: Vector3) -> void:
	var hit := body_in_cover(Vector3(pos.x, 0.0, pos.z))
	if hit != "":
		out.append("%s: %s" % [what, hit])


func _walk(out: PackedStringArray, what: String, a: Vector3, b: Vector3) -> void:
	var hit := _walk_in_cover(Vector3(a.x, 0.0, a.z), Vector3(b.x, 0.0, b.z))
	if hit != "":
		out.append("%s: %s" % [what, hit])


func _route(out: PackedStringArray, what: String, points: PackedVector3Array) -> void:
	for i in range(1, points.size()):
		var hit := _walk_in_cover(Vector3(points[i - 1].x, 0.0, points[i - 1].z), Vector3(points[i].x, 0.0, points[i].z))
		if hit != "":
			out.append("%s %d-%d: %s" % [what, i - 1, i, hit])
			return


# --- the drive-by --------------------------------------------------------------------------------------------------------------

## One lane as the game fires it (Events.server_fire_lane's ray: glass does not stop a round): {"end": Vector3,
## "blocked": bool, "collider": Node or null}.
func lane_cut(lane: Dictionary) -> Dictionary:
	var from: Vector3 = lane["from"]
	var end: Vector3 = lane["to"]
	var q := PhysicsRayQueryParameters3D.create(from, end, Const.LAYER_WORLD)
	var through: Array[RID] = []
	for pane in Events.DRIVEBY_GLASS_PANES + 1:
		q.exclude = through
		var hit := space.intersect_ray(q)
		if hit.is_empty():
			break
		if pane < Events.DRIVEBY_GLASS_PANES and Events._is_glass(hit.get("collider") as Node):
			through.append(hit["rid"])
			continue
		return {"end": hit["position"], "blocked": true, "collider": hit.get("collider")}
	return {"end": end, "blocked": false, "collider": null}


## Every lane: {"index", "cut" (the lane_cut), "by_cover": bool, "spot": Vector3 (INF = none), "spot_distance": float,
## "spot_cover": String}. The spot: the floor point nearest the lane's line (within LANE_REACH) where a worker has room
## to stand, no round of ANY lane reaches a standing worker, and something solid stands between them and the lane's
## muzzle.
func lanes() -> Array:
	var all: Array = room.get_gunfire_lanes()
	var cuts: Array = []
	for lane: Dictionary in all:
		cuts.append(lane_cut(lane))
	var out: Array = []
	for i in all.size():
		var from: Vector3 = all[i]["from"]
		var to: Vector3 = all[i]["to"]
		var best := Vector3.INF
		var best_d := INF
		var best_cover := ""
		var lo := Vector2(minf(from.x, to.x) - LANE_REACH, minf(from.z, to.z) - LANE_REACH)
		var hi := Vector2(maxf(from.x, to.x) + LANE_REACH, maxf(from.z, to.z) + LANE_REACH)
		var x := snappedf(lo.x, 0.5)
		while x <= hi.x:
			var z := snappedf(lo.y, 0.5)
			while z <= hi.y:
				var p := Vector3(x, 0.0, z)
				z += 0.5
				var near := Events._lane_closest(from, to, p)
				var d := Vector2(near.x - p.x, near.z - p.z).length()
				if d > LANE_REACH or d >= best_d or not room.contains_point(p, 0.3) or not body_free(p):
					continue
				var hit := ray(from, p + Vector3.UP * CHEST)
				if hit.is_empty() or Events._is_glass(hit.get("collider") as Node):
					continue
				if _any_lane_reaches(all, cuts, p):
					continue
				best = p
				best_d = d
				best_cover = String((hit["collider"] as Node).name)
			x += 0.5
		out.append({"index": i, "cut": cuts[i], "by_cover": is_cover(cuts[i]["collider"]), "spot": best, "spot_distance": best_d, "spot_cover": best_cover})
	return out


func _any_lane_reaches(all: Array, cuts: Array, p: Vector3) -> bool:
	for i in all.size():
		var from: Vector3 = all[i]["from"]
		var end: Vector3 = cuts[i]["end"]
		var near := Events._lane_closest(from, end, p)
		if Vector2(near.x - p.x, near.z - p.z).length() <= Events.DRIVEBY_WORKER_RADIUS + 0.1:
			return true
	return false


# --- the raid ------------------------------------------------------------------------------------------------------------------

## True when a bundle lying at `pos` (floor) is taken by a raid: one of the eyes is within RAID_RANGE with a clear
## LAYER_WORLD line to it (Events.server_raid_sweep's test).
func raid_sees(pos: Vector3) -> bool:
	var target := pos + Vector3.UP * Events.RAID_ITEM_LIFT
	for eye in room.get_raid_points():
		if eye.distance_to(target) <= Events.RAID_RANGE and ray(eye, target).is_empty():
			return true
	return false


## The dock's floor cells (CELL apart, as Vector2i(column, row) from the dock's north-west corner) where a bundle fits,
## no raid eye sees it, and a worker has room to stand within REACH of it.
func dock_hidden() -> Dictionary:
	var out: Dictionary = {}
	var area: AABB = Room.DOCK_AREA
	var cols := int(area.size.x / CELL)
	var rows := int(area.size.z / CELL)
	for row in rows:
		for col in cols:
			var p := dock_cell_position(Vector2i(col, row))
			if not room.contains_point(p, 0.15) or not bundle_fits(p) or raid_sees(p) or not _reachable(p):
				continue
			out[Vector2i(col, row)] = true
	return out


func dock_cell_position(cell: Vector2i) -> Vector3:
	var area: AABB = Room.DOCK_AREA
	return Vector3(area.position.x + (float(cell.x) + 0.5) * CELL, 0.0, area.position.z + (float(cell.y) + 0.5) * CELL)


func _reachable(p: Vector3) -> bool:
	if body_free(p):
		return true
	for ring: float in [REACH * 0.5, REACH]:
		for i in 8:
			var angle := TAU * float(i) / 8.0
			var stand := p + Vector3(cos(angle), 0.0, sin(angle)) * ring
			if room.contains_point(stand, 0.3) and body_free(stand) and ray(stand + Vector3.UP * 0.6, p + Vector3.UP * 0.3).is_empty():
				return true
	return false


## The middle of a set of dock cells (Vector3.INF for none).
func cells_centre(cells: Dictionary) -> Vector3:
	if cells.is_empty():
		return Vector3.INF
	var sum := Vector3.ZERO
	for cell: Vector2i in cells:
		sum += dock_cell_position(cell)
	return sum / float(cells.size())


## The dock from above, north at the top: '#' solid, 'H' hidden from the raid, 'h' hidden but out of a worker's reach,
## '.' seen, ' ' off the floor.
func dock_map(hidden: Dictionary) -> String:
	var area: AABB = Room.DOCK_AREA
	var cols := int(area.size.x / CELL)
	var rows := int(area.size.z / CELL)
	var lines := PackedStringArray()
	for row in rows:
		var text := ""
		for col in cols:
			var cell := Vector2i(col, row)
			var p := dock_cell_position(cell)
			if not room.contains_point(p, 0.15):
				text += " "
			elif not bundle_fits(p):
				text += "#"
			elif hidden.has(cell):
				text += "H"
			elif not raid_sees(p):
				text += "h"
			else:
				text += "."
		lines.append("      |%s| z %.2f" % [text, area.position.z + (float(row) + 0.5) * CELL])
	return "\n".join(lines)
