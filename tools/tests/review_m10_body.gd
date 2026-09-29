extends "res://tools/tests/qa_base.gd"
## M11 review of the M10 friendslop pass (review agent): adversarial regression suite on a single headless host
## with two fake workers (Bob, Chloe: spawned without an owning peer, so the SERVER side runs on them directly).
##   godot --headless --path . -s res://tools/tests/run_test.gd -- --body=res://tools/tests/review_m10_body.gd --port=7948 --round-sec=900
## Server handlers are called directly (sender 0 = this peer, the host's own worker), exactly like a client's
## request would arrive. Every section pins a bug that was demonstrated on the integrated M10 commit (143b633):
##   R1  the server accepted gameplay from a worker in the back room (pick-ups, deposits, purchases, the fuse box,
##       drops): a modified client walks out of the back room (movement is client-authoritative) and keeps working.
##       Now every request from a back-room worker is refused with "You're in the back room."
##   R2  honest client: the supply window stayed open OVER the back-room overlay (the BackRoomSpot is 2 m from the
##       counter, the window closes at 4 m) and kept buying. It shuts when its worker is sent to the back room.
##   R3  honest client: Escape was dead for the whole back-room stay (the pause menu refused to open under any UI lock),
##       so a worker could not leave the game for 30 s. The pause menu opens over the back-room lock.
##   R4  a worker who disconnected while in the back room dropped their item INSIDE the booth (closed off by the
##       partitions): a watering can was lost for the rest of the shift. It goes back to their spawn point.
##       The Boss also said "Back to work, X." to a worker who had just left.
##   R5  no stagger limit: a worker could be kept stunned 100 % of the time (rapid re-throws from 1.5 m, or two
##       shovers taking turns), with no counter. A staggered worker is immune for STAGGER_IMMUNITY_SEC after the stun.
##   R6  a shove needed no line of sight: a modified client shoved through the grow-area fence. A LAYER_WORLD ray
##       between the chests must be clear.
##   R8  hostile inputs on every new server handler (oversized / flooded chat, voice frames, non-finite vectors,
##       absurd throws, NaN poses, out-of-range requests): bounded cost, sane state, no engine errors.
##   R9  churn: disconnects mid-flight / while spectated / during an inspection; RETRY and return_to_menu during every
##       event and from the back room: no freed-instance access, no stuck UI lock, no leaked Rat / SpectatorCamera /
##       VoiceOut / PingMarker nodes, no orphans.
##   R10 copy audit of every new user-facing string (no "!", no cheer).  R11 performance smells (bounded costs).
##   R12 the back room in the last second of a shift: released at the shift end, the lock handed to the end screen.
## Every engine/script error fails the run unless announced (qa_base.gd).

const BOB := 2
const CHLOE := 3
const REASON_BACKROOM_TEXT := "You're in the back room."   # Interactable.REASON_BACKROOM (literal: runs on old code too)
const CHEER_WORDS: PackedStringArray = ["nice", "great", "awesome", "congrat", "well done", "good job", "yay", "woo", "amazing", "wonderful"]

var port: int = 7948
var world: World
var items: ItemManager
var room: Room
var hud: HUD
var me: Player
var bob: Player
var chloe: Player
var _staggers: Array = []     # [target peer, by_peer]


func _run() -> void:
	_label = "review_m10"
	port = port_arg(7948)
	await get_tree().process_frame
	Config.growth_speed_override = 0.0
	if not await _host():
		finish(); return
	await _r1_backroom_server_rule()
	await _r2_backroom_supply_window()
	await _r3_backroom_pause_menu()
	await _r4_backroom_stranded_item()
	await _r5_stagger_lock()
	await _r6_shove_line_of_sight()
	await _r8_hostile_inputs()
	await _r9_churn()
	_r10_copy_audit()
	await _r11_perf()
	await _r12_backroom_at_shift_end()
	step("leave")
	Game.return_to_menu()
	await wait_frames(4)
	_check_clean("final")
	finish()


# =================================================================================================== helpers

func _host() -> bool:
	if get_tree().get_first_node_in_group(Game.MENU_GROUP) == null:
		get_tree().root.add_child((load(Game.MENU_SCENE_PATH) as PackedScene).instantiate())
		await wait_frames(2)
	if not check(Game.start_host("Reviewer", port) == OK, "hosting on port %d" % port):
		return false
	if not await wait_until(func() -> bool: return Game.local_player != null and items_of(Const.ITEM_WATERING_CAN).size() == Config.balance.starting_watering_cans, 6.0, "world, player, starting cans"):
		return false
	world = Game.world
	items = world.items
	room = world.room
	hud = world.get_node("HUD") as HUD
	me = Game.local_player
	get_tree().root.size = Vector2i(1280, 720)
	_staggers.clear()
	me.staggered.connect(func(by: int) -> void: _staggers.append([1, by]))
	_add_worker(BOB, "Bob")
	_add_worker(CHLOE, "Chloe")
	await wait_frames(3)
	bob = world.get_player(BOB)
	chloe = world.get_player(CHLOE)
	if not check(bob != null and chloe != null and world.get_players().size() == 3, "Bob and Chloe spawned (3 workers)"):
		return false
	GameState.request_start_round()
	await wait_until(func() -> bool: return GameState.is_playing(), 2.0, "shift running")
	await wait_frames(2)
	return true


## A fake worker: in the registry and spawned on the host without an owning peer.
func _add_worker(id: int, worker_name: String) -> void:
	Net.players[id] = {"name": worker_name, "color": Net.PALETTE[(id - 1) % Net.PALETTE.size()]}
	Net.players_changed.emit()
	var p := world.server_spawn_player(id)
	if p != null:
		p.staggered.connect(func(by: int) -> void: _staggers.append([id, by]))


