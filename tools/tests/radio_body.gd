extends "res://tools/tests/qa_base.gd"
## M18 radio suite (radio agent): the walkie-talkies on a single headless host with one fake worker (Bob: a host-side
## body without an owning peer; his voice frames go straight into the receive path through Voice.debug_inject_frame).
## Two passes in one process: a plain game first, then back to the menu and hosted again with replay on (Config's
## replay_enabled set at runtime; --run=B5VP and a temp career file on the command line, as for every replay run).
##   godot --headless --path . -s res://tools/tests/run_test.gd -- --body=res://tools/tests/radio_body.gd --port=7936 --run=B5VP --career-file=user://radio_test_7936.cfg --round-sec=900
## Pins:
##   the shelf       Decor/RadioShelf/Spot on the main room's north wall, facing the room; radio_count slots on the
##                   plank; clear of the loose cover in all four COVER_LAYOUTS and of anything solid, off the routes,
##                   the doorways, the spawns, the station fronts, the Boss's walks and the wall phone; a worker in
##                   front of it has room in every layout and reaches both radios
##   stocking        no radio before the first shift; radio_count (2) at the slots once it starts, upright, facing the
##                   room, nobody's
##   the item        registered with the item system, model (Body + Led), collider, label "Radio" (the HUD's held
##                   line too), its own sound players, recipes of its own for radio_on / radio_off / radio_static
##   carrying        picked up through the real request, thrown (it flies and lands), dropped with the real request
##   a transmission  Bob holding radio A talks: on the radio at his first frame (radio_changed), one output at radio B
##                   (its child, the Radio bus with its band filters and its send to Voice, radio_volume_db, a 16 kHz
##                   generator that plays), nothing at his own radio, the proximity voice as before; radio_on at both
##                   ends, static + lamp at the receiver, the lamp at the sender; RADIO in Bob's HUD row; RADIO_GAP_MS
##                   after his last frame it ends (radio_off at both ends, static and lamps off, the output freed)
##   anywhere        a radio in the back room, one at the far end of the grow hall and one in my hands all receive at
##                   once; a radio despawned mid-transmission takes its output with it, without an error
##   me              the host's own frames (the real send path) put it on the radio: no output on its own peer, the
##                   lamp of my radio, static at the other one, RADIO in my row
##   validation      frames the receive checks drop (not a player, too big, over the rate) never reach a radio and put
##                   nobody on the radio; exactly the accepted frames of a burst do
##   trouble         a power cut changes nothing; every raid sweep leaves a radio it can see
##   shifts          NEXT SHIFT: a radio left outside the building goes back to the shelf, one inside stays where it is;
##                   START OVER despawns them, the next shift's start stocks the shelf again (fresh radios)
##   replay on       the same stocking, a transmission to a radio standing on the shelf, START OVER
##   shutdown        Voice.shutdown() releases every radio output and silences the radios
## Every engine/script error fails the run unless announced (qa_base.gd).

const VoiceScript := preload("res://scripts/core/voice.gd")
const BOB := 2
const STRANGER := 77
const BOB_SPOT := Vector3(-6.0, 0.0, 4.0)
const FLOOR_A := Vector3(-3.0, 0.0, 3.0)
const FAR_HALL := Vector3(20.5, 0.0, 4.0)
const DOCK_SPOT := Vector3(-2.5, 0.0, 12.6)
const SHELF_SPOT := Vector3(-9.0, 1.0, -7.34)

var world: World
var items: ItemManager
var room: Room
var me: Player
var bob: Player
var hud: HUD
var radios: Array[Radio] = []
var _changes: Array = []      # [peer, on] from Voice.radio_changed


func _run() -> void:
	_label = "radio"
	await get_tree().process_frame
	var b: BalanceConfig = Config.balance
	for s: SeedDef in b.seeds:
		s.mutation_chance = 0.0
	b.end_round_on_quota_met = false
	Voice.radio_changed.connect(func(p: int, on: bool) -> void: _changes.append([p, on]))
	if not await _host("plain"):
		finish(); return
	await _test_shelf()
	await _test_stocking("plain")
	if radios.size() != 2:
		finish(); return
	await _test_item()
	await _test_carry()
	await _test_transmission()
	await _test_anywhere()
	await _test_me()
	await _test_validation()
	await _test_trouble()
	await _test_shifts()

	step("replay on: back to the menu, hosted again")
	Game.return_to_menu()
	await wait_frames(5)
	check(Voice.get_radio_output_count() == 0 and Voice.get_radio_peers().is_empty(), "the menu: no radio output, nobody on the radio")
	Config.replay_enabled = true
	if not await _host("replay"):
		finish(); return
	await _test_stocking("replay")
	if radios.size() == 2:
		await _test_shelf_receives()
		await _test_start_over("replay")
	await _test_shutdown()
	finish()


