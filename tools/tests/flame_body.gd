extends "res://tools/tests/qa_base.gd"
## M12 flame suite (flame agent): the emergency cabinet and the flamethrower on a single headless host with two fake
## workers (Bob, Chloe: host-side bodies without an owning peer, so the SERVER side runs directly on them).
##   godot --headless --path . -s res://tools/tests/run_test.gd -- --body=res://tools/tests/flame_body.gd --port=7957
## Pins: cabinet prompt states (Break glass / Restocking (N s) / Cash short / Hands full); breaking the glass takes the
## deposit, hands over the flamethrower, writes the worker up for misuse while nothing is alive (the Hostiles stub);
## cash short refuses with a toast; the restock countdown; _rpc_request_fire refused for a non-holder sender, in the
## back room, between shifts and when empty; fuel drains while firing (flame loop + particles on); a plant in the
## cone scorches after scorch_sec (STAT_SCORCHED, arson, ash on the soil, Story line) while a plant outside the cone
## is untouched; a READY crop burns without the harvest transition; a worker in the cone is ignited (stagger, item
## released, arson, Story line) and not twice within 10 s; an empty flamethrower is still thrown and picked up; a
## full game reset restocks the cabinet and despawns the flamethrowers.
## Every engine/script error fails the run unless announced (qa_base.gd).

const BOB := 2
const CHLOE := 3

var world: World
var items: ItemManager
var me: Player
var bob: Player
var chloe: Player
var cabinet: EmergencyCabinet
var _write_ups: Array = []    # [peer, reason]
var _purchases: Array = []    # [cost, buyer, what]
var _glass: Array = []        # by_peer per glass_broken
var _restocks: int = 0
var _ignites: Array = []      # [victim, by_peer]
var _scorches: Array = []     # [plot name, by_peer]


