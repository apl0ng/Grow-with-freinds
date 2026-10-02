class_name AlleyHoop
extends Node3D
## The hoop on the alley wall and the counter beside it (M15 alley agent; `Lobby/Hoop` in scenes/world/lobby.tscn,
## model art/models/alley_hoop.glb). FRIENDSLOP 9.4, CONTRACTS "The alley". Something to do while the late one is late:
## a ball thrown so that it FALLS through the ring counts one. No reward, nothing more.
##
## Frame of the node: origin on the wall at the ring's height, front = +Z (out of the wall). `Ring` (a Marker3D) is the
## ring's centre, RING_OUT out of the wall. The ring has no collider: a ball flies through it like through air; the
## wall behind it stops it like any wall.
##
## Server-authoritative. While the alley is in use the HOST looks at every flying ball once per physics frame, BEFORE
## ItemManager steps the same piece of the arc (process_physics_priority below ItemManager's): when the arc crosses
## the ring's plane downwards within SCORE_RADIUS of the ring's centre the host
##   - adds one to `count` and tells every peer (_rpc_sync: the label, a dull sound at the ring),
##   - lets the ball drop straight down from the ring (ItemManager.server_redirect_flight): it lands below the hoop
##     like any thrown item (and staggers whoever stands under it, the thrower excepted).
## A ball carried under the ring or one that misses the ring's inside counts nothing; a throw that went UP through the
## ring from below counts nothing on its way back down either (no standing under it and throwing straight up).
##
## Synced state (host -> everyone, reliable, on every change and to a late joiner on Net.peer_registered):
##   count   balls through the ring since the alley came into use (the Lobby resets it: server_reset)
## Clients only display.

## Every peer: the number on the counter changed.
signal count_changed(count: int)

## Mirrors tools/blender/models/alley.py: the ring's centre this far out of the wall, the ring's radius.
const RING_OUT: float = 0.47
const RING_RADIUS: float = 0.34
## A ball counts when its arc crosses the ring's plane this close to the centre (its middle is inside the ring).
const SCORE_RADIUS: float = 0.3
## The ball leaves the ring straight down from this far below its plane, at this speed (m/s).
const DROP_BELOW: float = 0.06
const DROP_SPEED: float = 0.6
## A hook taking a bag's weight is what a bent ring taking a flat ball sounds like (no name of its own yet).
const SCORE_SOUND: StringName = &"rack_hang"
const RING_PATH := ^"Ring"
const COUNTER_PATH := ^"Counter"
const COUNT_LABEL_PATH := ^"Counter/Count"
const CAPTION_LABEL_PATH := ^"Counter/Caption"
const CAPTION_TEXT := "IN"
## The number's type size (Label3D font pixels at 3 mm): two digits fill the plate, three need the smaller one.
const COUNT_FONT_SIZE: int = 110
const COUNT_FONT_SIZE_SMALL: int = 76

## Balls through the ring since the alley came into use (synced).
var count: int = 0

## HOST: Item instance id -> [flight serial, arc time already looked at, this throw went UP through the ring].
var _tracked: Dictionary = {}


func _ready() -> void:
	process_physics_priority = -10
	Net.peer_registered.connect(_on_peer_registered)
	var caption := get_node_or_null(CAPTION_LABEL_PATH) as Label3D
	if caption != null:
		caption.text = CAPTION_TEXT
		caption.modulate = Toon.TEXT_SUBTLE
		caption.outline_modulate = Toon.INK
	var label := get_node_or_null(COUNT_LABEL_PATH) as Label3D
	if label != null:
		label.modulate = Toon.CREAM
		label.outline_modulate = Toon.INK
	_refresh_label()


func _physics_process(_delta: float) -> void:
	if GameState.phase != GameState.Phase.WAITING or not Config.lobby_enabled or not _is_host():
		return
	var items := _items()
	if items == null:
		return
	for c in items.get_children():
		var ball := c as Item
		if ball == null or ball.item_type != Const.ITEM_BALL or not ball.is_flying() or ball.is_queued_for_deletion():
			continue
		_server_look(items, ball)


# --- queries (any peer) -----------------------------------------------------------------------------------------

