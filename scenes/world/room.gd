class_name Room
extends Node3D
## The starting room: geometry, lights, props, station placement and spawn points.
## Owned by the world/level agent. Contract (CONTRACTS.md) that must be kept:
##   $Spawns/Spawn1..4 (Marker3D)  - player spawn points (feet level + 0.2 m, facing the shop)
##   $Stations/ShopCounter, Well, TurnInStation, GrowPlot1..6 - instances of the station scenes
##   get_spawn_points(), get_spawn_transform(index)
##
## Layout (Room-local metres, floor top at y = 0, interior x -8..8, z -6..6, ceiling at y = 4):
##   north wall (z-) : ShopCounter at (0, 0, -3.7) facing +Z, shelves + sign behind it, two windows
##   east (x+)       : GrowPlot1..6 in a 2x3 grid (x 3.6 / 6.0, z -2.4 / 0 / 2.4) facing -X, grow lights above
##   west (x-)       : Well at (-5.6, 0, 0) facing +X, water pipe from the wall into its back
##   south wall (z+) : TurnInStation at (0, 0, 4.5) facing -Z, crates either side, decorative door
##   centre          : round rug with the four spawn points
## Every station's "front" (+Z in its local space) faces the room centre.
## Solid geometry (floor, walls, ceiling, solid props) is on collision layer 1 with mask 0.

## Interior size in metres (x = width, y = floor-to-ceiling height, z = depth), centred on the Room origin.
const INTERIOR_SIZE := Vector3(16.0, 4.0, 12.0)

## Names of every station node under $Stations (contract).
const STATION_NAMES: PackedStringArray = [
	"ShopCounter", "Well", "TurnInStation",
	"GrowPlot1", "GrowPlot2", "GrowPlot3", "GrowPlot4", "GrowPlot5", "GrowPlot6",
]

## Sideways offset (metres, along the spawn marker's local X) applied per wrap-around when more players
## than spawn markers join, so a 5th..8th player never spawns inside another one.
const SPAWN_WRAP_OFFSET: float = 0.75


## Spawn markers in order (Spawn1..Spawn4).
func get_spawn_points() -> Array[Marker3D]:
	var out: Array[Marker3D] = []
	var spawns := get_node_or_null(^"Spawns")
	if spawns == null:
		return out
	for c in spawns.get_children():
		if c is Marker3D:
			out.append(c)
	return out


## Global transform for the index-th player (wraps around the markers; negative indices are safe).
func get_spawn_transform(index: int) -> Transform3D:
	var pts := get_spawn_points()
	if pts.is_empty():
		return _to_global(Transform3D(Basis.IDENTITY, Vector3(0.0, 1.0, 0.0)))
	var i := posmod(index, pts.size())
	var wraps := floori(float(absi(index)) / float(pts.size()))
	var t := _to_global(_room_transform_of(pts[i]))
	if wraps > 0:
		# Alternate right/left of the marker: +0.75, -0.75, +1.5, -1.5 ...
		var side := 1.0 if wraps % 2 == 1 else -1.0
		t.origin += t.basis.x.normalized() * SPAWN_WRAP_OFFSET * side * ceilf(float(wraps) * 0.5)
	return t


## A station node by name ("ShopCounter", "Well", "TurnInStation", "GrowPlot1".."GrowPlot6"), or null.
func get_station(station_name: String) -> Node3D:
	if station_name.is_empty():
		return null
	var stations := get_node_or_null(^"Stations")
	if stations == null:
		return null
	return stations.get_node_or_null(NodePath(station_name)) as Node3D


## All station nodes that exist, in STATION_NAMES order.
func get_stations() -> Array[Node3D]:
	var out: Array[Node3D] = []
	for n in STATION_NAMES:
		var s := get_station(n)
		if s != null:
			out.append(s)
	return out


## Interior bounds: floor extents (x/z) from the floor (y = 0) up to the ceiling. Global space when the
## room is in the tree (it sits at the world origin), Room-local space otherwise.
func get_bounds() -> AABB:
	var local := AABB(Vector3(-INTERIOR_SIZE.x * 0.5, 0.0, -INTERIOR_SIZE.z * 0.5), INTERIOR_SIZE)
	if is_inside_tree():
		return global_transform * local
	return local


## A standing spot `distance` metres in front of a station (along its +Z / front), on the floor.
## Handy for bots/tests that need to walk up to a station. Returns Vector3.INF if the station is missing.
func get_station_access_point(station_name: String, distance: float = 1.3) -> Vector3:
	var s := get_station(station_name)
	if s == null:
		return Vector3.INF
	var t := _to_global(_room_transform_of(s))
	var front := t.basis.z
	front.y = 0.0
	if front.length_squared() < 0.0001:
		front = Vector3.BACK
	var p := t.origin + front.normalized() * distance
	p.y = _to_global(Transform3D.IDENTITY).origin.y
	return p


# --- helpers ----------------------------------------------------------------------------------------

## Transform of a descendant relative to this Room (works in and out of the tree).
func _room_transform_of(node: Node3D) -> Transform3D:
	var t := node.transform
	var p := node.get_parent()
	while p != null and p != self:
		if p is Node3D:
			t = (p as Node3D).transform * t
		p = p.get_parent()
	return t


func _to_global(room_local: Transform3D) -> Transform3D:
	if is_inside_tree():
		return global_transform * room_local
	return room_local