func _host(tag: String) -> bool:
	step("hosting (%s)" % tag)
	Game.start_host("Tester", port_arg(7936))
	if not await wait_until(func() -> bool: return Game.world != null and Game.local_player != null, 5.0, "%s: world + local player" % tag):
		return false
	world = Game.world
	items = world.items
	room = world.room
	me = Game.local_player
	hud = world.get_node_or_null(^"HUD") as HUD
	Net.players[BOB] = {"name": "Bob", "color": Net.PALETTE[BOB - 1]}
	bob = world.server_spawn_player(BOB)
	Net.players_changed.emit()
	await wait_frames(3)
	return check(bob != null and world.get_players().size() == 2 and hud != null, "%s: host + Bob spawned, a HUD" % tag)


# --- the shelf ---------------------------------------------------------------------------------------------------------

func _test_shelf() -> void:
	step("the shelf: Decor/RadioShelf/Spot")
	var marker := room.get_node_or_null(^"Decor/RadioShelf/Spot") as Marker3D
	var spot := room.get_radio_spot()
	check(marker != null and spot.is_equal_approx(marker.global_transform) and spot.origin.is_equal_approx(SHELF_SPOT),
			"a Marker3D at %s, read by Room.get_radio_spot() (%s)" % [SHELF_SPOT, spot.origin])
	check((-spot.basis.z).is_equal_approx(Vector3.BACK) and spot.basis.y.is_equal_approx(Vector3.UP), "upright, a radio stood there faces the room (+Z)")
	check(room.get_area_index(spot.origin) == 0 and room.contains_point(spot.origin, 0.1), "in the main room")
	var s0 := room.get_radio_slot(0, 2)
	var s1 := room.get_radio_slot(1, 2)
	check(is_equal_approx(s0.origin.distance_to(s1.origin), Room.RADIO_SLOT_SPACING) and s0.basis.is_equal_approx(spot.basis)
			and s0.origin.lerp(s1.origin, 0.5).is_equal_approx(spot.origin), "two slots %.2f m apart, centred on the spot" % s0.origin.distance_to(s1.origin))
	check(room.get_radio_slot(0, 1).origin.is_equal_approx(spot.origin)
			and room.get_radio_slot(0, 6).origin.distance_to(room.get_radio_slot(5, 6).origin) <= Room.RADIO_SHELF_USABLE + 0.001,
			"one radio stands in the middle; six still fit on the plank")
	var space := world.get_world_3d().direct_space_state
	var on_plank := true
	for s: Transform3D in [s0, s1]:
		var hit := space.intersect_ray(PhysicsRayQueryParameters3D.create(s.origin + Vector3.UP * 0.1, s.origin + Vector3.DOWN * 0.3, Const.LAYER_WORLD))
		if hit.is_empty() or absf((hit["position"] as Vector3).y - s.origin.y) > 0.005 or (hit["collider"] as Node).get_parent().name != "RadioShelf":
			on_plank = false
	check(on_plank, "both slots stand on the plank's top (its collider, 1.0 m up)")
	var spot2 := Vector2(spot.origin.x, spot.origin.z)
	var route_d := INF
	for e: Vector2i in Room.ROUTE_EDGES:
		route_d = minf(route_d, Geometry2D.get_closest_point_to_segment(spot2, Room.ROUTE_POINTS[e.x], Room.ROUTE_POINTS[e.y]).distance_to(spot2))
	check(route_d > Room.ROUTE_MARGIN + 1.0, "off every route graph edge (%.1f m)" % route_d)
	var doors_clear := true
	for d: Dictionary in room.get_doorways():
		var c: Vector3 = d["center"]
		if Vector2(c.x, c.z).distance_to(spot2) < float(d["width"]) * 0.5 + 1.0:
			doors_clear = false
	var spawn_d := INF
	for i in 8:
		var p := room.get_spawn_transform(i).origin
		spawn_d = minf(spawn_d, Vector2(p.x, p.z).distance_to(spot2))
	check(doors_clear and spawn_d > 3.0, "out of every doorway, %.1f m from the nearest spawn" % spawn_d)
	var front_d := INF
	for st in room.get_stations():
		var f := st.global_transform.basis.z
		f.y = 0.0
		for dist: float in [0.0, 0.9, 1.3, 1.7]:
			var p := st.global_position + f.normalized() * dist
			front_d = minf(front_d, Vector2(p.x, p.z).distance_to(spot2))
	var walk_d := INF
	for pts: PackedVector3Array in [room.get_inspection_route(), room.get_headcount_route()]:
		for p in pts:
			walk_d = minf(walk_d, Vector2(p.x, p.z).distance_to(spot2))
	check(front_d > 2.0 and walk_d > 2.0, "no station or station front within 2 m (%.1f), nor the Boss's walks (%.1f)" % [front_d, walk_d])
	var phone := room.get_wall_phone()
	check(phone != null and absf(phone.global_position.x - spot.origin.x) - 0.45 - 0.16 > 0.5,
			"the plank ends more than 0.5 m short of the wall phone's housing")
	var front := Vector3(spot.origin.x, 0.0, spot.origin.z + 1.0)
	var footprint := BoxShape3D.new()
	footprint.size = Vector3(0.2, 0.34, 0.14)
	var body := CapsuleShape3D.new()
	body.radius = 0.35
	body.height = 1.8
	var layout0 := room.get_cover_layout()
	for layout in Room.COVER_LAYOUTS.size():
		room.apply_cover_layout(layout)
		await get_tree().physics_frame
		await get_tree().physics_frame
		var names: PackedStringArray = []
		var covered := false
		for s: Transform3D in [s0, s1]:
			covered = covered or room.is_in_cover(s.origin, 0.5)
			var q := PhysicsShapeQueryParameters3D.new()
			q.shape = footprint
			q.transform = Transform3D(s.basis, s.origin + Vector3.UP * 0.19)
			q.collision_mask = Const.LAYER_WORLD | Const.LAYER_INTERACTABLE
			for hit in space.intersect_shape(q, 4):
				names.append(str((hit["collider"] as Node).get_path()))
		check(not covered and names.is_empty(), "cover layout %d: both radios clear of cover (0.5 m) and of anything solid %s" % [layout, names])
		var cq := PhysicsShapeQueryParameters3D.new()
		cq.shape = body
		cq.transform = Transform3D(Basis.IDENTITY, front + Vector3.UP * 0.95)
		cq.collision_mask = Const.LAYER_WORLD | Const.LAYER_INTERACTABLE
		var reach := true
		for s: Transform3D in [s0, s1]:
			var ray := PhysicsRayQueryParameters3D.create(front + Vector3.UP * 1.6, s.origin + Vector3.UP * 0.2, Const.LAYER_WORLD | Const.LAYER_INTERACTABLE)
			if not space.intersect_ray(ray).is_empty():
				reach = false
		check(not room.is_in_cover(front, Room.COVER_BODY_MARGIN) and space.intersect_shape(cq, 1).is_empty() and reach,
				"cover layout %d: a worker 1 m in front of the shelf has room and reaches both radios" % layout)
	room.apply_cover_layout(layout0)
	await get_tree().physics_frame


