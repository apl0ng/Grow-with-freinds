extends "res://tools/tests/qa_base.gd"
## Robustness sweep on a real solo host session (QA milestone 7). Single process:
##   godot --headless --path . -s res://tools/tests/run_test.gd -- --body=res://tools/tests/qa_robust_body.gd --port=7971
## Sections:
##   A  garbage input to every server-side entry point (unknown ids, bad peers, bad props, negative amounts)
##   B  rapid double presses (two requests in the same frame): pickup, buy, ShopUI double click, plant, water,
##      harvest, sell -> every effect happens exactly once, no misleading "Someone is holding this"
##   C  dropping near walls, corners, the well, crates and grow plots: the item always lands on the floor or a
##      low prop, never buried inside geometry or on a station, and stays reachable by the interaction ray
##   D  selling / planting with an item that was despawned in the same frame
##   E  UI locks: Escape closes the shop (not the pause menu), overlays stacking, return_to_menu while the shop /
##      pause menu / round-end overlay is open (locks cleared, mouse released, no stray UI nodes)
## Every engine/script error fails the run unless announced with expect_error().

var me: Player
var items: ItemManager
var shop: ShopCounter
var well: Well
var turnin: TurnInStation

func _run() -> void:
	_label = "robust"
	await get_tree().process_frame
	Config.growth_speed_override = 0.0
	if not await _host():
		finish(); return
	await _section_a_garbage()
	await _section_b_double_press()
	await _section_c_drops()
	await _section_d_despawn_same_frame()
	await _section_e_ui()
	finish()

func _host() -> bool:
	var err := Game.start_host("Robo", port_arg(7971))
	if not check(err == OK, "hosting"):
		return false
	if not await wait_until(func(): return Game.local_player != null and items_of(Const.ITEM_WATERING_CAN).size() == 2, 5.0, "world, player, cans"):
		return false
	me = Game.local_player
	items = Game.world.items
	shop = station("ShopCounter")
	well = station("Well")
	turnin = station("TurnInStation")
	return true

func _clear_hands() -> void:
	var held := items.get_held_by(1)
	if held != null:
		items.server_despawn_item(held)
	await wait_frames(1)

# ================================================================================================= A

