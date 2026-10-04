extends "res://tools/tests/smoke_base.gd"
## M17 lead: the game's own quit path (Game.quit_gracefully, used by the window close and the menu's quit button).
## A hosted session with a fake worker, a live voice emitter, one-shot sounds and a running loop, then the quit: it
## leaves the session, stops every voice and sound and exits 0 after the audio thread has let go (the exit used to
## crash now and then with audio still referenced). The exit code is the test: test_all fails a non-zero one.

const FAKE_PEER := 2


func _run() -> void:
	_label = "quit"
	await get_tree().process_frame
	check(not get_tree().is_auto_accept_quit(), "closing the window does not quit at once (Game takes the close request)")
	check(not Game.is_quitting(), "not quitting yet")
	Game.start_host("Tester", port_arg(7992))
	await wait_until(func() -> bool: return Game.world != null and Game.local_player != null, 5.0, "world + local player")
	if Game.world == null:
		finish()
		return
	Net.players[FAKE_PEER] = {"name": "Dale", "color": Net.PALETTE[1]}
	Game.world.server_spawn_player(FAKE_PEER)
	await wait_frames(3)
	var frame := PackedByteArray()
	frame.resize(Voice.FRAME_SAMPLES)
	for i in 4:
		Voice.debug_inject_frame(FAKE_PEER, frame)
	await wait_frames(2)
	check(Voice.get_output_node(FAKE_PEER) != null, "a voice emitter plays for the fake worker")
	Sfx.play(&"ui_click")
	Sfx.play(&"harvest", Vector3(1.0, 1.0, 1.0))
	var loop := Sfx.play_loop(&"siren", Vector3(0.0, 1.5, 0.0))
	check(loop > 0 and Sfx.is_loop_playing(loop), "a loop runs")
	await wait_frames(2)

	step("quit")
	var t0 := Time.get_ticks_msec()
	Game.quit_gracefully(0)
	check(Game.is_quitting(), "quitting")
	Game.quit_gracefully(0)  # a second request (the close button pressed twice) changes nothing
	await wait_frames(1)
	check(not Net.is_online() and Net.players.is_empty(), "the session is left at once")
	check(Voice.get_output_node(FAKE_PEER) == null and not Sfx.is_loop_playing(loop), "every voice and loop is stopped")
	# The result line goes out now: the process ends from Game.quit_gracefully, not from finish().
	_finished = true
	print("[%s] %d passed, %d failed -> %s" % [_label, _passes, _fails, "PASS" if _fails == 0 else "FAIL"])
	print("RESULT: %s [%s] %d passed, %d failed (the quit settles for %.1f s, started %d ms ago)" % [
			"PASS" if _fails == 0 else "FAIL", _label, _passes, _fails, Game.QUIT_SETTLE_SEC, Time.get_ticks_msec() - t0])
	if _fails > 0:
		get_tree().quit(1)