# --- stocking ----------------------------------------------------------------------------------------------------------

func _test_stocking(tag: String) -> void:
	step("%s: no radios before the first shift, radio_count on the shelf once it starts" % tag)
	check(GameState.phase == GameState.Phase.WAITING and items.get_items_of_type(Const.ITEM_RADIO).is_empty(), "%s: WAITING, no radio yet" % tag)
	GameState.request_start_round()
	await wait_until(func() -> bool: return GameState.is_playing(), 3.0, "%s: PLAYING" % tag)
	await wait_frames(2)
	_collect_radios()
	check(Config.balance.radio_count == 2 and radios.size() == 2, "%s: radio_count (2) radios (%d)" % [tag, radios.size()])
	_check_on_shelf(tag)


func _collect_radios() -> void:
	radios.clear()
	for it in items.get_items_of_type(Const.ITEM_RADIO):
		if it is Radio:
			radios.append(it as Radio)


## Every radio at its own slot, nobody's, upright, facing the room.
func _check_on_shelf(tag: String) -> void:
	var n := radios.size()
	var ok := n > 0
	var used := {}
	for r in radios:
		var found := -1
		for i in n:
			if r.global_position.distance_to(room.get_radio_slot(i, n).origin) < 0.001:
				found = i
		if found < 0 or used.has(found) or r.is_held() or r.is_flying() or absf(angle_difference(r.rotation.y, PI)) > 0.001 \
				or absf(r.rotation.x) > 0.001 or absf(r.rotation.z) > 0.001:
			ok = false
		used[found] = true
	check(ok, "%s: each at a slot of its own, nobody's, upright, facing the room" % tag)


