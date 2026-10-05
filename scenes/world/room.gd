class_name Room
extends Node3D
## The starting room: a low-budget factory floor the players are stuck in, working off a debt to the Boss.
## Geometry, lights, props, station placement and spawn points. Owned by the world/level agent.
## Contract (CONTRACTS.md) that must be kept:
##   $Spawns/Spawn1..4 (Marker3D)  - player spawn points (feet level + 0.2 m, facing the shop)
##   $Stations/ShopCounter, Well, TurnInStation, GrowPlot1..6 - instances of the station scenes
##   get_spawn_points(), get_spawn_transform(index)
##
## Layout (Room-local metres, floor top at y = 0, interior x -10..10, z -7.5..7.5, ceiling at y = 6):
##   north (z-) : the Boss's booth: ShopCounter (barred pay window) at (0, 0, -5.0) facing +Z, partitions either
##                side close off the space behind it; DEBT BOARD, wall clock, "WORK HARDER" poster on the wall
##   east (x+)  : fenced GROW AREA (gate on its west side, caution stripes), GrowPlot1..6 in a 2x3 grid
##                (x 5.0 / 7.6, z -3.0 / 0 / 3.0) facing -X under two grow-light bars
##   west (x-)  : Well (water tank) at (-6.8, 0, 0) facing +X with its feed pipe, a barred night window, a leak
##   south (z+) : TurnInStation at (0, 0, 5.8) facing -Z, the passage to the loading dock (M14: the chained + beamed
##                roller door stands on the dock's outer wall now), CLOCK IN, pallets
##   ceiling    : 6 m, steel beams, pipes, a cable tray, drop-down pendant lamps and a black hole with dust
## M14 (level agent): two annexes joined to the main room, see the "M14 level" region at the end of this file:
##   grow hall  : x 10..22, the main room's z range. Two doorways (2.0 x 2.5 m) in the east wall: z -2.25..-0.25 from
##                inside the grow pen, z 5.25..7.25 from the corridor south of it. GrowPlot7..10 (x 16.0 / 18.6,
##                z -1.5 / 1.5) under two grow-light bars; the north wall is kept clear for the drying racks.
##   loading dock: x -10..5, z 7.5..15.6, through the 4.2 x 3.75 m passage where the roller door used to be
##                (x -7.1..-2.9). Arrivals/Arrival0..3 behind the parked van, crate stacks, the roller door (chained)
##                and two high windows on its south wall.
## INTERIOR_SIZE / get_bounds() still describe the main room; get_play_areas() lists all three.
## Every station's "front" (+Z in its local space) faces the room centre.
## Solid geometry (floor, walls, ceiling, booth partitions, fences, solid props) is on collision layer 1, mask 0.
## Props live under $Decor as scenes from scenes/world/props/ with their meshes under a `Visual` child.

## Interior size in metres (x = width, y = floor-to-ceiling height, z = depth), centred on the Room origin.
const INTERIOR_SIZE := Vector3(20.0, 6.0, 15.0)

## Names of every station node under $Stations (contract). FuseBox (M10) is wall-mounted (origin on the west
## wall at 1.2 m, front +X): layout rules for floor stations do not apply to it.
const STATION_NAMES: PackedStringArray = [
	"ShopCounter", "Well", "TurnInStation",
	"GrowPlot1", "GrowPlot2", "GrowPlot3", "GrowPlot4", "GrowPlot5", "GrowPlot6",
	"GrowPlot7", "GrowPlot8", "GrowPlot9", "GrowPlot10", # M14 level: the grow hall's trays
	"FuseBox",
]
## M14 level: how many trays the floor has (GrowPlot1..GROW_PLOT_COUNT: six in the pen, four in the grow hall).
const GROW_PLOT_COUNT := 10
## Stations mounted on a wall (not on the floor).
const WALL_STATION_NAMES: PackedStringArray = ["FuseBox"]

## The DEBT BOARD sign (a props/sign_board.tscn instance with a `text` property and a `Text` Label3D).
const DEBT_BOARD_PATH := ^"Decor/DebtBoard"
const DEBT_BOARD_DEFAULT_TEXT := "PAY UP"

## M10 (events agent): the Boss's inspection route (Marker3Ds P1..Pn, floor level, walked in name order), the
## back-room spot behind the booth, the booth door he leaves through (a hinged leaf in the west partition; its
## collider stays solid so workers never get in), and the mains power switch for the power cut.
const INSPECTION_ROUTE_PATH := ^"Decor/InspectionRoute"
const BACKROOM_SPOT_PATH := ^"Decor/BackRoomSpot"
const BACKROOM_DOOR_PATH := ^"Decor/BackRoomDoor"
## Extra back-room places (marker-local offsets) when several workers sit there at once.
const BACKROOM_SLOTS: Array[Vector3] = [Vector3.ZERO, Vector3(-2.4, 0.0, 0.0), Vector3(0.0, 0.0, -0.5), Vector3(-2.4, 0.0, -0.5)]
## Hinge swing when the door is open (degrees) and the tween time.
const DOOR_OPEN_DEG := 100.0
## The modelled leaf (backroom_door.glb `Door`, hinge edge pivot) swings this far (+Y) into the booth when open.
const DOOR_MODEL_OPEN_DEG := 80.0
const DOOR_SWING_SEC := 0.45
## Room ambience: the mains hum loop (Sfx `hum`), running while the power is on.
const HUM_SOUND: StringName = &"hum"
## The doorway centre, hinge-local (half the leaf width along the hinge's +Z).
const DOOR_CENTRE_OFFSET := Vector3(0.0, 0.0, 0.45)
## Power cut: every light drops to this fraction of its energy, the ambient to AMBIENT_OFF_FRACTION, over POWER_TWEEN_SEC.
const POWER_OFF_FRACTION := 0.06
const AMBIENT_OFF_FRACTION := 0.25
const POWER_TWEEN_SEC := 0.4

var _power_on: bool = true
var _power_tween: Tween
var _door_tween: Tween
var _door_open: bool = false
var _light_base: Dictionary = {}   # Light3D instance id -> base energy (captured the first time the power goes)
var _ambient_base: float = -1.0
var _hum_handle: int = 0


func _ready() -> void:
	_set_hum(true)
	_cover_ready() # M16 variety: the scene's cover transforms are read, the run's layout applied and followed


func _exit_tree() -> void:
	_set_hum(false)
	_cover_exit() # M16 variety


