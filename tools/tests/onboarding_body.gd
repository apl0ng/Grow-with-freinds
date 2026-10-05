extends "res://tools/tests/qa_base.gd"
## M19 onboarding suite (onboarding agent): the guided first shift (scripts/core/guide.gd, Story's and the HUD's M19
## regions, the alley board's and the van's hooks). A single headless host with one fake worker (Bob: a host-side
## body without an owning peer, so the SERVER side runs directly on him). Plain game (no --replay): --guide turns the
## guide on, a fake Settings object stands in for the autoload (the suite never reads or writes a real settings
## file), and the record lives in its own temp career file.
##   godot --headless --path . -s res://tools/tests/run_test.gd -- --body=res://tools/tests/onboarding_body.gd --port=9112 --guide --run=B5VP --career-file=user://onboarding_test_9112.cfg --round-sec=900
## Pins:
##   the copy      every line and hint flat (no "!", no cheer), short; the alley line exact
##   the gate      on with --guide (or in the real game with replay on), never with --no-guide; replay off without
##                 --guide: a whole first shift with no line, no hint, nothing on the board, while the crew works
##   who           a record with shifts and guidance off: nothing (board, van, lines, hint) while the crew works; guidance
##                 turned on mid-shift (Settings.changed): the guide starts at the step the crew has reached (bought,
##                 planted, watered: the wait line is the first thing said); turned off again: it stops at once
##   the walk      a fresh record: the board's NEXT column starts with the alley line, the van's hint once near its
##                 doors; the first shift: buy (said, said once more after guide_step_timeout_sec and never a third
##                 time, the hint stays), Bob buys -> plant, the host plants -> water (the hint follows the local can:
##                 pick up / fill / pour), Bob fills and pours -> wait, the tray ripens -> harvest, the host harvests ->
##                 deposit, Bob deposits -> the payment line, the guide is over, its hint stays PAYMENT_HINT_SEC; every
##                 line at the Boss (his bark label, Story.bark_log) and the normal lines still there; the hint on the
##                 HUD (World/HUD/Root/GuideHint), clear of the prompt, the chat, the toasts and the top column, hidden
##                 by a UI lock, never a lock or a pause itself
##   the end       the shift's end switches guidance off (Settings.set_value(&"guidance", false)), the record has the
##                 shift; START OVER: nothing for that player any more
##   START OVER    mid-shift for a player with no shift on file: the guide starts from the top again; the shift ending
##                 mid-guide ends it without a last line
##   safety        a headless / `-s` run with --replay and without --guide has no guide; the real Settings autoload is
##                 never written by a suite (only a stand-in or the real game is)
## Every engine/script error fails the run unless announced (qa_base.gd).

const BOB := 2

## Stands in for the Settings autoload (get_value / set_value / changed): every write is recorded, nothing is saved.
class FakeSettings:
	extends RefCounted
	signal changed(key: StringName)
	var values: Dictionary = {&"guidance": true}
	var writes: Array = []

	func get_value(key: StringName, default: Variant = null) -> Variant:
		return values.get(key, default)

	func set_value(key: StringName, value: Variant) -> void:
		values[key] = value
		writes.append([key, value])
		changed.emit(key)


var world: World
var room: Room
var items: ItemManager
var me: Player
var bob: Player
var hud: HUD
var board: AlleyBoard
var guide: Guide
var shop: ShopCounter
var well: Well
var chute: TurnInStation
var tray: GrowPlot
var fake := FakeSettings.new()
var _path: String = ""
var _steps: Array = []
## Guide lines the suite has accounted for (said_log entries).
var _seen: int = 0