# --- the item ----------------------------------------------------------------------------------------------------------

func _test_item() -> void:
	step("the item")
	var r := radios[0]
	check(ItemManager.get_scene_path(Const.ITEM_RADIO) == "res://scenes/items/radio.tscn" and r.item_type == Const.ITEM_RADIO,
			"Const.ITEM_RADIO maps to scenes/items/radio.tscn")
	check(r.get_node_or_null(^"Visual") is Toonify and r.get_node_or_null(^"Visual/Body") is MeshInstance3D
			and r.get_node_or_null(^"Visual/Led") is MeshInstance3D, "Visual (radio.glb) with Body and Led")
	var col := r.get_collider()
	check(col != null and col.collision_layer == Const.LAYER_ITEM and r.get_node_or_null(^"Sync") is MultiplayerSynchronizer, "an item collider on LAYER_ITEM, a synchronizer")
	check(r.get_display_name() == "Radio" and r.get_label_text() == "Radio" and r.get_props().is_empty(), "label '%s', no props" % r.get_label_text())
	var click := r.get_node_or_null(^"RadioClick") as AudioStreamPlayer3D
	var stat := r.get_node_or_null(^"RadioStatic") as AudioStreamPlayer3D
	check(click != null and stat != null and click.bus == Sfx.BUS_NAME and stat.bus == Sfx.BUS_NAME, "its own click and static players on the SFX bus")
	check(not r.is_lit() and (r.get_node(^"Visual/Led") as MeshInstance3D).material_override == null, "the lamp is dark")
	var on: float = Sfx.measure(Sfx.get_stream(&"radio_on")).seconds
	var off: float = Sfx.measure(Sfx.get_stream(&"radio_off")).seconds
	var hiss := Sfx.get_stream(&"radio_static")
	check(absf(on - 0.2) < 0.01 and absf(off - 0.32) < 0.01 and absf(float(Sfx.measure(hiss).seconds) - 2.0) < 0.01
			and hiss.loop_mode == AudioStreamWAV.LOOP_FORWARD, "radio_on %.2f s, radio_off %.2f s, radio_static a 2 s loop: recipes of their own" % [on, off])


# --- carrying ----------------------------------------------------------------------------------------------------------

func _test_carry() -> void:
	step("carrying: pick up (the real request), throw, drop")
	var r := radios[0]
	var front := room.get_radio_spot().origin
	_put_me(Vector3(front.x, 0.0, front.z + 1.1), PI)
	await wait_physics(2)
	check(r.can_interact(me) and r.get_prompt(me) == "Pick up Radio", "the prompt: '%s'" % r.get_prompt(me))
	r.interact(me)
	await wait_until(func() -> bool: return r.holder_id == 1, 3.0, "I hold the radio")
	await wait_until(func() -> bool: return hud.held_label.text == "Carrying: Radio" and hud.held_panel.visible, 2.0, "the HUD: 'Carrying: Radio'")
	var throws0 := GameState.get_stat(1, Const.STAT_THROWS)
	items.request_throw()
	await wait_until(func() -> bool: return r.is_flying(), 2.0, "thrown: it flies")
	await wait_until(func() -> bool: return not r.is_flying(), 4.0, "it lands")
	check(r.holder_id == 0 and room.contains_point(r.global_position) and GameState.get_stat(1, Const.STAT_THROWS) == throws0 + 1,
			"on the floor in the room (%s), a throw counted" % r.global_position)
	check(items.server_give_item(r, 1), "back in my hands")
	await wait_frames(2)
	items.request_drop()
	await wait_until(func() -> bool: return r.holder_id == 0, 2.0, "dropped")
	await wait_until(func() -> bool: return hud.held_label.text == "" and not hud.held_panel.visible, 2.0, "the held line is empty again")


# --- a transmission ------------------------------------------------------------------------------------------------------

