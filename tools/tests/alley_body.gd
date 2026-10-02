extends "res://tools/tests/qa_base.gd"
## M15 alley suite (alley agent): the ball, the hoop and its counter, the notice board. A single headless host with
## one fake worker (Net.players + World.server_spawn_player, no owning peer), the lobby on.
##   godot --headless --path . -s res://tools/tests/run_test.gd -- --body=res://tools/tests/alley_body.gd --lobby --port=7981
## Covers: one ball in the alley while the game waits there and nowhere else (gone with the ride, out of a holder's
## hands too, back on every return); held, dropped, thrown, landing inside the alley; a worker it hits staggers; the
## hoop counts a ball that FALLS through the ring once (the synced number and the label), nothing else counts, the
## ball drops below the ring; a worker's own aimed throw from 8 m; the counter starts over with the alley; the board
## before the first shift, after a paid shift and after a missed one, the briefing with and without
## get_shift_briefing, the record with and without Career lines (stand-ins), the type fitting; everything inert with
## the lobby off. Every engine/script error fails the run unless announced (qa_base.gd).

const Aim := preload("res://tools/tests/alley_aim.gd")


class BriefingStandIn extends RefCounted:
	var lines: Array[String] = []

	func get_shift_briefing() -> Array[String]:
		return lines


class CareerStandIn extends RefCounted:
	var lines: Array[String] = []
	var title: String = ""

	func get_summary_lines() -> Array[String]:
		return lines

	func get_title() -> String:
		return title


class NothingStandIn extends RefCounted:
	pass


var _port: int = 7981
var _world: World
var _room: Room
var _lobby: Lobby
var _hoop: AlleyHoop
var _board: AlleyBoard
var _items: ItemManager
var _counts: Array = []       # every count_changed value
var _board_changes: int = 0
var _keep: Array = []         # stand-ins (the board holds plain Object references)
var _nothing := NothingStandIn.new()


func _run() -> void:
	_label = "alley"
	_port = port_arg(7981)
	await get_tree().process_frame
	check(Config.lobby_enabled, "the suite runs with the lobby on (--lobby)")
	Config.lobby_enabled = true
	if await _host("lobby on"):
		await _test_things()
		await _test_board_before()
		await _test_hold_and_throw()
		await _test_stagger()
		await _test_hoop()
		await _test_own_throw()
		await _test_ride()
		await _test_paid_shift()
		await _test_missed_shift()
		await _leave()
	Config.lobby_enabled = false
	if await _host("lobby off"):
		await _test_lobby_off()
		await _leave()
	finish()


func _host(tag: String) -> bool:
	step("hosting (%s)" % tag)
	Config.growth_speed_override = 0.0
	Game.start_host("Tester", _port)
	await wait_until(func() -> bool: return Game.world != null and Game.local_player != null, 5.0, "%s: world + local player exist" % tag)
	if Game.world == null or Game.local_player == null:
		return false
	_world = Game.world
	_room = _world.room
	_lobby = _world.lobby
	_items = _world.items
	_hoop = _lobby.get_hoop() if _lobby != null else null
	_board = _lobby.get_board() if _lobby != null else null
	await wait_frames(3)
	if not check(_lobby != null and _hoop != null and _board != null, "%s: World/Lobby with its Hoop and its ReportBoard" % tag):
		return false
	_counts.clear()
	_hoop.count_changed.connect(func(n: int) -> void: _counts.append(n))
	_board.changed.connect(func() -> void: _board_changes += 1)
	return true


func _leave() -> void:
	Game.return_to_menu()
	await wait_until(func() -> bool: return GameState.phase == GameState.Phase.MENU and Game.world == null, 5.0, "back in the menu")


# --- what is there ----------------------------------------------------------------------------------------------------