func _run() -> void:
	_label = "flame"
	await get_tree().process_frame
	var b: BalanceConfig = Config.balance
	b.cabinet_restock_sec = 2.0 # 90 s in the data; shortened so the countdown can be watched

	step("hosting")
	Game.start_host("Tester", port_arg(7957))
	await wait_until(func() -> bool: return Game.world != null and Game.local_player != null, 5.0, "world + local player exist")
	if Game.world == null:
		finish(); return
	world = Game.world
	items = world.items
	me = Game.local_player
	await wait_until(func() -> bool: return items.get_items().size() >= b.starting_watering_cans, 3.0, "starting cans spawned")
	GameState.request_start_round()
	await wait_until(func() -> bool: return GameState.is_playing(), 2.0, "shift running")
	GameState.worker_written_up.connect(func(p: int, reason: String, _c: int) -> void: _write_ups.append([p, reason]))
	GameState.purchase_made.connect(func(cost: int, buyer: int, what: String) -> void: _purchases.append([cost, buyer, what]))
	cabinet = station("EmergencyCabinet") as EmergencyCabinet
	if not check(cabinet != null, "Room/Stations/EmergencyCabinet exists"):
		finish(); return
	check(cabinet.global_position.distance_to(station("FuseBox").global_position) < 2.0, "the cabinet hangs next to the fuse box")
	check(not cabinet.broken and cabinet.restock_left == 0, "stocked at the start")
	cabinet.glass_broken.connect(func(by: int) -> void: _glass.append(by))
	cabinet.restocked.connect(func() -> void: _restocks += 1)
	check(Story.line("glass_broke") == "Glass broke." and Story.line("on_fire") == "%s is on fire." and Story.line("plot_burnt") == "%s burnt.",
			"Story knows the flame lines")

	step("two fake workers on the host")
	for entry in [[BOB, "Bob"], [CHLOE, "Chloe"]]:
		Net.players[entry[0]] = {"name": entry[1], "color": Net.PALETTE[entry[0] - 1]}
		world.server_spawn_player(entry[0])
	await wait_frames(3)
	bob = world.get_player(BOB)
	chloe = world.get_player(CHLOE)
	if not check(bob != null and chloe != null, "Bob and Chloe spawned"):
		finish(); return
	for p in [me, bob, chloe]:
		p.ignited.connect(func(by: int) -> void: _ignites.append([p.peer_id, by]))
	_place(bob, Vector3(6.0, 0.0, -5.5), 0.0)
	_place(chloe, Vector3(-6.0, 0.0, -5.5), 0.0)

	# ---------------------------------------------------------------- cabinet prompts
	step("cabinet: prompt states")
	check(cabinet.get_prompt(me) == EmergencyCabinet.PROMPT_BREAK and cabinet.can_interact(me) and cabinet.get_denied_reason(me) == "",
			"stocked, cash on hand: 'Break glass' (%s)" % cabinet.get_prompt(me))
	var can := items.server_spawn_item(Const.ITEM_WATERING_CAN, {}, Vector3(-3.0, 0.0, 3.0), 1) as WateringCan
	check(can != null and can.holder_id == 1, "holding a can")
	check(not cabinet.can_interact(me) and cabinet.get_denied_reason(me) == EmergencyCabinet.REASON_HANDS_FULL, "hands full: '%s'" % cabinet.get_denied_reason(me))
	items.server_release_holder(1)
	await wait_frames(2)
	var money0 := GameState.money
	check(GameState.server_try_spend(money0 - (b.cabinet_deposit - 1), 1, "test drain"), "drained the cash to %d" % GameState.money)
	check(not cabinet.can_interact(me) and cabinet.get_denied_reason(me) == EmergencyCabinet.REASON_CASH_SHORT, "cash short: '%s'" % cabinet.get_denied_reason(me))
	_stand_at(cabinet)
	await wait_physics(2)
	toasts.clear()
	cabinet.interact(me)
	await wait_frames(3)
	check(toast_seen(EmergencyCabinet.REASON_CASH_SHORT), "the request is refused with a 'Cash short' toast %s" % [toasts])
	check(items.get_items_of_type(Const.ITEM_FLAMETHROWER).is_empty() and not cabinet.broken and _glass.is_empty(), "nothing spawned, glass intact")
	GameState.server_add_money(money0 - GameState.money)
	check(GameState.money == money0, "cash restored to %d" % money0)

	# ---------------------------------------------------------------- break glass
	step("cabinet: break glass")
	Story.tick(7.0) # past the rate-limit gap of the shift-start line
	_write_ups.clear()
	_purchases.clear()
	var strikes0 := GameState.get_write_ups(1)
	var wu_stat0 := GameState.get_stat(1, Const.STAT_WRITE_UPS)
	cabinet.interact(me)
	await wait_until(func() -> bool: return items.get_held_by(1) is Flamethrower, 3.0, "the flamethrower lands in my hands")
	var ft := items.get_held_by(1) as Flamethrower
	if ft == null:
		finish(); return
	check(ft.item_type == Const.ITEM_FLAMETHROWER and ft.fuel == b.flamethrower_fuel_sec and not ft.firing, "full tank (%.1f s), not firing" % ft.fuel)
	check(ft.get_props() == {"fuel": b.flamethrower_fuel_sec, "firing": false}, "props %s" % [ft.get_props()])
	check(ft.get_label_text() == "Flamethrower (%d s)" % ceili(b.flamethrower_fuel_sec), "label '%s'" % ft.get_label_text())
	check(_purchases.size() == 1 and _purchases[0] == [b.cabinet_deposit, 1, EmergencyCabinet.DEPOSIT_WHAT], "the deposit went through GameState %s" % [_purchases])
	check(GameState.money == money0 - b.cabinet_deposit - b.write_up_fine, "cash: deposit and the misuse fine (%d)" % GameState.money)
	check(_write_ups == [[1, Const.WRITE_UP_MISUSE]], "written up for misuse (nothing alive) %s" % [_write_ups])
	check(GameState.get_write_ups(1) == strikes0 + 1 and GameState.get_stat(1, Const.STAT_WRITE_UPS) == wu_stat0 + 1, "strike + STAT_WRITE_UPS")
	check(_glass == [1], "glass_broken(1) on this peer %s" % [_glass])
	check(cabinet.broken and cabinet.restock_left == ceili(b.cabinet_restock_sec), "broken, restock in %d s" % cabinet.restock_left)
	check(cabinet.get_prompt(me) == EmergencyCabinet.PROMPT_RESTOCKING % cabinet.restock_left and not cabinet.can_interact(me)
			and cabinet.get_denied_reason(me) == cabinet.get_prompt(me), "prompt '%s'" % cabinet.get_prompt(me))
	check(not cabinet.get_node("Visual/Glass").visible and not cabinet.get_node("Visual/Stock").visible, "pane and stock hidden while broken")
	check(Story.get_pending_text() == "Glass broke." or Story.bark_log.has("Glass broke."), "Story: 'Glass broke.' queued behind the write-up (pending '%s')" % Story.get_pending_text())

	# ---------------------------------------------------------------- request validation
	step("fire request: holder only, floor only, shift only")
	items.server_release_holder(1)
	await wait_frames(2)
	check(items.server_give_item(ft, BOB) and ft.holder_id == BOB, "Bob holds it now")
	ft._rpc_request_fire(true) # a direct call: the sender is this host (peer 1), who does not hold it
	await wait_frames(2)
	check(not ft.firing, "_rpc_request_fire from a non-holder does nothing")
	check(not ft.server_request_fire(1, true) and not ft.server_request_fire(99, true) and not ft.server_request_fire(0, true), "server_request_fire refuses non-holders")
	check(GameState.server_send_to_backroom(BOB, 30.0), "Bob sent to the back room")
	check(not ft.server_request_fire(BOB, true) and not ft.firing, "refused from the back room")
	check(ft.holder_id == 0, "the back room took it out of his hands (ItemManager rule)")
	GameState.server_release_from_backroom(BOB)
	await wait_frames(1)
	_place(bob, Vector3(-3.0, 0.0, 4.5), 0.0) # the clear lane, facing -Z, nothing within reach
	await wait_physics(2)
	check(items.server_give_item(ft, BOB) and ft.holder_id == BOB, "Bob holds it again")
	check(ft.server_request_fire(BOB, true) and ft.firing, "the holder on the floor may fire")
	check(ft.server_request_fire(BOB, false) and not ft.firing, "and stop")

	step("fuel drains while firing")
	var fuel0 := ft.fuel
	check(ft.server_request_fire(BOB, true), "firing")
	await wait_frames(2)
	check(ft._loop_handle != 0 and Sfx.is_loop_playing(ft._loop_handle), "the flame loop runs")
	check(ft._flame != null and ft._flame.emitting, "flame particles on")
	await wait_sec(1.0)
	var used := fuel0 - ft.fuel
	check(ft.firing and used >= 0.7 and used <= 1.4, "about a second of fuel gone (%.2f s)" % used)
	check(ft.server_request_fire(BOB, false) and not ft.firing and ft._loop_handle == 0 and not ft._flame.emitting, "stopped: loop and particles off")

	# ---------------------------------------------------------------- scorch
	step("a plant in the cone scorches after scorch_sec; one outside is untouched")
	var plot1 := plot(1)
	var plot3 := plot(3)
	check(plot1.server_plant(&"budget") and plot1.server_water(2.0), "plot 1 planted and watered")
	check(plot3.server_plant(&"budget"), "plot 3 planted (3 m to the side)")
	plot1.scorched.connect(func(by: int) -> void: _scorches.append([String(plot1.name), by]))
	_place(bob, plot1.global_position + Vector3(-2.0, 0.0, 0.0), -PI * 0.5, -0.3) # 2 m in front of the plot, looking +X and a little down at it
	await wait_physics(2)
	check(ft.get_cone_origin().distance_to(bob.camera.global_position) < 0.01, "the cone starts at the holder's eye")
	check(Flamethrower.point_in_cone(ft.get_cone_origin(), bob.get_look_direction(), plot1.global_position + Vector3.UP * 0.8, b.flamethrower_range, b.flamethrower_half_angle_deg), "plot 1's plant is in the cone")
	check(not Flamethrower.point_in_cone(ft.get_cone_origin(), bob.get_look_direction(), plot3.global_position + Vector3.UP * 0.8, b.flamethrower_range, b.flamethrower_half_angle_deg), "plot 3's plant is not")
	_write_ups.clear()
	var scorched0 := GameState.get_stat(BOB, Const.STAT_SCORCHED)
	var t0 := Time.get_ticks_msec()
	check(ft.server_request_fire(BOB, true), "Bob fires at plot 1")
	await wait_until(func() -> bool: return plot1.stage == GrowPlot.Stage.EMPTY, 3.0, "plot 1 burnt")
	var took := (Time.get_ticks_msec() - t0) / 1000.0
	check(took >= b.scorch_sec * 0.8 and took <= b.scorch_sec + 0.6, "after about scorch_sec of exposure (%.2f s)" % took)
	check(plot1.strain_id == &"" and plot1.water == 0.0, "crop lost: plot reset")
	check(GameState.get_stat(BOB, Const.STAT_SCORCHED) == scorched0 + 1, "STAT_SCORCHED +1 for Bob")
	check(_write_ups == [[BOB, Const.WRITE_UP_ARSON]], "arson write-up for Bob (no hostile within 4 m) %s" % [_write_ups])
	check(_scorches == [["GrowPlot1", BOB]], "scorched(Bob) fired on this peer %s" % [_scorches])
	check(plot1.is_scorched() and plot1._ash != null and plot1._ash.visible, "ash on the soil")
	check(plot1.get_scorch_label() == "GrowPlot 1", "Story label '%s'" % plot1.get_scorch_label())
	check(Story.get_pending_text() == "GrowPlot 1 burnt." or Story.bark_log.has("GrowPlot 1 burnt."), "Story: 'GrowPlot 1 burnt.' (pending '%s')" % Story.get_pending_text())
	check(plot3.stage == GrowPlot.Stage.SEEDLING, "plot 3 untouched")
	await wait_sec(0.6)
	check(plot1.stage == GrowPlot.Stage.EMPTY and plot3.stage == GrowPlot.Stage.SEEDLING, "an empty plot is not scorched again, plot 3 still stands")
	check(ft.server_request_fire(BOB, false), "stop")

	step("a READY crop burns without the harvest transition")
	check(plot1.server_plant(&"budget"), "plot 1 replanted")
	plot1.stage = GrowPlot.Stage.READY
	await wait_frames(1)
	check(plot1.server_scorch(0), "server_scorch(0) on a READY crop")
	check(plot1.stage == GrowPlot.Stage.FLOWERING and plot1._scorch_pending, "steps through FLOWERING for a frame")
	check(not plot1.server_scorch(BOB), "a second scorch while pending is refused")
	await wait_frames(2)
	check(plot1.stage == GrowPlot.Stage.EMPTY and not plot1._scorch_pending, "then EMPTY")
	check(GameState.get_stat(BOB, Const.STAT_SCORCHED) == scorched0 + 1, "shooter 0: no stat")
	check(not plot1.server_scorch(BOB), "an empty plot refuses")

	# ---------------------------------------------------------------- ignite
	step("a worker in the cone is ignited, not twice within 10 s")
	_place_me(Vector3(6.0, 0.0, 5.0), 0.0)
	_place(bob, Vector3(-3.0, 0.0, 2.0), 0.0, -0.15) # facing -Z, a touch down
	_place(chloe, Vector3(-3.0, 0.0, 0.0), PI)       # 2 m ahead, facing Bob
	var chloe_can := items.server_spawn_item(Const.ITEM_WATERING_CAN, {}, Vector3(-4.0, 0.0, 0.0), CHLOE) as WateringCan
	await wait_physics(2)
	check(chloe_can != null and chloe_can.holder_id == CHLOE, "Chloe holds a can")
	_ignites.clear()
	_write_ups.clear()
	check(ft.server_request_fire(BOB, true), "Bob fires at Chloe")
	await wait_until(func() -> bool: return not _ignites.is_empty(), 2.0, "Chloe ignited")
	check(_ignites == [[CHLOE, BOB]], "ignited(Bob) on Chloe's node %s" % [_ignites])
	check(chloe.is_stunned(), "Chloe stumbles (hit_stun_sec)")
	check(chloe_can.holder_id == 0 and not chloe_can.is_flying(), "her can dropped")
	check(_write_ups == [[BOB, Const.WRITE_UP_ARSON]], "arson write-up for Bob %s" % [_write_ups])
	check(Story.get_pending_text() == "Chloe is on fire." or Story.bark_log.has("Chloe is on fire."), "Story: 'Chloe is on fire.' (pending '%s')" % Story.get_pending_text())
	check(chloe.get_node_or_null(^"Visual/IgniteFx") != null, "flame cosmetic on her body")
	await wait_sec(1.0)
	check(_ignites.size() == 1, "not ignited again within 10 s")
	check(ft.server_request_fire(BOB, false), "stop")
	await wait_until(func() -> bool: return not chloe.is_stunned(), 2.0, "Chloe recovers")

	# ---------------------------------------------------------------- empty
	step("empty: label, refusal, still thrown and picked up")
	_place(bob, Vector3(-3.0, 0.0, 4.5), 0.0)
	await wait_physics(2)
	ft.server_set_fuel(0.3)
	check(ft.server_request_fire(BOB, true), "fires the last 0.3 s")
	await wait_until(func() -> bool: return ft.fuel == 0.0 and not ft.firing, 2.0, "ran dry and stopped by itself")
	check(ft.is_empty() and ft.get_label_text() == "Flamethrower (empty)", "label '%s'" % ft.get_label_text())
	check(not ft.server_request_fire(BOB, true) and not ft.firing, "an empty flamethrower does not fire")
	check(items.server_throw_item(ft, bob.global_position + Vector3(0.0, 1.2, -0.3), Vector3(0.0, 3.0, -4.0), BOB), "Bob throws it")
	check(ft.is_flying() and ft.holder_id == 0, "in the air")
	await wait_until(func() -> bool: return not ft.is_flying(), 3.0, "landed")
	check(ft.global_position.z < 4.0 and absf(ft.global_position.y) < 0.05, "on the floor ahead of Bob %s" % ft.global_position)
	_place_me(ft.global_position + Vector3(0.0, 0.0, 0.8), 0.0)
	await wait_physics(2)
	check(ft.can_interact(me) and items.server_give_item(ft, 1) and ft.holder_id == 1, "picked up again")
	check(ft.get_label_text() == "Flamethrower (empty)", "still empty in hand")
	items.server_release_holder(1)
	await wait_frames(2)

	# ---------------------------------------------------------------- restock
	step("restock")
	await wait_until(func() -> bool: return not cabinet.broken, b.cabinet_restock_sec + 2.0, "restocked after %.1f s" % b.cabinet_restock_sec)
	check(_restocks == 1 and cabinet.restock_left == 0, "restocked signal, countdown at 0")
	check(GameState.money < b.cabinet_deposit and cabinet.get_denied_reason(me) == EmergencyCabinet.REASON_CASH_SHORT,
			"the fines left the team short of a deposit (%d): 'Cash short'" % GameState.money)
	GameState.server_add_money(b.cabinet_deposit * 3)
	check(cabinet.get_prompt(me) == EmergencyCabinet.PROMPT_BREAK and cabinet.can_interact(me), "'Break glass' again with cash on hand")
	check(cabinet.get_node("Visual/Glass").visible and cabinet.get_node("Visual/Stock").visible, "new pane, new stock")
	_stand_at(cabinet)
	await wait_physics(2)
	check(cabinet.server_break(me), "server_break hands over a second flamethrower")
	await wait_frames(2)
	var ft2 := items.get_held_by(1) as Flamethrower
	check(ft2 != null and ft2 != ft and ft2.fuel == b.flamethrower_fuel_sec, "a fresh one in my hands")
	toasts.clear()
	check(not cabinet.server_break(me) and toast_seen("Restocking ("), "refused while broken: '%s'" % [toasts])

	step("no firing between shifts; a reset restocks and clears the floor")
	GameState.time_left = 0.0
	await wait_until(func() -> bool: return GameState.is_round_over(), 3.0, "shift over")
	check(not ft2.server_request_fire(1, true), "firing refused between shifts")
	GameState.request_retry()
	await wait_until(func() -> bool: return GameState.phase == GameState.Phase.WAITING, 3.0, "retry -> WAITING")
	await wait_frames(3)
	check(not cabinet.broken and cabinet.restock_left == 0, "cabinet restocked by the reset")
	check(items.get_items_of_type(Const.ITEM_FLAMETHROWER).is_empty(), "flamethrowers despawned by the reset")
	finish()