func _test_transmission() -> void:
	step("a transmission: Bob holds radio A and talks, radio B lies on the floor")
	var a := radios[0]
	var rb := radios[1]
	_put(bob, BOB_SPOT)
	_put_me(Vector3(-1.0, 0.0, 3.0), 0.0)
	check(items.server_give_item(a, BOB), "Bob picks radio A up")
	items.server_drop_item(rb, FLOOR_A)
	await wait_frames(3)
	_changes.clear()
	var st0 := Voice.get_radio_stats()
	var c0 := [a.get_click_count(true), rb.get_click_count(true), a.get_click_count(false), rb.get_click_count(false)]
	Voice.debug_inject_frame(BOB, _frame(0))
	check(Voice.is_on_radio(BOB) and Voice.get_radio_peers().size() == 1 and Voice.get_radio_peers()[0] == BOB and _changes == [[BOB, true]], "Bob is on the radio at his first frame (radio_changed %s)" % [_changes])
	var out := Voice.get_radio_output_node(BOB, rb)
	check(out != null and out.get_parent() == rb and String(out.name) == "RadioVoice%d" % BOB, "an output at radio B, its child (%s)" % (out.get_path() if out != null else "none"))
	check(Voice.get_radio_output_node(BOB, a) == null and Voice.get_radio_output_count() == 1, "nothing at Bob's own radio: one output in all")
	if out != null:
		var gen := out.stream as AudioStreamGenerator
		check(out.bus == Voice.RADIO_BUS and is_equal_approx(out.volume_db, Config.balance.radio_volume_db) and gen != null
				and is_equal_approx(gen.mix_rate, float(Voice.SAMPLE_RATE)) and out.playing,
				"on the Radio bus at radio_volume_db (%.1f dB), a 16 kHz generator, playing" % out.volume_db)
	var bi := AudioServer.get_bus_index(Voice.RADIO_BUS)
	var low_cut := false
	var high_cut := false
	for i in AudioServer.get_bus_effect_count(bi) if bi != -1 else 0:
		var e := AudioServer.get_bus_effect(bi, i)
		low_cut = low_cut or (e is AudioEffectHighPassFilter and (e as AudioEffectFilter).cutoff_hz > 250.0)
		high_cut = high_cut or (e is AudioEffectLowPassFilter and (e as AudioEffectFilter).cutoff_hz < 3500.0)
	check(bi != -1 and low_cut and high_cut and AudioServer.get_bus_send(bi) == Voice.VOICE_BUS and AudioServer.get_bus_index(Voice.VOICE_BUS) < bi,
			"the Radio bus: a narrow band (high-pass + low-pass), sent to Voice (the voice volume applies)")
	check(a.get_click_count(true) == int(c0[0]) + 1 and rb.get_click_count(true) == int(c0[1]) + 1, "radio_on at both ends")
	check(rb.is_receiving() and rb.is_static_playing() and rb.is_lit() and not rb.is_sending(), "radio B: the static under it, its lamp lit")
	check(a.is_sending() and a.is_lit() and not a.is_receiving() and not a.is_static_playing(), "radio A: its lamp lit, no static")
	check((rb.get_node(^"Visual/Led") as MeshInstance3D).material_override != null and (a.get_node(^"Visual/Led") as MeshInstance3D).material_override != null,
			"both lamps carry the lit material")
	var ls := Voice.get_radio_listeners()
	check(ls.size() == 1 and ls[0] == rb, "get_radio_listeners(): radio B")
	check(hud.has_radio_tag(BOB) and not hud.has_radio_tag(1), "the HUD: RADIO in Bob's row, not in mine")
	for i in range(1, 15):
		await wait_sec(0.02)
		Voice.debug_inject_frame(BOB, _frame(i))
	var t_last := Time.get_ticks_msec()
	await wait_frames(3)
	var st := Voice.get_radio_stats()
	check(int(st["frames"]) - int(st0["frames"]) == 15 and int(st["queued"]) - int(st0["queued"]) == 15, "all 15 frames went to radio B %s" % [st])
	check(int(st["played"]) > int(st0["played"]), "and into its generator (%d)" % (int(st["played"]) - int(st0["played"])))
	check(Voice.get_output_node(BOB) != null, "the proximity voice plays as before (VoiceOut/%d)" % BOB)
	await wait_until(func() -> bool: return not Voice.is_on_radio(BOB), 2.0, "the transmission ends after the gap")
	var gap := Time.get_ticks_msec() - t_last
	check(gap >= Voice.RADIO_GAP_MS - 40 and gap < Voice.RADIO_GAP_MS + 500, "about RADIO_GAP_MS (%d) after the last frame (%d ms)" % [Voice.RADIO_GAP_MS, gap])
	check(_changes == [[BOB, true], [BOB, false]], "radio_changed: on, then off %s" % [_changes])
	check(a.get_click_count(false) == int(c0[2]) + 1 and rb.get_click_count(false) == int(c0[3]) + 1, "radio_off at both ends")
	check(not rb.is_receiving() and not rb.is_static_playing() and not rb.is_lit() and not a.is_lit(), "the static stops, the lamps go out")
	await wait_frames(2)
	check(Voice.get_radio_output_count() == 0 and not is_instance_valid(out), "the output is freed")
	check(Voice.get_radio_listeners().is_empty() and not hud.has_radio_tag(BOB), "nobody listening, no tag")