func _test_things() -> void:
	step("the ball, the hoop, the board")
	var me: Player = Game.local_player
	var floor_y := _lobby.global_position.y
	check(GameState.phase == GameState.Phase.WAITING and _lobby.is_in_use(), "WAITING in the alley")
	var ball := _lobby.get_ball()
	check(ball is Ball and items_of(Const.ITEM_BALL).size() == 1, "one ball exists (%d)" % items_of(Const.ITEM_BALL).size())
	if ball == null:
		return
	check(ball.item_type == Const.ITEM_BALL and ItemManager.get_scene_path(Const.ITEM_BALL) == "res://scenes/items/ball.tscn", "type 'ball', registered in the type map")
	check(_flat(ball.global_position).distance_to(_flat(_lobby.get_ball_spot())) < 0.05 and absf(ball.global_position.y - floor_y) < 0.05,
			"it lies at the ball spot (%s)" % ball.global_position)
	check(_lobby.contains_point(ball.global_position) and not _room.get_play_bounds().grow(5.0).has_point(ball.global_position), "in the alley, nowhere near the floor")
	check(not ball.is_held() and not ball.is_flying() and ball.get_collider().collision_layer == Const.LAYER_ITEM, "on the ground, on the item layer")
	check(ball.get_display_name() == "Ball" and ball.get_prompt(me) == "Pick up Ball" and ball.get_props().is_empty(), "'%s', no props" % ball.get_prompt(me))
	var box := _mesh_box(ball.get_visual())
	check(box.size.x > 0.2 and box.size.x < 0.3 and box.size.y > 0.12 and box.size.y < 0.22 and absf(box.position.y) < 0.01,
			"ball.glb: about 0.24 m across, half flat, resting on its origin (%s)" % box.size)
	var stream := Sfx.get_stream(&"ball")
	check(Sfx.has_sound(&"ball") and stream != null and float(Sfx.measure(stream).seconds) > 0.3, "the 'ball' sound has a recipe of its own")
	# The hoop.
	var ring := _hoop.get_ring_center()
	var local := _lobby.global_transform.affine_inverse() * ring
	check(absf(local.y - 2.6) < 0.15, "the ring is about 2.6 m up (%.2f)" % local.y)
	check(absf(Lobby.INTERIOR_SIZE.z * 0.5 - local.z - AlleyHoop.RING_OUT) < 0.1 and absf(local.x) < Lobby.INTERIOR_SIZE.x * 0.5 - 1.0,
			"on the south wall, its centre %.2f m out (%s)" % [AlleyHoop.RING_OUT, local])
	check(_hoop.count == 0 and _hoop.get_count_text() == "0", "the counter reads 0")
	check(not _hoop.get_node(^"Model").find_children("*", "MeshInstance3D", true, false).is_empty(), "alley_hoop.glb is there")
	var counter := _hoop.get_node_or_null(AlleyHoop.COUNTER_PATH) as Node3D
	check(counter != null and counter.global_position.distance_to(ring) < 1.3 and counter.global_position.distance_to(ring) > 0.5, "the counter hangs beside the hoop")
	await get_tree().physics_frame
	var below := _ray(ring, ring + Vector3.DOWN * 4.0)
	check(not below.is_empty() and absf(float(below["position"].y) - floor_y) < 0.02, "nothing but floor under the ring")
	var out := _hoop.global_basis.z.normalized()
	var through := _ray(ring + out * 2.0, ring - out * 2.0)
	check(not through.is_empty() and (Vector3(through["position"]) - ring).dot(-out) > AlleyHoop.RING_OUT - 0.1, "nothing solid in the ring: the wall behind it is the first thing hit")
	# The board.
	var board_local := _lobby.global_transform.affine_inverse() * _board.global_position
	check(board_local.x > Lobby.INTERIOR_SIZE.x * 0.5 - 0.2 and _board.global_basis.z.normalized().dot(-_lobby.global_basis.x.normalized()) > 0.99,
			"the board hangs on the east wall and faces the alley (%s)" % board_local)
	check(board_local.y > 1.5 and board_local.y < 2.5, "at eye level (centre %.2f m)" % board_local.y)
	var heads_ok := true
	for i in AlleyBoard.COLUMN_COUNT:
		var head := _board.get_node_or_null("Head%d" % i) as Label3D
		var body := _board.get_node_or_null("Body%d" % i) as Label3D
		if head == null or body == null or head.text != AlleyBoard.HEADS[i]:
			heads_ok = false
	check(heads_ok, "three columns of Label3D: LAST SHIFT, NEXT, YOUR RECORD")
	check(AlleyBoard.BODY_FONT_SIZE * AlleyBoard.PIXEL_SIZE >= 0.09 and AlleyBoard.MIN_FONT_SIZE * AlleyBoard.PIXEL_SIZE >= 0.05,
			"type of %.1f cm (never under %.1f): readable from 4 m" % [AlleyBoard.BODY_FONT_SIZE * AlleyBoard.PIXEL_SIZE * 100.0, AlleyBoard.MIN_FONT_SIZE * AlleyBoard.PIXEL_SIZE * 100.0])
	check(_hoop.find_children("*", "CollisionObject3D", true, false).is_empty() and _board.find_children("*", "CollisionObject3D", true, false).is_empty(),
			"neither has a physics body")
	check(_hoop.is_visible_in_tree() and _board.is_visible_in_tree(), "both are drawn while the alley is in use")


# --- the board before the first shift -----------------------------------------------------------------------------------

