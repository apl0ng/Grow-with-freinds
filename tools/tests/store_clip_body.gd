extends "res://tools/tests/smoke_base.gd"
## The 30-second store clip (M24 clip, RELEASE.md R6) on the REAL renderer, recorded by Godot's Movie Maker: the chill
## game at 1920x1080 and 30 fps, staged like tools/tests/store_shots_body.gd (three fake workers with hats, events forced
## through Events, a scripted camera that glides between positions; the game's own HUD and copy, no title cards).
##   beat 1  the alley: Dale in the back of the van, Marge climbing in, Gus leaving the board; the host's Enter, the ride
##   beat 2  the floor at work: Marge plants, Dale waters a dry tray, Gus harvests; then Gus throws the bundle into the
##           chute (a chute shot: "+$140")
##   beat 3  the power cut: the room goes dark, Dale walks to the fuse box, the lights come back
##   beat 4  a drive-by's warning (tyres outside, the banner): the crew gets down on the floor, the camera too
##   beat 5  the camera throws a bundle hard at Marge: she goes down, the bundle lands bruised ("Bruised. It pays less."),
##           Dale helps her up
##   beat 6  the supply window: cash on hand, a packet of Purple Haze bought
##   beat 7  the camera deposits the last bundle at the chute and the final notice is PAID IN FULL
##
## Record (Godot 4.7 sizes the movie from the PROJECT settings, not the window: viewport_width/height, or with the
## canvas_items stretch the window size overrides. project.godot keeps the 1280x720 base, so the 1920x1080 movie needs
## a temporary override.cfg next to project.godot; tools/tests/store_clip.sh writes it, runs this and removes it):
##   override.cfg:   [display]
##                   window/size/window_width_override=1920
##                   window/size/window_height_override=1080
##                   window/size/borderless=true
##   godot --write-movie <abs path>.avi --fixed-fps 30 --position 0,0 --path . \
##       -s res://tools/tests/run_test.gd -- --body=res://tools/tests/store_clip_body.gd \
##       --port=7978 --no-mic --chill --replay --run=B5VP --event-delay=900 --borderless
## Sound: under --write-movie the engine always runs the Dummy audio driver (main.cpp: "Always use dummy driver for
## audio driver") and feeds the movie writer from it, so the clip carries the game's sound and nothing reaches the PC's
## speakers. This body checks it: whenever the audio driver is NOT Dummy (a windowed run without --write-movie) the
## Master bus is held muted for the whole run, so no run of this tool is ever audible. --mute gives a silent clip.
## Under --headless it stages every beat and records nothing (the dry run; Movie Maker needs a window):
##   godot --headless --fixed-fps 30 --path . -s res://tools/tests/run_test.gd -- \
##       --body=res://tools/tests/store_clip_body.gd --port=9205 --mute --no-mic --chill --replay --run=B5VP --event-delay=900
## Shift 1 is made the final notice (final_shift_by_team = 1, as the store shots do) so beat 7 clears the run; no strain
## walks off (mutation chances 0); the first-shift guide is off (Settings.guidance, in memory: a scripted run never
## writes settings); the throw in beat 5 knocks down for KNOCKDOWN_SEC (hit_stun_sec, in memory only). Without
## --career-file the record stays in memory. Between beats (a cut: time has passed) the staging makes no sound (Sfx.enabled
## off for that frame: five trays planted at once clipped the mix) and the toast stack is cleared; the engine's first
## frames, before the alley stands, are under a black layer that fades out. Timing is game time (create_timer), so in the
## movie a second is 30 frames whatever the PC's speed; each beat's start frame is printed ("store_clip: beat ..."). A
## stun runs on the engine's millisecond clock, which Movie Maker does not slow down: KNOCKDOWN_SEC leaves room. A
## watchdog ends the run after 150 s of game time.

