extends "res://tools/tests/qa_base.gd"
## Host alone + N raw ENet clients that send CONNECT and never ACK; then a proper raw client tries to connect.

var _keep := []

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
		c.service(0)
		c.flush()
		if bool(Config.get_arg("keep", false)):
			_keep.append(c)
		else:
			c.destroy()
	await wait_sec(float(Config.get_arg("delay", 0.3)))
	var t_all := Time.get_ticks_msec()
	for attempt in 40:
		var good := ENetConnection.new()
		good.create_host(1)
		good.connect_to_host("127.0.0.1", port, 3)
		var t0 := Time.get_ticks_msec()
		var connected := false
		while Time.get_ticks_msec() - t0 < 1500 and not connected:
			var ev := good.service(0)
			if ev[0] == ENetConnection.EVENT_CONNECT:
				connected = true
			await get_tree().process_frame
		good.destroy()
		if connected:
			print("good client got a slot %.1f s after the zombies" % ((Time.get_ticks_msec() - t_all) / 1000.0))
			break
	finish()
