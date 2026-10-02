class_name HandTruck
extends Item
## The dock's hand truck (M17 cart; scenes/items/hand_truck.tscn, model art/models/hand_truck.glb, CONTRACTS "M17",
## "Cart"). An ordinary item (Const.ITEM_HAND_TRUCK) that carries product bundles.
##
## Where it is. One stands at Room `Dock/HandTruckSpot` (scripts/items/hand_truck_spot.gd): the host spawns it there
## when the first shift starts and puts it back there at the start of every shift (out of anyone's hands, upright, its
## load KEPT: a bundle left on the floor stays there between shifts too). START OVER (GameState.game_reset) despawns it;
## the next shift's start spawns a fresh, empty one. Late joiners get it from the item spawner, its load from the
## synchronizer's spawn state.
##
## Carrying it. It is heavy (is_heavy(): Player.is_carrying_heavy() is true, so the holder walks at walk_speed x
## heavy_speed_factor and cannot sprint), loaded or empty. It can be dropped (Q), never thrown: the host refuses the
## throw (ItemManager.server_throw_item, one hook) and the holder's own client says "Too heavy to throw." (Interactor
## hook, refuse_throw()). While held it does not follow the hand socket: it stands on its wheels HELD_REACH in front
## of the holder, tipped back HELD_TILT_DEG about its axle, turned with the holder's body (not the look pitch).
##
## The load. `cargo` (synced, host-owned, spawn state on) is an Array of plain Dictionaries, bottom first:
##   {"strain_id": String, "amount": int, "cured": bool, "dry_left": float}
## everything a bundle carries that matters once it is off a rack (Product: strain, amount, cured, the drying it still
## needs). No item nodes ride on the truck: loading despawns the bundle through the item system and appends its data;
## unloading spawns a bundle with exactly that data. Every peer draws the load from `cargo`: product_bundle.glb
## instances stacked on the plate under `Visual/Load`, tinted like the product model (Toon.grade(strain colour),
## darker when cured); `LoadLabel` reads "2/4". Every assignment is a fresh Array, never an edit in place.
##   load     a worker HOLDING the truck presses E on a bundle that is not held by anyone else (on the floor, on a
##            rack: Product's "M17 cart" region routes the interaction here), or a worker HOLDING a bundle presses E
##            on the standing truck. Refused when full ("Truck's full.").
##   take     a worker with empty hands presses E on the LOAD of a standing truck: the top bundle spawns in their
##            hands. Where the crosshair meets the truck decides: on the bags it is "Take one", on the frame or the
##            handle above them (or anywhere on an empty truck) it is "Pick up". The client tells the host which (its
##            own request, _rpc_request_take); the host checks hands, load, range and the back room like any request.
##   chute    TurnInStation ("M17 cart" region): a worker holding the truck deposits every bundle, top first, one sale
##            each through the chute's own server_sell_item (the market, a buyer, cured, the job hooks, the stats, the
##            money float), as if each had been carried in by hand. If a sale ends the shift (the payment is met) the
##            rest stay on the truck, as a bundle still in someone's hands would.
##   raid     Events.server_raid_sweep asks server_raid_look() (one hook line): a truck the look sees (the rule for a
##            bundle: within RAID_RANGE, a clear world-layer line, not in the grow hall; a held truck is looked for at
##            its holder's chest, a standing one at the middle of its load) loses its whole load: Events.raid_took
##            once per bundle, the count joins the sweep's `taken`, and a worker holding it is written up once.
## The collector, the rat and the hostile plant never see the load: they deal in product ITEMS, and the load is not one.
## The truck itself is never taken by anything.

## Every peer: the load changed after the truck spawned (loaded, taken from, deposited, raided, cleared).
signal load_changed