func _section_a_garbage() -> void:
	step("A: garbage input to server entry points")
	stand_near(shop, 1.2)
	await wait_frames(2)
	var money := GameState.money
	for bad_id: StringName in [&"", &"nope", &"BUDGET", &"budget "]:
		var r: Dictionary = shop.server_buy_seed(1, bad_id)
		check(not bool(r["ok"]) and r["reason"] == ShopCounter.REASON_UNKNOWN_SEED, "buy seed '%s' -> Unknown seed" % bad_id)
	for bad_peer: int in [0, -1, 999999, 2]:
		var r2: Dictionary = shop.server_buy_seed(bad_peer, &"budget")
		check(not bool(r2["ok"]) and r2["reason"] == ShopCounter.REASON_NO_PLAYER, "buy for peer %d -> Player not found" % bad_peer)
	var r3: Dictionary = shop.server_buy_upgrade(1, &"nope")
	check(not bool(r3["ok"]) and r3["reason"] == ShopCounter.REASON_UNKNOWN_UPGRADE, "unknown upgrade refused")
	var r4: Dictionary = shop.server_buy_upgrade(424242, &"fertilizer")
	check(not bool(r4["ok"]) and r4["reason"] == ShopCounter.REASON_NO_PLAYER, "upgrade for a missing peer refused")
	check(GameState.money == money and items.get_items().size() == 2, "no money spent, nothing spawned")

	check(not GameState.server_try_spend(-50, 1, "x") and GameState.money == money, "negative spend refused")
	check(not GameState.server_try_spend(money + 1, 1, "x") and GameState.money == money, "overspend refused")
	GameState.server_add_sale(-10, 1) # warning only
	check(GameState.money == money and GameState.round_sales == 0, "negative sale ignored")
	check(not GameState.server_buy_upgrade(&"nope", 1), "GameState: unknown upgrade refused")
	GameState.server_add_money(-999999)
	check(GameState.money == 0, "money never goes negative (%d)" % GameState.money)
	GameState.server_add_money(money)

	var p := plot(2)
	check(not p.server_plant(&"nope") and p.is_empty(), "plot: unknown strain not planted")
	check(not p.server_water(1.0), "plot: watering an empty plot refused")
	check(p.server_plant(&"budget"), "plot: planted budget")
	check(not p.server_plant(&"golden"), "plot: double plant refused")
	p.water = 0.0
	check(not p.server_water(0.0) and not p.server_water(-3.0) and p.water == 0.0, "plot: zero/negative watering refused")
	check(not p.server_harvest(null) and not p.server_harvest(me), "plot: harvesting a growing plant refused")
	p.server_reset()

	expect_error("unknown item type 'banana'")
	check(items.server_spawn_item(&"banana") == null, "unknown item type -> null")
	var weird_can := items.server_spawn_item(Const.ITEM_WATERING_CAN, {"charges": -7, "bogus": Vector3.ONE}, Vector3(-2, 0, 1)) as WateringCan
	check(weird_can != null and weird_can.charges == 0, "negative charges clamped to 0")
	var text_can := items.server_spawn_item(Const.ITEM_WATERING_CAN, {"charges": "lots"}, Vector3(-2.5, 0, 1)) as WateringCan
	check(text_can != null and text_can.charges >= 0, "non-numeric charges tolerated (%d)" % (text_can.charges if text_can else -1))
	var odd := items.server_spawn_item(Const.ITEM_PRODUCT, {"strain_id": 42, "amount": -3}, Vector3(-3, 0, 1)) as Product
	check(odd != null and odd.amount == 1 and odd.get_seed() == null, "unknown-strain product with amount clamped to 1")
	var odd_packet := items.server_spawn_item(Const.ITEM_SEED_PACKET, {"strain_id": &"mystery"}, Vector3(-3.5, 0, 1)) as SeedPacket
	check(odd_packet != null and odd_packet.get_strain_name() == "Mystery", "unknown-strain packet shows 'Mystery'")
	await wait_frames(2)
	# Unknown products can't be sold, unknown seeds can't be planted.
	GameState.request_start_round()
	items.server_give_item(odd, 1)
	stand_near(turnin, 1.2)
	await wait_frames(2)
	toasts.clear()
	var before := GameState.money
	turnin.interact(me)
	await wait_frames(2)
	check(GameState.money == before and odd.is_inside_tree() and toast_seen(TurnInStation.REASON_BAD_PRODUCT), "unknown product refused at the bin")
	items.server_despawn_item(odd)
	await wait_frames(1)
	items.server_give_item(odd_packet, 1)
	stand_near(plot(3), 1.2)
	await wait_frames(2)
	toasts.clear()
	plot(3).interact(me)
	await wait_frames(2)
	check(plot(3).is_empty() and toast_seen("Unknown seed"), "unknown seed refused by the plot")
	await _clear_hands()
	for it in [weird_can, text_can]:
		items.server_despawn_item(it)
	# Items API with bad arguments.
	check(not items.server_give_item(null, 1), "give(null) refused")
	var can: Item = items_of(Const.ITEM_WATERING_CAN)[0]
	check(not items.server_give_item(can, 0) and not items.server_give_item(can, -4), "give to peer 0 / negative refused")
	items.server_despawn_item(null)
	items.server_release_holder(0)
	items.server_release_holder(999)
	check(items.get_held_by(0) == null and items.get_held_by(-1) == null, "get_held_by(<=0) is null")
	await wait_frames(2)
	check(items.get_items().size() == 2 and items_of(Const.ITEM_WATERING_CAN).size() == 2, "only the 2 cans remain")

# ================================================================================================= B