## Starts / stops the mains hum (Sfx.play_loop, 2D). Looked up at runtime: this script is a compile-time
## dependency of `-s` test scripts, which cannot name autoloads. Idempotent.
func _set_hum(on: bool) -> void:
	var sfx := get_node_or_null(^"/root/Sfx")
	if sfx == null:
		return
	if on:
		if _hum_handle == 0 and is_inside_tree() and sfx.has_method(&"play_loop"):
			_hum_handle = int(sfx.call(&"play_loop", HUM_SOUND))
	elif _hum_handle != 0:
		if sfx.has_method(&"stop_loop"):
			sfx.call(&"stop_loop", _hum_handle)
		_hum_handle = 0

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


## A station node by name ("ShopCounter", "Well", "TurnInStation", "GrowPlot1".."GrowPlot10", ...), or null.
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


## Writes the DEBT BOARD next to the Boss's window, e.g. "OWED: $400 / SHIFT 1" (shrinks to fit).
## Local cosmetic: call it on every peer (e.g. from a GameState signal). Null-safe if the board is missing.
func set_debt_board_text(text: String) -> void:
	var board := get_node_or_null(DEBT_BOARD_PATH)
	if board == null:
		return
	if &"text" in board:
		board.set(&"text", text)
	else:
		var label := board.get_node_or_null(^"Text") as Label3D
		if label != null:
			label.text = text


## Current DEBT BOARD text ("" when the board is missing).
func get_debt_board_text() -> String:
	var board := get_node_or_null(DEBT_BOARD_PATH)
	if board == null:
		return ""
	if &"text" in board:
		return String(board.get(&"text"))
	var label := board.get_node_or_null(^"Text") as Label3D
	return label.text if label != null else ""


# --- M10: inspection route / back room / booth door -------------------------------------------------

## True for a station that hangs on a wall (FuseBox): floor-layout rules do not apply to it.
static func is_wall_station(station_name: String) -> bool:
	return WALL_STATION_NAMES.has(station_name)


## The Boss's inspection walk: global floor positions of Decor/InspectionRoute/P1..Pn in numeric order
## (booth door -> grow-area gate -> along the trays -> water tank -> deposit chute -> back to the booth).
## Empty when the markers are missing.
func get_inspection_route() -> PackedVector3Array:
	var out := PackedVector3Array()
	var holder := get_node_or_null(INSPECTION_ROUTE_PATH)
	if holder == null:
		return out
	var markers: Array[Node] = []
	for c in holder.get_children():
		if c is Marker3D:
			markers.append(c)
	markers.sort_custom(func(a: Node, b: Node) -> bool: return _marker_index(a) < _marker_index(b))
	for m in markers:
		var t := _to_global(_room_transform_of(m as Marker3D))
		out.append(t.origin)
	return out


static func _marker_index(n: Node) -> int:
	var s := String(n.name)
	var digits := ""
	for ch in s:
		if ch.is_valid_int():
			digits += ch
	return int(digits) if digits != "" else 0


## The back-room marker behind the booth (null if missing).
func get_backroom_spot() -> Marker3D:
	return get_node_or_null(BACKROOM_SPOT_PATH) as Marker3D


## Global transform where a worker sent to the back room is put (feet). `slot` spreads several workers out
## (BACKROOM_SLOTS, wraps). Falls back to a spot behind the shop counter when the marker is missing.
func get_backroom_transform(slot: int = 0) -> Transform3D:
	var spot := get_backroom_spot()
	var t: Transform3D
	if spot != null:
		t = _to_global(_room_transform_of(spot))
	else:
		var shop := get_station("ShopCounter")
		var base := _room_transform_of(shop) if shop != null else Transform3D(Basis.IDENTITY, Vector3(0.0, 0.0, -5.0))
		t = _to_global(base * Transform3D(Basis.IDENTITY, Vector3(1.2, 0.2, -1.7)))
	var offset: Vector3 = BACKROOM_SLOTS[posmod(slot, BACKROOM_SLOTS.size())]
	t.origin += t.basis * offset
	return t


## M13 review: true when `point` (global) lies inside the Boss's booth: between the two partitions (Decor/Booth
## ShapeWest / ShapeEast), from the ShopCounter's centre line back to the north wall. No worker on the floor gets in
## there, so nothing a worker throws may come to rest there (ItemManager's flight landing asks: a thrown watering can
## or flamethrower used to sail over the 1 m counter and was lost for the shift). False without the booth nodes.
func is_in_booth(point: Vector3) -> bool:
	var west := get_node_or_null(^"Decor/Booth/ShapeWest") as Node3D
	var east := get_node_or_null(^"Decor/Booth/ShapeEast") as Node3D
	var counter := get_station("ShopCounter")
	if west == null or east == null or counter == null or not point.is_finite():
		return false
	var p := global_transform.affine_inverse() * point if is_inside_tree() else point
	var x0 := minf(_room_transform_of(west).origin.x, _room_transform_of(east).origin.x)
	var x1 := maxf(_room_transform_of(west).origin.x, _room_transform_of(east).origin.x)
	return p.x > x0 and p.x < x1 and p.z < _room_transform_of(counter).origin.z


## The booth door prop (hinge node) or null.
func get_backroom_door() -> Node3D:
	return get_node_or_null(BACKROOM_DOOR_PATH) as Node3D


## Global centre of the doorway the Boss walks through (the room origin when the door is missing).
func get_backroom_door_position() -> Vector3:
	var door := get_backroom_door()
	if door == null:
		return _to_global(Transform3D.IDENTITY).origin
	return _to_global(_room_transform_of(door)) * DOOR_CENTRE_OFFSET


## Swings the booth door open / shut (cosmetic, every peer on its own; idempotent). The leaf's collider stays
## solid either way: the Boss has no collision, workers stay out. A steel door slams when it shuts.
func set_backroom_door_open(open: bool) -> void:
	if open == _door_open:
		return
	_door_open = open
	var door := get_backroom_door()
	if door == null:
		return
	var hinge := door.get_node_or_null(^"Hinge") as Node3D
	var leaf := door.get_node_or_null(^"Model/Door") as Node3D # the modelled leaf (backroom_door.glb)
	if hinge == null and leaf == null:
		return
	var target := Vector3(0.0, deg_to_rad(-DOOR_OPEN_DEG) if open else 0.0, 0.0)
	var leaf_target := Vector3(0.0, deg_to_rad(DOOR_MODEL_OPEN_DEG) if open else 0.0, 0.0)
	if _door_tween != null and _door_tween.is_valid():
		_door_tween.kill()
	if not is_inside_tree():
		if hinge != null:
			hinge.rotation = target
		if leaf != null:
			leaf.rotation = leaf_target
		return
	_door_tween = create_tween().set_parallel(true)
	if hinge != null:
		_door_tween.tween_property(hinge, ^"rotation", target, DOOR_SWING_SEC).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_OUT if open else Tween.EASE_IN)
	if leaf != null:
		_door_tween.tween_property(leaf, ^"rotation", leaf_target, DOOR_SWING_SEC).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_OUT if open else Tween.EASE_IN)
	if not open:
		_door_tween.chain().tween_callback(_play_door_slam)


