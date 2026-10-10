extends "res://tools/tests/smoke_base.gd"
## Store-page screenshots (M22 ship, RELEASE.md R6) on the REAL renderer (lead tool, not a suite): eight moments of the
## chill game at 1920x1080, staged with the camera positions and calls of the m14 / m15 / m17 / m18 / m19 capture tools.
##   1_alley_van_board   the alley: the van with its doors open, the notice board filled in, three workers waiting
##   2_crew_trays        three workers in the pen between the trays (a can, a bundle, a point), plants at every stage
##   3_supply_window     the supply window open, cash on hand to spend
##   4_power_cut         the power cut: the room dark, a worker at the fuse box
##   5_sprinklers        the sprinklers over the trays, the crew still in the pen
##   6_driveby_warning   a drive-by's warning (tyres outside, the banner), two workers down on the floor
##   7_black_damp        Black Damp's cloud over a ripe tray, a worker in it (the grey haze round his head)
##   8_paid_in_full      the PAID IN FULL card, four workers on the report
##   godot --rendering-method forward_plus --resolution 1920x1080 --path . \
##       -s res://tools/tests/run_test.gd -- --body=res://tools/tests/store_shots_body.gd --out=<abs dir> \
##       --port=7977 --mute --no-mic --chill --replay --run=B5VP --event-delay=900 [--borderless]
## The pictures are the window's size. A 1920x1080 window does not fit a 1920x1080 screen with its title bar: there add
## --borderless (a borderless window at the screen's corner, about 70 s; the mouse stays free). Every shot whose size is
## not 1920x1080 says so. The chill game is the windowed default (--chill makes it explicit; a headless run needs it).
## Shift 1 is made the final notice (final_shift_by_team = 1, as m17 does) so the last shot can clear the run; the clock
## is held above half so the Boss's half-time look never fires; no strain walks off (mutation chances 0, in memory only).
## Without --career-file the record stays in memory (Career never writes in a scripted run). Under --headless it stages
## every moment and saves nothing (a dry run of the staging). A watchdog ends the run after 150 s.

const SIZE := Vector2i(1920, 1080)
## The three fake workers: [peer id, name]. Net.PALETTE[peer - 1] is their colour.
const CREW: Array = [[2, "Dale"], [3, "Marge"], [4, "Gus"]]
const HATS := {2: "hard_hat", 3: "hairnet", 4: "cone"}
## The trays of the main room's pen, planted for the crew shot: [station, strain, stage].
const TRAYS: Array = [
	["GrowPlot1", &"purple", GrowPlot.Stage.READY],
	["GrowPlot2", &"budget", GrowPlot.Stage.FLOWERING],
	["GrowPlot3", &"golden", GrowPlot.Stage.VEGETATIVE],
	["GrowPlot4", &"creeper", GrowPlot.Stage.SEEDLING],
	["GrowPlot5", &"budget", GrowPlot.Stage.READY],
	["GrowPlot6", &"purple", GrowPlot.Stage.FLOWERING],
]
## The clock is kept at or above this (the final notice's half-time look comes at half of 300 s).
const CLOCK_FLOOR := 250.0
## The floor's walking height for a placed worker (m17 / m18 / m19 place them at 0.05).
const FLOOR_Y := 0.05

var _out := "user://store_shots"
var _me: Player
var _shots := true
var _crew: Array[Player] = []


func _process(_delta: float) -> void:
	if _shots and Input.mouse_mode != Input.MOUSE_MODE_VISIBLE:
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE


func _run() -> void:
	_label = "store_shots"
	get_tree().create_timer(150.0).timeout.connect(func() -> void:
		print("store_shots: watchdog, quitting")
		get_tree().quit(2))
	_shots = DisplayServer.get_name() != "headless"
	if not _shots:
		print("store_shots: headless: staging every moment, saving nothing (run it without --headless for the pictures)")
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--out="):
			_out = a.trim_prefix("--out=")
	if _shots:
		DirAccess.make_dir_recursive_absolute(_out)
		_size_window()
	else:
		get_tree().root.size = SIZE
	if not Config.chill_enabled:
		print("store_shots: this is NOT the chill game (pass --chill): the store page shows the chill game")
	if not check(Config.replay_enabled, "replay is on (--replay: the final notice needs it)"):
		finish()
		return
	Config.balance.final_shift_by_team = [1, 1, 1, 1]
	for s: SeedDef in Config.balance.seeds:
		if s != null:
			s.mutation_chance = 0.0
	Config.lobby_enabled = true
	await get_tree().process_frame
	Game.start_host("Zay", port_arg(7977))
	await wait_until(func() -> bool: return Game.world != null and Game.local_player != null, 8.0, "world + local player")
	if Game.world == null:
		finish()
		return
	_me = Game.local_player
	var world: World = Game.world
	var lobby: Lobby = world.lobby
	if not check(lobby != null and lobby.get_van() != null and lobby.get_board() != null, "the alley, the van, the board"):
		finish()
		return
	for entry: Array in CREW:
		var peer := int(entry[0])
		Net.players[peer] = {"name": String(entry[1]), "color": Net.PALETTE[peer - 1]}
		var worker: Player = world.server_spawn_player(peer)
		if worker != null:
			_crew.append(worker)
	Net.players_changed.emit()
	await wait_frames(3)
	Net._rpc_hats_sync(HATS)
	if not check(_crew.size() == CREW.size(), "three more workers"):
		finish()
		return
	await wait_sec(1.0)

	step("1: the alley, the van, the board")
	check(GameState.phase == GameState.Phase.WAITING and lobby.contains_point(_me.global_position), "waiting in the alley")
	check(GameState.is_final_shift(), "shift 1 is the final notice (the last shot clears it)")
	var o := lobby.global_position
	var van: Van = lobby.get_van()
	var board: AlleyBoard = lobby.get_board()
	board.server_record_shift(true, 2, 1385, 1310,
			PackedStringArray(["Dale did the least.", "Marge deposited the most.", "Gus was written up the most."]))
	var entry_point := van.get_entry_point()
	_place(_crew[0], entry_point + Vector3(0.5, 0.0, 0.3), van.global_position + Vector3.UP)
	_place(_crew[1], board.global_position + Vector3(-1.0, 0.0, -0.3), board.global_position)
	_place(_crew[2], o + Vector3(3.3, 0.0, 2.2), o + Vector3(0.0, 0.0, 2.2))   # his back to the crate by the pallet
	await wait_sec(0.3)
	_crew[2].server_emote(Player.EMOTE_SLUMP)
	_look(o + Vector3(-1.6, 0.0, 6.8), o + Vector3(3.0, 1.5, 0.5))
	await wait_sec(1.0)
	await _shot("1_alley_van_board")
	_crew[2].server_emote(Player.EMOTE_NONE)
	await wait_sec(0.4)

	step("the ride")
	GameState.request_start_round()   # the host's Enter: the van leaves with everyone moved to the floor
	await wait_until(func() -> bool: return GameState.is_playing(), 10.0, "the ride ends in a running shift")
	if not GameState.is_playing():
		finish()
		return
	Events.set(&"_next_in", -1.0)
	GameState.server_add_money(900 - GameState.money)
	await wait_sec(3.0)   # the GO banner is gone
	check(not lobby.contains_point(_me.global_position), "on the floor after the ride")

	step("2: the crew at the trays")
	_hold_clock()
	var room: Room = world.room
	var plots: Dictionary = {}
	for row: Array in TRAYS:
		var plot := room.get_station(String(row[0])) as GrowPlot
		if not check(plot != null, String(row[0])):
			continue
		plot.server_reset()
		check(plot.server_plant(StringName(row[1])), "%s planted with %s" % [row[0], row[1]])
		plot.server_water(1.0)
		plot.stage = row[2]
		plots[String(row[0])] = plot
	if not check(plots.size() == TRAYS.size(), "six trays planted"):
		finish()
		return
	var p1: Vector3 = (plots["GrowPlot1"] as Node3D).global_position
	var p2: Vector3 = (plots["GrowPlot2"] as Node3D).global_position
	var p4: Vector3 = (plots["GrowPlot4"] as Node3D).global_position
	var p5: Vector3 = (plots["GrowPlot5"] as Node3D).global_position
	var aisle_x := (p1.x + p2.x) * 0.5   # between the two rows (m12 stood its camera there)
	_place(_crew[0], Vector3(aisle_x, 0.0, p1.z + 0.4), p1 + Vector3.UP * 0.5)
	_place(_crew[1], Vector3(aisle_x, 0.0, p4.z + 0.5), p4 + Vector3.UP * 0.5)
	_place(_crew[2], Vector3(aisle_x + 0.25, 0.0, p5.z - 0.2), Vector3(aisle_x, 1.0, p1.z - 2.0))
	var cans: Array[Item] = world.items.get_items_of_type(Const.ITEM_WATERING_CAN)
	if check(not cans.is_empty(), "a watering can for Dale"):
		world.items.server_give_item(cans[0], int(CREW[0][0]))
	var bundle: Item = world.items.server_spawn_item(Const.ITEM_PRODUCT, {"strain_id": &"purple", "amount": 1},
			_crew[1].global_position + Vector3(0.0, 1.0, 0.0), 0)
	for i in 3:
		await get_tree().physics_frame
	if check(bundle != null, "a bundle for Marge"):
		world.items.server_give_item(bundle, int(CREW[1][0]))
	await wait_sec(0.4)
	_crew[2].set(&"net_pitch", 0.15)
	_crew[2].server_emote(Player.EMOTE_POINT)
	_look(Vector3(aisle_x - 0.4, 0.0, p5.z + 1.3), Vector3(aisle_x, 0.9, p1.z - 0.5))
	await wait_sec(0.9)
	await _shot("2_crew_trays")
	_crew[2].server_emote(Player.EMOTE_NONE)

	step("3: the supply window")
	_hold_clock()
	var counter := room.get_station("ShopCounter") as ShopCounter
	if check(counter != null, "the supply window"):
		teleport(_me, counter)
		await wait_sec(0.3)
		counter.interact(_me)
		await wait_sec(1.0)
		var ui := counter.get_shop_ui()
		check(ui != null and ui.is_open(), "the supply window is open")
		await _shot("3_supply_window")
		if ui != null and ui.is_open():
			ui.close()
		await wait_sec(0.4)

	step("4: the power cut")
	_hold_clock()
	var fuse := room.get_station("FuseBox")
	if check(fuse != null, "the fuse box"):
		world.items.server_release_holder(int(CREW[0][0]))   # Dale puts the can down first
		var at := room.get_station_access_point("FuseBox", 0.9)
		_place(_crew[0], Vector3(at.x, 0.0, at.z), fuse.global_position)
		check(Events.server_start_event(Events.EVENT_POWER_CUT), "the power goes")
		_look(Vector3(-6.6, 0.0, -5.4), fuse.global_position.lerp(_crew[0].global_position + Vector3.UP, 0.5))
		await wait_sec(1.8)
		check(not Events.power_on, "the room is dark")
		await _shot("4_power_cut")
		_end_event()
		await wait_sec(3.2)   # the lights come back, the toasts fade

	step("5: the sprinklers")
	_hold_clock()
	_place(_crew[0], Vector3(aisle_x, 0.0, p1.z + 0.4), p1 + Vector3.UP * 0.5)
	check(Events.server_start_event(Events.EVENT_SPRINKLERS), "the sprinklers")
	_look(Vector3(-1.0, 0.0, 2.5), Vector3(5.0, 1.0, -1.0))
	await wait_sec(1.6)
	await _shot("5_sprinklers")
	_end_event()
	await wait_sec(3.2)

	step("6: the drive-by's warning")
	_hold_clock()
	_place(_crew[0], Vector3(-2.0, 0.0, 3.0), Vector3(0.6, 1.0, 0.4))   # m18's gesture spots, facing the camera
	_place(_crew[1], Vector3(-4.0, 0.0, 2.0), Vector3(0.6, 1.0, 0.4))
	_crew[0].crouching = true
	_crew[1].crouching = true
	check(Events.server_start_event(Events.EVENT_DRIVEBY), "tyres outside")
	_look(Vector3(0.6, 0.0, 0.4), Vector3(-5.0, 1.2, 10.5))
	await wait_sec(1.2)
	check(not Events.is_driveby_firing(), "still the warning")
	await _shot("6_driveby_warning")
	_end_event()
	_crew[0].crouching = false
	_crew[1].crouching = false
	await wait_sec(3.2)

	step("7: Black Damp's cloud")
	_hold_clock()
	var damp := room.get_station("GrowPlot3") as GrowPlot
	var spores := Spores.get_instance()
	if check(damp != null and spores != null, "GrowPlot3 and the spores"):
		damp.server_reset()
		check(damp.server_plant(&"damp"), "Black Damp planted")
		damp.server_water(1.0)
		damp.stage = GrowPlot.Stage.READY
		var d := damp.global_position
		_place(_crew[0], d + Vector3(-0.9, 0.0, 1.0), d + Vector3.UP * 0.6)   # inside the cloud's 2.6 m
		_look(d + Vector3(-2.6, 0.0, 2.4), d + Vector3(0.0, 0.9, 0.0))       # outside it: the screen stays clear
		await wait_sec(1.0)
		check(spores.server_puff(damp, Spores.CAUSE_HIT), "the tray puffs")
		await wait_sec(0.8)
		check(spores.is_fogged(int(CREW[0][0])) and not spores.is_fogged(1), "Dale breathes it, the camera does not")
		await _shot("7_black_damp")
		spores.server_clear()
		await wait_sec(1.0)

	step("8: PAID IN FULL")
	_hold_clock()
	_look(Vector3(-1.0, 0.0, 2.5), Vector3(3.0, 1.2, -3.0))
	Config.balance.end_round_on_quota_met = true
	var due := GameState.quota
	var shares: Array = [[int(CREW[0][0]), 0.34], [1, 0.28], [int(CREW[1][0]), 0.22]]
	var paid := 0
	for share: Array in shares:
		var amount := int(due * float(share[1]))
		GameState.server_add_sale(amount, int(share[0]))
		paid += amount
	GameState.server_add_sale(maxi(due - paid, 1), int(CREW[2][0]))   # the last deposit meets the payment
	await wait_until(func() -> bool: return GameState.is_run_cleared(), 5.0, "the run is cleared")
	await wait_sec(2.0)
	await _shot("8_paid_in_full")
	finish()