const BUNDLE_SCENE := preload("res://art/models/product_bundle.glb")
## Never more than this many entries, whatever arrives over the wire.
const MAX_CARGO := 16
const REASON_FULL := "Truck's full."
const REASON_EMPTY := "Truck's empty."
const REASON_THROW := "Too heavy to throw."
const REASON_HANDS_FULL := "Hands full."
const REASON_CARRIED := "Someone's carrying that."
const REASON_NOT_PRODUCT := "Product only."
const REASON_GONE := "Nothing to load."
## Model numbers (tools/blender/models/hand_truck.py, Godot space): the plate's top, the middle of the plate, how far
## back the uprights lean per metre of height, the axle the truck tips about while pushed.
const PLATE_TOP := 0.018
const STACK_Z := -0.19
const LEAN_PER_M := 0.1 / 1.05
const AXLE := Vector3(0.0, 0.13, 0.17)
## Held pose: the axle this far in front of the holder's feet (on the floor), the truck tipped back this far.
const HELD_REACH := 1.1
const HELD_TILT_DEG := 25.0
## A bag on the plate: product_bundle.glb at this scale (0.3 x 0.26 x 0.25 m), a little bigger with the amount like
## the product's own (capped), each sitting this much into the one below.
const BAG_SCALE := 0.72
const BAG_HEIGHT := 0.357
const BAG_SCALE_PER_UNIT := 0.05
const BAG_MAX_GROWTH := 1.15
const BAG_SETTLE := 0.9
const BAG_OUTLINE := 0.012
const BAG_X: Array[float] = [0.02, -0.025, 0.015, -0.01]
const BAG_YAW_DEG: Array[float] = [8.0, -14.0, 21.0, -6.0]
## Aim: a crosshair on the truck that passes the load below its top plus this margin is on the bags ("Take one").
const LOAD_AIM_MARGIN := 0.08
const FX_LOAD := 1
const FX_TAKE := 2

## The load (see the header). Synced, host-owned; set it only through the server API.
var cargo: Array = []:
	set = _set_cargo

var _load_sig: String = "-"
var _load_height: float = 0.0

@onready var _load_node: Node3D = get_node_or_null(^"Visual/Load") as Node3D
@onready var _label: Label3D = get_node_or_null(^"LoadLabel") as Label3D


# --- reading the load (any peer) --------------------------------------------------------------------------------------

## The load, bottom first, as copies: {"strain_id": StringName, "amount": int, "cured": bool, "dry_left": float}.
func get_load() -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for e: Dictionary in cargo:
		out.append({"strain_id": StringName(String(e["strain_id"])), "amount": int(e["amount"]),
				"cured": bool(e["cured"]), "dry_left": float(e["dry_left"])})
	return out


func get_load_count() -> int:
	return cargo.size()


## How many bundles it takes (Config.balance.hand_truck_capacity).
static func get_capacity() -> int:
	return maxi(Config.balance.hand_truck_capacity, 0)


func is_full() -> bool:
	return cargo.size() >= get_capacity()


## Height of the stacked load above the plate (metres; 0 when empty), as drawn on this peer.
func get_load_height() -> float:
	return _load_height


## The middle of the load (global): where a worker looks to take a bundle off.
func get_load_center() -> Vector3:
	return global_transform * Vector3(0.0, PLATE_TOP + _load_height * 0.5, STACK_Z)


## Heavy whatever it carries: the holder walks at heavy_speed_factor and cannot sprint (Player.is_carrying_heavy).
func is_heavy() -> bool:
	return true


func get_display_name() -> String:
	return "Hand truck"


## "2/4".
func get_status_text() -> String:
	return "%d/%d" % [cargo.size(), get_capacity()]


## The truck the worker holds, or null.
static func held_by(player: Player) -> HandTruck:
	if player == null or not is_instance_valid(player) or not player.is_inside_tree():
		return null
	return player.get_held_item() as HandTruck


# --- spawn data -----------------------------------------------------------------------------------------------------

## props: {"cargo": String} (encode_cargo) or {"cargo": Array of entries}. Other keys are ignored.
func apply_props(props: Dictionary) -> void:
	var v: Variant = props.get("cargo", null)
	if v is String:
		cargo = decode_cargo(v)
	elif v is Array:
		cargo = v


## {} for an empty truck, {"cargo": "purple|2|1|0.00;budget|1|0|0.00"} for a loaded one (plain types only).
func get_props() -> Dictionary:
	return {} if cargo.is_empty() else {"cargo": encode_cargo(cargo)}


static func encode_cargo(entries: Array) -> String:
	var parts := PackedStringArray()
	for v in entries:
		var e := clean_entry(v)
		if not e.is_empty():
			parts.append("%s|%d|%d|%.2f" % [e["strain_id"], e["amount"], 1 if e["cured"] else 0, e["dry_left"]])
	return ";".join(parts)


