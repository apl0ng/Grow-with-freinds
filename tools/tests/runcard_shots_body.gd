extends "res://tools/tests/smoke_base.gd"
## M25 runcard in-game screenshots on the REAL renderer (a capture tool for the lead, not a suite): the round-end card
## with THE RUN block and four workers, at PAID IN FULL and at a missed payment (the START OVER card).
##   godot --rendering-method forward_plus --resolution 1280x720 --position 1400,800 --path . \
##       -s res://tools/tests/run_test.gd -- --body=res://tools/tests/runcard_shots_body.gd --out=<abs dir> \
##       --replay --run=B5VP --career-file=user://runcard_shots.cfg --port=7977 --mute --no-mic --event-delay=900
## --career-file is required (PAID IN FULL counts a cleared debt: a real record is never touched); the file is removed at
## the end. Under --headless it stages everything the same way and saves nothing (a dry run: the staging is checked and
## the block texts are printed; the shots are skipped). The lobby is switched off (the floor is staged directly); the
## final notice is moved to shift 2; three fake workers (Dale, Wren Abernathy, Bartholomew Jone) join the host; the
## mouse is never captured; a watchdog ends the run after 90 s.
## Shots: 1_paid_in_full.png, 2_missed.png (each also prints the fit scale of the card).

const WORKERS := {2: "Dale", 3: "Wren Abernathy", 4: "Bartholomew Jone"}

var _out := "user://runcard_shots"
var _path := ""
var _dry := false
var _re: RoundEndOverlay


func _process(_delta: float) -> void:
	if Input.mouse_mode != Input.MOUSE_MODE_VISIBLE:
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE


func _run() -> void:
	_label = "runcard_shots"
	get_tree().create_timer(90.0).timeout.connect(func() -> void:
		print("runcard_shots: watchdog, quitting")
		_cleanup()
		get_tree().quit(2))
	_dry = DisplayServer.get_name() == "headless"
	if _dry:
		print("runcard_shots: headless, a dry run (staging only, no images); run it without --headless for the shots")
		get_tree().root.size = Vector2i(1280, 720)   # headless windows report 1280x1280: measure the fit at the real size
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--out="):
			_out = a.trim_prefix("--out=")
	_path = str(Config.get_arg("career-file", ""))
	if not check(_path != "" and _path != Career.DEFAULT_PATH and Career.path == _path and Config.replay_enabled,
			"its own --career-file (%s) and --replay" % _path):
		finish()
		return
	if not _dry:
		DirAccess.make_dir_recursive_absolute(_out)
	Config.lobby_enabled = false
	var b: BalanceConfig = Config.balance
	b.end_round_on_quota_met = true
	b.final_shift_by_team = [2, 2, 2, 2]
	await get_tree().process_frame
	Game.start_host("Zay", port_arg(7977))
	await wait_until(func() -> bool: return Game.world != null and Game.local_player != null, 8.0, "world + local player")
	if Game.world == null:
		_cleanup()
		finish()
		return
	_re = (Game.world.get_node(^"HUD") as HUD).round_end
	for id: int in WORKERS:
		Net.players[id] = {"name": WORKERS[id], "color": Net.PALETTE[(id - 1) % Net.PALETTE.size()]}
		Game.world.server_spawn_player(id)
	Net.players_changed.emit()
	await wait_frames(3)

	step("run 1: two shifts, the final notice paid")
	GameState.request_start_round()
	await wait_until(func() -> bool: return GameState.is_playing(), 5.0, "shift 1 runs")
	_book([[2, Const.STAT_HELPED, 1], [3, Const.STAT_BRUISED, 2], [4, Const.STAT_BITTEN, 1], [1, Const.STAT_PLANTED, 4],
			[2, Const.STAT_WATERED, 3], [3, Const.STAT_HARVESTED, 2], [4, Const.STAT_THROWS, 2]])
	await _pay([[2, 0.5], [3, 0.2]])
	GameState.request_next_round()
	await wait_until(func() -> bool: return GameState.is_playing() and GameState.is_final_shift(), 5.0, "shift 2, the final notice")
	_book([[2, Const.STAT_HELPED, 1], [3, Const.STAT_BRUISED, 1], [1, Const.STAT_PLANTED, 2], [4, Const.STAT_WATERED, 5]])
	await _pay([[2, 0.6], [4, 0.1]])
	check(_re.is_showing_cleared() and _re.is_showing_run(), "PAID IN FULL with THE RUN")
	await _shot("1_paid_in_full")

	step("run 2: shift 1 paid, shift 2 missed")
	_re.primary_button.pressed.emit()   # NEW RUN
	await wait_until(func() -> bool: return GameState.phase == GameState.Phase.WAITING and GameState.run_shifts == 0, 5.0, "a new run")
	GameState.request_start_round()
	await wait_until(func() -> bool: return GameState.is_playing(), 5.0, "shift 1 runs")
	_book([[4, Const.STAT_BITTEN, 2], [1, Const.STAT_PLANTED, 3], [3, Const.STAT_WATERED, 2]])
	await _pay([[3, 0.6]])
	GameState.request_next_round()
	await wait_until(func() -> bool: return GameState.is_playing(), 5.0, "shift 2 runs")
	GameState.server_write_up(1, Const.WRITE_UP_LOITERING)
	GameState.server_write_up(1, Const.WRITE_UP_SKIMMING)
	GameState.server_add_sale(int(GameState.quota * 0.3), 3)
	_book([[2, Const.STAT_PLANTED, 2], [4, Const.STAT_HARVESTED, 1]])
	GameState.time_left = 0.05
	await wait_until(func() -> bool: return GameState.phase == GameState.Phase.ROUND_FAILED, 5.0, "shift 2 missed")
	check(_re.is_showing_run() and _re.primary_button.text == RoundEndOverlay.TEXT_START_OVER, "the START OVER card with THE RUN")
	await _shot("2_missed")
	_cleanup()
	finish()


func _book(entries: Array) -> void:
	for e: Array in entries:
		GameState.server_add_stat(int(e[0]), e[1], int(e[2]))


## Shares of the payment for the workers ([peer, share]); the host pays the rest (a covered payment ends the shift).
func _pay(shares: Array) -> void:
	var q := GameState.quota
	for e: Array in shares:
		GameState.server_add_sale(mini(int(q * float(e[1])), maxi(GameState.quota - GameState.round_sales, 0)), int(e[0]))
	if GameState.is_playing():
		GameState.server_add_sale(maxi(GameState.quota - GameState.round_sales, 1), 1)
	await wait_frames(2)


func _shot(shot: String) -> void:
	await wait_sec(0.8)   # the pop-in is over and the fit has settled
	print("runcard_shots: %s, the card's fit scale %.3f, THE RUN:\n    %s" % [shot, _re.get_fit_scale(), _re.run_card.get_block_text().replace("\n", "\n    ")])
	if _dry:
		print("runcard_shots: (dry run) %s" % shot)
		return
	await RenderingServer.frame_post_draw
	var path := _out.path_join(shot + ".png")
	get_viewport().get_texture().get_image().save_png(path)
	print("runcard_shots: ", ProjectSettings.globalize_path(path))


func _cleanup() -> void:
	for p: String in [_path, _path + ".tmp"]:
		if p != "" and p != Career.DEFAULT_PATH and FileAccess.file_exists(p):
			DirAccess.remove_absolute(p)