# --- anywhere -------------------------------------------------------------------------------------------------------------

func _test_anywhere() -> void:
	step("anywhere: the back room, the far end of the grow hall, my hands")
	var a := radios[0]
	var rb := radios[1]
	var back := room.get_backroom_transform(0).origin
	var c := items.server_spawn_item(Const.ITEM_RADIO, {}, back) as Radio
	var d := items.server_spawn_item(Const.ITEM_RADIO, {}, FAR_HALL) as Radio
	check(items.server_give_item(rb, 1), "I hold radio B")
	await wait_frames(3)
	if not check(c != null and d != null and a.holder_id == BOB, "radio C in the back room, radio D in the grow hall, Bob still holds A"):
		return
	check(room.is_in_booth(c.global_position) and room.get_area_index(d.global_position) == 1, "C behind the booth, D in the hall")
	var st0 := Voice.get_radio_stats()
	for i in 8:
		Voice.debug_inject_frame(BOB, _frame(i))
		await wait_sec(0.02)
	var outs := [Voice.get_radio_output_node(BOB, rb), Voice.get_radio_output_node(BOB, c), Voice.get_radio_output_node(BOB, d)]
	var parents_ok := true
	for i in 3:
		var o: AudioStreamPlayer3D = outs[i]
		if o == null or o.get_parent() != [rb, c, d][i]:
			parents_ok = false
	check(parents_ok and Voice.get_radio_output_count() == 3 and Voice.get_radio_output_node(BOB, a) == null, "three outputs: in my hands, in the back room, in the hall")
	var st := Voice.get_radio_stats()
	check(int(st["queued"]) - int(st0["queued"]) == 24 and int(st["frames"]) - int(st0["frames"]) == 8, "every frame at all three (%s)" % [st])
	check(Voice.get_radio_listeners().size() == 3 and c.is_static_playing() and d.is_static_playing() and rb.is_static_playing(), "three listeners, static at each")
	step("a radio despawned mid-transmission takes its output with it")
	items.server_despawn_item(c)
	await wait_frames(2)
	for i in range(8, 12):
		Voice.debug_inject_frame(BOB, _frame(i))
		await wait_sec(0.02)
	check(Voice.get_radio_output_count() == 2 and not is_instance_valid(outs[1]) and Voice.get_radio_listeners().size() == 2, "two outputs and two listeners left")
	await wait_until(func() -> bool: return not Voice.is_on_radio(BOB), 2.0, "it ends")
	await wait_frames(2)
	check(Voice.get_radio_output_count() == 0, "no output left")
	items.server_despawn_item(d)
	await wait_frames(2)


# --- my own transmission ----------------------------------------------------------------------------------------------------

func _test_me() -> void:
	step("my own transmission (the real send path): never played back here")
	var a := radios[0]
	var rb := radios[1]
	items.server_release_holder(BOB)
	await wait_frames(2)
	check(rb.holder_id == 1 and a.holder_id == 0, "I hold B, A lies on the floor")
	_changes.clear()
	var sent0 := int(Voice.get_stats()["sent"])
	for i in 10:
		Voice.debug_send_frame(_frame(i))
		await wait_sec(0.02)
	check(int(Voice.get_stats()["sent"]) == sent0 + 10, "ten frames sent")
	check(Voice.is_on_radio(1) and not _changes.is_empty() and _changes[0] == [1, true], "my own frames put me on the radio %s" % [_changes])
	check(Voice.get_radio_output_count() == 0, "no radio output on my own peer: I never hear my own radio voice")
	check(rb.is_sending() and not rb.is_receiving() and a.is_receiving() and a.is_static_playing(), "my radio's lamp; static at radio A")
	check(Voice.is_transmitting_on_radio() and hud.has_radio_tag(1) and not hud.has_radio_tag(BOB), "the HUD: RADIO in my row")
	await wait_until(func() -> bool: return not Voice.is_on_radio(1), 2.0, "it ends after the gap")
	check(not hud.has_radio_tag(1) and not a.is_static_playing(), "the tag goes, the static stops")


# --- validation --------------------------------------------------------------------------------------------------------------