## The ring's centre (global).
func get_ring_center() -> Vector3:
	var ring := get_node_or_null(RING_PATH) as Node3D
	if ring != null and ring.is_inside_tree():
		return ring.global_position
	var local := Vector3(0.0, 0.0, RING_OUT)
	return global_transform * local if is_inside_tree() else local


## The floor point a ball that went through drops towards (global; the ring's centre at the node's floor height).
func get_drop_point() -> Vector3:
	var c := get_ring_center()
	var lobby := get_parent() as Node3D
	c.y = lobby.global_position.y if lobby != null and lobby.is_inside_tree() else 0.0
	return c


## The text on the counter.
func get_count_text() -> String:
	var label := get_node_or_null(COUNT_LABEL_PATH) as Label3D
	return label.text if label != null else str(count)


## True when the straight piece a -> b (global) goes DOWN through the inside of the ring.
func is_through_ring(a: Vector3, b: Vector3) -> bool:
	if not a.is_finite() or not b.is_finite():
		return false
	var c := get_ring_center()
	if not (a.y > c.y and b.y <= c.y):
		return false
	var p := a.lerp(b, (a.y - c.y) / (a.y - b.y))
	return Vector2(p.x - c.x, p.z - c.z).length() <= SCORE_RADIUS


# --- host -------------------------------------------------------------------------------------------------------

## HOST: the counter back to zero (the Lobby calls it when the alley comes into use again).
func server_reset() -> void:
	if not _is_host():
		return
	_tracked.clear()
	if count != 0:
		_rpc_sync.rpc(0, false)


## HOST: `ball` went through. One more on the counter; the ball drops straight down from the ring.
func server_score(ball: Item) -> void:
	if not _is_host():
		return
	var items := _items()
	if items != null and ball != null and is_instance_valid(ball) and ball.is_flying():
		items.server_redirect_flight(ball, get_ring_center() + Vector3.DOWN * DROP_BELOW, Vector3.DOWN * DROP_SPEED)
	_rpc_sync.rpc(count + 1, true)


## HOST: the piece of `ball`'s arc flown since the last look (ItemManager looks at the same piece right after).
func _server_look(items: ItemManager, ball: Item) -> void:
	var id := ball.get_instance_id()
	var serial := ball.flight_serial
	var t0 := 0.0
	var void_throw := false
	var seen: Variant = _tracked.get(id)
	if seen is Array and int((seen as Array)[0]) == serial:
		t0 = float((seen as Array)[1])
		void_throw = bool((seen as Array)[2])
	var t1 := ball.get_flight_time()
	if t1 <= t0:
		return
	var a := items.to_global(ball.get_flight_point(t0))
	var b := items.to_global(ball.get_flight_point(t1))
	# Up through the ring from below: whatever this throw does on its way back down, it does not count.
	if is_through_ring(b, a):
		void_throw = true
	_tracked[id] = [serial, t1, void_throw]
	if not void_throw and is_through_ring(a, b):
		server_score(ball)


func _is_host() -> bool:
	return Net.is_host and is_inside_tree() and multiplayer.has_multiplayer_peer() and multiplayer.is_server()


func _items() -> ItemManager:
	return ItemManager.find(self)


## HOST: a late joiner gets the number (reliable, after its world exists: clients build it before joining).
func _on_peer_registered(peer_id: int) -> void:
	if not _is_host() or count == 0:
		return
	if peer_id == multiplayer.get_unique_id() or peer_id not in multiplayer.get_peers():
		return
	_rpc_sync.rpc_id(peer_id, count, false)


# --- every peer -------------------------------------------------------------------------------------------------

## Host -> every peer (the host through call_local): the number, and whether a ball just went through.
@rpc("authority", "call_local", "reliable")
func _rpc_sync(new_count: int, scored: bool) -> void:
	var old := count
	count = maxi(new_count, 0)
	_refresh_label()
	if scored and is_inside_tree():
		Sfx.play(SCORE_SOUND, get_ring_center())
		var counter := get_node_or_null(COUNTER_PATH)
		if counter != null:
			Juice.bounce(counter, 0.15)
	if count != old:
		count_changed.emit(count)


func _refresh_label() -> void:
	var label := get_node_or_null(COUNT_LABEL_PATH) as Label3D
	if label != null:
		label.text = str(count)
		label.font_size = COUNT_FONT_SIZE if count < 100 else COUNT_FONT_SIZE_SMALL
