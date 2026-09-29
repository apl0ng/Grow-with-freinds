extends "res://tools/tests/smoke_base.gd"
## Host side of the two-process voice test (tools/tests/voice_mp.sh). Pairs with voice_mp_client.gd.
## The client sends real voice frames over ENet; this host must hear it start and stop speaking, then talks
## back for a second so the client hears the host. Prints HOST_READY once the client may join.
##   godot --headless --path . -s res://tools/tests/run_test.gd -- --body=res://tools/tests/voice_mp_host.gd --port=7845

const VoiceScript := preload("res://scripts/core/voice.gd")
const SEND_FRAMES: int = 50

var _events: Array = []


func _frame(phase: int) -> PackedByteArray:
	var s := PackedFloat32Array()
	s.resize(Voice.FRAME_SAMPLES)
	for i in Voice.FRAME_SAMPLES:
		s[i] = 0.4 * sin(TAU * 220.0 * float(i + phase * Voice.FRAME_SAMPLES) / float(Voice.SAMPLE_RATE))
	return VoiceScript.encode_mulaw(s)

func _run() -> void:
	_label = "voice_host"
	await get_tree().process_frame
	Voice.settings_path = "user://voice_mp_host_test.cfg"
	Voice.speaking_changed.connect(func(p: int, s: bool) -> void: _events.append([p, s]))
	var port := port_arg(7845)

	step("hosting on %d" % port)
	Game.start_host("Host", port)
	await wait_until(func() -> bool: return Game.world != null and Game.local_player != null, 5.0, "world + local player")
	if Game.world == null:
		finish(); return
	print("HOST_READY")

	step("waiting for the client")
	await wait_until(func() -> bool: return Net.players.size() == 2, 40.0, "client registered")
	var client_id := 0
	for id in Net.players:
		if id != 1:
			client_id = id
	check(client_id != 0, "client id known (%d)" % client_id)
	if client_id == 0:
		finish(); return
	await wait_until(func() -> bool: return Game.world.get_player(client_id) != null, 10.0, "client Player node spawned")

	step("client talks")
	await wait_until(func() -> bool: return _events.has([client_id, true]), 20.0, "speaking_changed(client, true)")
	check(Voice.is_speaking(client_id) or _events.has([client_id, false]), "is_speaking(client) while frames arrive")
	await wait_until(func() -> bool: return _events.has([client_id, false]), 10.0, "speaking_changed(client, false) after silence")
	var st: Dictionary = Voice.get_stats()
	check(int(st["received"]) >= 30, "received %d of the client's frames" % int(st["received"]))
	check(int(st["played"]) >= 2, "frames reached the generator (%d)" % int(st["played"]))
	check(int(st["dropped"].get("not_player", 0)) == 0 and int(st["dropped"].get("too_big", 0)) == 0, "nothing dropped as not_player / too_big")
	var out := Game.world.get_node_or_null("VoiceOut/%d" % client_id) as AudioStreamPlayer3D
	check(out != null, "VoiceOut/%d exists" % client_id)
	var cp: Node3D = Game.world.get_player(client_id)
	if out != null and cp != null:
		var head: Vector3 = cp.global_position + Vector3.UP * 1.6
		check(out.global_position.distance_to(head) < 0.3, "emitter at the client's head (%.2f m off)" % out.global_position.distance_to(head))
	check(Voice.get_speaking_peers().is_empty(), "nobody speaks after the client went quiet")

	step("host talks back")
	for i in SEND_FRAMES:
		Voice.debug_send_frame(_frame(i))
		await wait_sec(0.02)
	check(int(Voice.get_stats()["sent"]) == SEND_FRAMES, "sent %d frames" % SEND_FRAMES)

	step("waiting for the client to leave")
	await wait_until(func() -> bool: return Net.players.size() == 1, 30.0, "client left")
	await wait_frames(2)
	check(not Voice.is_speaking(client_id) and Voice.get_output_node(client_id) == null, "departed client: no speaking mark, no emitter")
	Game.return_to_menu()
	await wait_frames(3)
	check(Game.world == null, "world freed")
	finish()