func _test_board_before() -> void:
	step("the board before the first shift")
	_board.briefing_source = _nothing
	_board.career_source = _nothing
	_board.refresh()
	var due := "Payment due $%d." % GameState.quota
	check(_board.get_last_shift_lines().is_empty() and _board.report_lines.is_empty(), "blank: no shift is recorded")
	check(_board.get_column_text(0) == "No shift worked yet." and _board.get_shown_text(0) == "No shift worked yet.", "LAST SHIFT reads '%s'" % _board.get_shown_text(0))
	check(_board.get_next_lines() == PackedStringArray(["Shift 1 is next.", due]), "without get_shift_briefing: %s" % [_board.get_next_lines()])
	check(_board.get_shown_text(1) == "Shift 1 is next.\n" + due, "NEXT shows it")
	check(_board.get_career_lines().is_empty() and _board.get_shown_text(2) == "Nothing on file.", "without Career lines: '%s'" % _board.get_shown_text(2))
	step("a briefing")
	var brief := BriefingStandIn.new()
	_keep.append(brief)
	brief.lines = ["Dry air. Trays dry half again as fast.", "  ", "Paying well: Golden Kush. Paying badly: Budget Bud.", "New at the window: Golden Kush."]
	_board.briefing_source = brief
	var changes := _board_changes
	_board.refresh()
	check(_board.get_next_lines() == PackedStringArray(["Shift 1 is next.", due, brief.lines[0], brief.lines[2], brief.lines[3]]),
			"with get_shift_briefing: the shift, the payment, then its lines (blank ones dropped)")
	check(_board.get_shown_text(1).ends_with("New at the window: Golden Kush.") and _board_changes == changes + 1, "NEXT shows them, changed fired once")
	_board.refresh()
	check(_board_changes == changes + 1, "a refresh with nothing new changes nothing")
	var many: Array[String] = []
	for i in 12:
		many.append("Line %d." % i)
	brief.lines = many
	check(_board.get_next_lines().size() == 2 + AlleyBoard.MAX_BRIEFING, "a long briefing is cut to %d lines" % AlleyBoard.MAX_BRIEFING)
	brief.lines = ["Dry air. Trays dry half again as fast."]
	step("a record")
	var career := CareerStandIn.new()
	_keep.append(career)
	career.lines = ["Shifts worked: 7", "Best shift reached: 4", "Deposited: $3120"]
	_board.career_source = career
	_board.refresh()
	check(_board.get_career_lines() == PackedStringArray(career.lines) and _board.get_shown_text(2) == "\n".join(PackedStringArray(career.lines)),
			"Career.get_summary_lines() fills YOUR RECORD")
	career.title = "Floor hand"
	_board.refresh()
	check(_board.get_career_lines()[0] == "Floor hand." and _board.get_career_lines().size() == 4, "the job title comes first (%s)" % [_board.get_career_lines()])
	career.lines = ["Floor hand. Shifts worked: 7"]
	check(_board.get_career_lines().size() == 1, "not twice when the first line already names it")
	var text := _board.get_board_text()
	check(text.begins_with("LAST SHIFT\nNo shift worked yet.\n\nNEXT\nShift 1 is next.") and text.contains("YOUR RECORD\nFloor hand."), "get_board_text(): the three columns top to bottom")
	step("the type fits")
	check(_board.get_font_size() == AlleyBoard.BODY_FONT_SIZE, "a few lines: the full size (%d)" % _board.get_font_size())
	var wall: Array[String] = []
	for i in 7:
		wall.append("Line %d of a record that goes on for much longer than a board this size was built to hold." % i)
	career.lines = wall
	_board.refresh()
	check(_board.get_font_size() < AlleyBoard.BODY_FONT_SIZE and _board.get_font_size() >= AlleyBoard.MIN_FONT_SIZE,
			"a wall of text: the type shrinks, never below %d (%d)" % [AlleyBoard.MIN_FONT_SIZE, _board.get_font_size()])
	career.lines = ["Shifts worked: 7"]
	_board.refresh()
	check(_board.get_font_size() == AlleyBoard.BODY_FONT_SIZE, "and grows back")
	step("the real sources")
	_board.briefing_source = null
	_board.career_source = null
	_board.refresh()
	check(_board.get_next_lines()[0] == "Shift 1 is next." and _board.get_next_lines()[1] == due, "GameState: the shift and the payment lead the column")
	check(_board.get_shown_text(2) != "", "the Career autoload answers ('%s')" % _board.get_shown_text(2).get_slice("\n", 0))
	_add_worker(2)
	await wait_frames(3)
	var due2 := "Payment due $%d." % GameState.quota
	check(due2 != due, "a second worker clocks in: the payment is re-priced ($%d)" % GameState.quota)
	await wait_until(func() -> bool: return _board.get_shown_text(1).contains(due2), 1.5, "the board follows within a second")


# --- an ordinary item ---------------------------------------------------------------------------------------------------

