extends SceneTree
## Two-process end-to-end test of pickup / hold / drop on the REAL game stack (Game.start_host / start_join,
## World spawners, Player, Interactor, ItemManager). The host launches the client process itself.
##   godot --headless --path . -s res://tools/tests/items_e2e_test.gd            (host; spawns the client)
## Launcher only: the steps live in items_e2e_body.gd (compiled after the autoloads exist).
## Exit code: 0 all passed, 1 failures, 2 timeout.

const BODY_PATH := "res://tools/tests/items_e2e_body.gd"
const TIMEOUT_SEC := 90.0

func _initialize() -> void:
	create_timer(TIMEOUT_SEC).timeout.connect(_on_timeout)
	var script := load(BODY_PATH) as GDScript
	if script == null or not script.can_instantiate():
		print("FAIL: could not load " + BODY_PATH)
		quit(1)
		return
	var body: Node = script.new()
	body.name = "ItemsE2E" # same path in both processes: the body talks to its peer over RPC
	root.add_child(body)

func _on_timeout() -> void:
	print("FAIL: e2e test timed out after %d s" % int(TIMEOUT_SEC))
	quit(2)
