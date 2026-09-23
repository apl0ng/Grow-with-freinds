extends SceneTree
## Entry point for the headless network test (client role). All logic lives in net_test_runner.gd, which is
## loaded here (after the autoloads exist) so it can use Net / Game / Config directly.
##   godot --headless --path . -s res://tools/tests/net_client.gd -- --port=7799 [--scenario=pair|trio|full] [--who=a|b|idle|reject]

func _initialize() -> void:
	var runner: Node = (load("res://tools/tests/net_test_runner.gd") as GDScript).new()
	runner.name = "NetTestRunner"
	runner.set_meta(&"role", "client")
	root.add_child(runner)
