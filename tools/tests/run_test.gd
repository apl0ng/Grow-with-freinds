extends SceneTree
## Generic headless test launcher. A `-s` SceneTree script cannot reference autoloads at compile time,
## so the actual test lives in a Node script ("body") that is loaded here, after autoloads exist.
##   godot --headless --path . -s res://tools/tests/run_test.gd -- --body=res://tools/tests/smoke_solo.gd [--port=7801]

func _initialize() -> void:
	var body_path := ""
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--body="):
			body_path = a.substr(7)
	if body_path == "":
		push_error("run_test: pass --body=res://path/to/test_body.gd after --")
		quit(2)
		return
	var script: GDScript = load(body_path)
	if script == null:
		push_error("run_test: could not load " + body_path)
		quit(2)
		return
	var body: Node = script.new()
	body.name = "TestBody"
	root.add_child(body)