## The Sfx autoload is looked up at runtime: this script is a compile-time dependency of `-s` test scripts
## (tools/tests/world_test.gd), which cannot name autoloads.
func _play_door_slam() -> void:
	if not is_inside_tree():
		return
	var sfx := get_node_or_null(^"/root/Sfx")
	if sfx != null and sfx.has_method(&"play"):
		sfx.call(&"play", &"door_slam", get_backroom_door_position() + Vector3.UP * 1.0)


func is_backroom_door_open() -> bool:
	return _door_open


# --- M12 disrupt: head count -------------------------------------------------------------------------

## The line the Boss counts heads from (Decor/HeadcountSpot, a Marker3D on the floor in front of the pay window).
const HEADCOUNT_SPOT_PATH := ^"Decor/HeadcountSpot"
## Fallback when the marker is missing: this far in front of the ShopCounter's origin (its front is +Z).
const HEADCOUNT_FALLBACK_DISTANCE := 1.8
## The Boss's way to the line follows the inspection route up to its first point within this distance of the spot.
const HEADCOUNT_ROUTE_JOIN_DISTANCE := 3.0


## Global floor position of the head-count line, or a spot in front of the counter when the marker is missing.
func get_headcount_spot() -> Vector3:
	var floor_y := _to_global(Transform3D.IDENTITY).origin.y
	var spot := get_node_or_null(HEADCOUNT_SPOT_PATH) as Marker3D
	if spot != null:
		var t := _to_global(_room_transform_of(spot))
		return Vector3(t.origin.x, floor_y, t.origin.z)
	var p := get_station_access_point("ShopCounter", HEADCOUNT_FALLBACK_DISTANCE)
	return p if p.is_finite() else Vector3(0.0, floor_y, 0.0)


## The Boss's walk from the booth to the line: the inspection route up to its first point within
## HEADCOUNT_ROUTE_JOIN_DISTANCE of the spot (the nearest point when none is), then the spot. He leaves through
## the booth door like an inspection instead of walking through the counter. Just the spot without a route.
func get_headcount_route() -> PackedVector3Array:
	var spot := get_headcount_spot()
	var route := get_inspection_route()
	var out := PackedVector3Array()
	var join := -1
	var nearest := -1
	var best := INF
	for i in route.size():
		var d := route[i].distance_to(spot)
		if d < best:
			best = d
			nearest = i
		if join < 0 and d <= HEADCOUNT_ROUTE_JOIN_DISTANCE:
			join = i
	if join < 0:
		join = nearest
	for i in range(join + 1):
		out.append(route[i])
	out.append(spot)
	return out


# --- M10: mains power (power cut) ----------------------------------------------------------------------

## Mains on/off (cosmetic, every peer on its own from Events.power_changed; idempotent). Off: every Light3D under
## the room (the Sun included) fades to POWER_OFF_FRACTION of its energy over POWER_TWEEN_SEC, the ambient dims,
## fluoro tubes go dark and stop flickering, grow-light tubes and camera LEDs go off. On: everything comes back
## (fixtures re-powered when the fade is done).
func set_power(on: bool) -> void:
	if on == _power_on:
		return
	_power_on = on
	if _power_tween != null and _power_tween.is_valid():
		_power_tween.kill()
	var animate := is_inside_tree()
	_power_tween = create_tween().set_parallel(true) if animate else null
	_set_hum(on)
	if not on:
		_set_fixtures_powered(false)
	for l in find_children("*", "Light3D", true, false):
		var light := l as Light3D
		var id := light.get_instance_id()
		if not _light_base.has(id):
			_light_base[id] = light.light_energy
		var target: float = float(_light_base[id]) * (1.0 if on else POWER_OFF_FRACTION)
		if animate:
			_power_tween.tween_property(light, ^"light_energy", target, POWER_TWEEN_SEC)
		else:
			light.light_energy = target
	var env := _environment()
	if env != null:
		if _ambient_base < 0.0:
			_ambient_base = env.ambient_light_energy
		var amb := _ambient_base * (1.0 if on else AMBIENT_OFF_FRACTION)
		if animate:
			_power_tween.tween_property(env, ^"ambient_light_energy", amb, POWER_TWEEN_SEC)
		else:
			env.ambient_light_energy = amb
	_set_grow_tubes(on)
	if on:
		if animate:
			_power_tween.chain().tween_callback(_set_fixtures_powered.bind(true))
		else:
			_set_fixtures_powered(true)


func is_power_on() -> bool:
	return _power_on


## Fluoro fixtures / cameras: anything under the room with set_powered(on) (their tubes, flicker, LEDs).
func _set_fixtures_powered(on: bool) -> void:
	for n in find_children("*", "Node3D", true, false):
		if n.has_method(&"set_powered"):
			n.call(&"set_powered", on)


## The grow-light bars' glowing tubes (grow_light.tscn instances: `Tube` meshes under their Visual).
func _set_grow_tubes(on: bool) -> void:
	for holder_path: NodePath in [^"Decor", ^"Hall"]: # M14 level: the grow hall's bars too
		var holder := get_node_or_null(holder_path)
		if holder == null:
			continue
		for c in holder.get_children():
			if not (c is Node3D) or not String(c.scene_file_path).ends_with("grow_light.tscn"):
				continue
			for t in c.find_children("Tube", "", true, false):
				if t is Node3D:
					(t as Node3D).visible = on


func _environment() -> Environment:
	var we := get_node_or_null(^"WorldEnvironment") as WorldEnvironment
	return we.environment if we != null else null


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


# --- M14 level: the grow hall, the loading dock, play areas, arrivals, gunfire lanes, routes ---------------------------

