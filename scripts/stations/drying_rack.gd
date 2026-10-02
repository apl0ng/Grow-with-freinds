class_name DryingRack
extends Interactable
## A rail with three hooks (scenes/stations/drying_rack.tscn, owner: loop agent, M14). Free-standing: the scene origin
## is on the floor under the middle hook, front = local +Z (the side the bundles hang on).
##
## A worker holding a product bundle presses E ("Hang to dry"): the base Interactable flow validates range and
## can_interact() on the host, then _server_interact -> server_hang(player):
##   - the first free hook is picked (Hooks/Hook1..3, left to right as seen from the front);
##   - the bundle's synced `dry_left` becomes Config.balance.cure_sec (or stays what an earlier, interrupted hang left)
##     and `rack` true, THEN the host puts the item on the hook with ItemManager.server_drop_item (holder cleared,
##     resting upright exactly at the hook, turned to the rack's front). `rack` is set first so the release plays
##     `rack_hang` on every peer instead of the floor thud (Product._play_holder_effects).
## While the shift is PLAYING the host counts the hanging time down (tick): the exact clock lives here per bundle, the
## synced `Product.dry_left` is written in SYNC_STEP steps (two small reliable packets a second per bundle, not a
## stream). At zero the bundle is `cured` (sound, darker tint, the label reads "Cured": Product's setters, every
## peer). A hanging bundle is an ordinary floor item: anyone can take it. The moment it leaves its hook (picked up,
## despawned, moved) the host clears `rack` and writes the exact remainder into `dry_left`: it must hang again for
## the rest and never cures anywhere else.
##
## Nothing about the rack itself is synced. Which hook holds what is derived on every peer from the products'
## own synced state (`rack`, holder, rest position), so the prompt ("Rack is full.") can never disagree with what
## hangs there, and a late joiner needs no extra state.

## HOST: a bundle was hung on `hook` (0-based) by `by_peer`.
signal bundle_hung(hook: int, by_peer: int)
## HOST: the bundle on `hook` finished curing.
signal bundle_cured(hook: int)

const HOOK_COUNT: int = 3
const PROMPT_HANG := "Hang to dry"
const REASON_FULL := "Rack is full."
const REASON_EMPTY_HANDS := "Nothing to hang."
const REASON_NOT_PRODUCT := "Product only."
const REASON_CURED := "Already cured."
const REASON_UNAVAILABLE := "Rack's jammed."
## A bundle resting within this distance of a hook hangs on it (the host places it exactly there).
const HOOK_SNAP: float = 0.12
## The synced Product.dry_left moves in steps of this many seconds while a bundle hangs.
const SYNC_STEP: float = 0.5
const HOOKS_PATH := ^"Hooks"

## HOST: Product instance id -> exact seconds of hanging still needed, for the bundles on this rack's hooks.
var _exact: Dictionary = {}


func _enter_tree() -> void:
	super()
	add_to_group(Const.GROUP_DRYING_RACKS)


func _process(delta: float) -> void:
	# multiplayer.is_server() alone is true on a client that has not connected yet: pair it with Net.is_host.
	if Net.is_host and GrowPlot.is_server_peer(self):
		tick(delta)


# --- queries (any peer) -----------------------------------------------------------------------------------------------

## Where a bundle on `hook` (0-based) rests, in world space: the Hooks/Hook<n> marker.
func get_hook_position(hook: int) -> Vector3:
	var marker := get_node_or_null(NodePath("%s/Hook%d" % [HOOKS_PATH, hook + 1])) as Node3D
	if marker == null:
		return global_position + Vector3.UP * 1.1
	return marker.global_position


## The bundle hanging on `hook`, or null: a product with `rack` set that rests there (not held, not in the air).
func get_hook_item(hook: int) -> Item:
	if hook < 0 or hook >= HOOK_COUNT or not is_inside_tree():
		return null
	var items := ItemManager.find(self)
	if items == null:
		return null
	var at := get_hook_position(hook)
	for item in items.get_items_of_type(Const.ITEM_PRODUCT):
		if item.get(&"rack") == true and _rests_at(item, at):
			return item
	return null


## The first hook nothing hangs on (0-based), -1 when the rack is full.
func get_free_hook() -> int:
	for hook in HOOK_COUNT:
		if get_hook_item(hook) == null:
			return hook
	return -1


func is_full() -> bool:
	return get_free_hook() < 0


## How many bundles hang here right now.
func get_hung_count() -> int:
	var n := 0
	for hook in HOOK_COUNT:
		if get_hook_item(hook) != null:
			n += 1
	return n


## HOST: the exact hanging time `item` still needs on this rack (its synced dry_left when this rack does not track it).
func get_exact_left(item: Item) -> float:
	if item == null or not is_instance_valid(item):
		return 0.0
	return float(_exact.get(item.get_instance_id(), _dry_left_of(item)))


# --- Interactable overrides -------------------------------------------------------------------------------------------

