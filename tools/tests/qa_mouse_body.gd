extends "res://tools/tests/qa_base.gd"
## Real mouse-mode check (QA milestone 7). Headless has no mouse (Input.mouse_mode always reads VISIBLE), so this
## body needs a real display server; tools/test_all.sh runs it under xvfb when xvfb-run exists:
##   xvfb-run -a -s "-screen 0 1280x720x24" godot --path . --rendering-driver opengl3 --rendering-method gl_compatibility \
##       --audio-driver Dummy -s res://tools/tests/run_test.gd -- --body=res://tools/tests/qa_mouse_body.gd --port=7973
## Game owns the mouse: captured only in the world with no UI lock. Checked around the shop, the pause menu, the
## round-end overlay and return_to_menu from each of them.

func _run() -> void:
	_label = "mouse_x11"
	await get_tree().process_frame
	if DisplayServer.get_name() == "headless":
		print("  (headless display server: nothing to check, run this under xvfb-run)")
		check(true, "skipped under --headless")
		finish(); return
	var port := port_arg(7973)
	get_tree().root.add_child((load(Game.MENU_SCENE_PATH) as PackedScene).instantiate())
	await wait_frames(3)
	check(Input.mouse_mode == Input.MOUSE_MODE_VISIBLE, "menu: mouse visible (%d)" % Input.mouse_mode)
	Game.start_host("Mouse", port)
	await wait_until(func(): return Game.local_player != null, 5.0, "hosted")
	await wait_frames(5)
	check(Input.mouse_mode == Input.MOUSE_MODE_CAPTURED, "in the world: captured (%d)" % Input.mouse_mode)
	var shop: ShopCounter = station("ShopCounter")
	stand_near(shop, 1.2)
	await wait_frames(2)
	shop.open_shop_for(Game.local_player)
	await wait_frames(2)
	check(Input.mouse_mode == Input.MOUSE_MODE_VISIBLE, "shop open: visible (%d)" % Input.mouse_mode)
	shop.close_shop()
	await wait_frames(2)
	check(Input.mouse_mode == Input.MOUSE_MODE_CAPTURED, "shop closed: captured again (%d)" % Input.mouse_mode)
	shop.open_shop_for(Game.local_player)
	await wait_frames(2)
	Game.return_to_menu()
	await wait_frames(3)
	check(Input.mouse_mode == Input.MOUSE_MODE_VISIBLE, "menu after leaving with the shop open: visible (%d)" % Input.mouse_mode)
	Game.start_host("Mouse", port)
	await wait_until(func(): return Game.local_player != null, 5.0, "hosted again")
	await wait_frames(5)
	check(Input.mouse_mode == Input.MOUSE_MODE_CAPTURED, "in the world again: captured (%d)" % Input.mouse_mode)
	var hud := Game.world.get_node("HUD") as HUD
	hud.pause_menu.open()
	await wait_frames(2)
	check(Input.mouse_mode == Input.MOUSE_MODE_VISIBLE, "pause menu: visible (%d)" % Input.mouse_mode)
	hud.pause_menu.close()
	await wait_frames(2)
	check(Input.mouse_mode == Input.MOUSE_MODE_CAPTURED, "pause closed: captured (%d)" % Input.mouse_mode)
	hud.pause_menu.open()
	await wait_frames(2)
	hud.pause_menu.leave_button.pressed.emit()
	await wait_frames(3)
	check(Game.world == null and Input.mouse_mode == Input.MOUSE_MODE_VISIBLE, "menu after pause Leave: visible (%d)" % Input.mouse_mode)
	Game.start_host("Mouse", port)
	await wait_until(func(): return Game.local_player != null, 5.0, "hosted a third time")
	await wait_frames(5)
	GameState.request_start_round()
	GameState.time_left = 0.05
	await wait_until(func(): return GameState.phase == GameState.Phase.ROUND_FAILED, 3.0, "round failed")
	await wait_frames(2)
	check(Input.mouse_mode == Input.MOUSE_MODE_VISIBLE, "round-end overlay: visible (%d)" % Input.mouse_mode)
	GameState.request_retry()
	await wait_frames(3)
	check(Input.mouse_mode == Input.MOUSE_MODE_CAPTURED, "after RETRY: captured (%d)" % Input.mouse_mode)
	GameState.request_start_round()
	GameState.time_left = 0.05
	await wait_until(func(): return GameState.phase == GameState.Phase.ROUND_FAILED, 3.0, "round failed again")
	hud.round_end.menu_button.pressed.emit()
	await wait_frames(3)
	check(Game.world == null and Input.mouse_mode == Input.MOUSE_MODE_VISIBLE, "menu from the round-end overlay: visible (%d)" % Input.mouse_mode)
	finish()