## The worker leaves the way Net cleans up a dropped peer (item released, body despawned, registry synced).
func _drop_worker(id: int) -> void:
	Net.call(&"_server_cleanup_departed", id, Net.get(&"_peer"))


func _respawn(id: int) -> Player:
	_add_worker(id, "Bob" if id == BOB else "Chloe")
	await wait_frames(2)
	var p := world.get_player(id)
	if id == BOB:
		bob = p
	else:
		chloe = p
	return p


## Puts an unowned body exactly at `pos` (synced pose + node) with yaw `yaw`.
static func _place(p: Player, pos: Vector3, yaw: float) -> void:
	p.net_position = pos
	p.net_yaw = yaw
	p.net_pitch = 0.0
	p.position = pos
	p.rotation = Vector3(0.0, yaw, 0.0)
	p.velocity = Vector3.ZERO


## Puts my own body at `pos` facing `yaw` (0 = -Z), looking `pitch` radians down.
func _place_me(pos: Vector3, yaw: float, pitch: float = 0.0) -> void:
	me.velocity = Vector3.ZERO
	me.global_position = pos + Vector3.UP * 0.02
	me.rotation = Vector3(0.0, yaw, 0.0)
	me.head.rotation.x = pitch


## A watering can nobody holds (spawned on the floor if the starting ones are gone or in hands).
func _free_can() -> Item:
	for it in items_of(Const.ITEM_WATERING_CAN):
		if it.holder_id == 0 and not it.is_flying():
			return it
	return items.server_spawn_item(Const.ITEM_WATERING_CAN, {}, Vector3(-4.0, 0.0, 2.0))


func _clear_hands(peer: int = 1) -> void:
	var held := items.get_held_by(peer)
	if held != null:
		items.server_despawn_item(held)
	await wait_frames(1)


func _press_escape() -> void:
	for pressed: bool in [true, false]:
		var ev := InputEventKey.new()
		ev.keycode = KEY_ESCAPE
		ev.physical_keycode = KEY_ESCAPE
		ev.pressed = pressed
		get_viewport().push_input(ev)
	await wait_frames(2)


func wait_physics(n: int) -> void:
	for i in n:
		await get_tree().physics_frame


## Inside the Boss's booth (between the partitions, behind the counter): unreachable for the floor.
func _in_booth(p: Vector3) -> bool:
	return absf(p.x) < 2.06 and p.z < -5.0


func _backroom_spot() -> Vector3:
	return room.get_backroom_transform(0).origin


## Nodes that must never survive a session: the rat, the spectator camera, voice emitters, ping markers.
func _leftovers() -> Array:
	var out := []
	var root := get_tree().root
	for n in root.find_children("*", "", true, false):
		if n.is_queued_for_deletion():
			continue
		if n is PingMarker or n is Rat or String(n.name) == "SpectatorCamera" or String(n.name) == "VoiceOut":
			out.append(str(n.get_path()))
	return out


func _count_markers() -> int:
	var n := 0
	if world == null or not is_instance_valid(world):
		return 0
	for c in world.get_children():
		if c is PingMarker and not c.is_queued_for_deletion():
			n += 1
	return n


func _check_clean(tag: String) -> void:
	check(Game.world == null and Game.local_player == null and GameState.phase == GameState.Phase.MENU, "%s: world gone, MENU" % tag)
	check(not Game.is_ui_locked(), "%s: every UI lock released" % tag)
	check(not Events.is_event_active() and Events.is_power_on(), "%s: Events reset" % tag)
	check(_leftovers().is_empty(), "%s: no leftover nodes %s" % [tag, _leftovers()])
	check(int(Performance.get_monitor(Performance.OBJECT_ORPHAN_NODE_COUNT)) == 0, "%s: no orphan nodes" % tag)
	check(int(Voice.get_stats().get("peers", -1)) == 0, "%s: no voice emitters left" % tag)


# =================================================================================================== R1