func _section_b_double_press() -> void:
	step("B: double presses (two requests in the same frame)")
	await _clear_hands()
	var can: Item = items_of(Const.ITEM_WATERING_CAN)[0]
	stand_near(can, 0.7)
	await wait_frames(2)
	toasts.clear()
	can.interact(me)
	can.interact(me)
	await wait_frames(2)
	check(can.holder_id == 1, "pickup x2: holding the can")
	check(toasts.is_empty(), "pickup x2: no error toast for the second press %s" % [toasts])
	items.server_release_holder(1)
	await wait_frames(1)

	# Buy twice in the same frame (bypassing the UI's own guard): one packet, money spent once.
	stand_near(shop, 1.2)
	await wait_frames(2)
	var money := GameState.money
	toasts.clear()
	shop.request_buy_seed(&"budget")
	shop.request_buy_seed(&"budget")
	await wait_frames(2)
	check(items_of(Const.ITEM_SEED_PACKET).size() == 1 and GameState.money == money - 20, "buy x2: one packet, $20 spent once")
	check(toast_seen(ShopCounter.REASON_HANDS_FULL), "buy x2: second refused with hands full")
	await _clear_hands()
	# ShopUI: double click on BUY -> one request.
	shop.open_shop_for(me)
	await wait_frames(2)
	var ui := shop.get_shop_ui()
	var card := ui.get_card(ShopCounter.KIND_SEED, &"budget") if ui != null else null
	money = GameState.money
	toasts.clear()
	if check(card != null and card.is_buy_enabled(), "shop UI open with an enabled Budget card"):
		card.get_buy_button().pressed.emit()
		# A real second click only reaches an enabled button (the host's answer is instant: now HANDS FULL).
		check(not card.is_buy_enabled(), "UI: BUY disabled right after the purchase (hands full)")
		if card.is_buy_enabled():
			card.get_buy_button().pressed.emit()
		await wait_frames(2)
		check(GameState.money == money - 20 and items_of(Const.ITEM_SEED_PACKET).size() == 1, "UI double click: one purchase")
		check(not toast_seen(ShopCounter.REASON_HANDS_FULL), "UI double click: no error toast")
	shop.close_shop()
	await wait_frames(1)

	# Plant twice.
	var p := plot(1)
	stand_near(p, 1.2)
	await wait_frames(2)
	p.interact(me)
	p.interact(me)
	await wait_frames(2)
	check(p.stage == GrowPlot.Stage.SEEDLING and items_of(Const.ITEM_SEED_PACKET).is_empty(), "plant x2: planted once, packet consumed")
	# Water twice.
	items.server_give_item(can, 1)
	await wait_frames(1)
	var charges := int(can.get(&"charges"))
	p.interact(me)
	p.interact(me)
	await wait_frames(2)
	check(int(can.get(&"charges")) == charges - 1 and p.water > 0.9, "water x2: one charge used")
	items.server_release_holder(1)
	await wait_frames(1)
	# Harvest twice.
	p.stage = GrowPlot.Stage.READY
	await wait_frames(1)
	p.interact(me)
	p.interact(me)
	await wait_frames(2)
	check(items_of(Const.ITEM_PRODUCT).size() == 1 and p.is_empty(), "harvest x2: one product")
	# Sell twice.
	stand_near(turnin, 1.2)
	await wait_frames(2)
	money = GameState.money
	var sales := GameState.round_sales
	turnin.interact(me)
	turnin.interact(me)
	await wait_frames(2)
	check(GameState.money == money + 60 and GameState.round_sales == sales + 60 and items_of(Const.ITEM_PRODUCT).is_empty(), "sell x2: sold once (+$60)")
	# Two sell requests while the despawn is still pending: the server-side guard.
	items.server_spawn_item(Const.ITEM_PRODUCT, {"strain_id": &"budget", "amount": 1}, Vector3.ZERO, 1)
	await wait_frames(1)
	money = GameState.money
	turnin._rpc_request_interact()
	turnin._rpc_request_interact()
	await wait_frames(2)
	check(GameState.money == money + 60, "raw sell requests x2 in one frame: paid once")

# ================================================================================================= C