func _run() -> void:
	_label = "onboarding"
	await get_tree().process_frame
	# Headless windows report 1280x1280; force the reference logical size.
	get_tree().root.size = Vector2i(1280, 720)
	_path = str(Config.get_arg("career-file", ""))
	if not check(_path != "" and _path != Career.DEFAULT_PATH and Career.path == _path and Career.persistent,
			"this run has its own career file (%s)" % _path):
		finish(); return
	check(not Config.replay_enabled and Config.has_arg("guide") and not Config.lobby_enabled, "plain game, --guide, the lobby off")
	_remove(_path)
	Career.clear_record()
	guide = Story.guide
	if not check(guide != null and guide is Guide and guide.get_path() == ^"/root/Story/Guide", "Story made its guide (/root/Story/Guide)"):
		finish(); return
	guide.settings_override = fake
	guide.step_changed.connect(func(s: StringName) -> void: _steps.append(s))
	var b: BalanceConfig = Config.balance
	for s: SeedDef in b.seeds:
		s.mutation_chance = 0.0
	b.end_round_on_quota_met = false
	check(is_equal_approx(b.guide_step_timeout_sec, 25.0), "guide_step_timeout_sec is 25 (%.1f)" % b.guide_step_timeout_sec)

	_test_copy()
	_test_gate()

	step("hosting")
	Game.start_host("Tester", port_arg(9112))
	await wait_until(func() -> bool: return Game.world != null and Game.local_player != null, 5.0, "world + local player exist")
	if Game.world == null:
		_cleanup(); finish(); return
	world = Game.world
	room = world.room
	items = world.items
	me = Game.local_player
	hud = world.get_node_or_null(^"HUD") as HUD
	board = world.get_node_or_null(^"Lobby/ReportBoard") as AlleyBoard
	Net.players[BOB] = {"name": "Bob", "color": Net.PALETTE[BOB - 1]}
	bob = world.server_spawn_player(BOB)
	await wait_frames(3)
	shop = room.get_station("ShopCounter") as ShopCounter
	well = room.get_station("Well") as Well
	chute = room.get_station("TurnInStation") as TurnInStation
	tray = room.get_station("GrowPlot1") as GrowPlot
	if not check(hud != null and board != null and bob != null and shop != null and well != null and chute != null and tray != null,
			"HUD, the alley board, Bob and the stations exist"):
		_cleanup(); finish(); return
	_test_hud_node()

	await _test_replay_off()
	await _test_record_off()
	await _test_walk(b)
	await _test_start_over()
	_cleanup()
	finish()


# --- the copy, the gate ---------------------------------------------------------------------------------------------

func _test_copy() -> void:
	step("the copy")
	var texts := PackedStringArray([Guide.ALLEY_LINE])
	for s: StringName in Guide.LINES:
		texts.append(String(Guide.LINES[s]))
	for k: StringName in Guide.HINTS:
		texts.append(String(Guide.HINTS[k]) % "E" if String(Guide.HINTS[k]).contains("%s") else String(Guide.HINTS[k]))
	var flat := true
	for t in texts:
		var low := t.to_lower()
		if t == "" or t.contains("!") or t.length() > 72 or low.contains("great") or low.contains("awesome") or low.contains("good job") \
				or low.contains("welcome") or low.contains("please") or low.contains(":)"):
			flat = false
			print("      not flat: '%s'" % t)
	check(flat, "every line and hint is flat and short (%d texts)" % texts.size())
	check(Guide.STEPS == [&"buy", &"plant", &"water", &"wait", &"harvest", &"deposit"] and Guide.LINES.has(Guide.STEP_PAYMENT),
			"six steps in order, then the payment line")
	check(Guide.get_line(Guide.STEP_BUY) == "Window's there. Seeds cost money.", "the first line: '%s'" % Guide.get_line(Guide.STEP_BUY))
	check(Guide.ALLEY_LINE == "Get in the back. The shift starts when everyone is in.", "the alley line: '%s'" % Guide.ALLEY_LINE)


func _test_gate() -> void:
	step("the gate")
	check(guide.is_enabled(), "--guide: on (replay off)")
	Config.user_args.erase("guide")
	check(not guide.is_enabled() and not guide.is_wanted(), "replay off without --guide: off, nobody gets it")
	Config.replay_enabled = true
	check(not Guide.is_real_game() and not guide.is_enabled(), "--replay in a headless or `-s` run without --guide: off (the replay suites, the capture tools)")
	Config.user_args["guide"] = true
	Config.user_args["no-guide"] = true
	check(not guide.is_enabled(), "--no-guide wins over --guide")
	Config.user_args.erase("no-guide")
	Config.user_args.erase("guide")
	Config.replay_enabled = false
	Config.user_args["guide"] = true
	check(guide.is_enabled() and guide.is_wanted() and Career.get_record("shifts") == 0, "back on: an empty record wants it")