const SIZE := Vector2i(1920, 1080)
const FPS := 30
## The three fake workers: [peer id, name]. Net.PALETTE[peer - 1] is their colour.
const CREW: Array = [[2, "Dale"], [3, "Marge"], [4, "Gus"]]
const HATS := {2: "hard_hat", 3: "hairnet", 4: "cone"}
## The floor's walking height for a placed worker (the store shots place them at 0.05).
const FLOOR_Y := 0.05
## How fast the fake workers walk (m/s; the game's walk_speed is 4.5: a clip reads better slower).
const WALK := 2.3
## The stun of the knockdown in beat 5 (seconds of the engine clock; Dale helps her up long before it runs out).
const KNOCKDOWN_SEC := 8.0
## What is still owed when beat 7 starts (the last bundle, Purple Haze x1, deposits for more).
const LAST_OWED := 100
## The trays of the main room's pen for beat 2: [station, strain, stage, water]. GrowPlot5 stays empty for Marge.
const TRAYS: Array = [
	["GrowPlot1", &"budget", GrowPlot.Stage.VEGETATIVE, 0.0],     # Dale waters it (dry: it droops until he does)
	["GrowPlot2", &"golden", GrowPlot.Stage.FLOWERING, 0.8],
	["GrowPlot3", &"purple", GrowPlot.Stage.READY, 0.6],          # Gus harvests it
	["GrowPlot4", &"nightshift", GrowPlot.Stage.SEEDLING, 0.7],
	["GrowPlot6", &"budget", GrowPlot.Stage.READY, 0.6],
]
## The pen's aisle between its two rows of trays (x 5 and 7.6): the crew works the west row from here, facing the gate.
const AISLE_X := 6.3

var _me: Player
var _dry := false
var _movie := false
var _hold_mute := false
var _crew: Array[Player] = []
var _dale: Player
var _marge: Player
var _gus: Player
var _items: ItemManager
var _room: Room
## The room's two watering cans: Dale waters with one in beat 2, Gus carries the other from beat 3.
var _dale_can: Item
var _tank_can: Item
## Beat 2's trays by station name (_stage_trays).
var _plots: Dictionary = {}
var _fade: ColorRect
## The camera glide: the local worker goes from _cam_a to _cam_b (x / z) while its look point goes from _look_a to _look_b.
var _cam_a := Vector3.ZERO
var _cam_b := Vector3.ZERO
var _look_a := Vector3.ZERO
var _look_b := Vector3.ZERO
var _cam_t := 0.0
var _cam_len := 0.0
var _cam_on := false
## Walks under way: {"worker", "points": PackedVector3Array, "d": metres walked, "speed", "face"}.
var _walks: Array[Dictionary] = []
var _start_msec := 0
var _beats: PackedStringArray = []


func _process(delta: float) -> void:
	if not _dry and Input.mouse_mode != Input.MOUSE_MODE_VISIBLE:
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	if _hold_mute and not AudioServer.is_bus_mute(0):
		AudioServer.set_bus_mute(0, true)
	if _me != null and is_instance_valid(_me) and _cam_on:
		_cam_t += delta
		var k := smoothstep(0.0, 1.0, _cam_t / _cam_len) if _cam_len > 0.0 else 1.0
		_look(_cam_a.lerp(_cam_b, k), _look_a.lerp(_look_b, k))
	for i in range(_walks.size() - 1, -1, -1):
		if not _step_walk(_walks[i], delta):
			_walks.remove_at(i)


func _run() -> void:
	_label = "store_clip"
	_start_msec = Time.get_ticks_msec()
	get_tree().create_timer(150.0).timeout.connect(func() -> void:
		print("store_clip: watchdog, quitting")
		get_tree().quit(2))
	_dry = DisplayServer.get_name() == "headless"
	_movie = Engine.get_write_movie_path() != ""
	_audio_policy()
	if _dry:
		print("store_clip: headless: a dry run (every beat staged, nothing recorded; Movie Maker needs a window)")
	elif not _movie:
		print("store_clip: no --write-movie: the beats play in the window and nothing is recorded")
	else:
		_movie_size_check()
	_size_window()
	_make_fade()
	if not Config.chill_enabled:
		print("store_clip: this is NOT the chill game (pass --chill): the store clip shows the chill game")
	if not check(Config.replay_enabled, "replay is on (--replay: the final notice needs it)"):
		finish()
		return
	Config.balance.final_shift_by_team = [1, 1, 1, 1]
	for s: SeedDef in Config.balance.seeds:
		if s != null:
			s.mutation_chance = 0.0
	Config.lobby_enabled = true
	Settings.set_value(&"guidance", false)   # in memory: a scripted run reads and writes no settings file
	await get_tree().process_frame
	Game.start_host("Cara", port_arg(7978))   # a crew name, not the user's
	if not await _wait(func() -> bool: return Game.world != null and Game.local_player != null, 8.0, "world + local player"):
		finish()
		return
	_me = Game.local_player
	var world: World = Game.world
	_items = world.items
	_room = world.room
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
	await wait_frames(2)
	Net._rpc_hats_sync(HATS)
	if not check(_crew.size() == CREW.size(), "three more workers"):
		finish()
		return
	_dale = _crew[0]
	_marge = _crew[1]
	_gus = _crew[2]
	await _beat_alley(lobby)
	if not GameState.is_playing():
		finish()
		return
	await _beat_floor()
	await _beat_power_cut()
	await _beat_driveby()
	await _beat_help_up()
	await _beat_supply_window()
	await _beat_paid_in_full()
	var frames := Engine.get_process_frames()
	var real_sec := (Time.get_ticks_msec() - _start_msec) / 1000.0
	print("store_clip: %d frames so far (%.2f s of movie at %d fps; the exit adds about 13), %.1f s of real time" % [
			frames, frames / float(FPS), FPS, real_sec])
	print("store_clip: beats: %s" % ", ".join(_beats))
	finish()