static func decode_cargo(text: String) -> Array:
	var out: Array = []
	for part in text.split(";", false):
		var f := part.split("|")
		if f.size() < 4:
			continue
		var e := clean_entry({"strain_id": f[0], "amount": f[1].to_int(), "cured": f[2] == "1", "dry_left": f[3].to_float()})
		if not e.is_empty():
			out.append(e)
	return out


## One load entry in its synced form, or {} when `v` is not one (wrong types, no strain). Accepts what arrives over
## the wire, so nothing here trusts it.
static func clean_entry(v: Variant) -> Dictionary:
	if not v is Dictionary:
		return {}
	var d: Dictionary = v
	var strain: Variant = d.get("strain_id", "")
	if not (strain is String or strain is StringName):
		return {}
	var s := String(strain)
	if s == "" or s.length() > 64:
		return {}
	var amount: Variant = d.get("amount", 1)
	if not (amount is int or amount is float):
		return {}
	var n := float(amount)
	if not is_finite(n):
		return {}
	var dry: Variant = d.get("dry_left", 0.0)
	var left := float(dry) if (dry is float or dry is int) else 0.0
	if not is_finite(left):
		left = 0.0
	return {"strain_id": s, "amount": clampi(int(n), 1, 999), "cured": d.get("cured", false) == true,
			"dry_left": clampf(left, 0.0, 3600.0)}


# --- Interactable overrides -------------------------------------------------------------------------------------------

func get_prompt(player: Player) -> String:
	var held := _get_held_item_of(player) if player != null else null
	if held != null and held != self and held.item_type == Const.ITEM_PRODUCT:
		return get_load_prompt(held)
	if held == null and is_aimed_at_load(player):
		return "Take one (%s)" % get_status_text()
	return super(player)


func can_interact(player: Player) -> bool:
	return player != null and _get_denial(player) == ""


func get_denied_reason(player: Player) -> String:
	return _get_denial(player) if player != null else ""


## Local client (the Interactor): E on the bags of a standing truck asks for the top bundle (_rpc_request_take);
## anything else goes through the base request (_server_interact: load what is in hand, or pick the truck up).
func interact(player: Player) -> void:
	if player == null or not player.is_local():
		return
	if _get_held_item_of(player) == null and is_aimed_at_load(player):
		var reason := get_take_denial(player)
		if reason != "":
			Game.toast(reason, &"error")
			Sfx.play(&"error")
			return
		_rpc_request_take.rpc_id(Const.SERVER_PEER_ID)
		return
	super(player)


## SERVER (after the base range / back room / can_interact checks): a bundle in hand goes on the truck; with empty
## hands the truck is picked up.
func _server_interact(player: Player) -> void:
	var held := _get_held_item_of(player)
	if held != null and held != self and held.item_type == Const.ITEM_PRODUCT:
		server_load(held, player.peer_id)
		return
	super(player)


func _get_denial(player: Player) -> String:
	if is_flying():
		return REASON_IN_THE_AIR
	if holder_id == player.peer_id:
		return ""
	if is_held():
		return REASON_CARRIED
	var held := _get_held_item_of(player)
	if held == null:
		return ""
	if held.item_type == Const.ITEM_PRODUCT:
		return get_load_denial(held, player)
	return REASON_HANDS_FULL


## "Load Purple Haze x2 (1/4)": the prompt on a bundle (or on the truck, with the bundle in hand).
func get_load_prompt(bundle: Item) -> String:
	var what := bundle.get_display_name() if bundle != null and is_instance_valid(bundle) else "bundle"
	return "Load %s (%s)" % [what, get_status_text()]


## Why `bundle` cannot go on this truck for `player` ("" = it can). `player` may be null (a host-side load: the bundle
## must then be free, not in anyone's hands).
func get_load_denial(bundle: Item, player: Player) -> String:
	return _load_denial(bundle, player.peer_id if player != null and is_instance_valid(player) else 0)


## The same for the worker `who` (peer id; 0 = nobody: bundle and truck must both be free).
func _load_denial(bundle: Item, who: int) -> String:
	if bundle == null or not is_instance_valid(bundle) or bundle.is_queued_for_deletion():
		return REASON_GONE
	if bundle.item_type != Const.ITEM_PRODUCT:
		return REASON_NOT_PRODUCT
	if bundle.has_meta(TurnInStation.SOLD_META):
		return REASON_GONE
	if bundle.is_flying() or is_flying():
		return REASON_IN_THE_AIR
	if bundle.is_held() and bundle.holder_id != who:
		return REASON_CARRIED
	if is_held() and holder_id != who:
		return REASON_CARRIED
	if is_full():
		return REASON_FULL
	return ""


