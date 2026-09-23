extends "res://tools/tests/qa_base.gd"
## Host alone + N raw ENet clients that send CONNECT and vanish (never ACK). Print the host's slot table.

func _run() -> void:
	_label = "zombie"
	await get_tree().process_frame
	var port := port_arg(8471)
	check(Game.start_host("Z", port) == OK, "host")
	await wait_frames(2)
	for i in int(Config.get_arg("zombies", 2)):
		var c := ENetConnection.new()
		c.create_host(1)
		c.connect_to_host("127.0.0.1", port, 3)
		c.flush()
		c.destroy()
	var t0 := Time.get_ticks_msec()
	for s in 40:
		var e := Net._peer as ENetMultiplayerPeer
		var states := []
		for pp in e.host.get_peers():
			if pp.get_state() != ENetPacketPeer.STATE_DISCONNECTED:
				states.append(pp.get_state())
		print("t=%.1fs enet_states=%s mp_peers=%s" % [(Time.get_ticks_msec() - t0) / 1000.0, states, multiplayer.get_peers()])
		if states.is_empty() and s > 0:
			break
		await wait_sec(1.0)
	finish()