func _r1_backroom_server_rule() -> void:
	step("R1: the server refuses gameplay from a worker in the back room (a modified client walked out)")
	var shop: ShopCounter = station("ShopCounter")
	var turnin: TurnInStation = station("TurnInStation")
	var fuse: FuseBox = station("FuseBox")
	var can: Item = items_of(Const.ITEM_WATERING_CAN)[0]
	check(GameState.server_send_to_backroom(1, 120.0), "the host's own worker is sent to the back room")
	await wait_frames(2)
	check(GameState.is_in_backroom(1) and me.global_position.distance_to(_backroom_spot()) < 0.6, "body teleported into the booth (%.2f m)" % me.global_position.distance_to(_backroom_spot()))
	# The cheat: movement is owner-authoritative, so the body simply walks back onto the floor.
	stand_near(can, 0.7)
	await wait_frames(2)
	toasts.clear()
	can._rpc_request_interact()
	await wait_frames(1)
	check(can.holder_id == 0, "pick-up from the back room refused (holder %d)" % can.holder_id)
	check(toast_seen(REASON_BACKROOM_TEXT), "told '%s' %s" % [REASON_BACKROOM_TEXT, toasts])
	if can.holder_id == 1:
		items.server_drop_item(can, Vector3(-4.0, 0.0, 0.0)) # unfixed code: keep the demonstration from cascading
	# Deposits: a product in hand at the chute.
	var product := items.server_spawn_item(Const.ITEM_PRODUCT, {"strain_id": &"budget", "amount": 1}, Vector3.ZERO, 1) as Item
	stand_near(turnin, 1.2)
	await wait_frames(2)
	var money := GameState.money
	var sales := GameState.round_sales
	turnin._rpc_request_interact()
	await wait_frames(1)
	check(GameState.money == money and GameState.round_sales == sales and is_instance_valid(product) and product.holder_id == 1,
			"deposit from the back room refused (no sale, product still in hand)")
	# Purchases (the raw RPC and the server API).
	stand_near(shop, 1.2)
	await wait_frames(2)
	await _clear_hands()
	money = GameState.money
	toasts.clear()
	shop._rpc_request_buy_seed(&"budget")
	await wait_frames(1)
	check(GameState.money == money and items_of(Const.ITEM_SEED_PACKET).is_empty(), "seed purchase from the back room refused")
	check(toast_seen(REASON_BACKROOM_TEXT), "buyer told '%s' %s" % [REASON_BACKROOM_TEXT, toasts])
	var r: Dictionary = shop.server_buy_upgrade(1, &"fertilizer")
	check(not bool(r["ok"]) and String(r["reason"]) == REASON_BACKROOM_TEXT and GameState.money == money, "favor purchase from the back room refused ('%s')" % r["reason"])
	# The fuse box during a power cut.
	check(Events.server_start_event(Events.EVENT_POWER_CUT), "power cut")
	stand_near(fuse, 1.3)
	await wait_frames(2)
	toasts.clear()
	fuse._rpc_request_reset()
	await wait_frames(1)
	check(not Events.is_power_on() and Events.is_event_active(Events.EVENT_POWER_CUT), "fuse-box reset from the back room refused (power still off)")
	check(toast_seen(REASON_BACKROOM_TEXT), "told '%s'" % REASON_BACKROOM_TEXT)
	Events.server_end_event()
	await wait_frames(1)
	# Drops and throws with something in hand.
	check(items.server_give_item(can, 1), "holding a can (server API)")
	_place_me(Vector3(-3.0, 0.0, 2.0), 0.0)
	await wait_frames(1)
	items._rpc_request_drop()
	items._rpc_request_throw()
	await wait_frames(1)
	check(can.holder_id == 1 and not can.is_flying(), "drop and throw from the back room refused (can still in hand)")
	# Positive control: released, the same requests work again.
	GameState.server_release_from_backroom(1)
	await wait_frames(2)
	check(not GameState.is_in_backroom(1), "released")
	items._rpc_request_drop()
	await wait_frames(1)
	check(can.holder_id == 0, "released: the drop goes through")
	stand_near(can, 0.7)
	await wait_frames(2)
	can._rpc_request_interact()
	await wait_frames(1)
	check(can.holder_id == 1, "released: the pick-up goes through")
	items.server_release_holder(1)
	await wait_frames(1)
	_place_me(Vector3(0.0, 0.0, 0.0), 0.0)


# =================================================================================================== R2

func _r2_backroom_supply_window() -> void:
	step("R2: the supply window shuts when its worker is sent to the back room")
	var shop: ShopCounter = station("ShopCounter")
	stand_near(shop, 1.2)
	await wait_frames(2)
	shop.open_shop_for(me)
	await wait_frames(2)
	check(shop.is_shop_open() and Game.is_ui_locked_by(&"shop"), "supply window open")
	check(GameState.server_send_to_backroom(1, 60.0), "sent to the back room with the window open")
	await wait_frames(3)
	check(me.global_position.distance_to(shop.global_position) < 4.0, "the BackRoomSpot is inside the window's own 4 m walk-away distance (%.2f m)" % me.global_position.distance_to(shop.global_position))
	check(hud.back_room.is_open(), "back-room overlay up")
	check(not shop.is_shop_open() and not Game.is_ui_locked_by(&"shop"), "the supply window closed and released its lock")
	shop.close_shop() # no-op once fixed; keeps a failure here from cascading into the next sections
	GameState.server_release_from_backroom(1)
	await wait_frames(2)
	check(not hud.back_room.is_open() and not Game.is_ui_locked(), "released: overlay gone, no lock")


# =================================================================================================== R3

func _r3_backroom_pause_menu() -> void:
	step("R3: Escape opens the pause menu over the back room (the only way to leave for 30 s)")
	check(GameState.server_send_to_backroom(1, 60.0), "sent to the back room")
	await wait_frames(2)
	check(hud.back_room.is_open() and Game.is_ui_locked_by(Const.UI_LOCK_BACKROOM), "overlay up, back-room lock held")
	await _press_escape()
	check(hud.pause_menu.is_open() and Game.is_ui_locked_by(PauseMenu.LOCK_SOURCE), "Escape opens the pause menu over the back room")
	check(hud.back_room.is_open() and Game.is_ui_locked_by(Const.UI_LOCK_BACKROOM), "the back room keeps its overlay and lock underneath")
	await _press_escape()
	check(not hud.pause_menu.is_open() and Game.is_ui_locked_by(Const.UI_LOCK_BACKROOM) and hud.back_room.is_open(),
			"Escape closes the pause menu; the back-room lock stays")
	GameState.server_release_from_backroom(1)
	await wait_frames(2)
	check(not Game.is_ui_locked(), "released: no lock")
	await _press_escape()
	check(hud.pause_menu.is_open(), "on the floor the pause menu still opens")
	await _press_escape()
	check(not hud.pause_menu.is_open() and not Game.is_ui_locked(), "and closes")


# =================================================================================================== R4