# --- the HUD node ---------------------------------------------------------------------------------------------------

func _test_hud_node() -> void:
	step("the HUD's hint line")
	var panel := world.get_node_or_null(^"HUD/Root/GuideHint") as PanelContainer
	var label := world.get_node_or_null(^"HUD/Root/GuideHint/Label") as Label
	check(panel != null and label != null and hud.get_guide_hint() == panel, "World/HUD/Root/GuideHint holds a Label")
	if panel == null:
		return
	var root := panel.get_parent()
	check(panel.get_index() == hud.prompt_panel.get_index() + 1 and panel.get_index() < hud.round_end.get_index()
			and panel.get_index() < hud.pause_menu.get_index(), "drawn right after the prompt, under the overlays (index %d)" % panel.get_index())
	check(panel.mouse_filter == Control.MOUSE_FILTER_IGNORE and label.mouse_filter == Control.MOUSE_FILTER_IGNORE, "it never takes the mouse")
	check(not panel.visible and hud.get_guide_hint_text() == "", "hidden with nothing to say")
	check(root == hud.root_control, "a child of the HUD's Root")


## The hint's rect at 1280 x 720 against everything it must never cover.
func _check_hint_rect(tag: String) -> void:
	var panel := hud.get_guide_hint()
	var r := panel.get_global_rect()
	print("      [%s] GuideHint rect %s (text '%s')" % [tag, r, hud.get_guide_hint_text()])
	check(get_viewport().get_visible_rect().size == Vector2(1280, 720), "[%s] the frame is 1280 x 720" % tag)
	check(is_equal_approx(r.position.x, 430.0) and is_equal_approx(r.end.x, 850.0) and is_equal_approx(r.position.y, 620.0) and r.end.y <= 700.0,
			"[%s] x 430..850, from y 620 down (%s)" % [tag, r])
	var prompt_bottom := 720.0 - 110.0
	check(r.position.y > prompt_bottom, "[%s] below the prompt panel's bottom edge (%.0f)" % [tag, prompt_bottom])
	var others := {
		"the centre banner": hud.banner, "the event banner": hud.event_panel, "the payment column": hud.quota_panel,
		"the chips": hud.get_condition_chips(), "the job line": hud.get(&"_career_job_label"), "the toasts": hud.toasts,
		"the chat": hud.chat, "the go banner": hud.go_banner, "the workers": hud.players_panel,
	}
	for what: String in others:
		var c := others[what] as Control
		if c == null:
			continue
		var cr := c.get_global_rect()
		if what == "the toasts" or what == "the chat":
			cr = Rect2(Vector2(cr.position.x, 0.0), Vector2(cr.size.x, 720.0)) # both grow upwards from the bottom
		check(not r.intersects(cr), "[%s] clear of %s (%s)" % [tag, what, cr])


# --- replay off, no --guide -----------------------------------------------------------------------------------------

func _test_replay_off() -> void:
	step("replay off without --guide: a whole first shift with nothing")
	Config.user_args.erase("guide")
	check(guide.get_alley_line() == "" and not board.get_next_lines().has(Guide.ALLEY_LINE), "the board: no alley line")
	GameState.request_start_round()
	await wait_until(func() -> bool: return GameState.is_playing() and GameState.round_number == 1, 3.0, "shift 1 runs")
	await _skip(2)
	_buy(bob)
	await _skip(2)
	check(not guide.is_active() and guide.get_step() == &"" and guide.said_log.is_empty(), "no guide, no line")
	check(hud.get_guide_hint_text() == "" and not hud.get_guide_hint().visible, "no hint")
	check(not _guide_lines_in(Story.bark_log), "nothing of the guide in Story's log")
	await _new_run()
	Config.user_args["guide"] = true


# --- a record, guidance off; then on mid-shift ----------------------------------------------------------------------