## The annexes in Room-local metres, floor to ceiling. Each box includes the SHARED_WALL it has in common with the
## main room (solid apart from its openings), so the three areas touch and a point in a doorway is inside one of them.
const HALL_AREA := AABB(Vector3(10.0, 0.0, -7.5), Vector3(12.0, 6.0, 15.0))
const DOCK_AREA := AABB(Vector3(-10.0, 0.0, 7.5), Vector3(15.0, 6.0, 8.1))
## Thickness of the walls between the main room and the annexes (two wall panels back to back).
const SHARED_WALL := 0.6
## The openings between the areas (Room-local): `center` on the floor in the middle of the wall, `axis` the way
## through it from the main room into the annex, clear `width` and `height`.
const DOORWAYS: Array[Dictionary] = [
	{"name": "pen_door", "center": Vector3(10.3, 0.0, -1.25), "axis": Vector3(1.0, 0.0, 0.0), "width": 2.0, "height": 2.5},
	{"name": "corridor_door", "center": Vector3(10.3, 0.0, 6.25), "axis": Vector3(1.0, 0.0, 0.0), "width": 2.0, "height": 2.5},
	{"name": "dock_passage", "center": Vector3(-5.0, 0.0, 7.8), "axis": Vector3(0.0, 0.0, 1.0), "width": 4.2, "height": 3.75},
]
## Where the workers stand after the van ride (Marker3Ds Arrival0..3 on the dock, feet + 0.2 m, facing the passage).
const ARRIVALS_PATH := ^"Arrivals"
## What a walking body cannot cross, as Room-local floor rectangles (x, z, width, depth). The first
## WALL_BLOCKER_COUNT are the solid walls between the areas (minus the doorways); then the pen's chain-link fence
## (minus the gate) and the Boss's booth with its counter. Trays, crates and the van are not listed: whoever walks a
## route still looks where it steps.
const WALK_BLOCKERS: Array[Rect2] = [
	Rect2(10.0, -7.5, 0.6, 5.25), Rect2(10.0, -0.25, 0.6, 5.5), Rect2(10.0, 7.25, 0.6, 0.25),
	Rect2(-10.0, 7.5, 2.9, 0.6), Rect2(-2.9, 7.5, 12.9, 0.6),
	Rect2(3.0, -5.05, 7.0, 0.1), Rect2(3.0, 4.95, 7.0, 0.1), Rect2(2.95, -5.0, 0.1, 2.5), Rect2(2.95, 2.5, 0.1, 2.5),
	Rect2(-2.12, -7.5, 4.24, 3.1),
]
const WALL_BLOCKER_COUNT := 5
## A route keeps this far from every blocker (a body is wider than a line), except where it starts or ends closer.
const ROUTE_MARGIN := 0.35
## The hand-made waypoint graph (Room-local x, z on the floor): the pen gate, the aisle between the pen's tray rows,
## both hall doorways, the corridor south of the pen, the open floor and the dock passage.
const ROUTE_POINTS: Array[Vector2] = [
	Vector2(2.1, 0.0),      # 0 outside the pen gate
	Vector2(3.9, 0.0),      # 1 inside the gate
	Vector2(3.9, -1.5),     # 2 the pen's west aisle, level with the gap between the tray rows
	Vector2(9.2, -1.35),    # 3 the pen's east aisle, at the pen door
	Vector2(11.6, -1.25),   # 4 the hall, inside the pen door
	Vector2(11.6, 6.25),    # 5 the hall, inside the corridor door
	Vector2(9.2, 6.25),     # 6 the corridor, at its door
	Vector2(7.6, 5.66),     # 7 the corridor south of the pen
	Vector2(2.3, 5.6),      # 8 the pen's south-west corner
	Vector2(-1.0, 3.2),     # 9 the open floor
	Vector2(-5.0, 6.3),     # 10 the main room, at the dock passage
	Vector2(-5.0, 9.4),     # 11 the dock, inside the passage
]
const ROUTE_EDGES: Array[Vector2i] = [
	Vector2i(0, 1), Vector2i(1, 2), Vector2i(2, 3), Vector2i(3, 4), Vector2i(4, 5), Vector2i(5, 6), Vector2i(6, 7),
	Vector2i(7, 8), Vector2i(8, 0), Vector2i(8, 9), Vector2i(0, 9), Vector2i(9, 10), Vector2i(0, 10), Vector2i(10, 11),
]
## Drive-by lanes, Room-local [from, to] at chest height. `from` is just inside the outer wall the shots come through
## (the dock's roller door and its two windows, the main room's west window), `to` is where the lane ends on a wall.
## Lanes 0, 1 and 3 leave the dock through the passage and cross the main room; the crate stacks on the dock stand in
## lanes 1 and 3, the pen's trays under lane 5.
const GUNFIRE_HEIGHT := 1.3
const GUNFIRE_LANES: Array = [
	[Vector3(-3.3, 1.3, 15.3), Vector3(-4.0, 1.3, -7.2)],   # 0 roller door -> passage -> the main room's north wall
	[Vector3(-2.5, 1.3, 15.3), Vector3(-9.7, 1.3, 1.5)],    # 1 roller door -> passage -> west wall (CrateMid in it)
	[Vector3(-1.1, 1.3, 15.3), Vector3(-0.6, 1.3, 8.4)],    # 2 roller door -> across the dock, past the van's rear
	[Vector3(-6.7, 1.3, 15.3), Vector3(-4.0, 1.3, -7.2)],   # 3 dock west window -> passage -> north wall (CrateWest)
	[Vector3(3.3, 1.3, 15.3), Vector3(-9.7, 1.3, 3.6)],     # 4 dock east window -> passage -> the main room's west wall
	[Vector3(-9.5, 1.3, -4.6), Vector3(9.7, 1.3, 0.6)],     # 5 west window -> the pen gate -> over GrowPlot3 / 4
]


## Arrival markers in order (Arrival0..Arrival3); empty when the room has none.
func get_arrival_points() -> Array[Marker3D]:
	var out: Array[Marker3D] = []
	var holder := get_node_or_null(ARRIVALS_PATH)
	if holder == null:
		return out
	for c in holder.get_children():
		if c is Marker3D:
			out.append(c)
	return out


## Where worker `index` stands after the van ride: on the loading dock behind the parked van, facing the passage
## into the building (wraps like get_spawn_transform; the spawn transform when the room has no arrival markers).
func get_arrival_transform(index: int) -> Transform3D:
	var pts := get_arrival_points()
	if pts.is_empty():
		return get_spawn_transform(index)
	var i := posmod(index, pts.size())
	var wraps := floori(float(absi(index)) / float(pts.size()))
	var t := _to_global(_room_transform_of(pts[i]))
	if wraps > 0:
		var side := 1.0 if wraps % 2 == 1 else -1.0
		t.origin += t.basis.x.normalized() * SPAWN_WRAP_OFFSET * side * ceilf(float(wraps) * 0.5)
	return t


## Every walkable room as an AABB (global space in the tree, Room-local otherwise): the main room (== get_bounds()),
## the grow hall, the loading dock.
func get_play_areas() -> Array[AABB]:
	var out: Array[AABB] = [get_bounds()]
	for local: AABB in [HALL_AREA, DOCK_AREA]:
		out.append(global_transform * local if is_inside_tree() else local)
	return out


## The box round all the play areas (it also covers the outside corner between the hall and the dock: ask
## contains_point() whether a point is on the floor).
func get_play_bounds() -> AABB:
	var areas := get_play_areas()
	var box := areas[0]
	for i in range(1, areas.size()):
		box = box.merge(areas[i])
	return box