func _r4_backroom_stranded_item() -> void:
	step("R4: an item let go of in the back room goes back to the floor, not into the booth")
	var can: Item = _free_can()
	check(items.server_give_item(can, BOB), "Bob holds a can")
	check(GameState.server_send_to_backroom(BOB, 120.0), "Bob sent to the back room")
	await wait_frames(2)
	check(_in_booth(bob.global_position), "Bob's body is inside the booth %s" % bob.global_position)
	items.server_release_holder(BOB)   # what Net does when the peer drops
	await wait_frames(1)
	check(can.holder_id == 0 and not _in_booth(can.global_position), "the can is not stranded inside the booth (%s)" % can.global_position)
	check(room.get_bounds().grow(-0.05).has_point(can.global_position + Vector3.UP * 0.05) and absf(can.global_position.y) < 0.1, "it rests on the floor inside the room")
	GameState.server_release_from_backroom(BOB)
	await wait_frames(2)
	# The real path: Chloe holds the other can, sits in the back room and disconnects.
	var can2: Item = _free_can()
	items.server_drop_item(can2, Vector3(-4.0, 0.0, 0.0))
	check(items.server_give_item(can2, CHLOE), "Chloe holds a can")
	check(GameState.server_send_to_backroom(CHLOE, 120.0), "Chloe sent to the back room")
	await wait_frames(2)
	Story.reset_state()
	_drop_worker(CHLOE)
	await wait_frames(2)
	check(world.get_player(CHLOE) == null and not Net.players.has(CHLOE) and not GameState.is_in_backroom(CHLOE), "Chloe is gone: despawned, out of the registry and the back room")
	check(can2.holder_id == 0 and not _in_booth(can2.global_position), "her can did not stay in the booth (%s)" % can2.global_position)
	check(Story.last_bark != "Back to work, Chloe.", "the Boss does not tell a departed worker to get back to work ('%s')" % Story.last_bark)
	await _respawn(CHLOE)
	check(chloe != null and world.get_players().size() == 3, "Chloe is back for the next sections")
	items.server_drop_item(can2, Vector3(-4.0, 0.0, 1.0))
	await wait_frames(1)


# =================================================================================================== R5

func _r5_stagger_lock() -> void:
	step("R5: a worker cannot be kept staggered without a break")
	var b: BalanceConfig = Config.balance
	# Rapid re-throws: the bundle lands at Bob's feet, within the thrower's reach, and goes straight back at him.
	await _clear_hands()
	_place(bob, Vector3(-3.0, 0.0, 0.0), 0.0)
	_place(chloe, Vector3(6.0, 0.0, -5.5), 0.0)
	_place_me(Vector3(-3.0, 0.0, 1.6), 0.0, -0.32)
	await wait_physics(2)
	var product := items.server_spawn_item(Const.ITEM_PRODUCT, {"strain_id": &"budget", "amount": 1}, Vector3.ZERO, 1) as Item
	check(product != null and product.holder_id == 1, "I hold a bundle 1.6 m from Bob")
	var hits0 := GameState.get_stat(1, Const.STAT_HITS)
	var throws0 := GameState.get_stat(1, Const.STAT_THROWS)
	var stunned := 0
	var total := 0
	var pickups := 0
	for i in 180:
		if product.holder_id == 0 and not product.is_flying():
			if items.server_give_item(product, 1):
				pickups += 1
		if product.holder_id == 1 and not me.is_stunned():
			items.request_throw()
		await get_tree().physics_frame
		total += 1
		if bob.is_stunned():
			stunned += 1
	var uptime := float(stunned) / float(maxi(total, 1))
	var hits := GameState.get_stat(1, Const.STAT_HITS) - hits0
	check(pickups >= 3 and GameState.get_stat(1, Const.STAT_THROWS) - throws0 >= 3, "the loop threw the bundle %d times (%d pick-ups)" % [GameState.get_stat(1, Const.STAT_THROWS) - throws0, pickups])
	check(hits >= 2, "at least two hits landed (%d)" % hits)
	check(uptime <= 0.5, "Bob's stagger uptime under rapid re-throws is bounded: %.0f%% (stun %.2f s, %d hits in 3 s)" % [uptime * 100.0, b.hit_stun_sec, hits])
	await wait_until(func() -> bool: return not product.is_flying(), 3.0, "bundle at rest")
	await wait_until(func() -> bool: return not bob.is_stunned() and not me.is_stunned(), 3.0, "nobody stunned")
	items.server_despawn_item(product)
	await wait_frames(1)
	# Immunity semantics.
	if check(bob.has_method(&"can_be_staggered"), "Player.can_be_staggered() exists"):
		await wait_until(func() -> bool: return bool(bob.call(&"can_be_staggered")), 3.0, "Bob can be staggered again")
		_staggers.clear()
		Player.server_stagger(bob, Vector3(1.0, 0.0, 0.0), false, 1)
		check(_staggers.has([BOB, 1]) and bob.is_stunned() and not bool(bob.call(&"can_be_staggered")), "a stagger lands and starts the immunity")
		await wait_until(func() -> bool: return not bob.is_stunned(), 2.0, "stun over")
		check(not bool(bob.call(&"can_be_staggered")), "still immune right after the stun")
		_staggers.clear()
		Player.server_stagger(bob, Vector3(1.0, 0.0, 0.0), false, 1)
		check(_staggers.is_empty() and not bob.is_stunned(), "a stagger during the immunity does nothing")
		await wait_until(func() -> bool: return bool(bob.call(&"can_be_staggered")), 3.0, "immunity over (STAGGER_IMMUNITY_SEC after the stun)")
		Player.server_stagger(bob, Vector3(1.0, 0.0, 0.0), false, 1)
		check(_staggers.has([BOB, 1]), "then it lands again")
		await wait_until(func() -> bool: return bool(bob.call(&"can_be_staggered")), 3.0, "Bob clear")
	# Two shovers taking turns on the server API (each shover's own cooldown is 0.8 s; two of them cover it).
	_place(chloe, Vector3(-3.0, 0.0, -1.2), 0.0)
	_place_me(Vector3(-3.0, 0.0, 1.2), 0.0)
	await wait_physics(2)
	stunned = 0
	total = 0
	var turn := 0
	var t_end := Time.get_ticks_msec() + 2000
	while Time.get_ticks_msec() < t_end:
		if turn % 2 == 0:
			me.server_shove(bob, Vector3(0.0, 0.0, -1.0), false)
		else:
			chloe.server_shove(bob, Vector3(0.0, 0.0, 1.0), false)
		turn += 1
		bob.velocity = Vector3.ZERO
		await get_tree().physics_frame
		total += 1
		if bob.is_stunned():
			stunned += 1
	uptime = float(stunned) / float(maxi(total, 1))
	check(uptime <= 0.5, "Bob's stagger uptime under two alternating shovers is bounded: %.0f%%" % (uptime * 100.0))
	await wait_until(func() -> bool: return not bob.is_stunned(), 2.0, "Bob recovers")
	_place(chloe, Vector3(6.0, 0.0, -5.5), 0.0)