func _test_hold_and_throw() -> void:
	step("held, dropped, thrown")
	var me: Player = Game.local_player
	var ball := _lobby.get_ball()
	var floor_y := _lobby.global_position.y
	_put_at(me, _lobby.get_ball_spot() + Vector3(0.0, 0.05, 1.0), 0.0)
	await wait_frames(3)
	check(ball.can_interact(me), "a worker with free hands can pick it up")
	ball.interact(me)
	await wait_until(func() -> bool: return ball.holder_id == 1, 2.0, "picked up through the interaction request")
	check(me.get_held_item() == ball and ball.get_collider().collision_layer == 0 and ball.get_label_text() == "Ball", "in the host's hands ('%s')" % ball.get_label_text())
	_items.request_drop()
	await wait_until(func() -> bool: return ball.holder_id == 0, 2.0, "dropped")
	await wait_frames(2)
	check(ball.global_position.distance_to(me.global_position) < 1.5 and absf(ball.global_position.y - floor_y) < 0.05 and _in_alley(ball), "it lies in front of the worker")
	check(_items.server_give_item(ball, 1), "picked up again")
	me.head.rotation.x = 0.0
	_items.request_throw()
	await wait_until(func() -> bool: return ball.is_flying(), 1.0, "thrown: it is in the air")
	check(me.get_held_item() == null and not ball.can_interact(me), "out of the hands, not catchable")
	await wait_until(func() -> bool: return not ball.is_flying(), 4.0, "it lands")
	check(_in_alley(ball) and absf(ball.global_position.y - floor_y) < 0.05 and ball.global_position.distance_to(me.global_position) > 3.0,
			"on the alley floor, metres away (%s)" % (_lobby.global_transform.affine_inverse() * ball.global_position))
	step("nothing gets it out of the alley")
	var from := _lobby.global_position + Vector3(-2.0, 1.4, 3.0)
	for v: Vector3 in [Vector3(25.0, 4.0, 0.0), Vector3(-25.0, 4.0, 0.0), Vector3(0.0, 4.0, 25.0), Vector3(0.0, 4.0, -25.0), Vector3(0.5, 16.0, 0.5)]:
		check(_items.server_throw_item(ball, from, v, 1), "thrown at %s" % v)
		await wait_until(func() -> bool: return not ball.is_flying(), 4.5, "it comes down")
		await wait_frames(2)
		check(_in_alley(ball) and ball.global_position.y < floor_y + 1.2, "inside the walls (%s)" % (_lobby.global_transform.affine_inverse() * ball.global_position))
	check(items_of(Const.ITEM_BALL).size() == 1, "still one ball")
	step("out of reach")
	var van := _lobby.get_van()
	check(_items.server_throw_item(ball, van.global_transform * Vector3(0.0, 4.0, -0.6), Vector3.DOWN * 0.5, 1), "let go above the van")
	await wait_until(func() -> bool: return not ball.is_flying(), 3.0, "it comes down")
	await wait_frames(2)
	check(ball.global_position.y > floor_y + 2.0 and _in_alley(ball), "on the van's roof (%.2f m up)" % (ball.global_position.y - floor_y))
	await wait_until(func() -> bool: return _flat(ball.global_position).distance_to(_flat(_lobby.get_ball_spot())) < 0.05 and absf(ball.global_position.y - floor_y) < 0.05,
			3.0, "nobody can get at it there: the host puts it back at the ball spot")
	_items.server_drop_item(ball, _lobby.global_position + Vector3(-4.4, 1.12, 1.6))
	await wait_sec(2.0)
	check(ball.global_position.y > floor_y + 1.0, "on top of a bin it stays (within reach)")


func _test_stagger() -> void:
	step("a thrown ball staggers the worker it hits")
	var me: Player = Game.local_player
	var ball := _lobby.get_ball()
	var w2 := _world.get_player(2)
	if not check(w2 != null, "the fake worker is there"):
		return
	_place(w2, _lobby.global_position + Vector3(2.6, 0.0, 3.4))
	_put_at(me, _lobby.global_position + Vector3(-3.0, 0.05, 2.0), 0.0)
	await wait_frames(3)
	var hits := GameState.get_stat(1, Const.STAT_HITS)
	check(_items.server_throw_item(ball, w2.global_position + Vector3(0.0, 1.0, 3.0), Vector3(0.0, 1.8, -8.0), 1), "thrown at worker 2's chest")
	await wait_until(func() -> bool: return not ball.is_flying(), 3.0, "the flight ends")
	check(w2.is_stunned() and GameState.get_stat(1, Const.STAT_HITS) == hits + 1, "worker 2 staggers, a hit is counted for the thrower")
	check(ball.global_position.distance_to(w2.global_position) < 1.5 and _in_alley(ball), "the ball drops at their feet")
	await wait_until(func() -> bool: return not w2.is_stunned(), 2.0, "they recover")
	_place(w2, _lobby.global_position + Vector3(3.6, 0.0, -0.8))