## A drop result is good if it lies inside the room, is not inside static geometry, does not rest on a station
## and the interaction ray from a standing player looking at it hits the item itself.
func _check_drop(tag: String, it: Item) -> void:
	var pos := it.global_position
	var space := me.get_world_3d().direct_space_state
	var b: AABB = Game.world.room.get_bounds()
	check(b.grow(-0.05).has_point(pos + Vector3.UP * 0.05), "%s: inside the room (%s)" % [tag, pos])
	var pq := PhysicsPointQueryParameters3D.new()
	pq.position = pos + Vector3.UP * 0.06
	pq.collision_mask = Const.LAYER_WORLD
	var inside := space.intersect_point(pq, 1)
	check(inside.is_empty(), "%s: not buried in %s" % [tag, "" if inside.is_empty() else str(inside[0]["collider"].get_path())])
	var below := space.intersect_ray(PhysicsRayQueryParameters3D.create(pos + Vector3.UP * 0.2, pos + Vector3.DOWN * 0.3, Const.LAYER_WORLD))
	var on_station := not below.is_empty() and (int(below["collider"].collision_layer) & Const.LAYER_INTERACTABLE) != 0
	check(not on_station, "%s: not resting on a station" % tag)
	# Reachability: from the dropper's eye towards the item, the first thing hit must be the item.
	var eye := me.get_node("%Camera").global_position as Vector3
	var target := pos + Vector3.UP * 0.1
	var hit := space.intersect_ray(PhysicsRayQueryParameters3D.create(eye, eye + (target - eye) * 1.5,
			Const.LAYER_WORLD | Const.LAYER_INTERACTABLE | Const.LAYER_ITEM, [me.get_rid()]))
	var hit_item := false
	if not hit.is_empty():
		var n: Node = hit["collider"]
		while n != null and not (n is Item):
			n = n.get_parent()
		hit_item = n == it
	check(hit_item, "%s: interaction ray reaches it (hit %s)" % [tag, "nothing" if hit.is_empty() else str(hit["collider"].get_path())])

func _drop_from(tag: String, feet: Vector3, look_at_point: Vector3, pitch_deg: float = -20.0) -> void:
	await _clear_hands()
	var it := items.server_spawn_item(Const.ITEM_SEED_PACKET, {"strain_id": &"budget"}, Vector3.ZERO, 1)
	me.velocity = Vector3.ZERO
	me.global_position = feet
	var flat := Vector3(look_at_point.x, feet.y, look_at_point.z)
	if flat.distance_to(feet) > 0.01:
		me.look_at(flat, Vector3.UP)
	me.head.rotation.x = deg_to_rad(pitch_deg)
	await wait_frames(1)
	me.global_position = feet # undo any physics push-out from the frame in between
	items.request_drop()
	await wait_frames(2)
	check(it.holder_id == 0, "%s: dropped" % tag)
	await _check_drop(tag, it)
	items.server_despawn_item(it)
	await wait_frames(1)