func get_prompt(_player: Player) -> String:
	return PROMPT_HANG


func can_interact(player: Player) -> bool:
	return player != null and _get_denial(player) == ""


func get_denied_reason(player: Player) -> String:
	return _get_denial(player) if player != null else ""


func _server_interact(player: Player) -> void:
	server_hang(player)


# --- server API -------------------------------------------------------------------------------------------------------

## SERVER. Hangs the bundle `player` holds on the first free hook. False (nothing changed) without a product in hand,
## for a bundle that is already cured, with every hook taken, or without an ItemManager.
func server_hang(player: Player) -> bool:
	if not GrowPlot.is_server_peer(self):
		push_error("DryingRack.server_hang called on a client")
		return false
	if player == null or not is_instance_valid(player) or not player.is_inside_tree():
		return false
	if _get_denial(player) != "":
		return false
	var items := ItemManager.find(self)
	var item := GrowPlot.get_held_item_of(player)
	var hook := get_free_hook()
	if items == null or item == null or hook < 0:
		return false
	var left := _dry_left_of(item)
	if left <= 0.0:
		left = maxf(Config.balance.cure_sec, 0.0)
	# `rack` first (see the header), then the release that rests the bundle on the hook, turned to the rack's front.
	item.set(&"dry_left", _stepped(left))
	item.set(&"rack", true)
	items.server_drop_item(item, get_hook_position(hook))
	item.server_set_rest(item.rest_position, Vector3(0.0, global_rotation.y, 0.0))
	_exact[item.get_instance_id()] = left
	bundle_hung.emit(hook, player.peer_id)
	return true


## Host step, called every frame by _process; public so tests can drive the clock. Bundles that left their hook are
## released first (always); the countdown itself only runs while the shift is PLAYING.
func tick(delta: float) -> void:
	if not GrowPlot.is_server_peer(self):
		return
	var on_hooks: Dictionary = {}
	for hook in HOOK_COUNT:
		var item := get_hook_item(hook)
		if item == null:
			continue
		var key := item.get_instance_id()
		on_hooks[key] = true
		if not _exact.has(key):
			_exact[key] = _dry_left_of(item) # a bundle that was put here with `rack` already set (spawn props)
		if item.get(&"cured") == true or delta <= 0.0 or not GameState.is_playing():
			continue
		var left := maxf(float(_exact[key]) - delta, 0.0)
		_exact[key] = left
		if left <= 0.0:
			item.set(&"dry_left", 0.0)
			item.set(&"cured", true)
			bundle_cured.emit(hook)
		else:
			var shown := _stepped(left)
			if shown != _dry_left_of(item):
				item.set(&"dry_left", shown)
	for key: int in _exact.keys():
		if on_hooks.has(key):
			continue
		var left: float = _exact[key]
		_exact.erase(key)
		var gone := instance_from_id(key) as Item
		if gone == null or not is_instance_valid(gone) or gone.is_queued_for_deletion():
			continue # sold, despawned by a reset
		if gone.get(&"rack") == true and _on_any_hook(gone):
			continue # taken off and hung on another rack within one frame: that rack owns it now
		# Taken off (picked up, thrown, moved): no longer on a rack, and the exact remainder stays with the bundle.
		if gone.get(&"cured") != true:
			gone.set(&"dry_left", left)
		gone.set(&"rack", false)


# --- internals --------------------------------------------------------------------------------------------------------

func _get_denial(player: Player) -> String:
	var item := GrowPlot.get_held_item_of(player)
	if item == null:
		return REASON_EMPTY_HANDS
	if item.item_type != Const.ITEM_PRODUCT:
		return REASON_NOT_PRODUCT
	if item.get(&"cured") == true:
		return REASON_CURED
	if is_full():
		return REASON_FULL
	return ""


## True if `item` rests on a hook of any rack in the world.
func _on_any_hook(item: Item) -> bool:
	for n in get_tree().get_nodes_in_group(Const.GROUP_DRYING_RACKS):
		var other := n as DryingRack
		if other == null or not other.is_inside_tree():
			continue
		for hook in HOOK_COUNT:
			if _rests_at(item, other.get_hook_position(hook)):
				return true
	return false


static func _rests_at(item: Item, at: Vector3) -> bool:
	if item == null or not is_instance_valid(item) or item.is_queued_for_deletion() or not item.is_inside_tree():
		return false
	if item.is_held() or item.is_flying():
		return false
	return item.global_position.distance_to(at) <= HOOK_SNAP


static func _dry_left_of(item: Item) -> float:
	var v: Variant = item.get(&"dry_left")
	return float(v) if v is float or v is int else 0.0


## The synced value for an exact remainder: rounded UP to the next SYNC_STEP (a bundle never reads drier than it is).
static func _stepped(left: float) -> float:
	return ceilf(left / SYNC_STEP) * SYNC_STEP if left > 0.0 else 0.0