# --- the beats -------------------------------------------------------------------------------------------------------

## Beat 1: the alley. Dale stands in the back of the van, Marge climbs in, Gus leaves the board for it, the camera walks
## up behind them; the host's Enter sends the van off (the doors swing shut, the screen fades: the ride).
func _beat_alley(lobby: Lobby) -> void:
	var van: Van = lobby.get_van()
	var board: AlleyBoard = lobby.get_board()
	var entry := van.get_entry_point()                 # on the ground behind the open doors
	var seat_r := van.get_seat_transform(1).origin     # inside, by the right-hand door
	var seat_l := van.get_seat_transform(0).origin     # inside, by the left-hand door
	var out := entry + Vector3(0.0, 0.0, 6.0)          # where the two inside look: out of the back, at the alley
	_place(_dale, seat_r, out, seat_r.y)
	_place(_marge, entry + Vector3(0.6, 0.0, 3.4), entry)
	_place(_gus, board.global_position + Vector3(-1.1, 0.0, 0.2), board.global_position)
	_stage_trays()   # now, far from the camera: their planting puffs are long gone when the floor fades in
	_cut(Vector3(-2.6, 0.0, 87.2), Vector3(1.0, 1.5, 77.6))
	await wait_frames(2)
	_beat("alley")
	check(GameState.phase == GameState.Phase.WAITING and lobby.contains_point(_me.global_position), "waiting in the alley")
	check(GameState.is_final_shift(), "shift 1 is the final notice (beat 7 clears it)")
	_fade_in(0.5)
	_glide(Vector3(-1.2, 0.0, 83.6), Vector3(0.9, 1.45, 77.8), 4.2)
	_walk(_marge, [Vector3(entry.x - 0.2, FLOOR_Y, entry.z + 0.3), seat_l], WALK * 0.8, out)
	await _hold(0.8)
	_walk(_gus, [entry + Vector3(1.8, FLOOR_Y, 2.4)], WALK, entry)
	await _hold(2.8)
	check(van.server_count() == 2, "two of the crew in the back of the van")
	step("the ride")
	GameState.request_start_round()   # the host's Enter: the doors shut, the screen fades, everyone wakes up on the floor
	await _wait(func() -> bool: return GameState.is_playing(), 6.0, "the ride ends in a running shift")