## Index into get_play_areas() of the area `point` (global) is in: 0 main room, 1 grow hall, 2 loading dock, -1 none.
## Only x / z count, plus a little slack below the floor and above the ceiling.
func get_area_index(point: Vector3) -> int:
	if not point.is_finite():
		return -1
	var areas := get_play_areas()
	for i in areas.size():
		var a := areas[i]
		if point.x >= a.position.x and point.x <= a.end.x and point.z >= a.position.z and point.z <= a.end.z \
				and point.y >= a.position.y - 0.5 and point.y <= a.end.y + 0.5:
			return i
	return -1


## True when `point` (global) is in one of the play areas. With `margin` > 0 it must also be that far from the outside
## (a doorway between two areas is inside whatever the margin).
func contains_point(point: Vector3, margin: float = 0.0) -> bool:
	if get_area_index(point) < 0:
		return false
	if margin <= 0.0:
		return true
	for offset: Vector3 in [Vector3(margin, 0.0, 0.0), Vector3(-margin, 0.0, 0.0), Vector3(0.0, 0.0, margin), Vector3(0.0, 0.0, -margin)]:
		if get_area_index(point + offset) < 0:
			return false
	return true


## The openings between the areas in global space: {"name", "center" (floor, mid-wall), "axis" (unit, from the main
## room into the annex), "width", "height"}.
func get_doorways() -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for d: Dictionary in DOORWAYS:
		var g := d.duplicate()
		if is_inside_tree():
			g["center"] = global_transform * (d["center"] as Vector3)
			g["axis"] = (global_transform.basis * (d["axis"] as Vector3)).normalized()
		out.append(g)
	return out


## Drive-by lanes in global space: each {"from": Vector3, "to": Vector3} at chest height (see GUNFIRE_LANES). A shot
## travels from `from` towards `to` and stops at the first thing on LAYER_WORLD (a crate stack, the van, a fence).
func get_gunfire_lanes() -> Array:
	var out: Array = []
	for lane: Array in GUNFIRE_LANES:
		var from: Vector3 = lane[0]
		var to: Vector3 = lane[1]
		if is_inside_tree():
			from = global_transform * from
			to = global_transform * to
		out.append({"from": from, "to": to})
	return out


## True when a solid wall between two areas lies on the straight line from `a` to `b` (global), or the line leaves
## the play areas. The pen's fence and the booth do not count: this is "could they see each other without the mesh".
func is_wall_between(a: Vector3, b: Vector3) -> bool:
	if not a.is_finite() or not b.is_finite():
		return true
	var a2 := _floor_point(a)
	var b2 := _floor_point(b)
	for i in WALL_BLOCKER_COUNT:
		if _segment_hits_rect(a2, b2, WALK_BLOCKERS[i]):
			return true
	return not _stays_inside(a2, b2)


## The way round on foot from `from` to `to` (global): the points to walk through, ending at `to`. Empty when the
## straight line is already clear (no wall, fence or booth on it) or when there is no way (an end outside the play
## areas, or inside the booth). The points come from ROUTE_POINTS: through the doorways and the pen gate.
func get_route(from: Vector3, to: Vector3) -> PackedVector3Array:
	var out := PackedVector3Array()
	if not from.is_finite() or not to.is_finite():
		return out
	var a := _floor_point(from)
	var b := _floor_point(to)
	if not _local_in_areas(a) or not _local_in_areas(b) or _walk_clear(a, b):
		return out
	var n := ROUTE_POINTS.size()
	var start := n
	var goal := n + 1
	var pts: Array[Vector2] = []
	pts.assign(ROUTE_POINTS)
	pts.append(a)
	pts.append(b)
	var links: Array = []
	for i in n + 2:
		links.append([])
	for e in ROUTE_EDGES:
		(links[e.x] as Array).append(e.y)
		(links[e.y] as Array).append(e.x)
	for i in n:
		if _walk_clear(a, pts[i]):
			(links[start] as Array).append(i)
		if _walk_clear(pts[i], b):
			(links[i] as Array).append(goal)
	# Dijkstra over a dozen points.
	var dist: Array[float] = []
	var prev: Array[int] = []
	var done: Array[bool] = []
	dist.resize(n + 2)
	prev.resize(n + 2)
	done.resize(n + 2)
	dist.fill(INF)
	prev.fill(-1)
	done.fill(false)
	dist[start] = 0.0
	for _step in n + 2:
		var u := -1
		var best := INF
		for i in n + 2:
			if not done[i] and dist[i] < best:
				best = dist[i]
				u = i
		if u < 0 or u == goal:
			break
		done[u] = true
		for v: int in links[u]:
			var d := best + pts[u].distance_to(pts[v])
			if d < dist[v]:
				dist[v] = d
				prev[v] = u
	if not is_finite(dist[goal]):
		return out
	var chain: Array[int] = []
	var c := prev[goal]
	while c >= 0 and c != start:
		chain.push_front(c)
		c = prev[c]
	var floor_y := _to_global(Transform3D.IDENTITY).origin.y
	for i in chain:
		var p := _to_global(Transform3D(Basis.IDENTITY, Vector3(pts[i].x, 0.0, pts[i].y))).origin
		out.append(Vector3(p.x, floor_y, p.z))
	out.append(to)
	return out


## `point` (global) as Room-local floor coordinates (x, z).
func _floor_point(point: Vector3) -> Vector2:
	var p := global_transform.affine_inverse() * point if is_inside_tree() else point
	return Vector2(p.x, p.z)


func _local_in_areas(p: Vector2) -> bool:
	var b := AABB(Vector3(-INTERIOR_SIZE.x * 0.5, 0.0, -INTERIOR_SIZE.z * 0.5), INTERIOR_SIZE)
	for a: AABB in [b, HALL_AREA, DOCK_AREA]:
		if p.x >= a.position.x and p.x <= a.end.x and p.y >= a.position.z and p.y <= a.end.z:
			return true
	return false


## True when every point of the Room-local segment a-b is in a play area (sampled every 0.25 m).
func _stays_inside(a: Vector2, b: Vector2) -> bool:
	var steps := int(ceil(a.distance_to(b) / 0.25))
	for i in range(0, steps + 1):
		if not _local_in_areas(a.lerp(b, float(i) / float(maxi(steps, 1)))):
			return false
	return true


## True when nothing in WALK_BLOCKERS (grown by ROUTE_MARGIN, unless an end of the segment is that close itself) lies on
## the Room-local segment a-b and the segment stays inside the play areas.
func _walk_clear(a: Vector2, b: Vector2) -> bool:
	for r in WALK_BLOCKERS:
		var grown := r.grow(ROUTE_MARGIN)
		if grown.has_point(a) or grown.has_point(b):
			grown = r
		if _segment_hits_rect(a, b, grown):
			return false
	return _stays_inside(a, b)