# --- the hoop -----------------------------------------------------------------------------------------------------------

func _test_hoop() -> void:
	step("the ring's geometry")
	var ball := _lobby.get_ball()
	var floor_y := _lobby.global_position.y
	var c := _hoop.get_ring_center()
	var out := _hoop.global_basis.z.normalized()
	var side := _hoop.global_basis.x.normalized()
	check(_hoop.is_through_ring(c + Vector3.UP * 0.2, c + Vector3.DOWN * 0.2), "down through the middle: through")
	check(not _hoop.is_through_ring(c + Vector3.DOWN * 0.2, c + Vector3.UP * 0.2), "up through the middle: not")
	check(_hoop.is_through_ring(c + Vector3.UP * 0.2 + side * 0.28, c + Vector3.DOWN * 0.2 + side * 0.28), "down just inside the ring: through")
	check(not _hoop.is_through_ring(c + Vector3.UP * 0.2 + side * 0.36, c + Vector3.DOWN * 0.2 + side * 0.36), "down just outside it: not")
	check(not _hoop.is_through_ring(c + Vector3.UP * 0.5, c + Vector3.UP * 0.1) and not _hoop.is_through_ring(c + Vector3.DOWN * 0.1, c + Vector3.DOWN * 0.5), "a piece that never crosses the plane: not")
	check(not _hoop.is_through_ring(Vector3(NAN, 0.0, 0.0), c), "a NaN point: not")

	step("throws that count nothing")
	_counts.clear()
	await _throw(ball, c + Vector3.DOWN * 1.2, Vector3.UP * 9.0 + out * 1.5, "from below, up through the ring, down a long way out")
	await _throw(ball, c + Vector3.DOWN * 1.2, Vector3.UP * 9.0, "from below, straight up through the ring and back down through it")
	await _throw(ball, c + Vector3.UP * 1.0 + side * 0.5, Vector3.DOWN * 0.5, "falling past the outside of the ring")
	await _throw(ball, c + out * 3.0 + Vector3.UP * 0.6, -out * 9.0 + Vector3.UP * 1.0, "flat into the wall above the ring")
	_items.server_drop_item(ball, c + Vector3.UP * 0.3)
	await wait_frames(4)
	_items.server_drop_item(ball, _hoop.get_drop_point() + out * 1.0)
	await wait_frames(4)
	check(_hoop.count == 0 and _counts.is_empty() and _hoop.get_count_text() == "0", "none of them counted, nor did a ball put down through the ring by hand")

	step("a ball that falls through")
	check(_items.server_throw_item(ball, c + Vector3.UP * 0.9 + side * 0.1 + out * 0.05, Vector3.DOWN * 0.5, 1), "let go above the ring")
	var serial := ball.flight_serial
	await wait_until(func() -> bool: return _hoop.count == 1, 2.0, "the host counts it")
	check(_hoop.get_count_text() == "1" and _counts == [1], "the synced number and the label read 1 (%s)" % [_counts])
	check(ball.is_flying() and ball.flight_serial != serial, "the ball is still in the air, on a new arc")
	check(_items.to_global(ball.flight_origin).distance_to(c + Vector3.DOWN * AlleyHoop.DROP_BELOW) < 0.01 and ball.flight_velocity.is_equal_approx(Vector3.DOWN * AlleyHoop.DROP_SPEED),
			"straight down from the ring's centre")
	await wait_until(func() -> bool: return not ball.is_flying(), 3.0, "it lands")
	await wait_frames(2)
	check(_flat(ball.global_position).distance_to(_flat(_hoop.get_drop_point())) < 0.3 and absf(ball.global_position.y - floor_y) < 0.05, "below the hoop (%s)" % (_lobby.global_transform.affine_inverse() * ball.global_position))
	await wait_sec(0.3)
	check(_hoop.count == 1 and _counts == [1], "one throw, one count")

	step("standing under it")
	var w2 := _world.get_player(2)
	_place(w2, _hoop.get_drop_point())
	await wait_frames(3)
	check(_items.server_throw_item(ball, c + Vector3.UP * 0.9, Vector3.DOWN * 0.5, 1), "another one through, a worker below")
	await wait_until(func() -> bool: return _hoop.count == 2, 2.0, "counted: 2")
	await wait_until(func() -> bool: return not ball.is_flying(), 3.0, "the ball comes down")
	check(w2.is_stunned(), "on the head of whoever stands there")
	await wait_until(func() -> bool: return not w2.is_stunned(), 2.0, "they recover")
	_place(w2, _lobby.global_position + Vector3(3.6, 0.0, -0.8))

	step("a lob from seven metres")
	var t := 1.3
	var lob := -out * (7.0 / t) + Vector3.UP * ((1.3 + 4.9 * t * t) / t)
	var from := c + Vector3.DOWN * 1.3 + out * 7.0
	check(absf(lob.length() - Config.balance.throw_speed) < 1.5, "at about a worker's throwing speed (%.1f m/s)" % lob.length())
	check(_items.server_throw_item(ball, from, lob, 1), "thrown")
	await wait_until(func() -> bool: return _hoop.count == 3, 3.0, "through: 3")
	await wait_until(func() -> bool: return not ball.is_flying(), 3.0, "it lands")
	check(_flat(ball.global_position).distance_to(_flat(_hoop.get_drop_point())) < 0.3, "below the hoop")
	await _throw(ball, from + side * 0.55, lob, "the same lob half a metre to the side")
	await _throw(ball, from, lob * 0.93, "the same lob, short")
	check(_hoop.count == 3 and _counts == [1, 2, 3] and _hoop.get_count_text() == "3", "both missed: still 3 (%s)" % [_counts])