# =================================================================================================== R6

func _r6_shove_line_of_sight() -> void:
	step("R6: a shove needs a clear line between the two workers")
	var b: BalanceConfig = Config.balance
	# Fence7 stands at x = 3 from z -5 to -2.5 (the grow area's west fence): 2 m apart across it.
	_place(bob, Vector3(4.0, 0.0, -3.75), 0.0)
	_place_me(Vector3(2.0, 0.0, -3.75), -PI * 0.5)   # facing +X, at Bob
	await wait_physics(2)
	var space := me.get_world_3d().direct_space_state
	var wall := space.intersect_ray(PhysicsRayQueryParameters3D.create(me.get_chest_position(), bob.get_chest_position(), Const.LAYER_WORLD))
	check(not wall.is_empty(), "the fence is between us on LAYER_WORLD (%s)" % ("nothing" if wall.is_empty() else str((wall["collider"] as Node).get_path())))
	check(me.global_position.distance_to(bob.global_position) <= b.shove_range + 1.0, "within shove range (%.2f m)" % me.global_position.distance_to(bob.global_position))
	await wait_until(func() -> bool: return not bob.is_stunned() and (not bob.has_method(&"can_be_staggered") or bool(bob.call(&"can_be_staggered"))), 3.0, "Bob clear")
	_staggers.clear()
	var shoves0 := GameState.get_stat(1, Const.STAT_SHOVES)
	me.request_shove(BOB)
	await wait_frames(2)
	check(_staggers.is_empty() and not bob.is_stunned() and GameState.get_stat(1, Const.STAT_SHOVES) == shoves0, "a shove through the fence is refused")
	# Control: the same distance in the open lands.
	await wait_sec(b.shove_cooldown_sec + 0.1)
	_place(bob, Vector3(-3.0, 0.0, -1.5), 0.0)
	_place_me(Vector3(-3.0, 0.0, 0.5), 0.0)
	await wait_physics(2)
	_staggers.clear()
	me.request_shove(BOB)
	await wait_frames(2)
	check(_staggers.has([BOB, 1]) and GameState.get_stat(1, Const.STAT_SHOVES) == shoves0 + 1, "the same shove in the open lands %s" % [_staggers])
	await wait_until(func() -> bool: return not bob.is_stunned(), 2.0, "Bob recovers")


# =================================================================================================== R8