## Beat 2: the floor at work (the crew placed in the dark of the ride, revealed by its fade-in): through the pen's open gate the
## crew works the west row from the aisle, facing the camera. Then a cut to the chute: Gus throws his bundle in.
func _beat_floor() -> void:
	Events.set(&"_next_in", -1.0)
	_walks.clear()
	_quiet(true)
	var empty := _plots.get("GrowPlot5") as GrowPlot
	var dry := _plots.get("GrowPlot1") as GrowPlot
	var ripe := _plots.get("GrowPlot3") as GrowPlot
	if not check(empty != null and empty.is_empty() and dry != null and dry.is_dry() and ripe != null
			and ripe.is_ready_to_harvest(), "the trays came through the ride as staged"):
		_quiet(false)
		return
	_place(_dale, Vector3(AISLE_X, 0.0, dry.global_position.z + 0.2), dry.global_position)
	_place(_gus, Vector3(AISLE_X, 0.0, ripe.global_position.z), ripe.global_position)
	_place(_marge, Vector3(AISLE_X, 0.0, empty.global_position.z - 0.2), empty.global_position)
	var cans: Array[Item] = _items.get_items_of_type(Const.ITEM_WATERING_CAN)
	if check(not cans.is_empty(), "a watering can for Dale"):
		_dale_can = cans[0]
		_items.server_give_item(_dale_can, _dale.peer_id)
		_dale_can.set(&"charges", 3)
	if cans.size() > 1:
		_tank_can = cans[1]
	var packet := _items.server_spawn_item(Const.ITEM_SEED_PACKET, {"strain_id": &"golden"},
			_marge.global_position + Vector3.UP, _marge.peer_id)
	check(packet != null, "a packet of Golden Kush in Marge's hands")
	_cut(Vector3(2.4, 0.0, -0.3), Vector3(6.4, 0.85, 0.0))   # in the gate: its leaves and the fence stay out of frame
	await wait_frames(1)
	_quiet(false)
	await _wait(func() -> bool: return _fade_dark_done(), 2.0, "the ride's fade-in starts")
	_beat("floor")
	_glide(Vector3(2.9, 0.0, -0.1), Vector3(6.3, 0.85, 0.1), 3.2)
	await _hold(0.7)
	empty._server_interact(_marge)                              # the seed goes in (puff, `plant`)
	check(empty.stage == GrowPlot.Stage.SEEDLING, "Marge planted")
	await _hold(0.6)
	dry._server_interact(_dale)                                 # the can (splash, `water`, the plant perks up)
	check(dry.water > 0.2, "Dale watered")
	await _hold(0.6)
	ripe._server_interact(_gus)                                 # snip and burst: the bundle is in his hands
	var bundle := _items.get_held_by(_gus.peer_id)
	check(bundle != null and bundle.item_type == Const.ITEM_PRODUCT, "Gus harvested a bundle")
	await _hold(1.0)
	# The chute shot: Gus is out of the pen (west of the gate's open leaf, so nothing stands between him and the chute).
	var chute := _room.get_station("TurnInStation") as TurnInStation
	var mouth := chute.get_mouth_position()
	_place(_gus, Vector3(0.25, 0.0, 1.0), mouth)
	_cut(Vector3(-5.0, 0.0, 3.5), Vector3(0.2, 1.0, 3.5))   # side on: Gus left, the chute right (far enough that its board stays under the HUD)
	await wait_frames(1)
	_beat("floor: the chute shot")
	_glide(Vector3(-4.7, 0.0, 3.4), Vector3(0.1, 0.95, 3.6), 2.6)
	await _hold(0.6)
	var sales0 := GameState.round_sales
	if bundle != null:
		_throw_at(bundle, _gus, mouth, 0.6)
	await _wait(func() -> bool: return GameState.round_sales > sales0, 2.0, "the chute took Gus's bundle (a chute shot)")
	await _hold(1.3)


## Beat 3: the power cut. Dale walks from the tank to the fuse box in the dark and resets it; Marge waits by the wall.
func _beat_power_cut() -> void:
	_walks.clear()
	_clear_toasts()
	_quiet(true)
	_items.server_release_holder(_dale.peer_id)
	if _dale_can != null:
		_items.server_drop_item(_dale_can, Vector3(9.4, 0.0, -4.3))   # Dale's can stays in the pen's far corner
	if _tank_can != null and not _tank_can.is_held():
		_items.server_give_item(_tank_can, _gus.peer_id)            # Gus carries the tank's can from here on
	var fuse := _room.get_station("FuseBox")
	var at := _room.get_station_access_point("FuseBox", 0.85)
	_place(_dale, Vector3(-7.6, 0.0, -2.0), Vector3(-5.0, 1.0, -1.4))   # between the tank and the wall, facing the room
	_place(_marge, Vector3(-8.0, 0.0, -5.6), Vector3(-6.0, 1.0, -2.6))
	_place(_gus, Vector3(-6.0, 0.0, 0.9), Vector3(-6.8, 1.0, 0.0))     # at the tank with the can (out of frame)
	_cut(Vector3(-4.6, 0.0, -3.0), Vector3(-9.98, 1.1, -3.7))   # north of the tank: it stays out of frame
	await wait_frames(1)
	_quiet(false)
	_beat("power cut")
	_glide(Vector3(-5.4, 0.0, -3.4), Vector3(-9.98, 1.2, -3.9), 4.4)
	await _hold(0.6)
	check(Events.server_start_event(Events.EVENT_POWER_CUT), "the power goes")
	await _hold(0.4)
	check(not Events.power_on, "the room is dark")
	_walk(_dale, [Vector3(at.x, FLOOR_Y, at.z)], WALK, fuse.global_position)
	_marge.net_yaw = _yaw_to(_marge.global_position, _dale.global_position)
	await _wait(func() -> bool: return _walks.is_empty(), 4.0, "Dale at the fuse box")
	await _hold(0.6)
	Events.server_end_event()   # what the fuse box's finished hold asks the host to do
	Events.set(&"_next_in", -1.0)
	check(Events.power_on, "the lights are back")
	await _hold(1.0)