## Segment a-b against an axis-aligned rectangle (Liang-Barsky).
static func _segment_hits_rect(a: Vector2, b: Vector2, r: Rect2) -> bool:
	var d := b - a
	var t0 := 0.0
	var t1 := 1.0
	for axis in 2:
		var lo := r.position[axis] - a[axis]
		var hi := r.end[axis] - a[axis]
		if absf(d[axis]) < 0.000001:
			if lo > 0.0 or hi < 0.0:
				return false
			continue
		var ta := lo / d[axis]
		var tb := hi / d[axis]
		t0 = maxf(t0, minf(ta, tb))
		t1 = minf(t1, maxf(ta, tb))
		if t0 > t1:
			return false
	return true


# --- M15 mayhem2: where the raid looks in from, where the collector stands ------------------------------------------

## The eye point just inside the roller door (a Marker3D at eye height) and where the collector stands (a Marker3D
## on the floor; he faces along its -Z). The fallbacks are Room-local and match the markers.
const RAID_DOOR_EYE_PATH := ^"Dock/RaidEye"
const RAID_DOOR_EYE_FALLBACK := Vector3(-2.5, 1.6, 15.0)
const COLLECTOR_SPOT_PATH := ^"Dock/CollectorSpot"
const COLLECTOR_SPOT_FALLBACK := Vector3(-2.5, 0.0, 13.6)
## The roll-up door on the dock's outer wall (whatever comes from outside comes through it).
const ROLLER_DOOR_PATH := ^"Decor/RollerDoor"
const ROLLER_DOOR_FALLBACK := Vector3(-2.5, 0.0, 15.6)
## How high above the floor a raid looks from.
const RAID_EYE_HEIGHT := 1.6
## The main room's eye point (Room-local floor position): the middle of the open floor.
const RAID_MIDDLE := Vector3(0.0, 0.0, 0.0)
## Index into get_play_areas() of the grow hall: the one room a raid never looks into.
const HALL_AREA_INDEX := 1


## Where a raid looks from, in the order it looks (global, RAID_EYE_HEIGHT above the floor): just inside the roller
## door, the dock passage, the middle of the main room. Events tests a LAYER_WORLD line from each to every bundle.
func get_raid_points() -> PackedVector3Array:
	var out := PackedVector3Array()
	var door := get_node_or_null(RAID_DOOR_EYE_PATH) as Marker3D
	out.append(_to_global(_room_transform_of(door)).origin if door != null else _to_global(Transform3D(Basis.IDENTITY, RAID_DOOR_EYE_FALLBACK)).origin)
	var passage := RAID_MIDDLE
	for d: Dictionary in DOORWAYS:
		if String(d["name"]) == "dock_passage":
			passage = d["center"]
	for local: Vector3 in [passage, RAID_MIDDLE]:
		out.append(_to_global(Transform3D(Basis.IDENTITY, Vector3(local.x, RAID_EYE_HEIGHT, local.z))).origin)
	return out


## Where the collector stands on the loading dock (global; origin on the floor, he faces along -Z).
func get_collector_spot() -> Transform3D:
	var spot := get_node_or_null(COLLECTOR_SPOT_PATH) as Marker3D
	if spot != null:
		return _to_global(_room_transform_of(spot))
	return _to_global(Transform3D(Basis.IDENTITY, COLLECTOR_SPOT_FALLBACK))


## Global floor point at the foot of the roller door (the sirens, the knock and the collector come from there).
func get_roller_door_position() -> Vector3:
	var door := get_node_or_null(ROLLER_DOOR_PATH) as Node3D
	if door != null:
		return _to_global(_room_transform_of(door)).origin
	return _to_global(Transform3D(Basis.IDENTITY, ROLLER_DOOR_FALLBACK)).origin


## True when `point` (global) is in the grow hall: out of a raid's sight whatever the doorways show of it.
func is_in_hall(point: Vector3) -> bool:
	return get_area_index(point) == HALL_AREA_INDEX
# --- end M15 mayhem2 ---------------------------------------------------------------------------------------------


# --- M18 radio: the radio shelf ------------------------------------------------------------------------------------
# The walkie-talkies (scripts/items/radio.gd) stand on a small steel-bracketed plank on the main room's north wall, in
# the north-west corner between the west wall and the wall phone: Decor/RadioShelf (the plank's top 1.0 m up, 0.3 m
# deep), its marker Decor/RadioShelf/Spot on the middle of the plank's top, turned so its -Z points at the room (a
# radio stood there with the marker's yaw shows its face to the room). The marker's own script
# (scripts/items/radio_spot.gd) has the host stock the shelf. It hangs on the wall above the floor plan: no cover
# layout, route, doorway, walk, lane, spawn or station front comes near it (tools/tests/radio_body.gd measures it).
# Nothing here may name an autoload or the Radio class: this script is a compile-time dependency of `-s` test scripts.

const RADIO_SPOT_PATH := ^"Decor/RadioShelf/Spot"
## Room-local point and yaw (degrees) of the marker, for a room without it.
const RADIO_SPOT_FALLBACK := Vector3(-9.0, 1.0, -7.34)
const RADIO_SPOT_FALLBACK_YAW := 180.0
## The radios stand along the marker's X, this far apart, never wider than RADIO_SHELF_USABLE in all.
const RADIO_SLOT_SPACING := 0.32
const RADIO_SHELF_USABLE := 0.72


## The middle of the radio shelf's top (global; a radio stood here with this basis faces the room).
func get_radio_spot() -> Transform3D:
	var spot := get_node_or_null(RADIO_SPOT_PATH) as Marker3D
	if spot != null:
		return _to_global(_room_transform_of(spot))
	return _to_global(Transform3D(Basis(Vector3.UP, deg_to_rad(RADIO_SPOT_FALLBACK_YAW)), RADIO_SPOT_FALLBACK))


## Where radio `index` of `count` stands on the shelf (global; spread evenly along the shelf, centred on the spot).
func get_radio_slot(index: int, count: int) -> Transform3D:
	var spot := get_radio_spot()
	var n := maxi(count, 1)
	var spacing := minf(RADIO_SLOT_SPACING, RADIO_SHELF_USABLE / float(n))
	var offset := (float(clampi(index, 0, n - 1)) - float(n - 1) * 0.5) * spacing
	return Transform3D(spot.basis, spot.origin + spot.basis.x.normalized() * offset)

# --- end M18 radio -------------------------------------------------------------------------------------------------


# --- M17 mayhem3 --- the wall phone ----------------------------------------------------------------------------------
## The wall phone that rings for Events.EVENT_PHONE (scenes/world/props/wall_phone.tscn, a WallPhone): on the main
## room's north wall, 1.5 m west of the debt board, its origin 1.15 m up the wall. No cover layout puts anything near it
## (the closest piece, layout 2's pallet stack against the same wall, stands 1 m east of its edge) and no route,
## walk or lane passes it.
const WALL_PHONE_PATH := ^"Decor/WallPhone"