func _r8_hostile_inputs() -> void:
	step("R8: hostile inputs on the new server handlers")
	var b: BalanceConfig = Config.balance
	# Chat: oversized payload, a flood in one frame.
	Comms.reset_limits()
	var lines: Array = []
	var conn := func(p: int, t: String) -> void: lines.append([p, t])
	Comms.chat_received.connect(conn)
	var t0 := Time.get_ticks_usec()
	Comms._rpc_chat("x".repeat(200000))
	for i in 1000:
		Comms._rpc_chat("spam %d" % i)
	var ms := (Time.get_ticks_usec() - t0) / 1000.0
	check(lines.size() == 1, "200k-char line dropped, 1000 lines in one frame -> one accepted (%d)" % lines.size())
	check(ms < 250.0, "the flood cost %.1f ms (bounded)" % ms)
	Comms.chat_received.disconnect(conn)
	# Pings: absurd but finite positions are out of range; a flood is one marker.
	var pings: Array = []
	var pconn := func(p: int, pos: Vector3) -> void: pings.append([p, pos])
	Comms.ping_received.connect(pconn)
	Comms.reset_limits()
	Comms._rpc_ping(Vector3(1e30, 1e30, 1e30))
	Comms._rpc_ping(Vector3(INF, 0.0, 0.0))
	Comms._rpc_ping(Vector3(-1e12, 0.0, 0.0))
	for i in 500:
		Comms._rpc_ping(me.global_position + Vector3(0.5, 0.0, 0.5))
	check(pings.size() == 1, "absurd pings refused, a 500-ping flood lands once (%d)" % pings.size())
	Comms.ping_received.disconnect(pconn)
	await wait_frames(1)
	check(hud.get_ping_marker(1) != null and _count_markers() == 1, "one marker under the world (%d)" % _count_markers())
	# Voice: oversized frame, a flood, negative / huge sequence numbers, a stranger.
	var stats0: Dictionary = Voice.get_stats()
	var big := PackedByteArray()
	big.resize(5000)
	Voice._rpc_voice(1, big)
	var frame := PackedByteArray()
	frame.resize(Voice.FRAME_SAMPLES)
	frame.fill(0xFF)
	t0 = Time.get_ticks_usec()
	for i in 300:
		Voice._rpc_voice(i + 2, frame)
	ms = (Time.get_ticks_usec() - t0) / 1000.0
	Voice._rpc_voice(-7, frame)
	Voice._rpc_voice(1 << 40, frame)
	Voice._rpc_voice(5, PackedByteArray())
	var stats: Dictionary = Voice.get_stats()
	var dropped: Dictionary = stats["dropped"]
	var dropped0: Dictionary = stats0["dropped"]
	check(int(dropped.get("too_big", 0)) == int(dropped0.get("too_big", 0)) + 1, "a 5000-byte frame is dropped (too_big)")
	check(int(stats["received"]) - int(stats0["received"]) <= Voice.MAX_FRAMES_PER_SEC + 2, "300 frames in one frame: at most %d accepted (%d)" % [Voice.MAX_FRAMES_PER_SEC, int(stats["received"]) - int(stats0["received"])])
	check(int(dropped.get("rate", 0)) > int(dropped0.get("rate", 0)) and int(dropped.get("empty", 0)) == int(dropped0.get("empty", 0)) + 1, "the rest dropped by rate; the empty frame by 'empty'")
	check(ms < 250.0, "300 voice frames cost %.1f ms (bounded)" % ms)
	var saved: Dictionary = Net.players.duplicate(true)
	Net.players.erase(1)
	var received := int(Voice.get_stats()["received"])
	Voice._rpc_voice(9000, frame)
	Net.players = saved
	check(int(Voice.get_stats()["received"]) == received, "a frame from a peer outside the registry is dropped")
	# Stagger cosmetics with garbage: never a stun longer than 5 s, never from a non-finite value, no error.
	me._rpc_stagger_fx(BOB, NAN, true)
	check(not me.is_stunned(), "a NaN stun in the cosmetic RPC does not stun")
	me._rpc_stagger_fx(BOB, 1e12, false)
	check(me.is_stunned() and me._stun_until_msec - Time.get_ticks_msec() <= 5100, "an absurd stun is clamped to 5 s")
	me._stun_until_msec = 0
	me.apply_stagger(Vector3(INF, 0.0, 0.0), 0.5)
	check(not me.is_stunned() and me.velocity.is_finite(), "a non-finite impulse is ignored")
	# Shove at a target with a broken pose (the renderer complains about the NaN transform of every mesh: engine noise
	# from the test's own write, not from game code).
	var good := bob.position
	allow_error("!v.is_finite()", 80)
	bob.position = Vector3(NAN, 0.0, 0.0)
	_staggers.clear()
	me.request_shove(BOB)
	await wait_frames(1)
	check(_staggers.is_empty(), "a NaN-positioned target cannot be shoved")
	_place(bob, good, 0.0)
	await wait_frames(1)
	clear_allowed_errors()
	# Throws: absurd velocity, an origin far above the room.
	var can: Item = items_of(Const.ITEM_WATERING_CAN)[0]
	check(items.server_throw_item(can, Vector3(-3.0, 1.2, 0.0), Vector3(1e6, 1e6, 1e6), 1), "a 1e6 m/s throw is accepted (finite)")
	await wait_until(func() -> bool: return not can.is_flying(), 3.5, "it lands within the time cap")
	check(room.get_bounds().grow(0.05).has_point(can.global_position + Vector3.UP * 0.05), "inside the room (%s)" % can.global_position)
	check(items.server_throw_item(can, Vector3(0.0, 1e6, 0.0), Vector3.ZERO, 1), "a throw from a kilometre above is accepted")
	await wait_until(func() -> bool: return not can.is_flying(), 3.5, "it lands")
	check(room.get_bounds().grow(0.05).has_point(can.global_position + Vector3.UP * 0.05), "back on the room floor (%s)" % can.global_position)
	check(not items.server_throw_item(can, Vector3(NAN, 1.0, 0.0), Vector3.FORWARD, 1) and not items.server_throw_item(can, Vector3.ONE, Vector3(0.0, INF, 0.0), 1), "non-finite throws refused")
	# Requests out of range / with nothing to do.
	var fuse: FuseBox = station("FuseBox")
	_place_me(Vector3(5.0, 0.0, 5.0), 0.0)
	await wait_frames(1)
	toasts.clear()
	fuse._rpc_request_reset()
	await wait_frames(1)
	check(toast_seen(FuseBox.REASON_TOO_FAR), "a fuse-box reset from across the room: 'Too far.'")
	stand_near(fuse, 1.3)
	await wait_frames(1)
	toasts.clear()
	fuse._rpc_request_reset()
	await wait_frames(1)
	check(toast_seen(FuseBox.REASON_NOTHING) and Events.is_power_on(), "with the power on: 'Nothing to reset.'")
	items._rpc_request_throw()
	items._rpc_request_drop()
	check(items.get_held_by(1) == null, "throw / drop with empty hands: nothing")
	# GameState guards on server-only numbers (an audit with a broken fraction never breaks the quota).
	var q := GameState.quota
	for bad: float in [NAN, INF, -INF, -1.0, 0.0, 1e30]:
		GameState.server_raise_quota(bad)
	check(GameState.quota >= q and GameState.quota <= q + 2 * maxi(q, 1) + 2, "garbage raise fractions leave the quota sane (%d -> %d)" % [q, GameState.quota])
	check(GameState.server_write_up(-5, Const.WRITE_UP_OTHER) == 0 and GameState.server_write_up(0, Const.WRITE_UP_OTHER) == 0, "write-ups of peer <= 0 refused")
	check(not GameState.server_send_to_backroom(0) and not GameState.server_send_to_backroom(-3), "back room for peer <= 0 refused")
	check(b.shove_range > 0.0, "balance loaded")
	_place_me(Vector3(0.0, 0.0, 0.0), 0.0)


# =================================================================================================== R9