## Why `player` cannot take the top bundle off this truck ("" = they can).
func get_take_denial(player: Player) -> String:
	if is_flying():
		return REASON_IN_THE_AIR
	if is_held():
		return REASON_CARRIED
	if cargo.is_empty():
		return REASON_EMPTY
	if player != null and _get_held_item_of(player) != null:
		return REASON_HANDS_FULL
	return ""


## True when `player` (the LOCAL worker) has the crosshair on the bags of this standing, loaded truck (not on the
## frame or the handle above them). Always false for a remote worker: the host learns it from their request.
func is_aimed_at_load(player: Player) -> bool:
	if player == null or not is_instance_valid(player) or not player.is_inside_tree() or not player.is_local():
		return false
	var interactor := player.get_interactor()
	var cam := interactor.get_camera() if interactor != null else null
	if cam == null or not cam.is_inside_tree():
		return false
	return is_ray_on_load(cam.global_position, -cam.global_transform.basis.z)


## True when a ray from `from` along `dir` (global) meets the truck and passes the load below its top (plus
## LOAD_AIM_MARGIN), on a standing truck that carries something.
func is_ray_on_load(from: Vector3, dir: Vector3) -> bool:
	if cargo.is_empty() or is_held() or is_flying() or not is_inside_tree():
		return false
	var height := get_aim_height(from, dir)
	return is_finite(height) and height <= PLATE_TOP + _load_height + LOAD_AIM_MARGIN


## How high (the truck's local y) a ray from `from` along `dir` (global) passes the load: its height where it comes
## nearest the stack's upright axis (local x 0, z STACK_Z), as seen from any side. NAN when the ray misses the
## collider box.
func get_aim_height(from: Vector3, dir: Vector3) -> float:
	var shape_node := get_node_or_null(^"Collider/Shape") as CollisionShape3D
	var box := shape_node.shape as BoxShape3D if shape_node != null else null
	if box == null or not from.is_finite() or not dir.is_finite() or dir.length_squared() < 0.000001:
		return NAN
	var inv := shape_node.global_transform.affine_inverse()
	var o := inv * from
	var d := inv.basis * dir.normalized()
	var half := box.size * 0.5
	var t0 := 0.0
	var t1 := INF
	for axis in 3:
		if absf(d[axis]) < 0.000001:
			if o[axis] < -half[axis] or o[axis] > half[axis]:
				return NAN
			continue
		var ta := (-half[axis] - o[axis]) / d[axis]
		var tb := (half[axis] - o[axis]) / d[axis]
		t0 = maxf(t0, minf(ta, tb))
		t1 = minf(t1, maxf(ta, tb))
		if t0 > t1:
			return NAN
	var to_truck := global_transform.affine_inverse()
	var lo := to_truck * from
	var ld := (to_truck.basis * dir).normalized()
	var flat := ld.x * ld.x + ld.z * ld.z
	var t := 0.0
	if flat > 0.000001:
		t = maxf(-(lo.x * ld.x + (lo.z - STACK_Z) * ld.z) / flat, 0.0)
	return lo.y + ld.y * t


# --- server API ---------------------------------------------------------------------------------------------------------

## SERVER. Puts `bundle` (a product nobody else holds: on the floor, on a rack, or in `peer_id`'s own hands) on the
## truck: its data joins the top of the load and the bundle is despawned through the item system. A bundle taken off a
## rack keeps the exact drying it still needed. False (nothing changed) when full, when someone else holds the bundle
## or the truck, for anything that is not a live, unsold product, or on a client.
func server_load(bundle: Item, peer_id: int) -> bool:
	if not _require_server("server_load"):
		return false
	var items := get_manager()
	if items == null or not _is_live_here(items):
		return false
	if bundle == null or not is_instance_valid(bundle) or bundle.get_parent() != items:
		return false
	if _load_denial(bundle, maxi(peer_id, 0)) != "":
		return false
	var entry := clean_entry({"strain_id": bundle.get(&"strain_id"), "amount": bundle.get(&"amount"),
			"cured": bundle.get(&"cured"), "dry_left": _exact_dry_left(bundle)})
	if entry.is_empty():
		return false
	items.server_despawn_item(bundle)
	var next := cargo.duplicate()
	next.append(entry)
	cargo = next
	_rpc_cargo_fx.rpc(FX_LOAD)
	return true


