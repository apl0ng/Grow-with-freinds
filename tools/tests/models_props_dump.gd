extends SceneTree
func _initialize() -> void:
	_run.call_deferred()
func _run() -> void:
	var TV = load("res://scenes/world/props/tint_variety.gd")
	var drums := {"DrumA": Vector3(-1.95, 0, 6.85), "DrumB": Vector3(-1.45, 0, 6.05), "DrumC": Vector3(9.2, 0, -6.8), "DrumD": Vector3(8.5, 0, -6.95)}
	var crates := {"CrateA": Vector3(2.2, 0.3, 6.75), "CrateB": Vector3(4.2, 0, -6.9), "CrateC": Vector3(6.35, 0, 6.8)}
	for salt in 12:
		var s := "salt %d drums:" % salt
		for k in drums:
			s += " %s=%d" % [k, TV.pick(drums[k], 3, salt)]
		s += " | crates:"
		for k in crates:
			s += " %s=%d" % [k, TV.pick(crates[k], 3, salt)]
		print(s)
	quit(0)