func _r9_churn() -> void:
	step("R9a: the thrower disconnects mid-flight")
	_place(bob, Vector3(-3.0, 0.0, 3.0), 0.0)
	var product := items.server_spawn_item(Const.ITEM_PRODUCT, {"strain_id": &"budget", "amount": 1}, Vector3.ZERO, BOB) as Item
	await wait_frames(1)
	check(items.server_throw_item(product, bob.get_chest_position(), Vector3(0.0, 4.0, -3.0), BOB), "Bob throws")
	await wait_frames(1)
	_drop_worker(BOB)
	await wait_frames(2)
	check(world.get_player(BOB) == null and product.is_flying() and product.thrower_id == BOB, "Bob is gone while his bundle is still in the air")
	await wait_until(func() -> bool: return not product.is_flying(), 3.5, "the flight still ends")
	check(room.get_bounds().grow(0.05).has_point(product.global_position + Vector3.UP * 0.05), "landed inside the room")
	items.server_despawn_item(product)
	await _respawn(BOB)

	step("R9b: the spectated worker disconnects")
	check(GameState.server_send_to_backroom(1, 60.0), "I am in the back room")
	await wait_frames(2)
	var br: BackRoomOverlay = hud.back_room
	check(br.is_open() and br.get_watched_peer() == BOB, "watching Bob (%d)" % br.get_watched_peer())
	_drop_worker(BOB)
	await wait_frames(3)
	check(br.is_open() and br.get_watched_peer() == CHLOE and br.get_spectator_camera() != null, "the camera moved on to Chloe (%d)" % br.get_watched_peer())
	_drop_worker(CHLOE)
	await wait_frames(3)
	check(br.is_open() and br.get_watched_peer() == 0 and br.get_spectator_camera() != null and br.watching_label.text.contains("the floor"), "nobody left: the overview shot ('%s')" % br.watching_label.text)
	GameState.server_release_from_backroom(1)
	await wait_frames(2)
	await _respawn(BOB)
	await _respawn(CHLOE)

	step("R9c: a worker disconnects during an inspection, in the Boss's sight")
	check(Events.server_start_event(Events.EVENT_INSPECTION), "inspection")
	var boss := room.get_station("ShopCounter").get_node(^"ShopkeeperAnchor/Shopkeeper") as ShopkeeperNPC
	# Six seconds into the route, on the floor, frozen (deterministic sight checks, as in events_body).
	boss.walk_route(room.get_inspection_route(), float(Events.get_event_params().get("speed", 1.6)), 6.0)
	boss.set_process(false)
	await wait_frames(2)
	var eye := boss.get_eye_position()
	var facing := boss.get_facing()
	_place(bob, Vector3(eye.x, 0.0, eye.z) + facing * 2.5, 0.0)
	_place(chloe, Vector3(eye.x, 0.0, eye.z) - facing * 3.0, 0.0)
	Events.server_sight_check()
	Events.tick(0.6)
	check(Events.get(&"_seen_since").has(BOB), "Bob is in the Boss's sight")
	_drop_worker(BOB)
	await wait_frames(2)
	Events.server_sight_check()
	Events.tick(1.0)
	check(not Events.get(&"_seen_since").has(BOB) and Events.is_event_active(Events.EVENT_INSPECTION), "his sight record went with him; the inspection goes on")
	boss.set_process(true)
	Events.server_end_event()
	await wait_frames(2)
	await _respawn(BOB)

	step("R9d: RETRY (full reset) in the middle of every event")
	for kind: StringName in [Events.EVENT_POWER_CUT, Events.EVENT_INSPECTION, Events.EVENT_AUDIT, Events.EVENT_RAT]:
		if kind == Events.EVENT_RAT:
			var p := plot(1)
			p.server_plant(&"budget")
			p.server_water(1.0)
		if not check(Events.server_start_event(kind), "%s starts" % kind):
			continue
		await wait_sec(0.4)
		GameState.server_reset_game()
		await wait_frames(3)
		check(GameState.phase == GameState.Phase.WAITING and not Events.is_event_active() and Events.is_power_on() and room.is_power_on(), "%s: reset -> WAITING, event over, power on" % kind)
		if kind == Events.EVENT_INSPECTION:
			await wait_until(func() -> bool: return not boss.is_walking() and boss.position.length() < 0.05, 3.0, "the Boss is back behind the counter")
		if kind == Events.EVENT_RAT:
			await wait_until(func() -> bool: return room.get_node_or_null(^"Rat") == null, 12.0, "the rat is gone")
		GameState.request_start_round()
		await wait_until(func() -> bool: return GameState.is_playing(), 2.0, "shift again")

	step("R9e: the fuse box's resend guard outlives the world")
	check(Events.server_start_event(Events.EVENT_POWER_CUT), "power cut")
	var fuse: FuseBox = station("FuseBox")
	stand_near(fuse, 1.3)
	await wait_frames(2)
	fuse.request_reset()
	await wait_frames(1)
	check(Events.is_power_on(), "the reset went through")
	Game.return_to_menu()
	await wait_frames(3)
	await wait_sec(FuseBox.RESEND_GUARD_SEC + 0.3)
	_check_clean("after a reset then leaving at once")

	step("R9f: return_to_menu in the middle of every event, from the back room, with voice and pings live")
	for kind: StringName in [Events.EVENT_POWER_CUT, Events.EVENT_INSPECTION, Events.EVENT_RAT]:
		if not await _host():
			return
		if kind == Events.EVENT_RAT:
			plot(1).server_plant(&"budget")
			plot(1).server_water(1.0)
		check(Events.server_start_event(kind), "%s starts" % kind)
		var frame := PackedByteArray()
		frame.resize(Voice.FRAME_SAMPLES)
		for i in 3:
			Voice.debug_inject_frame(BOB, frame)
		check(Voice.get_output_node(BOB) != null, "Bob's voice emitter exists")
		Comms.reset_limits()
		Comms.ping_received.emit(BOB, bob.global_position)
		check(hud.get_ping_marker(BOB) != null, "a ping marker is up")
		check(GameState.server_send_to_backroom(1, 60.0), "and I am in the back room, spectating")
		await wait_frames(2)
		check(hud.back_room.is_open() and hud.back_room.get_spectator_camera() != null, "overlay + spectator camera up")
		await wait_sec(0.5)
		Game.return_to_menu("review leaves during %s" % kind)
		await wait_frames(4)
		_check_clean("left during %s" % kind)
	if not await _host():
		return


