extends SceneTree
## Replication test for items over a real ENet connection (localhost), all in ONE process:
## /root/Server, /root/Client1, /root/Client2 each get their own SceneMultiplayer (SceneTree.set_multiplayer
## with a root path) and a minimal World (Players + Items + ItemSpawner). Client2 joins late.
##   godot --headless --path . -s res://tools/tests/items_net_test.gd
## Launcher only: the checks live in items_net_test_body.gd (compiled after the autoloads exist).
## Exit code: 0 all passed, 1 failures, 2 timeout.

const BODY_PATH := "res://tools/tests/items_net_test_body.gd"
const TIMEOUT_SEC := 90.0

func _initialize() -> void:
	create_timer(TIMEOUT_SEC).timeout.connect(_on_timeout)
	var script := load(BODY_PATH) as GDScript
	if script == null or not script.can_instantiate():
		print("FAIL: could not load " + BODY_PATH)
		quit(1)
		return
	var body: Node = script.new()
	body.name = "ItemsNetTest"
	root.add_child(body)

func _on_timeout() -> void:
	print("FAIL: test timed out after %d s" % int(TIMEOUT_SEC))
	quit(2)