## Ends the running event and keeps the scheduler from dealing another one while the staging goes on.
func _end_event() -> void:
	Events.server_end_event()
	Events.set(&"_next_in", -1.0)


## Keeps the clock above half (the final notice's half-time look would put its banner over the next shot).
func _hold_clock() -> void:
	if GameState.time_left < CLOCK_FLOOR:
		GameState.time_left = CLOCK_FLOOR + 20.0


## Puts the fake `worker` at `at` (x / z; on the floor) facing `face` (world space).
func _place(worker: Player, at: Vector3, face: Vector3) -> void:
	var dir := face - at
	dir.y = 0.0
	var yaw := atan2(-dir.x, -dir.z) if dir.length() > 0.01 else 0.0
	worker.place_at(Transform3D(Basis(Vector3.UP, yaw), Vector3(at.x, FLOOR_Y, at.z)))


## Puts the local player at `pos` (x / z; the height stays) looking at `target` (world space).
func _look(pos: Vector3, target: Vector3) -> void:
	_me.velocity = Vector3.ZERO
	_me.global_position = Vector3(pos.x, _me.global_position.y, pos.z)
	var eye := _me.global_position + Vector3.UP * 1.6
	var dir := (target - eye).normalized()
	_me.rotation = Vector3(0.0, atan2(-dir.x, -dir.z), 0.0)
	_me.head.rotation.x = asin(clampf(dir.y, -1.0, 1.0))


## The window at 1920x1080 (with --borderless: no frame, at the corner of its screen, so it fits a 1920x1080 screen).
func _size_window() -> void:
	var win := get_window()
	if Config.has_arg("borderless"):
		win.borderless = true
		win.position = DisplayServer.screen_get_position(win.current_screen)
	win.size = SIZE


func _shot(shot: String) -> void:
	if not _shots:
		print("store_shots: (dry run) %s staged" % shot)
		return
	await get_tree().process_frame
	await RenderingServer.frame_post_draw
	var img := get_viewport().get_texture().get_image()
	if img.get_size() != SIZE:
		print("store_shots: %s is %dx%d, not 1920x1080 (the window did not fit: add --borderless)" % [shot, img.get_width(), img.get_height()])
	var path := _out.path_join(shot + ".png")
	img.save_png(path)
	print("store_shots: ", ProjectSettings.globalize_path(path))