# --- helpers --------------------------------------------------------------------------------------------------------

## Puts a remote (fake) body exactly at `pos` (synced pose + node) with yaw `yaw` and head pitch `pitch` (radians,
## negative = looking down).
func _place(p: Player, pos: Vector3, yaw: float, pitch: float = 0.0) -> void:
	p.net_position = pos
	p.net_yaw = yaw
	p.net_pitch = pitch
	p.position = pos
	p.rotation = Vector3(0.0, yaw, 0.0)
	p.head.rotation.x = pitch
	p.velocity = Vector3.ZERO


func _place_me(pos: Vector3, yaw: float) -> void:
	me.velocity = Vector3.ZERO
	me.global_position = pos + Vector3.UP * 0.02
	me.rotation = Vector3(0.0, yaw, 0.0)
	me.head.rotation.x = 0.0


## My body 1.2 m in front of a wall station, facing it.
func _stand_at(target: Node3D) -> void:
	var pos := target.global_position + target.global_basis.z.normalized() * 1.2
	pos.y = 0.02
	me.velocity = Vector3.ZERO
	me.global_position = pos
	me.look_at(Vector3(target.global_position.x, pos.y, target.global_position.z), Vector3.UP)
	me.head.rotation.x = 0.0


func wait_physics(n: int) -> void:
	for i in n:
		await get_tree().physics_frame