## Beat 4: a drive-by's warning. Tyres outside, the banner; the crew gets down, then the camera.
func _beat_driveby() -> void:
	_walks.clear()
	_clear_toasts()
	_place(_dale, Vector3(-2.0, 0.0, 3.0), Vector3(-1.2, 1.0, -1.4))
	_place(_marge, Vector3(-4.1, 0.0, 2.0), Vector3(-1.2, 1.0, -1.4))
	_place(_gus, Vector3(-0.6, 0.0, 4.4), Vector3(-3.0, 1.0, 10.0))   # the can still in hand, his back to the camera
	_cut(Vector3(-1.6, 0.0, -1.6), Vector3(-5.4, 1.2, 10.0))   # west of the pen's gate: its open leaf stays out of frame
	await wait_frames(1)
	_beat("drive-by warning")
	_glide(Vector3(-1.8, 0.0, -1.1), Vector3(-5.0, 0.9, 10.4), 3.4)
	check(Events.server_start_event(Events.EVENT_DRIVEBY), "tyres outside")
	await _hold(0.5)
	_dale.crouching = true
	await _hold(0.2)
	_marge.crouching = true
	_gus.crouching = true
	await _hold(0.3)
	Input.action_press(&"crouch")   # the camera gets down too
	await _hold(2.0)
	check(not Events.is_driveby_firing(), "still the warning (nobody fires in the clip)")
	check(_dale.crouching and _marge.crouching and _me.crouching, "the crew is on the floor")
	await _hold(0.3)
	Events.server_end_event()   # a force-ended drive-by bills nobody
	Events.set(&"_next_in", -1.0)
	Input.action_release(&"crouch")
	for w in _crew:
		w.crouching = false


## Beat 5: the camera throws a bundle hard at Marge: she goes down, it lands bruised; Dale helps her up.
func _beat_help_up() -> void:
	_walks.clear()
	_clear_toasts()
	var down_at := Vector3(-3.7, 0.0, 1.2)   # the open floor between the tank and the window (the store shots' spot)
	_place(_marge, down_at, down_at + Vector3(1.0, 0.0, 0.6))
	_place(_dale, down_at + Vector3(-1.9, 0.0, 0.5), Vector3(-6.8, 1.0, 0.0))   # by the tank, his back half to her
	_place(_gus, Vector3(-5.9, 0.0, -1.1), Vector3(-6.8, 1.0, 0.0))   # at the tank with the can
	_quiet(true)
	var bundle := _items.server_spawn_item(Const.ITEM_PRODUCT, {"strain_id": &"purple", "amount": 2},
			_me.global_position + Vector3.UP, 1)
	check(bundle != null and bundle.holder_id == 1, "a bundle in the camera's hands")
	_cut(down_at + Vector3(0.9, 0.0, 3.9), down_at + Vector3(0.2, 1.0, 0.0))
	await wait_frames(1)
	_quiet(false)
	_beat("bruise + knocked down + helped up")
	_glide(down_at + Vector3(0.6, 0.0, 3.1), down_at + Vector3(0.6, 0.45, 0.2), 4.7)
	await _hold(0.8)
	var old_stun: float = Config.balance.hit_stun_sec
	Config.balance.hit_stun_sec = KNOCKDOWN_SEC   # the throw's hit goes through Player.server_stagger with this stun
	if bundle != null:
		_throw_at(bundle, _me, _marge.get_chest_position(), 0.4)
	await _wait(func() -> bool: return bundle == null or not is_instance_valid(bundle) or not bundle.is_flying(), 1.5, "the bundle lands")
	Config.balance.hit_stun_sec = old_stun
	if not _marge.is_stunned():   # the arc missed her: knock her down anyway (the long stun of the contract)
		Player.server_stagger(_marge, Vector3(-1.0, 0.0, -0.6), true, 1, KNOCKDOWN_SEC, true)
	var product := bundle as Product
	if product != null and is_instance_valid(product) and not product.is_bruised():
		_items.server_bruise_bundle(product, 1)
	check(_marge.is_stunned(), "Marge is down")
	check(product != null and is_instance_valid(product) and product.is_bruised(), "the bundle is bruised")
	await _hold(0.5)
	_walk(_dale, [down_at + Vector3(-0.95, FLOOR_Y, 0.1)], WALK * 0.8, down_at)   # to her side (she slumps the other way), in view
	await _wait(func() -> bool: return _walks.is_empty(), 3.0, "Dale comes over")
	await _hold(0.25)
	check(_dale.server_help_up(_marge), "Dale helps her up")
	await _hold(1.8)
	check(not _marge.is_stunned(), "Marge is up")