## A worker's own throw (the request path, the hand socket, the look direction) from behind the van.
func _test_own_throw() -> void:
	step("a worker's own throw")
	var me: Player = Game.local_player
	var ball := _lobby.get_ball()
	var c := _hoop.get_ring_center()
	_put_at(me, _lobby.global_position + Vector3(-1.2, 0.05, -1.4), 0.0)
	await wait_sec(0.4)
	check(_items.server_give_item(ball, 1), "the host holds the ball, %.1f m from the hoop" % _flat(me.global_position).distance_to(_flat(c)))
	await wait_frames(2)
	var miss := Aim.aim(me, me.get_item_socket(), c)
	check(miss < 0.05, "there is a pitch that does it (%.1f degrees up, predicted miss %.3f m)" % [rad_to_deg(me.head.rotation.x), miss])
	var n := _hoop.count
	_items.request_throw()
	await wait_until(func() -> bool: return _hoop.count == n + 1, 4.0, "it falls through: %d" % (n + 1))
	await wait_until(func() -> bool: return not ball.is_flying(), 3.0, "and lands")
	me.head.rotation.x = 0.0


# --- only in the alley, only while it is in use --------------------------------------------------------------------------

func _test_ride() -> void:
	step("the ride takes the ball away")
	var b: BalanceConfig = Config.balance
	var me: Player = Game.local_player
	var ball := _lobby.get_ball()
	var count := _hoop.count
	check(_items.server_give_item(ball, 1) and me.get_held_item() == ball, "the host carries the ball")
	GameState.request_start_round()
	check(GameState.is_transitioning() and _lobby.get_ball() == ball, "the doors close; the ball is still there while it is light")
	await wait_until(func() -> bool: return GameState.is_playing(), b.transition_fade_sec + 1.5, "PLAYING")
	check(items_of(Const.ITEM_BALL).is_empty() and _lobby.get_ball() == null and me.get_held_item() == null, "the ball is gone the moment the shift starts, out of the holder's hands too")
	await wait_frames(3)
	check(not is_instance_valid(ball) or ball.is_queued_for_deletion(), "despawned")
	await wait_sec(0.7)
	check(items_of(Const.ITEM_BALL).is_empty(), "none on the floor, none in the alley")
	check(not _hoop.is_visible_in_tree() and not _board.is_visible_in_tree(), "the hoop and the board are not drawn during a shift")
	check(_hoop.count == count, "the counter keeps its number until the alley is used again (%d)" % count)
	var stray := _items.server_spawn_item(Const.ITEM_BALL, {}, Vector3(0.0, 0.0, 3.0))
	check(stray != null, "a ball put on the floor by hand")
	await wait_until(func() -> bool: return items_of(Const.ITEM_BALL).is_empty(), 1.0, "is removed at the next look")
	await wait_until(func() -> bool: return not (_world.get_node(^"HUD") as HUD).is_transition_showing(), b.transition_fade_sec + 1.5, "the screen fades back in")