## SERVER. Takes the top bundle off the truck and spawns it with exactly its data in `peer_id`'s hands (peer_id <= 0:
## on the floor in front of the plate). Null (nothing changed) when the truck is held, in the air or empty, when that
## worker's hands are full or they have no body here, or on a client.
func server_unload(peer_id: int) -> Item:
	if not _require_server("server_unload"):
		return null
	if is_held() or is_flying() or cargo.is_empty():
		return null
	var items := get_manager()
	if items == null or not _is_live_here(items):
		return null
	if peer_id > 0 and (items.get_player(peer_id) == null or items.get_held_by(peer_id) != null):
		return null
	var front := global_position - global_basis.z.normalized() * 0.75
	var product := _server_pop(items, maxi(peer_id, 0), Vector3(front.x, global_position.y, front.z))
	if product != null:
		_rpc_cargo_fx.rpc(FX_TAKE)
	return product


## SERVER. Takes the top bundle off the truck (held or not) and spawns it on the floor at `at` (global). Used by the
## chute to sell the load one bundle at a time. Null when the load is empty.
func server_unload_at(at: Vector3) -> Item:
	if not _require_server("server_unload_at"):
		return null
	var items := get_manager()
	if items == null or not _is_live_here(items) or cargo.is_empty():
		return null
	return _server_pop(items, 0, at if at.is_finite() else global_position)


## SERVER. Empties the truck without spawning anything (a raid took it all, a test). Returns how many bundles were on it.
func server_clear_load() -> int:
	if not _require_server("server_clear_load"):
		return 0
	var n := cargo.size()
	if n > 0:
		cargo = []
	return n


## SERVER. The one dock truck: put back at `spot` (global; the truck faces its -Z) out of anyone's hands, upright, its
## load kept; spawned there, empty, when there is none. Extra trucks (none should exist) are despawned. Returns it.
static func server_stand(items: ItemManager, spot: Transform3D) -> HandTruck:
	if items == null or not items.is_inside_tree() or not items.multiplayer.is_server():
		return null
	var truck: HandTruck = null
	for item in items.get_items_of_type(Const.ITEM_HAND_TRUCK):
		if truck == null and item is HandTruck:
			truck = item as HandTruck
		else:
			items.server_despawn_item(item)
	var yaw := spot.basis.get_euler().y
	if truck == null:
		truck = items.server_spawn_item(Const.ITEM_HAND_TRUCK, {}, spot.origin) as HandTruck
	else:
		items.server_drop_item(truck, spot.origin)
	if truck != null:
		truck.server_set_rest(truck.rest_position, Vector3(0.0, yaw, 0.0))
	return truck


## SERVER. Despawns every hand truck (START OVER). Returns how many.
static func server_despawn_all(items: ItemManager) -> int:
	if items == null or not items.is_inside_tree() or not items.multiplayer.is_server():
		return 0
	var n := 0
	for item in items.get_items_of_type(Const.ITEM_HAND_TRUCK):
		items.server_despawn_item(item)
		n += 1
	return n