func _test_record_off() -> void:
	step("a player with a record and guidance off")
	_write_record(3)
	fake.set_value(&"guidance", false)
	check(Career.get_record("shifts") == 3 and not guide.is_wanted(), "shifts 3, guidance off: not wanted")
	check(guide.get_alley_line() == "" and not board.get_next_lines().has(Guide.ALLEY_LINE), "nothing on the board")
	GameState.request_start_round()
	await wait_until(func() -> bool: return GameState.is_playing(), 3.0, "shift 1 runs")
	await _skip(2)
	_buy(bob)
	await _skip(1)
	_plant(bob)
	await _skip(1)
	_water(bob)
	await _skip(2)
	check(not guide.is_active() and guide.said_log.is_empty() and hud.get_guide_hint_text() == "", "the crew works: nothing for this player")
	check(GameState.get_stat(BOB, Const.STAT_WATERED) == 1 and tray.stage == GrowPlot.Stage.SEEDLING, "Bob bought, planted and watered")

	step("guidance turned on mid-shift (Settings.changed): the steps the crew did are skipped")
	_steps.clear()
	fake.set_value(&"guidance", true)
	check(guide.is_wanted() and guide.is_active() and guide.get_step() == &"", "wanted at once; the guide reads the floor first")
	await _settle()
	check(guide.get_step() == Guide.STEP_WAIT and _steps == [Guide.STEP_WAIT], "the current step is 'wait' (%s)" % [_steps])
	await _expect_line(Guide.STEP_WAIT)
	check(guide.said_log == PackedStringArray([Guide.get_line(Guide.STEP_WAIT)]), "the first thing said is the wait line %s" % [guide.said_log])
	check(hud.get_guide_hint_text() == "Wait. E · water it when it dries" and hud.get_guide_hint().visible, "the hint: '%s'" % hud.get_guide_hint_text())

	step("guidance turned off again: it stops at once")
	fake.set_value(&"guidance", false)
	await wait_frames(2)
	check(not guide.is_active() and guide.get_step() == &"" and hud.get_guide_hint_text() == "" and not hud.get_guide_hint().visible, "no step, no hint")
	var said := guide.said_log.size()
	await _skip(40)
	check(guide.said_log.size() == said, "nothing more is said")
	await _new_run()


# --- the walk: a fresh record ---------------------------------------------------------------------------------------

