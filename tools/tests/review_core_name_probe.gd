extends "res://tools/tests/qa_base.gd"

func _run() -> void:
	_label = "names"
	await get_tree().process_frame
	for n in [1000, 5000, 10000, 20000, 40000]:
		var s := "a".repeat(n)
		var t0 := Time.get_ticks_usec()
		var r := Net.sanitize_name(s)
		print("len %d -> %.1f ms (result %s)" % [n, (Time.get_ticks_usec() - t0) / 1000.0, r])
	for raw in ["​​", " 　", "‮Bob", "Bo b", "Bo\u0085b", "Bob​", "﻿", "⁦x"]:
		var r2 := Net.sanitize_name(raw)
		var codes := []
		for ch in r2: codes.append("%04X" % ch.unicode_at(0))
		print("sanitize(%s) -> len %d %s" % [raw.c_escape(), r2.length(), codes])
	print("unique: ", Net._unique_name(Net.sanitize_name("Bob​"), {1: {"name": "Bob"}}).c_escape())
	finish()