func _test_validation() -> void:
	step("validation: frames the receive checks drop never reach a radio")
	var a := radios[0]
	items.server_release_holder(1)
	check(items.server_give_item(a, BOB), "Bob holds A again")
	await wait_sec(1.1) # Bob's rate window and his sequence start afresh
	var st0 := Voice.get_radio_stats()
	var vs0 := Voice.get_stats()
	var dropped0: Dictionary = vs0["dropped"]
	Voice.debug_inject_frame(STRANGER, _frame(0))
	var big := PackedByteArray()
	big.resize(Voice.MAX_FRAME_BYTES + 1)
	Voice.debug_inject_frame(BOB, big)
	Voice.debug_inject_frame(BOB, PackedByteArray())
	check(not Voice.is_on_radio(STRANGER) and not Voice.is_on_radio(BOB) and int(Voice.get_radio_stats()["queued"]) == int(st0["queued"]),
			"a stranger's frame, a frame too big, an empty one: nobody on the radio, nothing queued")
	for i in 70:
		Voice.debug_inject_frame(BOB, _frame(i))
	var vs1 := Voice.get_stats()
	var st1 := Voice.get_radio_stats()
	var dropped1: Dictionary = vs1["dropped"]
	var accepted := int(vs1["received"]) - int(vs0["received"])
	check(accepted == Voice.MAX_FRAMES_PER_SEC and int(st1["frames"]) - int(st0["frames"]) == accepted and int(st1["queued"]) - int(st0["queued"]) == accepted,
			"a burst of 70: %d accepted, exactly those reach radio B" % accepted)
	check(int(dropped1.get("rate", 0)) - int(dropped0.get("rate", 0)) == 70 - accepted and int(dropped1.get("not_player", 0)) == int(dropped0.get("not_player", 0)) + 1
			and int(dropped1.get("too_big", 0)) == int(dropped0.get("too_big", 0)) + 1, "the rest dropped by the receive checks (rate, not_player, too_big)")
	await wait_until(func() -> bool: return not Voice.is_on_radio(BOB), 2.0, "it ends")


# --- trouble -----------------------------------------------------------------------------------------------------------------

func _test_trouble() -> void:
	step("a power cut changes nothing")
	var a := radios[0]
	var rb := radios[1]
	items.server_drop_item(rb, FLOOR_A)
	await wait_sec(1.1) # the burst above used up Bob's rate window: let it start afresh
	check(Events.server_start_event(Events.EVENT_POWER_CUT), "the power goes")
	await wait_frames(2)
	check(not Events.is_power_on(), "the lights are out")
	for i in 6:
		Voice.debug_inject_frame(BOB, _frame(i))
		await wait_sec(0.02)
	check(Voice.is_on_radio(BOB) and Voice.get_radio_output_node(BOB, rb) != null and rb.is_static_playing(), "Bob still gets through to radio B")
	await wait_until(func() -> bool: return not Voice.is_on_radio(BOB), 2.0, "it ends")
	Events.server_end_event()
	await wait_frames(2)
	step("a raid that sees a radio leaves it")
	items.server_release_holder(BOB)
	items.server_drop_item(a, DOCK_SPOT)
	await wait_frames(2)
	var taken := 0
	for i in room.get_raid_points().size():
		taken += ((Events.server_raid_sweep(i)["taken"]) as Array).size()
	await wait_frames(2)
	check(taken == 0 and is_instance_valid(a) and not a.is_queued_for_deletion() and items.get_items_of_type(Const.ITEM_RADIO).size() == 2,
			"every sweep leaves both radios (one on the dock in the door's sight)")


# --- shifts ------------------------------------------------------------------------------------------------------------------

func _test_shifts() -> void:
	step("NEXT SHIFT: a radio left outside the building goes back to the shelf, one inside stays")
	var a := radios[0]
	var rb := radios[1]
	var lobby := world.get_node_or_null(^"Lobby") as Node3D
	var outside := (lobby.global_position + Vector3(0.0, 0.0, 3.0)) if lobby != null else Vector3(0.0, 0.0, 60.0)
	items.server_drop_item(a, outside)
	items.server_drop_item(rb, FLOOR_A)
	await wait_frames(2)
	check(not room.contains_point(a.global_position) and room.contains_point(rb.global_position), "A lies outside the building (%s), B in it" % a.global_position)
	var names := [String(a.name), String(rb.name)]
	Config.balance.end_round_on_quota_met = true
	GameState.server_add_sale(maxi(GameState.quota - GameState.round_sales, 1), 1)
	await wait_until(func() -> bool: return GameState.phase == GameState.Phase.ROUND_SUCCESS, 3.0, "the shift is paid")
	Config.balance.end_round_on_quota_met = false
	GameState.request_next_round()
	await wait_until(func() -> bool: return GameState.is_playing() and GameState.round_number == 2, 3.0, "shift 2 running")
	await wait_frames(2)
	_collect_radios()
	check(radios.size() == 2 and is_instance_valid(a) and is_instance_valid(rb) and [String(radios[0].name), String(radios[1].name)] == names,
			"the same two radios")
	var slot := room.get_radio_slot(0, 2)
	check(a.global_position.distance_to(slot.origin) < 0.001 and absf(angle_difference(a.rotation.y, PI)) < 0.001, "A is back on the shelf (%s)" % a.global_position)
	check(rb.global_position.distance_to(FLOOR_A) < 0.05, "B stays where it was left (%s)" % rb.global_position)
	await _test_start_over("plain")