## The wall phone, null when the room has none.
func get_wall_phone() -> Node3D:
	return get_node_or_null(WALL_PHONE_PATH) as Node3D
# --- end M17 mayhem3 -----------------------------------------------------------------------------------------------



# --- M16 variety: cover that moves --------------------------------------------------------------------------------
# The loose cover (the crates and pallets on the dock, in the main room and in the hall) stands differently each run
# (FRIENDSLOP 10.1, CONTRACTS "M16", "Variety"). The run's seed picks one of COVER_LAYOUTS on the host
# (GameState.get_run_cover(), synced in the state dictionary); every peer's Room moves its own nodes when it hears
# GameState.run_changed, and once at _ready for a peer whose state arrived first. The host only changes the layout
# while the game is WAITING (a reset or a test), so nothing moves under a running shift; a late joiner's Room takes
# the layout the moment its state arrives.
# The nodes are moved, never reparented, freed or given another collider. Layout 0 is the scene: its transforms are
# read from the nodes at _ready, and a layout only lists the nodes it moves.
# What every layout keeps (tools/tests/variety_body.gd proves it from the geometry, layout by layout): no piece in
# another or in anything solid, every raised piece resting on one below it, the route graph and the doorways clear by
# ROUTE_MARGIN, a worker's width free at every spawn, arrival, marker and station front and along the Boss's walks,
# for every drive-by lane a spot behind cover, on the dock a spot no raid eye sees.

## Every node a layout may move, by its path from the Room.
const COVER_NODES: Array[NodePath] = [
	^"Decor/PalletA", ^"Decor/PalletB", ^"Decor/CrateA", ^"Decor/CrateB", ^"Decor/CrateC",
	^"Hall/CrateNorthA", ^"Hall/CrateNorthB", ^"Hall/PalletSouth", ^"Hall/CrateSouth",
	^"Dock/CrateWestA", ^"Dock/CrateWestB", ^"Dock/CrateWestC", ^"Dock/CrateWestD", ^"Dock/CrateMidA", ^"Dock/CrateMidB",
	^"Dock/PalletEast", ^"Dock/CrateEast", ^"Dock/PalletWestA", ^"Dock/PalletWestB",
]
## A worker is clear of a cover piece when their feet are this far outside its footprint (the body's radius and a bit).
const COVER_BODY_MARGIN := 0.45
## The arrangements: node path (as in COVER_NODES) -> [Room-local position, yaw in degrees]. A node a layout does not
## name stands where the scene put it. Layout 0 names none: it is exactly the scene.
const COVER_LAYOUTS: Array[Dictionary] = [
	{},
	{
		"Dock/CrateMidA": [Vector3(-3.45, 0.0, 12.8), 4.0], "Dock/CrateMidB": [Vector3(-3.42, 0.9, 12.83), -9.0],
		"Dock/CrateWestA": [Vector3(0.45, 0.0, 12.7), 12.0], "Dock/CrateWestB": [Vector3(0.5, 0.9, 12.72), -6.0],
		"Dock/PalletEast": [Vector3(3.4, 0.0, 12.0), 90.0], "Dock/CrateEast": [Vector3(3.4, 0.15, 12.0), 15.0],
		"Dock/CrateWestC": [Vector3(4.35, 0.0, 13.3), -10.0],
		"Dock/PalletWestA": [Vector3(-9.3, 0.0, 9.5), 90.0], "Dock/PalletWestB": [Vector3(-9.25, 0.0, 12.9), 84.0],
		"Dock/CrateWestD": [Vector3(-9.4, 0.0, 11.2), 8.0],
		"Decor/PalletA": [Vector3(-8.6, 0.0, 6.9), 0.0], "Decor/PalletB": [Vector3(-8.6, 0.15, 6.9), 6.0],
		"Decor/CrateA": [Vector3(-8.6, 0.3, 6.85), -8.0], "Decor/CrateB": [Vector3(-9.4, 0.0, 4.5), 15.0],
		"Hall/CrateNorthA": [Vector3(21.2, 0.0, -3.4), 8.0], "Hall/CrateNorthB": [Vector3(21.2, 0.9, -3.35), -12.0],
		"Hall/PalletSouth": [Vector3(14.6, 0.0, 6.8), 0.0], "Hall/CrateSouth": [Vector3(14.6, 0.15, 6.8), 15.0],
	},
	{
		"Dock/CrateWestA": [Vector3(-6.15, 0.0, 10.7), -6.0], "Dock/CrateWestB": [Vector3(-6.12, 0.9, 10.72), 10.0],
		"Dock/CrateMidA": [Vector3(1.4, 0.0, 13.6), 14.0], "Dock/CrateMidB": [Vector3(1.43, 0.9, 13.6), -5.0],
		"Dock/PalletWestA": [Vector3(-8.7, 0.0, 12.7), 0.0], "Dock/PalletWestB": [Vector3(-8.7, 0.15, 12.7), 6.0],
		"Dock/CrateWestD": [Vector3(-8.7, 0.3, 12.7), 8.0], "Dock/CrateWestC": [Vector3(-8.2, 0.0, 13.85), 15.0],
		"Decor/PalletA": [Vector3(-6.0, 0.0, -6.85), 0.0], "Decor/PalletB": [Vector3(-6.0, 0.15, -6.85), 6.0],
		"Decor/CrateA": [Vector3(-6.0, 0.3, -6.8), 10.0], "Decor/CrateB": [Vector3(2.3, 0.0, 6.95), -8.0],
		"Hall/CrateNorthA": [Vector3(17.6, 0.0, 6.9), -8.0], "Hall/CrateNorthB": [Vector3(17.6, 0.9, 6.88), 12.0],
		"Hall/PalletSouth": [Vector3(21.0, 0.0, 3.0), 90.0], "Hall/CrateSouth": [Vector3(21.0, 0.15, 3.0), -15.0],
	},
	{
		"Dock/CrateMidA": [Vector3(-3.45, 0.0, 12.8), -5.0], "Dock/CrateMidB": [Vector3(-3.47, 0.9, 12.78), 9.0],
		"Dock/CrateWestA": [Vector3(-6.5, 0.0, 13.9), 8.0], "Dock/CrateWestB": [Vector3(-6.47, 0.9, 13.92), -12.0],
		"Dock/CrateEast": [Vector3(0.3, 0.0, 15.05), 0.0], "Dock/CrateWestC": [Vector3(1.5, 0.0, 14.45), 20.0],
		"Dock/PalletWestA": [Vector3(4.2, 0.0, 12.3), 90.0], "Dock/PalletWestB": [Vector3(4.2, 0.15, 12.3), 96.0],
		"Dock/CrateWestD": [Vector3(4.2, 0.3, 12.35), 8.0], "Dock/PalletEast": [Vector3(-9.2, 0.0, 10.4), 90.0],
		"Decor/PalletA": [Vector3(-4.6, 0.0, 3.4), 35.0], "Decor/PalletB": [Vector3(-4.6, 0.15, 3.4), 41.0],
		"Decor/CrateA": [Vector3(-4.6, 0.3, 3.4), 20.0],
		"Hall/CrateNorthA": [Vector3(13.0, 0.0, 6.9), 8.0], "Hall/CrateNorthB": [Vector3(13.0, 0.9, 6.9), -12.0],
	},
]