## SERVER, from Events.server_raid_sweep (one hook line, before the look is counted): every loaded truck the raid sees
## from `eye` (global) loses its whole load. Per bundle: an entry "<truck>/load<n>" in out["taken"], the holder in
## out["holders"] when somebody holds the truck, Events' tally, and Events.raid_took on every peer; the holder is
## written up once (Const.WRITE_UP_RAID, the usual cooldown). Returns how many bundles were taken.
static func server_raid_look(eye: Vector3, out: Dictionary) -> int:
	var w: World = Game.world
	if w == null or not is_instance_valid(w) or not w.is_inside_tree() or w.items == null or w.room == null:
		return 0
	if not eye.is_finite() or not w.multiplayer.is_server():
		return 0
	var room: Room = w.room
	var space := w.get_world_3d().direct_space_state
	var taken: Array = out.get("taken", [])
	var holders: Array = out.get("holders", [])
	var total := 0
	for item in w.items.get_items_of_type(Const.ITEM_HAND_TRUCK):
		var truck := item as HandTruck
		if truck == null or truck.cargo.is_empty():
			continue
		var target: Vector3 = Events._bundle_position(truck, w)
		if not target.is_finite() or not room.contains_point(target) or room.is_in_hall(target):
			continue
		if truck.holder_id == 0:
			target += Vector3.UP * maxf(Events.RAID_ITEM_LIFT, PLATE_TOP + truck.get_load_height() * 0.5)
		if not (eye.distance_to(target) <= Events.RAID_RANGE):
			continue
		if not space.intersect_ray(PhysicsRayQueryParameters3D.create(eye, target, Const.LAYER_WORLD)).is_empty():
			continue
		var holder: int = truck.holder_id
		var count := truck.server_clear_load()
		for i in count:
			var item_name := "%s/load%d" % [truck.name, i + 1]
			taken.append(item_name)
			Events._raid_taken += 1
			if holder != 0:
				holders.append(holder)
			Events._rpc_raid_took.rpc(item_name, holder, target)
		if holder != 0 and count > 0 and Events._can_write_up(holder):
			Events._write_up(holder, Const.WRITE_UP_RAID)
		total += count
	return total


## Local client, before a throw request goes out (Interactor hook): true for the hand truck, with the toast and the
## error blip ("Too heavy to throw."). The host refuses the throw anyway (ItemManager.server_throw_item).
static func refuse_throw(item: Item) -> bool:
	if item == null or not is_instance_valid(item) or item.item_type != Const.ITEM_HAND_TRUCK:
		return false
	Game.toast(REASON_THROW, &"error")
	Sfx.play(&"error")
	return true


# --- requests ----------------------------------------------------------------------------------------------------------

## Any peer -> host: take the top bundle off this standing truck into the sender's hands. Validated like the base
## request (a body on the floor, not in the back room, within reach) plus get_take_denial().
@rpc("any_peer", "call_local", "reliable")
func _rpc_request_take() -> void:
	if not multiplayer.is_server():
		return
	var sender := multiplayer.get_remote_sender_id()
	if sender == 0:
		sender = Const.SERVER_PEER_ID
	var player: Player = Game.get_player(sender)
	if player == null:
		return
	if GameState.is_in_backroom(sender):
		_rpc_denied.rpc_id(sender, REASON_BACKROOM)
		return
	var max_dist: float = Config.balance.interact_distance + server_range_slack
	if not (player.global_position.distance_to(global_position) <= max_dist):
		_rpc_denied.rpc_id(sender, "Too far.")
		return
	var reason := get_take_denial(player)
	if reason != "":
		_rpc_denied.rpc_id(sender, reason)
		return
	server_unload(sender)


## Every peer: a bundle went on (FX_LOAD) or came off (FX_TAKE) the truck.
@rpc("authority", "call_local", "reliable")
func _rpc_cargo_fx(kind: int) -> void:
	if not is_inside_tree():
		return
	var at := global_position + Vector3.UP * 0.4
	Sfx.play(&"truck_load" if kind == FX_LOAD else &"pickup", at)
	Juice.bounce(get_visual(), 0.18)


# --- held pose -----------------------------------------------------------------------------------------------------------

## Where the truck is while `holder` pushes it (global): on its wheels HELD_REACH in front of their feet, tipped back
## HELD_TILT_DEG about the axle towards them, turned with their body.
static func get_held_transform(holder: Node3D) -> Transform3D:
	var yaw := holder.global_rotation.y
	var turn := Basis(Vector3.UP, yaw)
	var tipped := turn * Basis(Vector3.RIGHT, deg_to_rad(HELD_TILT_DEG))
	var axle := holder.global_position + turn * (Vector3.FORWARD * HELD_REACH) + Vector3.UP * AXLE.y
	return Transform3D(tipped, axle - tipped * AXLE)


## The base follows the hand socket (and so the look pitch); a hand truck stays on its wheels in front of the body.
func _follow_holder() -> void:
	var holder := get_holder()
	if holder == null:
		_set_hidden_without_holder(true)
		_update_view_model(null)
		return
	_set_hidden_without_holder(false)
	_update_view_model(holder)
	var xf := get_held_transform(holder)
	if xf.origin.is_finite():
		global_transform = xf
	if _view_model_owner_id != 0:
		holder.sync_view_model()


