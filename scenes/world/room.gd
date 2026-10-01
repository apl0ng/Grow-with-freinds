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
##   south (z+) : TurnInStation at (0, 0, 5.8) facing -Z, the chained + beamed roller door, CLOCK IN, pallets
##   ceiling    : 6 m, steel beams, pipes, a cable tray, drop-down pendant lamps and a black hole with dust
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
	"FuseBox",
]
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


func _exit_tree() -> void:
	_set_hum(false)


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
	var decor := get_node_or_null(^"Decor")
	if decor == null:
		return
	for c in decor.get_children():
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