func _test_start_over(tag: String) -> void:
	step("%s: START OVER despawns the radios; the next shift's start stocks the shelf again" % tag)
	var old := {}
	for r in radios:
		if is_instance_valid(r):
			old[String(r.name)] = true
	GameState.server_reset_game()
	await wait_frames(3)
	check(GameState.phase == GameState.Phase.WAITING and items.get_items_of_type(Const.ITEM_RADIO).is_empty(), "%s: WAITING, no radio" % tag)
	GameState.request_start_round()
	await wait_until(func() -> bool: return GameState.is_playing(), 3.0, "%s: PLAYING again" % tag)
	await wait_frames(2)
	_collect_radios()
	var fresh := radios.size() == 2
	for r in radios:
		fresh = fresh and not old.has(String(r.name))
	check(fresh, "%s: two fresh radios" % tag)
	_check_on_shelf("%s, after START OVER" % tag)


# --- replay on: a radio on the shelf receives ---------------------------------------------------------------------------------

func _test_shelf_receives() -> void:
	step("replay: Bob takes one radio, the other one on the shelf carries him")
	var a := radios[0]
	var rb := radios[1]
	_put(bob, BOB_SPOT)
	check(items.server_give_item(a, BOB), "Bob holds A")
	await wait_frames(2)
	var c0 := rb.get_click_count(true)
	for i in 6:
		Voice.debug_inject_frame(BOB, _frame(i))
		await wait_sec(0.02)
	var out := Voice.get_radio_output_node(BOB, rb)
	check(Voice.is_on_radio(BOB) and out != null and out.get_parent() == rb and rb.get_click_count(true) == c0 + 1 and rb.is_static_playing(),
			"the radio on the shelf plays him (click, static, an output)")
	await wait_until(func() -> bool: return not Voice.is_on_radio(BOB), 2.0, "it ends")
	check(rb.get_click_count(false) >= 1 and Voice.get_radio_output_count() == 0, "radio_off, no output left")
	items.server_release_holder(BOB)
	await wait_frames(2)


# --- shutdown ------------------------------------------------------------------------------------------------------------------

func _test_shutdown() -> void:
	step("Voice.shutdown() lets go of every radio output and silences the radios")
	_collect_radios()
	if not check(radios.size() == 2, "two radios"):
		return
	var a := radios[0]
	var rb := radios[1]
	check(items.server_give_item(a, BOB), "Bob holds A")
	for i in 4:
		Voice.debug_inject_frame(BOB, _frame(i))
		await wait_sec(0.02)
	check(Voice.get_radio_output_count() == 1 and rb.is_static_playing(), "a transmission running")
	Voice.shutdown()
	check(Voice.get_radio_output_count() == 0 and Voice.get_radio_peers().is_empty() and not rb.is_static_playing() and not rb.is_lit() and not a.is_lit(),
			"no output, nobody on the radio, every radio silent and dark")


# --- helpers ------------------------------------------------------------------------------------------------------------------

func _frame(phase: int) -> PackedByteArray:
	var s := PackedFloat32Array()
	s.resize(VoiceScript.FRAME_SAMPLES)
	for i in VoiceScript.FRAME_SAMPLES:
		s[i] = 0.4 * sin(TAU * 220.0 * float(i + phase * VoiceScript.FRAME_SAMPLES) / float(VoiceScript.SAMPLE_RATE))
	return VoiceScript.encode_mulaw(s)


## Places a fake (unowned) worker: place_at writes the synced net_position too, so remote smoothing keeps him there.
func _put(p: Player, pos: Vector3) -> void:
	p.place_at(Transform3D(Basis.IDENTITY, Vector3(pos.x, 0.05, pos.z)))


func _put_me(pos: Vector3, yaw: float) -> void:
	me.velocity = Vector3.ZERO
	me.global_position = Vector3(pos.x, 0.02, pos.z)
	me.rotation = Vector3(0.0, yaw, 0.0)
	me.head.rotation.x = 0.0


func wait_physics(n: int) -> void:
	for i in n:
		await get_tree().physics_frame