func _test_paid_shift() -> void:
	step("a paid shift on the board")
	var b: BalanceConfig = Config.balance
	check(_board.report_lines.is_empty(), "nothing is written while the first shift runs")
	GameState.server_add_stat(2, Const.STAT_THROWS, 4)
	var due := GameState.quota
	GameState.server_add_sale(due + 15, 2)
	if not GameState.is_round_over():
		GameState.time_left = 0.01
	await wait_until(func() -> bool: return GameState.phase == GameState.Phase.ROUND_SUCCESS, 2.0, "payment met: ROUND_SUCCESS")
	var verdicts := Story.get_report_verdicts()
	var want := PackedStringArray(["Shift 1. Paid.", "Deposited $%d." % (due + 15), "Due $%d." % due])
	for i in mini(verdicts.size(), 3):
		want.append(verdicts[i])
	check(not verdicts.is_empty() and want.size() <= 6, "the report has verdicts (%d)" % verdicts.size())
	check(_board.get_last_shift_lines() == want, "recorded at the end of the shift: %s" % [_board.get_last_shift_lines()])
	check(items_of(Const.ITEM_BALL).is_empty(), "no ball while the report is read")
	GameState.request_next_round()
	await wait_until(func() -> bool: return GameState.phase == GameState.Phase.WAITING, b.transition_fade_sec + 1.5, "NEXT SHIFT: WAITING in the alley")
	await wait_frames(3)
	var ball := _lobby.get_ball()
	check(ball != null and items_of(Const.ITEM_BALL).size() == 1 and _flat(ball.global_position).distance_to(_flat(_lobby.get_ball_spot())) < 0.05, "a fresh ball lies at the ball spot")
	check(_hoop.count == 0 and _hoop.get_count_text() == "0" and _counts.back() == 0, "the counter starts over")
	check(_board.get_shown_text(0) == "\n".join(want), "LAST SHIFT: '%s'" % _board.get_shown_text(0).replace("\n", " / "))
	check(_board.get_next_lines()[0] == "Shift 2 is next." and _board.get_next_lines()[1] == "Payment due $%d." % GameState.get_quota_for(2), "NEXT: %s" % [_board.get_next_lines()])
	check(_board.get_shown_text(1).begins_with("Shift 2 is next.\nPayment due $%d." % GameState.quota), "and it is what the label shows")
	check(_hoop.is_visible_in_tree() and _board.is_visible_in_tree(), "the hoop and the board are drawn again")
	var on_face := true
	for i in AlleyBoard.COLUMN_COUNT:
		var body := _board.get_node("Body%d" % i) as Label3D
		var box := body.transform * body.get_aabb()
		if box.size.x <= 0.0 or absf(box.position.x) > AlleyBoard.BOARD_SIZE.x * 0.5 or absf(box.end.x) > AlleyBoard.BOARD_SIZE.x * 0.5 \
				or box.position.y < -AlleyBoard.BOARD_SIZE.y * 0.5 or box.end.y > AlleyBoard.BOARD_SIZE.y * 0.5:
			on_face = false
			print("      column %d runs off the board: %s" % [i, box])
	check(on_face and _board.get_font_size() == AlleyBoard.BODY_FONT_SIZE, "every column's text lies on the board's face at the full type size")
	await wait_until(func() -> bool: return not (_world.get_node(^"HUD") as HUD).is_transition_showing(), b.transition_fade_sec + 1.5, "the screen fades back in")


func _test_missed_shift() -> void:
	step("a missed shift on the board")
	var b: BalanceConfig = Config.balance
	var ball := _lobby.get_ball()
	var c := _hoop.get_ring_center()
	check(_items.server_throw_item(ball, c + Vector3.UP * 0.9, Vector3.DOWN * 0.5, 1), "one through the hoop before leaving")
	await wait_until(func() -> bool: return _hoop.count == 1, 2.0, "1")
	GameState.request_start_round()
	await wait_until(func() -> bool: return GameState.is_playing(), b.transition_fade_sec + 1.5, "shift 2: PLAYING")
	check(items_of(Const.ITEM_BALL).is_empty(), "the ball is gone, in the air or not")
	await wait_until(func() -> bool: return not (_world.get_node(^"HUD") as HUD).is_transition_showing(), b.transition_fade_sec + 1.5, "the screen fades back in")
	check(_board.get_last_shift_lines()[0] == "Shift 1. Paid.", "the board still holds shift 1 while shift 2 runs")
	GameState.server_add_sale(30, 1)
	var due := GameState.quota
	GameState.time_left = 0.01
	await wait_until(func() -> bool: return GameState.phase == GameState.Phase.ROUND_FAILED, 2.0, "payment missed: ROUND_FAILED")
	var verdicts := Story.get_report_verdicts()
	var want := PackedStringArray(["Shift 2. Missed.", "Deposited $30.", "Due $%d." % due])
	for i in mini(verdicts.size(), 3):
		want.append(verdicts[i])
	check(_board.get_last_shift_lines() == want, "recorded: %s" % [_board.get_last_shift_lines()])
	GameState.request_retry()
	await wait_until(func() -> bool: return GameState.phase == GameState.Phase.WAITING, b.transition_fade_sec + 1.5, "START OVER: WAITING in the alley")
	await wait_frames(3)
	check(GameState.round_number == 1, "round 1 again")
	check(_board.get_shown_text(0) == "\n".join(want), "the board keeps the shift that was missed: '%s'" % _board.get_shown_text(0).replace("\n", " / "))
	check(_board.get_next_lines()[0] == "Shift 1 is next.", "and says shift 1 is next")
	check(_lobby.get_ball() != null and items_of(Const.ITEM_BALL).size() == 1 and _hoop.count == 0 and _hoop.get_count_text() == "0", "a ball, the counter at 0")
	await wait_until(func() -> bool: return not (_world.get_node(^"HUD") as HUD).is_transition_showing(), b.transition_fade_sec + 1.5, "the screen fades back in")