# =================================================================================================== R12

func _r12_backroom_at_shift_end() -> void:
	step("R12: sent to the back room in the last second of the shift")
	GameState.time_left = 0.8
	check(GameState.server_send_to_backroom(1, 30.0), "sent with 0.8 s left")
	await wait_frames(2)
	check(GameState.is_in_backroom(1) and GameState.get_backroom_time_left(1) <= 0.8 and hud.back_room.is_open(), "the stay is clamped to the shift (%.2f s left), overlay up" % GameState.get_backroom_time_left(1))
	await wait_until(func() -> bool: return GameState.is_round_over(), 3.0, "the shift ended")
	await wait_frames(2)
	check(not GameState.is_in_backroom(1) and not hud.back_room.is_open() and hud.back_room.get_spectator_camera() == null, "released at the shift end, overlay and camera gone")
	check(not Game.is_ui_locked_by(Const.UI_LOCK_BACKROOM) and Game.is_ui_locked_by(&"round_end") and hud.round_end.is_open(), "the back-room lock is gone; the end screen holds its own")
	check(me.camera.current, "the worker's own camera is current again")


# =================================================================================================== R10

func _r10_copy_audit() -> void:
	step("R10: copy tone of every new user-facing string")
	var scripts := {
		"story": "res://scripts/core/story.gd", "hud": "res://scripts/ui/hud.gd", "backroom": "res://scripts/ui/backroom_overlay.gd",
		"chat": "res://scripts/ui/chat_box.gd", "pause": "res://scripts/ui/pause_menu.gd", "round_end": "res://scripts/ui/round_end.gd",
		"report": "res://scripts/ui/shift_report.gd", "fuse": "res://scripts/stations/fuse_box.gd", "item": "res://scripts/items/item.gd",
		"turnin": "res://scripts/stations/turn_in_station.gd", "shop": "res://scripts/stations/shop_counter.gd",
		"interactable": "res://scripts/interaction/interactable.gd", "grow_plot": "res://scripts/stations/grow_plot.gd",
	}
	var checked := 0
	var bad: PackedStringArray = []
	for tag: String in scripts:
		var s := load(scripts[tag]) as GDScript
		for key: Variant in s.get_script_constant_map():
			var v: Variant = s.get_script_constant_map()[key]
			if v is String:
				checked += 1
				_audit_line(String(v), "%s.%s" % [tag, key], bad)
	for key: Variant in Story.lines:
		checked += 1
		_audit_line(String(Story.lines[key]), "Story.lines.%s" % key, bad)
	for key: Variant in Story.blurbs:
		checked += 1
		_audit_line(String(Story.blurbs[key]), "Story.blurbs.%s" % key, bad)
	var boss := room.get_station("ShopCounter").get_node(^"ShopkeeperAnchor/Shopkeeper") as ShopkeeperNPC
	for line: String in boss.idle_lines:
		checked += 1
		_audit_line(line, "Boss idle line", bad)
	var verdicts := Story.get_report_verdicts()
	for v in verdicts:
		checked += 1
		_audit_line(v, "verdict", bad)
	check(checked > 80 and bad.is_empty(), "%d strings: no exclamation marks, no cheer %s" % [checked, bad])


func _audit_line(text: String, where: String, bad: PackedStringArray) -> void:
	if text.contains("!"):
		bad.append("%s has '!': %s" % [where, text])
	var lower := text.to_lower()
	for w in CHEER_WORDS:
		if lower.contains(w):
			bad.append("%s cheers (%s): %s" % [where, w, text])


# =================================================================================================== R11

func _r11_perf() -> void:
	step("R11: bounded costs on the hot paths")
	var rows_before: Array = []
	for row: Node in hud.player_list.get_children():
		rows_before.append(row.get_instance_id())
	var t0 := Time.get_ticks_usec()
	for i in 50:
		GameState.server_add_stat(BOB, Const.STAT_PINGS)
	var ms := (Time.get_ticks_usec() - t0) / 1000.0
	var rows_after: Array = []
	for row: Node in hud.player_list.get_children():
		rows_after.append(row.get_instance_id())
	check(rows_after == rows_before, "stats_changed updates the WORKERS marks without rebuilding the rows")
	check(ms < 400.0, "50 stat broadcasts (state + HUD marks) cost %.1f ms" % ms)
	check(Events.server_start_event(Events.EVENT_INSPECTION), "inspection for the sight checks")
	await wait_sec(0.3)
	t0 = Time.get_ticks_usec()
	for i in 100:
		Events.server_sight_check()
	ms = (Time.get_ticks_usec() - t0) / 1000.0
	check(ms < 400.0, "100 sight passes over 3 workers cost %.1f ms" % ms)
	Events.server_end_event()
	var frame := PackedByteArray()
	frame.resize(Voice.FRAME_SAMPLES)
	for peer in [BOB, CHLOE]:
		for i in 3:
			Voice.debug_inject_frame(peer, frame)
	t0 = Time.get_ticks_usec()
	for i in 200:
		Voice._process(0.016)
	ms = (Time.get_ticks_usec() - t0) / 1000.0
	check(ms < 400.0, "200 Voice._process ticks with two emitters cost %.1f ms" % ms)
	var long_text := "x".repeat(1000000)
	t0 = Time.get_ticks_usec()
	var clean := Comms.sanitize_chat(long_text)
	ms = (Time.get_ticks_usec() - t0) / 1000.0
	check(clean.length() == Comms.CHAT_MAX_CHARS and ms < 50.0, "sanitize_chat on a 1M-char line: %.1f ms" % ms)
