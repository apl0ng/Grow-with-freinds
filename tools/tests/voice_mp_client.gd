extends "res://tools/tests/smoke_base.gd"
## Client side of the two-process voice test (tools/tests/voice_mp.sh). Pairs with voice_mp_host.gd.
## Joins, sends a second of synthetic voice frames through the real send path, then waits to hear the host.
##   godot --headless --path . -s res://tools/tests/run_test.gd -- --body=res://tools/tests/voice_mp_client.gd --port=7845

const VoiceScript := preload("res://scripts/core/voice.gd")
const SEND_FRAMES: int = 50

var _events: Array = []


func _frame(phase: int) -> PackedByteArray:
	var s := PackedFloat32Array()
	s.resize(Voice.FRAME_SAMPLES)
	for i in Voice.FRAME_SAMPLES:
		s[i] = 0.4 * sin(TAU * 330.0 * float(i + phase * Voice.FRAME_SAMPLES) / float(Voice.SAMPLE_RATE))
	return VoiceScript.encode_mulaw(s)

func _run() -> void:
	_label = "voice_client"
	await get_tree().process_frame
	Voice.settings_path = "user://voice_mp_client_test.cfg"
	Voice.speaking_changed.connect(func(p: int, s: bool) -> void: _events.append([p, s]))
	var port := port_arg(7845)

	step("joining 127.0.0.1:%d" % port)
	Game.start_join("127.0.0.1", port, "Client")
	await wait_until(func() -> bool: return Game.world != null and Game.local_player != null, 30.0, "world + local player")
	if Game.world == null or Game.local_player == null:
		finish(); return
	var my_id: int = multiplayer.get_unique_id()
	check(not Net.is_host and my_id != 1, "client (id %d)" % my_id)
	await wait_until(func() -> bool: return Net.players.size() == 2, 10.0, "players dict has 2 entries")
	await wait_until(func() -> bool: return Game.world.get_player(1) != null, 10.0, "host Player node visible")
	await wait_sec(0.5)

	step("talking")
	for i in SEND_FRAMES:
		Voice.debug_send_frame(_frame(i))
		await wait_sec(0.02)
	check(int(Voice.get_stats()["sent"]) == SEND_FRAMES, "sent %d frames" % SEND_FRAMES)
	check(_events.is_empty(), "own frames never come back (call_remote)")

	step("listening to the host")
	await wait_until(func() -> bool: return _events.has([1, true]), 20.0, "speaking_changed(1, true)")
	check(Voice.is_speaking(1) or _events.has([1, false]), "is_speaking(1) while the host talks")
	await wait_until(func() -> bool: return _events.has([1, false]), 10.0, "speaking_changed(1, false) after silence")
	var st: Dictionary = Voice.get_stats()
	check(int(st["received"]) >= 30, "received %d of the host's frames" % int(st["received"]))
	check(int(st["played"]) >= 2, "frames reached the generator (%d)" % int(st["played"]))
	var out := Game.world.get_node_or_null("VoiceOut/1") as AudioStreamPlayer3D
	check(out != null, "VoiceOut/1 exists")
	var hp: Node3D = Game.world.get_player(1)
	if out != null and hp != null:
		var head: Vector3 = hp.global_position + Vector3.UP * 1.6
		check(out.global_position.distance_to(head) < 0.3, "emitter at the host's head (%.2f m off)" % out.global_position.distance_to(head))
	check(_events == [[1, true], [1, false]], "exactly two transitions for the host (%s)" % str(_events))

	step("leave")
	Game.return_to_menu()
	await wait_frames(3)
	check(Game.world == null, "world freed")
	check(int(Voice.get_stats()["peers"]) == 0 and Voice.get_speaking_peers().is_empty(), "voice state cleared")
	finish()