func _section_c_drops() -> void:
	step("C: dropping near walls, corners, the well, crates and plots")
	me.process_mode = Node.PROCESS_MODE_DISABLED # keep the body exactly where the test puts it
	await _clear_hands()
	var b: AABB = Game.world.room.get_bounds()
	var cx := b.get_center().x
	var cz := b.get_center().z
	var west := b.position.x
	var east := b.end.x
	var north := b.position.z
	var south := b.end.z
	await _drop_from("west wall", Vector3(west + 0.45, 0.0, cz + 2.0), Vector3(west - 1, 0, cz + 2.0))
	await _drop_from("north wall", Vector3(cx - 3.0, 0.0, north + 0.45), Vector3(cx - 3.0, 0, north - 1))
	await _drop_from("south wall", Vector3(cx - 3.2, 0.0, south - 0.45), Vector3(cx - 3.2, 0, south + 1))
	await _drop_from("east wall", Vector3(east - 0.45, 0.0, cz + 4.6), Vector3(east + 1, 0, cz + 4.6))
	await _drop_from("corner (diagonal)", Vector3(west + 0.5, 0.0, north + 0.5), Vector3(west - 1, 0, north - 1))
	await _drop_from("wall, looking straight down", Vector3(west + 0.45, 0.0, cz - 2.0), Vector3(west - 1, 0, cz - 2.0), -89.0)
	await _drop_from("wall, looking straight up", Vector3(west + 0.45, 0.0, cz - 2.5), Vector3(west - 1, 0, cz - 2.5), 89.0)
	# The well: 0.76 m ring under the 1.0 m wall check (used to bury the item inside the ring).
	for d in [1.25, 1.5, 1.8]:
		var front: Vector3 = well.global_position + well.global_basis.z.normalized() * d
		await _drop_from("well front at %.2f m" % d, Vector3(front.x, 0.0, front.z), well.global_position)
	var side: Vector3 = well.global_position + well.global_basis.x.normalized() * 1.4
	await _drop_from("well side", Vector3(side.x, 0.0, side.z), well.global_position)
	# A lone 0.9 m crate.
	var crate := Game.world.room.get_node_or_null("Decor/CrateC") as Node3D
	if crate != null:
		var toward := (Vector3(cx, 0, cz) - crate.global_position)
		toward.y = 0.0
		var spot: Vector3 = crate.global_position + toward.normalized() * 1.05
		await _drop_from("crate", Vector3(spot.x, 0.0, spot.z), crate.global_position)
	# An EMPTY grow plot: the item must not rest on the soil (it would be buried in the plant once planted).
	var p := plot(5)
	var pf: Vector3 = p.global_position + p.global_basis.z.normalized() * 1.2
	await _drop_from("empty plot", Vector3(pf.x, 0.0, pf.z), p.global_position)
	me.process_mode = Node.PROCESS_MODE_INHERIT

# ================================================================================================= D

func _section_d_despawn_same_frame() -> void:
	step("D: item despawned in the same frame as the request")
	await _clear_hands()
	stand_near(turnin, 1.2)
	await wait_frames(2)
	var product := items.server_spawn_item(Const.ITEM_PRODUCT, {"strain_id": &"purple", "amount": 1}, Vector3.ZERO, 1)
	await wait_frames(1)
	var money := GameState.money
	toasts.clear()
	items.server_despawn_item(product)
	turnin.interact(me)             # local prediction path
	turnin._rpc_request_interact()  # raw server path
	await wait_frames(2)
	check(GameState.money == money and GameState.round_sales >= 0, "no sale for a despawned product")
	check(toast_seen(TurnInStation.REASON_EMPTY), "told 'Nothing to sell'")
	# Same for planting with a packet that vanished (e.g. RETRY despawned it) in the same frame.
	var packet := items.server_spawn_item(Const.ITEM_SEED_PACKET, {"strain_id": &"budget"}, Vector3.ZERO, 1)
	await wait_frames(1)
	var p := plot(6)
	stand_near(p, 1.2)
	await wait_frames(2)
	items.server_despawn_item(packet)
	p._rpc_request_interact()
	await wait_frames(2)
	check(p.is_empty(), "no planting with a despawned packet")
	# And a request for an item that is already freed.
	var gone := items.server_spawn_item(Const.ITEM_SEED_PACKET, {"strain_id": &"budget"}, Vector3(-2, 0, 2))
	await wait_frames(1)
	gone.free()
	await wait_frames(1)
	check(items.get_held_by(1) == null and items_of(Const.ITEM_SEED_PACKET).is_empty(), "freed item leaves no trace")

# ================================================================================================= E

func _press_escape() -> void:
	for pressed: bool in [true, false]:
		var ev := InputEventKey.new()
		ev.keycode = KEY_ESCAPE
		ev.physical_keycode = KEY_ESCAPE
		ev.pressed = pressed
		get_viewport().push_input(ev)
	await wait_frames(2)

func _hud() -> HUD:
	return Game.world.get_node("HUD") as HUD if Game.world != null else null

func _stray_ui() -> Array:
	var out := []
	for c in get_tree().root.get_children():
		if c is ShopUI or c is CanvasLayer and c != Game and not c.is_queued_for_deletion():
			out.append(c.name)
	return out