func _test_walk(b: BalanceConfig) -> void:
	step("a fresh record: the alley")
	Career.clear_record()
	_remove(_path)
	fake.set_value(&"guidance", true)
	fake.writes.clear()
	guide.said_log = PackedStringArray()
	_seen = 0
	check(guide.is_wanted() and GameState.phase == GameState.Phase.WAITING and GameState.round_number == 1, "wanted, waiting for shift 1")
	board.refresh()
	var next := board.get_next_lines()
	check(next.size() > 2 and next[0] == Guide.ALLEY_LINE and board.get_column_text(1).begins_with(Guide.ALLEY_LINE), "the board's NEXT column starts with the alley line %s" % [next])
	var van: Van = world.lobby.get_van() if world.lobby != null else null
	check(van != null and guide.is_van_said() == false, "the van, not said yet")
	var floor_spot := me.global_position
	_put_me(van.get_entry_point() + Vector3(0.0, 0.0, 2.0))
	guide.refresh()
	check(guide.is_van_said() and hud.get_guide_hint_text() == Guide.ALLEY_LINE, "near its doors: the van's line on the hint ('%s')" % hud.get_guide_hint_text())
	await wait_frames(2)
	check(hud.get_guide_hint().visible and (hud.get_guide_hint().get_node(^"Label") as Label).text == Guide.ALLEY_LINE, "shown on the HUD")
	_check_hint_rect("the van's line, waiting")
	guide.tick(Guide.VAN_HINT_SEC + 0.1)
	check(hud.get_guide_hint_text() == "", "gone after %.0f s" % Guide.VAN_HINT_SEC)
	_put_me(floor_spot)
	guide.refresh()
	_put_me(van.get_entry_point())
	guide.refresh()
	check(hud.get_guide_hint_text() == "", "said once: back at the doors, nothing")
	_put_me(floor_spot)
	await wait_frames(2)

	step("shift 1: buy")
	_steps.clear()
	GameState.request_start_round()
	await wait_until(func() -> bool: return GameState.is_playing(), 3.0, "shift 1 runs")
	check(guide.get_alley_line() == "" and not board.get_next_lines().has(Guide.ALLEY_LINE), "the board's line is gone once the shift runs")
	check(guide.is_active() and hud.get_guide_hint_text() == "", "the guide runs; nothing shown while it reads the floor")
	await _settle()
	check(guide.get_step() == Guide.STEP_BUY, "step 'buy'")
	check(hud.get_guide_hint_text() == "E · buy seeds at the window", "the hint: '%s'" % hud.get_guide_hint_text())
	await _expect_line(Guide.STEP_BUY)
	var buy_line := Guide.get_line(Guide.STEP_BUY)
	check(guide.said_log == PackedStringArray([buy_line]) and Story.last_bark == buy_line and Story.bark_log.has(buy_line), "the Boss says '%s'" % buy_line)
	var boss := Story.find_boss()
	check(boss is ShopkeeperNPC and (boss as ShopkeeperNPC).get_current_bark() == buy_line, "at his window (his bark label)")
	check(Story.bark_log.has(Story.line("shift_start")), "his own shift line still came first")
	await wait_frames(2)
	check(hud.get_guide_hint().visible and not Game.is_ui_locked() and not get_tree().paused, "the hint shows; no UI lock, no pause")
	_check_hint_rect("buy, playing")
	Game.set_ui_lock(&"onboarding_test", true)
	await wait_frames(1)
	check(not hud.get_guide_hint().visible, "a UI lock hides it")
	Game.set_ui_lock(&"onboarding_test", false)
	await wait_frames(1)
	check(hud.get_guide_hint().visible, "back when the lock goes")

	step("buy: said once more after the timeout, never a third time")
	var t := b.guide_step_timeout_sec
	guide.tick(t - 2.0)
	Story.tick(Story.ONBOARDING_GAP_SEC + 0.1)
	guide.tick(0.2)
	check(guide.get_said_count() == 1, "not before %.0f s" % t)
	guide.tick(2.5)
	await _expect_line(Guide.STEP_BUY)
	check(guide.get_said_count() == 2 and guide.said_log == PackedStringArray([buy_line, buy_line]), "said once more after %.0f s" % t)
	for i in 3:
		guide.tick(t + 1.0)
		Story.tick(Story.ONBOARDING_GAP_SEC + 0.1)
		guide.tick(0.2)
	check(guide.said_log.size() == 2 and guide.get_step() == Guide.STEP_BUY and hud.get_guide_hint_text() == "E · buy seeds at the window", "then never again; the hint stays")

	step("Bob buys -> plant")
	check(_buy(bob), "Bob bought seeds at the window")
	await wait_frames(1)
	check(guide.get_step() == Guide.STEP_PLANT, "step 'plant' at once")
	check(hud.get_guide_hint_text() == "E · plant them in an empty tray", "the hint: '%s'" % hud.get_guide_hint_text())
	await _expect_line(Guide.STEP_PLANT)
	check(guide.said_log[-1] == Guide.get_line(Guide.STEP_PLANT), "the plant line")

	step("the host plants -> water")
	var packet := items.get_held_by(BOB)
	items.server_drop_item(packet, me.global_position)
	check(items.server_give_item(packet, 1), "the packet goes to the host")
	tray._server_interact(me)
	await wait_frames(1)
	check(tray.stage == GrowPlot.Stage.SEEDLING and GameState.get_stat(1, Const.STAT_PLANTED) == 1, "the host planted GrowPlot1")
	guide.tick(0.2)
	check(guide.get_step() == Guide.STEP_WATER and hud.get_guide_hint_text() == "E · pick up a can, fill it at the tank", "step 'water'; empty hands: '%s'" % hud.get_guide_hint_text())
	await _expect_line(Guide.STEP_WATER)
	check(guide.said_log[-1] == Guide.get_line(Guide.STEP_WATER), "the water line")
	var cans := items.get_items_of_type(Const.ITEM_WATERING_CAN)
	check(cans.size() >= 2, "two cans on the floor")
	var my_can := cans[0]
	my_can.set(&"charges", 0)
	items.server_give_item(my_can, 1)
	guide.tick(0.2)
	check(hud.get_guide_hint_text() == "E · fill the can at the tank", "an empty can in hand: '%s'" % hud.get_guide_hint_text())
	well._server_interact(me)
	guide.tick(0.2)
	check(GrowPlot.get_can_charges(my_can) > 0 and hud.get_guide_hint_text() == "E · pour it on the tray", "filled: '%s'" % hud.get_guide_hint_text())

	step("Bob fills a can and pours -> wait")
	var bob_can := cans[1]
	bob_can.set(&"charges", 0)
	items.server_give_item(bob_can, BOB)
	well._server_interact(bob)
	tray._server_interact(bob)
	await wait_frames(1)
	check(GameState.get_stat(BOB, Const.STAT_WATERED) == 1 and tray.water > 0.5, "Bob watered GrowPlot1")
	guide.tick(0.2)
	check(guide.get_step() == Guide.STEP_WAIT and hud.get_guide_hint_text() == "Wait. E · water it when it dries", "step 'wait': '%s'" % hud.get_guide_hint_text())
	await _expect_line(Guide.STEP_WAIT)
	check(guide.said_log[-1] == Guide.get_line(Guide.STEP_WAIT), "the wait line (the stages and the water)")

	step("the tray ripens -> harvest")
	tray.stage = GrowPlot.Stage.READY
	guide.tick(0.2)
	check(guide.get_step() == Guide.STEP_HARVEST and hud.get_guide_hint_text() == "E · harvest it with empty hands", "step 'harvest': '%s'" % hud.get_guide_hint_text())
	await _expect_line(Guide.STEP_HARVEST)
	check(guide.said_log[-1] == Guide.get_line(Guide.STEP_HARVEST), "the harvest line")

	step("the host harvests -> deposit")
	items.server_despawn_item(my_can)
	items.server_despawn_item(bob_can)
	await wait_frames(1)
	tray._server_interact(me)
	await wait_frames(1)
	var product := items.get_held_by(1)
	check(product != null and product.item_type == Const.ITEM_PRODUCT and GameState.get_stat(1, Const.STAT_HARVESTED) == 1, "the host holds the bundle")
	guide.tick(0.2)
	check(guide.get_step() == Guide.STEP_DEPOSIT and hud.get_guide_hint_text() == "E · deposit it at the chute", "step 'deposit': '%s'" % hud.get_guide_hint_text())
	await _expect_line(Guide.STEP_DEPOSIT)
	check(guide.said_log[-1] == Guide.get_line(Guide.STEP_DEPOSIT), "the deposit line")

	step("Bob deposits -> the payment line, the end of the guide")
	items.server_drop_item(product, me.global_position)
	items.server_give_item(product, BOB)
	_put(bob, room.get_station_access_point("TurnInStation"))
	chute._server_interact(bob)
	await wait_frames(1)
	check(GameState.round_sales > 0 and GameState.get_stat(BOB, Const.STAT_DEPOSITED) > 0, "Bob deposited ($%d)" % GameState.round_sales)
	check(guide.get_step() == Guide.STEP_PAYMENT and hud.get_guide_hint_text() == Guide.HINTS[Guide.STEP_PAYMENT], "the payment hint: '%s'" % hud.get_guide_hint_text())
	await _expect_line(Guide.STEP_PAYMENT)
	var pay_line := Guide.get_line(Guide.STEP_PAYMENT)
	check(guide.said_log[-1] == pay_line and Story.bark_log.has(pay_line), "the last line: '%s'" % pay_line)
	check(guide.is_finished() and not guide.is_active() and guide.get_step() == &"", "the guide is over")
	check(hud.get_guide_hint_text() == Guide.HINTS[Guide.STEP_PAYMENT], "its hint stays a while")
	guide.tick(Guide.PAYMENT_HINT_SEC + 0.1)
	await wait_frames(1)
	check(hud.get_guide_hint_text() == "" and not hud.get_guide_hint().visible, "then the hint is gone")
	for i in 3:
		guide.tick(30.0)
		Story.tick(10.0)
	var lines := guide.said_log
	var expect := PackedStringArray([buy_line, buy_line, Guide.get_line(Guide.STEP_PLANT), Guide.get_line(Guide.STEP_WATER),
			Guide.get_line(Guide.STEP_WAIT), Guide.get_line(Guide.STEP_HARVEST), Guide.get_line(Guide.STEP_DEPOSIT), pay_line])
	check(lines == expect, "everything said, in order, once each (buy twice) %s" % [lines])
	check(_steps == [Guide.STEP_BUY, Guide.STEP_PLANT, Guide.STEP_WATER, Guide.STEP_WAIT, Guide.STEP_HARVEST, Guide.STEP_DEPOSIT, Guide.STEP_PAYMENT, &""],
			"the steps in order %s" % [_steps])

	step("the end of the shift: guidance off, the shift on file")
	check(fake.writes.is_empty(), "nothing written to the settings yet")
	GameState.time_left = 0.05
	await wait_until(func() -> bool: return GameState.is_round_over(), 3.0, "the shift ends")
	await wait_frames(2)
	check(fake.writes == [[&"guidance", false]] and not bool(fake.get_value(&"guidance")), "Settings.set_value(&\"guidance\", false), once")
	check(Career.get_record("shifts") == 1 and not guide.is_wanted(), "one shift on file; not wanted any more")

	step("START OVER: nothing for this player")
	await _new_run()
	check(guide.get_alley_line() == "" and not board.get_next_lines().has(Guide.ALLEY_LINE), "no alley line")
	var said := guide.said_log.size()
	GameState.request_start_round()
	await wait_until(func() -> bool: return GameState.is_playing(), 3.0, "shift 1 again")
	await _skip(3)
	check(not guide.is_active() and guide.said_log.size() == said and hud.get_guide_hint_text() == "", "no guide, no line, no hint")
	await _new_run()