## The scene's own transform of every cover node (path -> Transform3D in its parent's space), read once.
var _cover_base: Dictionary = {}
var _cover_layout: int = 0


## The arrangement the cover stands in (an index into COVER_LAYOUTS; 0 = the scene's own).
func get_cover_layout() -> int:
	return _cover_layout


## Moves the loose cover into arrangement `index` of COVER_LAYOUTS (an index out of range is refused with a warning).
## Local and immediate: every peer calls it for the layout the host synced. Never reparents, frees or adds anything.
func apply_cover_layout(index: int) -> void:
	if index < 0 or index >= COVER_LAYOUTS.size():
		push_warning("Room.apply_cover_layout: no layout %d" % index)
		return
	_cover_capture()
	var layout: Dictionary = COVER_LAYOUTS[index]
	for path in COVER_NODES:
		var node := get_node_or_null(path) as Node3D
		if node == null or not _cover_base.has(path):
			continue
		var placed: Variant = layout.get(String(path))
		if placed is Array and (placed as Array).size() >= 2 and (placed as Array)[0] is Vector3:
			node.transform = Transform3D(Basis(Vector3.UP, deg_to_rad(float((placed as Array)[1]))), (placed as Array)[0])
		else:
			node.transform = _cover_base[path]
	_cover_layout = index


## Every cover node that exists, in COVER_NODES order.
func get_cover_nodes() -> Array[Node3D]:
	var out: Array[Node3D] = []
	for path in COVER_NODES:
		var node := get_node_or_null(path) as Node3D
		if node != null:
			out.append(node)
	return out


## The floor rectangle each cover piece stands on as it stands now (Room-local x / z; the box round its collider,
## so a turned crate's rectangle is a little larger than the crate). Same order as get_cover_nodes().
func get_cover_footprints() -> Array[Rect2]:
	var out: Array[Rect2] = []
	for node in get_cover_nodes():
		out.append(_cover_footprint(node))
	return out


## True when `point` (global) is on the floor plan within `margin` of a cover piece, whatever its height.
func is_in_cover(point: Vector3, margin: float = 0.0) -> bool:
	if not point.is_finite():
		return false
	var p := _floor_point(point)
	for rect in get_cover_footprints():
		if rect.grow(margin).has_point(p):
			return true
	return false


func _cover_ready() -> void:
	_cover_capture()
	# Looked up at runtime, like the hum: this script is a compile-time dependency of `-s` test scripts.
	var state := get_node_or_null(^"/root/GameState")
	if state == null or not state.has_signal(&"run_changed") or not state.has_method(&"get_run_cover"):
		return
	state.connect(&"run_changed", _on_run_changed)
	_on_run_changed()


func _cover_exit() -> void:
	var state := get_node_or_null(^"/root/GameState")
	if state != null and state.has_signal(&"run_changed") and state.is_connected(&"run_changed", _on_run_changed):
		state.disconnect(&"run_changed", _on_run_changed)


func _on_run_changed() -> void:
	if not is_inside_tree():
		return
	var state := get_node_or_null(^"/root/GameState")
	if state == null:
		return
	var index := int(state.call(&"get_run_cover"))
	if index != _cover_layout:
		apply_cover_layout(index)


## Reads the scene's transforms (once: before anything was moved).
func _cover_capture() -> void:
	if not _cover_base.is_empty():
		return
	for path in COVER_NODES:
		var node := get_node_or_null(path) as Node3D
		if node != null:
			_cover_base[path] = node.transform


## The Room-local floor rectangle round a cover node's box collider (a 0.9 m square round its origin without one).
func _cover_footprint(node: Node3D) -> Rect2:
	var xf := _room_transform_of(node)
	var half := Vector3(0.45, 0.45, 0.45)
	var centre := Vector3.ZERO
	var shape_node := node.get_node_or_null(^"Shape") as CollisionShape3D
	if shape_node != null and shape_node.shape is BoxShape3D:
		half = (shape_node.shape as BoxShape3D).size * 0.5
		centre = shape_node.position
	var bx := xf.basis.x * half.x
	var bz := xf.basis.z * half.z
	var ex := absf(bx.x) + absf(bz.x)
	var ez := absf(bx.z) + absf(bz.z)
	var c := xf * centre
	return Rect2(c.x - ex, c.z - ez, ex * 2.0, ez * 2.0)

# --- end M16 variety -----------------------------------------------------------------------------------------------


# --- M17 cart: where the hand truck stands --------------------------------------------------------------------------
# The hand truck (scripts/items/hand_truck.gd) stands at the Marker3D Dock/HandTruckSpot at the start of every shift:
# the loading dock's north-west corner, backed against the wall west of the dock passage, its plate (the truck's -Z)
# facing into the dock. The marker's own script (scripts/items/hand_truck_spot.gd) has the host put it there. The spot
# is clear of every COVER_LAYOUTS arrangement, of the route graph, the doorways, the arrivals and the collector's walk
# (tools/tests/cart_body.gd measures it). Nothing here may name an autoload or the HandTruck class: this script is a
# compile-time dependency of `-s` test scripts.

const HAND_TRUCK_SPOT_PATH := ^"Dock/HandTruckSpot"
## Room-local floor point and yaw (degrees) of the marker, for a room without it.
const HAND_TRUCK_SPOT_FALLBACK := Vector3(-8.0, 0.0, 8.6)
const HAND_TRUCK_SPOT_FALLBACK_YAW := 180.0


## Where the hand truck stands (global; the origin on the floor, the truck's plate towards the transform's -Z).
func get_hand_truck_spot() -> Transform3D:
	var spot := get_node_or_null(HAND_TRUCK_SPOT_PATH) as Marker3D
	if spot != null:
		return _to_global(_room_transform_of(spot))
	return _to_global(Transform3D(Basis(Vector3.UP, deg_to_rad(HAND_TRUCK_SPOT_FALLBACK_YAW)), HAND_TRUCK_SPOT_FALLBACK))

# --- end M17 cart ---------------------------------------------------------------------------------------------------