## Beat 6: the supply window, and a packet of Purple Haze bought from it.
func _beat_supply_window() -> void:
	_walks.clear()
	_clear_toasts()
	_quiet(true)
	for it in _items.get_items_of_type(Const.ITEM_PRODUCT):
		_items.server_despawn_item(it)   # beat 5's bundle off the floor
	var counter := _room.get_station("ShopCounter") as ShopCounter
	if not check(counter != null, "the supply window"):
		_quiet(false)
		return
	var at := _room.get_station_access_point("ShopCounter", 1.0)
	_place(_dale, at + Vector3(-1.6, 0.0, 1.4), counter.global_position)
	_place(_marge, at + Vector3(1.7, 0.0, 1.0), counter.global_position)
	_cut(at, counter.global_position + Vector3(0.0, 1.2, 0.0))
	await wait_frames(1)
	_quiet(false)
	counter.interact(_me)
	await wait_frames(1)
	_beat("supply window")
	var ui := counter.get_shop_ui()
	check(ui != null and ui.is_open(), "the supply window is open")
	await _hold(1.4)
	var card: ShopCard = ui.get_card(ShopCounter.KIND_SEED, &"purple") if ui != null else null
	var money0 := GameState.money
	if check(card != null, "the Purple Haze card"):
		card.buy_pressed.emit(card)
	await _wait(func() -> bool: return GameState.money < money0, 2.0, "a packet bought")
	await _hold(1.5)
	if ui != null and ui.is_open():
		ui.close()
	var packet := _items.get_held_by(1)
	if packet != null:
		_items.server_despawn_item(packet)


## Beat 7: the crew has deposited all but LAST_OWED of the payment; the camera puts the last bundle down the chute.
func _beat_paid_in_full() -> void:
	_walks.clear()
	_clear_toasts()
	var chute := _room.get_station("TurnInStation") as TurnInStation
	var at := Vector3(0.0, 0.0, 3.75)   # 1.4 m from the chute's north face, inside the interact range
	_quiet(true)
	_items.server_release_holder(_gus.peer_id)
	if _tank_can != null:
		_items.server_drop_item(_tank_can, Vector3(-7.9, 0.0, 1.0))   # back by the tank, out of this shot
	_place(_dale, Vector3(-1.05, 0.0, 7.0), at)    # behind the chute (clear of the drums at x -1.95 and -1.45)
	_place(_marge, Vector3(1.1, 0.0, 7.0), at)     # and of the cover crate at x 1.7..2.7: watching the last deposit
	_place(_gus, Vector3(3.2, 0.0, 1.0), chute.global_position)   # behind the camera
	var bundle := _items.server_spawn_item(Const.ITEM_PRODUCT, {"strain_id": &"purple", "amount": 1},
			_me.global_position + Vector3.UP, 1)
	check(bundle != null and bundle.holder_id == 1, "the last bundle in the camera's hands")
	# What the crew deposited before (the report's numbers): all of the payment but LAST_OWED.
	var owed := GameState.quota - GameState.round_sales - LAST_OWED
	var shares: Array = [[_dale.peer_id, 0.36], [1, 0.27], [_marge.peer_id, 0.37]]
	var given := 0
	for i in shares.size():
		var amount := owed - given if i == shares.size() - 1 else int(owed * float(shares[i][1]))
		if amount > 0:
			GameState.server_add_sale(amount, int(shares[i][0]))
			given += amount
	check(GameState.is_playing() and GameState.quota - GameState.round_sales == LAST_OWED, "$%d still owed" % LAST_OWED)
	check(bundle != null and chute.get_sale_value(bundle) > LAST_OWED, "the last bundle covers it")
	_cut(at + Vector3(0.0, 0.0, -0.5), chute.global_position + Vector3(0.0, 0.95, -0.2))
	await wait_frames(1)
	_quiet(false)
	_beat("PAID IN FULL")
	_glide(at, chute.global_position + Vector3(0.0, 0.92, -0.1), 1.4)
	await _hold(1.4)
	chute._server_interact(_me)   # the deposit (E): the payment is met, the shift ends
	await _wait(func() -> bool: return GameState.is_run_cleared(), 3.0, "the run is cleared")
	await _hold(2.6)


# --- staging helpers -------------------------------------------------------------------------------------------------

func _beat(beat: String) -> void:
	var frame := Engine.get_process_frames()
	_beats.append("%s @ %.2f s" % [beat, frame / float(FPS)])
	print("store_clip: beat %s at frame %d (%.2f s)" % [beat, frame, frame / float(FPS)])
	step(beat)


## Waits `sec` of game time (in the movie: exactly sec x 30 frames, whatever the PC's speed).
func _hold(sec: float) -> void:
	await get_tree().create_timer(sec, true).timeout