# --- START OVER mid-shift, the shift ending mid-guide ---------------------------------------------------------------

func _test_start_over() -> void:
	step("START OVER mid-shift for a player with no shift on file")
	Career.clear_record()
	_remove(_path)
	fake.set_value(&"guidance", true)
	fake.writes.clear()
	guide.said_log = PackedStringArray()
	_seen = 0
	GameState.request_start_round()
	await wait_until(func() -> bool: return GameState.is_playing(), 3.0, "shift 1 runs")
	await _settle()
	await _expect_line(Guide.STEP_BUY)
	_buy(bob)
	await wait_frames(1)
	await _expect_line(Guide.STEP_PLANT)
	check(guide.said_log == PackedStringArray([Guide.get_line(Guide.STEP_BUY), Guide.get_line(Guide.STEP_PLANT)]) and guide.get_step() == Guide.STEP_PLANT,
			"buy, Bob buys, plant %s" % [guide.said_log])
	await _new_run()
	check(not guide.is_active() and not guide.is_finished() and guide.get_done_count() == 0 and guide.get_step() == &"", "the reset clears the guide")
	check(Career.get_record("shifts") == 0 and fake.writes.is_empty(), "no shift worked, guidance untouched")
	check(guide.get_alley_line() == Guide.ALLEY_LINE, "the alley line is back")
	GameState.request_start_round()
	await wait_until(func() -> bool: return GameState.is_playing(), 3.0, "shift 1 again")
	await _settle()
	await _expect_line(Guide.STEP_BUY)
	check(guide.get_step() == Guide.STEP_BUY and guide.said_log[-1] == Guide.get_line(Guide.STEP_BUY), "from the top: buy")

	step("the shift ends mid-guide: no last line")
	var said := guide.said_log.size()
	GameState.time_left = 0.05
	await wait_until(func() -> bool: return GameState.is_round_over(), 3.0, "the shift ends")
	await _skip(3)
	check(guide.is_finished() and not guide.is_active() and guide.said_log.size() == said and not guide.said_log.has(Guide.get_line(Guide.STEP_PAYMENT)),
			"over, nothing more said")
	check(hud.get_guide_hint_text() == "", "no hint on the end screen")
	check(fake.writes == [[&"guidance", false]] and Career.get_record("shifts") == 1, "guidance off, the shift on file")
	await _new_run()

	step("a suite never writes the real Settings autoload")
	guide.settings_override = null
	Career.clear_record()
	_remove(_path)
	guide.set(&"_session_off", false) # what a fresh session would have
	var emitted := [0]
	var count := func(_key: StringName) -> void: emitted[0] += 1
	Settings.changed.connect(count)
	GameState.request_start_round()
	await wait_until(func() -> bool: return GameState.is_playing(), 3.0, "shift 1 runs")
	await _settle()
	check(guide.is_active() and guide.get_step() == Guide.STEP_BUY, "the stub's default (guidance on) and an empty record: the guide runs")
	GameState.time_left = 0.05
	await wait_until(func() -> bool: return GameState.is_round_over(), 3.0, "the shift ends")
	await wait_frames(2)
	check(emitted[0] == 0 and not guide.is_wanted(), "the shift ends: nothing written to Settings (a `-s` run), guidance off for the session")
	Settings.changed.disconnect(count)
	guide.settings_override = fake
	await _new_run()