func _check_menu_state(tag: String) -> void:
	check(Game.world == null and GameState.phase == GameState.Phase.MENU, "%s: back in the menu" % tag)
	check(not Game.is_ui_locked(), "%s: every UI lock cleared" % tag)
	# Headless cannot observe the real mouse mode; Game's rule is: captured only with a world and no lock.
	check(Game.world == null, "%s: mouse released (no world -> Game keeps it visible)" % tag)
	check(_stray_ui().is_empty(), "%s: no stray UI layers under the root %s" % [tag, _stray_ui()])
	check(get_tree().get_first_node_in_group(Game.MENU_GROUP) != null, "%s: main menu present" % tag)

func _section_e_ui() -> void:
	step("E: UI locks, Escape routing, return_to_menu with overlays open")
	await _clear_hands()
	var hud := _hud()
	stand_near(shop, 1.2)
	await wait_frames(2)
	shop.open_shop_for(me)
	await wait_frames(2)
	check(shop.is_shop_open() and Game.is_ui_locked_by(&"shop"), "shop open, locked")
	await _press_escape()
	check(not shop.is_shop_open() and not hud.pause_menu.is_open(), "Escape closed the shop and did NOT open the pause menu")
	check(not Game.is_ui_locked(), "no lock left after closing the shop")
	await _press_escape()
	check(hud.pause_menu.is_open() and Game.is_ui_locked_by(&"pause"), "next Escape opens the pause menu")
	await _press_escape()
	check(not hud.pause_menu.is_open() and not Game.is_ui_locked(), "Escape closes the pause menu")

	step("E: round ends while the shop is open / while the pause menu is open")
	shop.open_shop_for(me)
	await wait_frames(2)
	GameState.server_add_sale(GameState.quota, 1)
	await wait_frames(2)
	check(GameState.phase == GameState.Phase.ROUND_SUCCESS, "round success")
	check(not shop.is_shop_open() and not Game.is_ui_locked_by(&"shop"), "shop closed itself at round end")
	check(hud.round_end.is_open() and Game.is_ui_locked_by(&"round_end"), "round-end overlay owns the UI")
	await _press_escape()
	check(not hud.pause_menu.is_open(), "Escape does not open the pause menu over the round-end overlay")
	GameState.request_next_round()
	await wait_frames(2)
	check(not hud.round_end.is_open() and not Game.is_ui_locked(), "next round: overlay gone, unlocked")
	await _press_escape()
	check(hud.pause_menu.is_open(), "pause menu open during round 2")
	GameState.time_left = 0.05
	await wait_until(func(): return GameState.phase == GameState.Phase.ROUND_FAILED, 3.0, "round failed while paused")
	check(hud.round_end.is_open(), "round-end overlay shown even with the pause menu open")
	await _press_escape()
	check(not hud.pause_menu.is_open() and hud.round_end.is_open() and Game.is_ui_locked_by(&"round_end"),
			"Escape closes the pause menu; the round-end overlay stays and keeps its lock")

	step("E: return_to_menu with the round-end overlay open")
	Game.return_to_menu()
	await wait_frames(3)
	_check_menu_state("from round-end")

	step("E: return_to_menu with the shop open")
	if not await _host():
		return
	stand_near(shop, 1.2)
	await wait_frames(2)
	shop.open_shop_for(me)
	await wait_frames(2)
	check(Game.is_ui_locked_by(&"shop"), "shop open")
	Game.return_to_menu()
	await wait_frames(3)
	_check_menu_state("from shop")

	step("E: return_to_menu with the pause menu open (its Leave button)")
	if not await _host():
		return
	hud = _hud()
	await _press_escape()
	check(hud.pause_menu.is_open(), "pause menu open")
	hud.pause_menu.leave_button.pressed.emit()
	await wait_frames(3)
	_check_menu_state("from pause Leave")

	step("E: host again, everything fresh")
	if not await _host():
		return
	check(GameState.phase == GameState.Phase.WAITING and GameState.round_number == 1 and GameState.money == Config.balance.starting_money,
			"fresh session: WAITING, round 1, $%d" % Config.balance.starting_money)
	check(items.get_items().size() == 2 and not Game.is_ui_locked(), "fresh session: 2 cans, no locks")
	Game.return_to_menu()
	await wait_frames(3)
	_check_menu_state("final")