## Like wait_until, on the game clock (wait_until counts real milliseconds, which run apart from a movie's frames).
func _wait(pred: Callable, timeout_sec: float, msg: String) -> bool:
	var left := timeout_sec
	while left > 0.0:
		if bool(pred.call()):
			return check(true, msg)
		await get_tree().process_frame
		left -= get_process_delta_time()
	return check(false, msg + " (timeout %.1f s)" % timeout_sec)


## Throws `item` (held by `thrower`) on an arc that reaches `target` after `flight_sec` (the item system's own flight:
## a chute shot sells, anything else lands, bruising a bundle that strikes hard).
func _throw_at(item: Item, thrower: Player, target: Vector3, flight_sec: float) -> void:
	var origin := _items.compute_throw_origin(thrower)
	var velocity := (target - origin) / flight_sec - Item.FLIGHT_GRAVITY * (0.5 * flight_sec)
	check(_items.server_throw_item(item, origin, velocity, thrower.peer_id), "%s throws" % thrower.display_name)


## Clears the toast stack at a cut (time has passed; the next beat's toasts are its own).
func _clear_toasts() -> void:
	var hud := Game.world.get_node_or_null(^"HUD") if Game.world != null else null
	var stack: Node = hud.get(&"toasts") if hud != null else null
	if stack != null:
		for t in stack.get_children():
			t.queue_free()


## Beat 2's trays, set while the camera is still in the alley (silently: five plantings at once stacked their sounds
## into a clipped burst): TRAYS planted and grown, GrowPlot5 empty in damp soil (Marge's seedling must not come up "DRY").
func _stage_trays() -> void:
	_quiet(true)
	_plots.clear()
	for row: Array in TRAYS:
		var plot := _room.get_station(String(row[0])) as GrowPlot
		if not check(plot != null, String(row[0])):
			continue
		plot.server_reset()
		check(plot.server_plant(StringName(row[1])), "%s planted with %s" % [row[0], row[1]])
		plot.stage = row[2]
		plot.water = float(row[3])
		_plots[String(row[0])] = plot
	var empty := _room.get_station("GrowPlot5") as GrowPlot
	if check(empty != null, "GrowPlot5 for Marge"):
		empty.server_reset()
		empty.water = 0.6
		_plots["GrowPlot5"] = empty
	_quiet(false)


## Staging at a cut makes no sound (items handed over or put down, trays set): Sfx.enabled off until the next frame.
## The sounds of the beats themselves (a planting, a throw, the help-up) play as in the game.
func _quiet(on: bool) -> void:
	Sfx.enabled = not on


## Puts the fake `worker` at `at` (x / z; on the floor, or at `height`) facing `face` (world space). No smoothing: a cut.
func _place(worker: Player, at: Vector3, face: Vector3, height: float = FLOOR_Y) -> void:
	var yaw := _yaw_to(at, face)
	worker.place_at(Transform3D(Basis(Vector3.UP, yaw), Vector3(at.x, height, at.z)))


## Walks the fake `worker` (its synced position, so its body walks, bobs and steps) along `points` (world space, y
## included) at `speed` m/s, then faces `face` (INF: keeps the walking direction).
func _walk(worker: Player, points: Array, speed: float, face: Vector3 = Vector3.INF) -> void:
	var path := PackedVector3Array([worker.net_position])
	for p: Vector3 in points:
		path.append(p)
	_walks.append({"worker": worker, "points": path, "d": 0.0, "speed": maxf(speed, 0.1), "face": face})


## One frame of a walk; false once it is over.
func _step_walk(w: Dictionary, delta: float) -> bool:
	var worker: Player = w["worker"]
	if not is_instance_valid(worker):
		return false
	var path: PackedVector3Array = w["points"]
	var d := float(w["d"]) + float(w["speed"]) * delta
	w["d"] = d
	for i in path.size() - 1:
		var seg := path[i].distance_to(path[i + 1])
		if d <= seg:
			worker.net_position = path[i].lerp(path[i + 1], d / maxf(seg, 0.0001))
			worker.net_yaw = _yaw_to(path[i], path[i + 1])
			return true
		d -= seg
	worker.net_position = path[path.size() - 1]
	var face: Vector3 = w["face"]
	if face.is_finite():
		worker.net_yaw = _yaw_to(worker.net_position, face)
	return false


static func _yaw_to(from: Vector3, to: Vector3) -> float:
	var dir := to - from
	dir.y = 0.0
	return atan2(-dir.x, -dir.z) if dir.length() > 0.01 else 0.0