# --- helpers --------------------------------------------------------------------------------------------------------

## START OVER (the host's RETRY with the lobby off), empty hands first.
func _new_run() -> void:
	for id in [1, BOB]:
		var held := items.get_held_by(id)
		if held != null:
			items.server_despawn_item(held)
	await wait_frames(1)
	GameState.server_reset_game()
	await wait_until(func() -> bool: return GameState.phase == GameState.Phase.WAITING and GameState.round_number == 1, 3.0, "START OVER: waiting for shift 1")
	await wait_frames(3)
	_put(bob, Vector3(2.0, 0.0, 2.0))


## Lets real frames and the guide's and the Boss's clocks run `sec` seconds.
func _skip(sec: float) -> void:
	guide.tick(sec)
	Story.tick(sec)
	guide.tick(0.2)
	await wait_frames(2)


## The guide reads the floor for SETTLE_SEC.
func _settle() -> void:
	guide.tick(Guide.SETTLE_SEC + 0.05)
	guide.tick(0.15)
	await wait_frames(1)


## Exactly one new guide line since the last call, and it is `step`'s: the Boss goes quiet long enough for it if it
## has not come yet (a queued normal line may come first).
func _expect_line(step: StringName) -> void:
	var text := Guide.get_line(step)
	for i in 6:
		if guide.said_log.size() > _seen:
			break
		Story.tick(Story.ONBOARDING_GAP_SEC + 0.1)
		guide.tick(0.15)
	await wait_frames(1)
	var fresh := guide.said_log.slice(_seen)
	_seen = guide.said_log.size()
	check(fresh == PackedStringArray([text]), "the Boss says the %s line once: '%s' (%s)" % [step, text, fresh])