# --- lobby off -----------------------------------------------------------------------------------------------------------

func _test_lobby_off() -> void:
	step("lobby off: nothing of this exists")
	await wait_sec(0.7)
	check(GameState.phase == GameState.Phase.WAITING and not _lobby.is_in_use(), "WAITING on the floor")
	check(_lobby.get_ball() == null and items_of(Const.ITEM_BALL).is_empty(), "no ball")
	check(not _hoop.is_visible_in_tree() and not _board.is_visible_in_tree(), "the hoop and the board are not drawn")
	var ball := _items.server_spawn_item(Const.ITEM_BALL, {}, _lobby.get_ball_spot())
	var c := _hoop.get_ring_center()
	check(ball != null and _items.server_throw_item(ball, c + Vector3.UP * 0.9, Vector3.DOWN * 0.5, 1), "a ball made by hand, let go above the ring")
	await wait_until(func() -> bool: return not ball.is_flying(), 3.0, "it lands")
	check(_hoop.count == 0 and _counts.is_empty(), "the hoop counts nothing")
	_items.server_despawn_item(ball)
	GameState.request_start_round()
	check(GameState.is_playing(), "Enter starts the shift at once")
	GameState.server_add_sale(GameState.quota, 1)
	if not GameState.is_round_over():
		GameState.time_left = 0.01
	await wait_until(func() -> bool: return GameState.phase == GameState.Phase.ROUND_SUCCESS, 2.0, "ROUND_SUCCESS")
	await wait_frames(3)
	check(_board.report_lines.is_empty(), "nothing is written on the board")


# --- helpers -------------------------------------------------------------------------------------------------------------

## Throws the ball, waits for it to land and checks the counter did not move.
func _throw(ball: Item, from: Vector3, velocity: Vector3, what: String) -> void:
	var before := _hoop.count
	if not check(_items.server_throw_item(ball, from, velocity, 1), "thrown: " + what):
		return
	await wait_until(func() -> bool: return not ball.is_flying(), 4.0, "it lands")
	await wait_frames(2)
	check(_hoop.count == before and _in_alley(ball), "not counted (%d)" % _hoop.count)


func _add_worker(id: int) -> void:
	Net.players[id] = {"name": "Worker %d" % id, "color": Net.PALETTE[(id - 1) % Net.PALETTE.size()]}
	Net.players_changed.emit()
	_world.server_spawn_player(id)


## Puts my own body at `pos` facing `yaw`.
func _put_at(me: Player, pos: Vector3, yaw: float) -> void:
	me.velocity = Vector3.ZERO
	me.global_position = pos
	me.rotation = Vector3(0.0, yaw, 0.0)
	me.head.rotation.x = 0.0


## Puts a body nobody owns exactly at `pos` (synced pose + node).
func _place(p: Player, pos: Vector3) -> void:
	p.net_position = pos
	p.net_yaw = 0.0
	p.net_pitch = 0.0
	p.position = pos
	p.rotation = Vector3.ZERO
	p.velocity = Vector3.ZERO


func _in_alley(item: Item) -> bool:
	return _lobby.get_bounds().grow(0.05).has_point(item.global_position + Vector3.UP * 0.1)


## Bounds of every mesh under `node`, in `node`'s space.
func _mesh_box(node: Node3D) -> AABB:
	var box := AABB()
	var first := true
	for n in node.find_children("*", "MeshInstance3D", true, false):
		var mi := n as MeshInstance3D
		if mi.mesh == null or mi.has_meta(&"toonify_outline"):
			continue
		var part := (node.global_transform.affine_inverse() * mi.global_transform) * mi.mesh.get_aabb()
		box = part if first else box.merge(part)
		first = false
	return box


func _ray(from: Vector3, to: Vector3) -> Dictionary:
	var query := PhysicsRayQueryParameters3D.create(from, to, Const.LAYER_WORLD)
	return _world.get_world_3d().direct_space_state.intersect_ray(query)


static func _flat(v: Vector3) -> Vector3:
	return Vector3(v.x, 0.0, v.z)