## The camera jumps to `pos` (x / z) looking at `target`.
func _cut(pos: Vector3, target: Vector3) -> void:
	_cam_a = pos
	_cam_b = pos
	_look_a = target
	_look_b = target
	_cam_t = 0.0
	_cam_len = 0.0
	_cam_on = true
	_look(pos, target)


## The camera glides from where it is to `pos` looking at `target`, over `sec` (eased at both ends).
func _glide(pos: Vector3, target: Vector3, sec: float) -> void:
	var k := smoothstep(0.0, 1.0, _cam_t / _cam_len) if _cam_len > 0.0 else 1.0
	_cam_a = _cam_a.lerp(_cam_b, k)
	_look_a = _look_a.lerp(_look_b, k)
	_cam_b = pos
	_look_b = target
	_cam_t = 0.0
	_cam_len = maxf(sec, 0.01)
	_cam_on = true


## Puts the local player at `pos` (x / z; the height stays) looking at `target` (world space) from its camera.
func _look(pos: Vector3, target: Vector3) -> void:
	_me.velocity = Vector3.ZERO
	_me.global_position = Vector3(pos.x, _me.global_position.y, pos.z)
	var eye := Vector3(pos.x, _me.camera.global_position.y, pos.z)
	var dir := (target - eye).normalized()
	_me.rotation = Vector3(0.0, atan2(-dir.x, -dir.z), 0.0)
	_me.head.rotation.x = asin(clampf(dir.y, -1.0, 1.0))


## A black layer over everything for the frames before the alley is staged (the movie starts at the engine's first
## frame); it fades out once the first beat stands.
func _make_fade() -> void:
	var layer := CanvasLayer.new()
	layer.layer = 128
	add_child(layer)
	_fade = ColorRect.new()
	_fade.color = Color.BLACK
	_fade.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_fade.set_anchors_preset(Control.PRESET_FULL_RECT)
	layer.add_child(_fade)


func _fade_in(sec: float) -> void:
	if _fade == null:
		return
	var tween := create_tween()
	tween.tween_property(_fade, "color:a", 0.0, sec)
	tween.tween_callback(_fade.hide)


## True once the ride's black has started to lift (the HUD's transition overlay below full black).
func _fade_dark_done() -> bool:
	var hud := Game.world.get_node_or_null(^"HUD") if Game.world != null else null
	if hud == null or not hud.has_method(&"get_transition_alpha"):
		return true
	return float(hud.call(&"get_transition_alpha")) < 0.999


## The clip's sound rule: only the Dummy driver (Movie Maker, --headless) may run unmuted; any other driver would play
## on the PC's speakers, so the Master bus is held muted for the whole run.
func _audio_policy() -> void:
	var driver := AudioServer.get_driver_name()
	if driver != "Dummy":
		_hold_mute = true
		Settings.set(&"_forced_mute", true)   # Settings re-applies the buses on a change: keep it muted there too
		AudioServer.set_bus_mute(0, true)
		print("store_clip: audio driver %s (not Movie Maker): muted for the whole run" % driver)
	elif Config.has_arg("mute"):
		print("store_clip: audio driver Dummy, --mute: the clip is silent")
	else:
		print("store_clip: audio driver Dummy (Movie Maker feeds the movie from it; nothing plays on the speakers): the clip carries the game's sound")


## Movie Maker sizes the movie from the project settings at start (see the header). Says so when it is not 1920x1080.
func _movie_size_check() -> void:
	var w := int(ProjectSettings.get_setting("display/window/size/window_width_override", 0))
	var h := int(ProjectSettings.get_setting("display/window/size/window_height_override", 0))
	if w <= 0:
		w = int(ProjectSettings.get_setting("display/window/size/viewport_width", 0))
	if h <= 0:
		h = int(ProjectSettings.get_setting("display/window/size/viewport_height", 0))
	if Vector2i(w, h) != SIZE:
		print("store_clip: the movie is %dx%d, not 1920x1080: run it through tools/tests/store_clip.sh (override.cfg)" % [w, h])
	else:
		print("store_clip: recording %dx%d at %d fps to %s" % [w, h, FPS, Engine.get_write_movie_path()])


## The window at 1920x1080 (with --borderless: no frame, at the corner of its screen, so it fits a 1920x1080 screen).
func _size_window() -> void:
	if _dry:
		get_tree().root.size = SIZE
		return
	var win := get_window()
	if Config.has_arg("borderless"):
		win.borderless = true
		win.position = DisplayServer.screen_get_position(win.current_screen)
	win.size = SIZE