func _guide_lines_in(log: PackedStringArray) -> bool:
	for s: StringName in Guide.LINES:
		if log.has(String(Guide.LINES[s])):
			return true
	return false


func _buy(who: Player) -> bool:
	_put(who, room.get_station_access_point("ShopCounter"))
	var r := shop.server_buy_seed(who.peer_id, &"budget")
	return bool(r.get("ok", false))


func _plant(who: Player) -> void:
	tray._server_interact(who)


func _water(who: Player) -> void:
	var held := items.get_held_by(who.peer_id)
	if held != null:
		items.server_despawn_item(held)
	var can: Item = null
	for c in items.get_items_of_type(Const.ITEM_WATERING_CAN):
		if not c.is_held():
			can = c
			break
	if can == null:
		return
	items.server_give_item(can, who.peer_id)
	well.server_fill_can(can)
	tray._server_interact(who)
	items.server_drop_item(can, Vector3(1.0, 0.0, 1.0))


func _write_record(shifts: int) -> void:
	var f := FileAccess.open(_path, FileAccess.WRITE)
	f.store_string("[career]\nshifts=%d\nbest_round=1\n" % shifts)
	f.close()
	Career.load_file(_path)


## Places a fake (unowned) worker: place_at writes the synced net_position too.
func _put(p: Player, pos: Vector3) -> void:
	p.place_at(Transform3D(Basis.IDENTITY, Vector3(pos.x, 0.05, pos.z)))


func _put_me(pos: Vector3) -> void:
	me.velocity = Vector3.ZERO
	me.global_position = Vector3(pos.x, pos.y + 0.05, pos.z)


func _remove(p: String) -> void:
	if FileAccess.file_exists(p):
		DirAccess.remove_absolute(p)


func _cleanup() -> void:
	_remove(_path)
	_remove(_path + ".tmp")