# --- internals -------------------------------------------------------------------------------------------------------------

func _set_cargo(value: Array) -> void:
	var clean: Array = []
	if value is Array:
		for v in value:
			if clean.size() >= MAX_CARGO:
				break
			var e := clean_entry(v)
			if not e.is_empty():
				clean.append(e)
	if clean == cargo:
		return
	cargo = clean
	if not is_node_ready():
		return
	_notify_props_changed()
	load_changed.emit()


func _refresh_visuals() -> void:
	_build_load()
	if _label != null:
		_label.text = get_status_text()
		_label.visible = not is_held()


## Rebuilds the bags under Visual/Load when the load changed (cheap otherwise).
func _build_load() -> void:
	var sig := encode_cargo(cargo)
	if sig == _load_sig:
		return
	_load_sig = sig
	if _load_node == null:
		return
	for c in _load_node.get_children():
		_load_node.remove_child(c)
		c.queue_free()
	var y := PLATE_TOP
	for i in cargo.size():
		var e: Dictionary = cargo[i]
		var s := BAG_SCALE * minf(1.0 + BAG_SCALE_PER_UNIT * float(int(e["amount"]) - 1), BAG_MAX_GROWTH)
		var bag := BUNDLE_SCENE.instantiate() as Node3D
		bag.name = "Bag%d" % (i + 1)
		var turn := Basis(Vector3.UP, deg_to_rad(BAG_YAW_DEG[i % BAG_YAW_DEG.size()]))
		bag.transform = Transform3D(turn * Basis.from_scale(Vector3.ONE * s),
				Vector3(BAG_X[i % BAG_X.size()], y, STACK_Z + LEAN_PER_M * y))
		var model := bag as Toonify
		if model != null:
			model.tint = bag_color(e)
			model.outline_width = BAG_OUTLINE
		_load_node.add_child(bag)
		y += BAG_HEIGHT * s * BAG_SETTLE
	_load_height = y - PLATE_TOP if not cargo.is_empty() else 0.0
	if _view_model_owner_id != 0:
		_apply_view_model_layers(true) # bags added while the local holder draws the truck in the view model


## The colour a bag of this entry shows (Product's own: the graded strain colour, darker when cured).
static func bag_color(entry: Dictionary) -> Color:
	var def: SeedDef = Config.balance.get_seed(StringName(String(entry.get("strain_id", ""))))
	var c := Toon.grade(def.color if def != null else Product.UNKNOWN_COLOR)
	return c.darkened(Product.CURED_DARKEN) if entry.get("cured", false) == true else c


## Pops the top entry and spawns it as a bundle (in `peer_id`'s hands, or on the floor at `at` for 0).
func _server_pop(items: ItemManager, peer_id: int, at: Vector3) -> Item:
	var entry: Dictionary = cargo.back()
	var props := {"strain_id": String(entry["strain_id"]), "amount": int(entry["amount"])}
	if bool(entry["cured"]):
		props["cured"] = true
	if float(entry["dry_left"]) > 0.0:
		props["dry_left"] = float(entry["dry_left"])
	var product := items.server_spawn_item(Const.ITEM_PRODUCT, props, at, peer_id)
	if product == null:
		return null
	var next := cargo.duplicate()
	next.pop_back()
	cargo = next
	return product


## A bundle hanging on a rack: the exact drying it still needs (the rack's own clock; the synced value is rounded up).
func _exact_dry_left(bundle: Item) -> float:
	var left := float(bundle.get(&"dry_left")) if bundle.get(&"dry_left") != null else 0.0
	if bundle.get(&"rack") == true and bundle.get(&"cured") != true and is_inside_tree():
		for n in get_tree().get_nodes_in_group(Const.GROUP_DRYING_RACKS):
			var rack := n as DryingRack
			if rack != null:
				left = minf(left, rack.get_exact_left(bundle))
	return left


func _is_live_here(items: ItemManager) -> bool:
	return is_instance_valid(self) and not is_queued_for_deletion() and get_parent() == items


func _require_server(what: String) -> bool:
	if is_inside_tree() and multiplayer.has_multiplayer_peer() and multiplayer.is_server():
		return true
	push_error("HandTruck.%s called on a client" % what)
	return false
