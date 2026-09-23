extends Node
## Body of review_viewmodel_test.gd: the first-person view-model layer (task 9.6). Prints PASS/FAIL lines, exits 0/1.
## Host role (default), in order:
##   1. player.tscn contract: %Camera's cull mask excludes Player.VIEW_MODEL_LAYER; no view-model nodes in the scene
##      (they are built at runtime for the local player only).
##   2. Manual world (world.tscn on the OfflineMultiplayerPeer, no Game.start_host): an item held by peer 1 spawns
##      BEFORE player 1 exists (hidden, world layers) -> player 1 spawns -> the item moves into the view model; an
##      item spawned straight into the local hand is in the view model from _ready; the local player leaving the tree
##      while holding puts the item back on its world layers and takes the view-model bit off the lights again.
##   3. Game.start_host: the local view model (SubViewport sharing the World3D, transparent, its camera copying
##      %Camera, CanvasLayer below the HUD, TextureRect ignoring the mouse), lights shared (also lights added later),
##      a fake remote peer 2 without a view model, holding toggles for the can / packet / product with the render
##      layers of EVERY GeometryInstance3D checked (outline hulls, labels), frame order (a camera change at process
##      priority 0 reaches both the item (10) and the view-model camera in the same frame), enable/disable, despawn
##      while held, viewport settings following the main viewport, return_to_menu leaving nothing behind.
##   4. Network: a real client process joins; the host puts a can in the client's hands; the client draws it in ITS
##      view model while the host draws it at the client's %BodyHandSocket on world layers; the drop restores the
##      client's layers; the client returns to the menu and has no view-model nodes left.

const VM := Player.VIEW_MODEL_LAYER
const WORLD := Player.WORLD_RENDER_LAYER
const AREA := Vector3(0.0, 0.0, 1.5) # free floor near the room centre (spawns face the shop)
const WAIT_SEC := 15.0

var _role := "host"
var _next_port := 0 # next port to try hosting on (--port=N from tools/test_all.sh, else random); probed before use
var _passes := 0
var _fails := 0
# network section (host side)
var _pid := -1
var _client_id := 0
var _client_step := ""
# network section (client side)
var _host_step := ""


## Priority-0 node: turns the camera a little every frame, i.e. AFTER the players (-10) and BEFORE the items (10).
class CameraNudger extends Node:
	var target: Node3D = null
	var step := 0.013

	func _ready() -> void:
		process_priority = 0

	func _process(_delta: float) -> void:
		if target != null and is_instance_valid(target):
			target.rotate_object_local(Vector3.UP, step)
			target.rotate_object_local(Vector3.RIGHT, -step * 0.5)


## Priority-100 node: after everything else processed, compares the view-model camera with %Camera and the held
## item with where the hand socket puts it relative to the view-model camera (what the view-model pass renders).
class OrderProbe extends Node:
	var player: Player = null
	var item: Item = null
	var frames := 0
	var cam_bad := 0
	var item_bad := 0
	var max_cam_err := 0.0
	var max_item_err := 0.0

	func _ready() -> void:
		process_priority = 100

	func _process(_delta: float) -> void:
		if player == null or item == null or not is_instance_valid(player) or not is_instance_valid(item):
			return
		var vm := player.get_view_model_camera()
		if vm == null:
			return
		frames += 1
		var cam_err := _xform_err(vm.global_transform, player.camera.global_transform)
		var rel := vm.global_transform.affine_inverse() * item.global_transform
		var want := (player.get_node("%HandSocket") as Node3D).transform * item._get_hold_transform()
		var item_err := _xform_err(rel, want)
		max_cam_err = maxf(max_cam_err, cam_err)
		max_item_err = maxf(max_item_err, item_err)
		if cam_err > 0.0005:
			cam_bad += 1
		if item_err > 0.0005:
			item_bad += 1

	static func _xform_err(a: Transform3D, b: Transform3D) -> float:
		var e := a.origin.distance_to(b.origin)
		for i in 3:
			e = maxf(e, (a.basis[i] - b.basis[i]).length())
		return e


func _ready() -> void:
	_run()

func check(cond: bool, what: String) -> bool:
	if cond:
		_passes += 1
	else:
		_fails += 1
	print("%s: %s%s" % ["PASS" if cond else "FAIL", "" if _role == "host" else "[client] ", what])
	if _role == "client" and multiplayer.has_multiplayer_peer() and multiplayer.get_unique_id() != 1 \
			and multiplayer.multiplayer_peer.get_connection_status() == MultiplayerPeer.CONNECTION_CONNECTED:
		_rpc_report.rpc_id(1, cond)
	return cond

func frames(n: int = 1) -> void:
	for i in n:
		await get_tree().process_frame

func wait_until(cond: Callable, seconds: float = WAIT_SEC) -> bool:
	var end := Time.get_ticks_msec() + int(seconds * 1000.0)
	while Time.get_ticks_msec() < end:
		if cond.call():
			return true
		await get_tree().process_frame
	return cond.call()

func _run() -> void:
	await get_tree().process_frame
	var args := Config.parse_user_args()
	_role = str(args.get("role", "host"))
	if _role == "client":
		await _run_client(int(args.get("port", 0)))
		return
	_next_port = int(args.get("port", 0))
	if _next_port <= 0:
		_next_port = 29000 + randi() % 900
	var orphans_at_start := Performance.get_monitor(Performance.OBJECT_ORPHAN_NODE_COUNT)
	_test_scene_contract()
	await _test_manual_world()
	await _test_hosted_game()
	check(Performance.get_monitor(Performance.OBJECT_ORPHAN_NODE_COUNT) == orphans_at_start,
			"no orphan nodes left after the single-process sections (%d -> %d)"
			% [orphans_at_start, Performance.get_monitor(Performance.OBJECT_ORPHAN_NODE_COUNT)])
	await _test_network()
	print("review_viewmodel_test: %d passed, %d failed" % [_passes, _fails])
	_end(1 if _fails > 0 else 0)

# ================================================================================================ helpers

static func _geometry(item: Node) -> Array[GeometryInstance3D]:
	var out: Array[GeometryInstance3D] = []
	for n in item.find_children("*", "GeometryInstance3D", true, false):
		out.append(n as GeometryInstance3D)
	return out

static func _layers_of(item: Node) -> Dictionary:
	var out := {}
	for gi in _geometry(item):
		out[gi] = gi.layers
	return out

## Every GeometryInstance3D under `item` renders on exactly `want`.
static func _all_on(item: Node, want: int) -> bool:
	var list := _geometry(item)
	if list.is_empty():
		return false
	for gi in list:
		if gi.layers != want:
			return false
	return true

## Every GeometryInstance3D is back on the layers recorded in `baseline` and carries no stored-layers meta.
static func _restored(item: Node, baseline: Dictionary) -> bool:
	var list := _geometry(item)
	if list.size() != baseline.size():
		return false
	for gi in list:
		if not baseline.has(gi) or gi.layers != int(baseline[gi]) or gi.has_meta(Item.META_WORLD_LAYERS):
			return false
	return true

static func _count_hulls(item: Node) -> int:
	var n := 0
	for gi in _geometry(item):
		if gi.has_meta(&"toonify_outline"):
			n += 1
	return n

static func _count_labels(item: Node) -> int:
	var n := 0
	for gi in _geometry(item):
		if gi is Label3D:
			n += 1
	return n

static func _only(list: Array, node: Node) -> bool:
	return list.size() == 1 and list[0] == node

## Nodes in the tree outside the autoloads and this test body (Sfx pools, caches... are not the world's business).
func _scene_node_count() -> int:
	var skip := {}
	for n in ["Const", "Config", "Net", "Game", "GameState", "Sfx", "Juice", "Story", String(name)]:
		skip[n] = true
	var count := 0
	for c in get_tree().root.get_children():
		if skip.has(String(c.name)):
			continue
		count += 1 + c.find_children("*", "", true, false).size()
	return count

## A UDP port nobody is bound to (probing prints nothing; a busy port would make ENet print an ERROR line).
func _take_port() -> int:
	for i in 50:
		var port := _next_port
		_next_port += 1
		var probe := PacketPeerUDP.new()
		var err := probe.bind(port)
		probe.close()
		if err == OK:
			return port
	return _next_port

func _sub_viewports() -> Array[Node]:
	return get_tree().root.find_children("*", "SubViewport", true, false)

func _view_model_nodes() -> Array[Node]:
	return get_tree().root.find_children("ViewModel", "CanvasLayer", true, false)

func _lights_in(root_node: Node) -> Array[Light3D]:
	var out: Array[Light3D] = []
	for n in root_node.find_children("*", "Light3D", true, false):
		out.append(n as Light3D)
	return out

## All lights under `root_node` the main camera sees carry the view-model bit (and light it).
func _lights_shared(root_node: Node, cam: Camera3D) -> bool:
	var any := false
	for l in _lights_in(root_node):
		if (l.layers & WORLD) == 0 or (l.layers & cam.cull_mask & ~VM) == 0:
			continue
		any = true
		if (l.layers & VM) == 0 or (l.light_cull_mask & VM) == 0:
			return false
	return any

# ================================================================================================ 1. scene contract

func _test_scene_contract() -> void:
	var p := (load("res://scenes/player/player.tscn") as PackedScene).instantiate() as Player
	var cam := p.get_node("%Camera") as Camera3D
	check((cam.cull_mask & VM) == 0 and (cam.cull_mask & WORLD) != 0 and cam.cull_mask == (0xFFFFF & ~VM),
			"player.tscn: %%Camera cull mask = every layer but VIEW_MODEL_LAYER (%d)" % cam.cull_mask)
	check(VM == 1 << 9, "VIEW_MODEL_LAYER is render layer 10 (bit value 512)")
	check(p.get_node_or_null(^"ViewModel") == null and p.get_view_model_viewport() == null,
			"player.tscn has no view-model nodes (built at runtime for the local player only)")
	check(Player.VIEW_MODEL_CANVAS_LAYER < 1, "view-model canvas layer %d is below the HUD (layer 1)" % Player.VIEW_MODEL_CANVAS_LAYER)
	p.free()

# ================================================================================================ 2. manual world

func _test_manual_world() -> void:
	var world := (load("res://scenes/world/world.tscn") as PackedScene).instantiate() as World
	world.name = "World"
	get_tree().root.add_child(world)
	Game.world = world
	await frames(2)
	var mgr := world.items
	# An item held by peer 1 spawns before player 1 exists (a late joiner receives items before its own player).
	var can := mgr.server_spawn_item(Const.ITEM_WATERING_CAN, {"charges": 2}, AREA, 1) as WateringCan
	await frames(2)
	check(can != null and can.holder_id == 1 and not can.visible and not can.is_in_view_model() and _all_on(can, WORLD),
			"item held by a not-yet-spawned local player: hidden, world layers, not in a view model")
	var p := world.server_spawn_player(1)
	await frames(2)
	check(p != null and p.is_local() and p.uses_view_model(), "local player 1 spawned with a view model")
	if p == null or can == null:
		_free_world(world)
		return
	check(can.visible and can.is_in_view_model() and _all_on(can, VM),
			"the waiting item moved into the view model once its local holder spawned")
	check(p.is_view_model_active() and _only(p.get_view_model_users(), can),
			"view model active with the can as its only user")
	check(_lights_shared(world, p.camera), "manual world: lights shared with the view model")
	mgr.server_drop_item(can, AREA + Vector3(1, 0, 0))
	check(not can.is_in_view_model() and _all_on(can, WORLD) and not p.is_view_model_active(),
			"drop: world layers back, view model idle")
	# Spawned straight into the local hand: in the view model from _ready on (no frame on world layers).
	var packet := mgr.server_spawn_item(Const.ITEM_SEED_PACKET, {"strain_id": &"purple"}, Vector3.ZERO, 1) as SeedPacket
	check(packet != null and packet.is_in_view_model() and _all_on(packet, VM) and p.is_view_model_active(),
			"item spawned into the local hand is in the view model right after spawning")
	# The local player leaves the tree while holding: item back to world layers, lights lose the bit.
	var sun := world.room.get_node_or_null(^"Sun") as Light3D
	check(sun != null and (sun.layers & VM) != 0, "the room's Sun carries the view-model bit while the local player exists")
	var players_root := world.players_root
	players_root.remove_child(p)
	check(not packet.is_in_view_model() and _all_on(packet, WORLD),
			"local player leaving the tree: its held item goes back to world layers")
	check(sun == null or (sun.layers & VM) == 0, "local player leaving the tree: lights lose the view-model bit")
	var lights_left := 0
	for l in _lights_in(world):
		if (l.layers & VM) != 0 or l.has_meta(Player.META_VIEW_MODEL_LIGHT):
			lights_left += 1
	check(lights_left == 0, "no light keeps the view-model bit or meta (%d)" % lights_left)
	p.free()
	await frames(2)
	check(packet != null and not packet.visible and _all_on(packet, WORLD), "holder gone: packet hidden, still world layers")
	_free_world(world)
	await frames(2)
	check(_sub_viewports().is_empty() and _view_model_nodes().is_empty(), "manual world freed: no view-model nodes left")

func _free_world(world: World) -> void:
	if world.players_root != null:
		for p in world.players_root.get_children():
			world.players_root.remove_child(p)
			p.free()
	world.get_parent().remove_child(world)
	world.free()
	Game.world = null

# ================================================================================================ 3. hosted game

func _test_hosted_game() -> void:
	# Warm-up cycle: host + return to menu, to take the node-count baseline with the menu in place.
	var port := _take_port()
	check(Game.start_host("VM", port) == OK, "warm-up host on port %d" % port)
	await frames(3)
	Game.return_to_menu("")
	await frames(3)
	var nodes_baseline := _scene_node_count()
	port = _take_port()
	if not check(Game.start_host("VM", port) == OK, "host on port %d" % port):
		return
	await wait_until(func() -> bool: return Game.local_player != null, 5.0)
	await frames(3)
	var world := Game.world
	var p := Game.local_player
	if not check(p != null and world != null, "local player spawned"):
		return
	var root := get_tree().root
	var sv := p.get_view_model_viewport()
	var vm := p.get_view_model_camera()
	var layer := p.get_node_or_null(^"ViewModel") as CanvasLayer
	var screen := p.get_node_or_null(^"ViewModel/Screen") as TextureRect
	check(sv != null and vm != null and layer != null and screen != null and sv.get_parent() == layer
			and vm.get_parent() == sv, "ViewModel (CanvasLayer) / Viewport (SubViewport) / Camera + Screen built")
	if sv == null or vm == null or layer == null or screen == null:
		return
	check(_only(_sub_viewports(), sv), "exactly one SubViewport in the whole tree (the local view model)")
	check(not sv.own_world_3d and sv.world_3d == null and sv.find_world_3d() == p.get_world_3d(),
			"view-model SubViewport renders the SAME World3D (own_world_3d off)")
	check(sv.transparent_bg and sv.render_target_clear_mode == SubViewport.CLEAR_MODE_ALWAYS, "transparent, cleared every frame")
	check(sv.positional_shadow_atlas_size == 0 and not sv.audio_listener_enable_3d and sv.gui_disable_input,
			"no positional shadow atlas, no audio listener, no GUI input")
	check(sv.get_camera_3d() == vm and root.get_camera_3d() == p.camera and p.camera.current,
			"view-model camera current in the SubViewport only, %Camera still current in the main viewport")
	check(vm.cull_mask == VM and (p.camera.cull_mask & VM) == 0 and (p.camera.cull_mask & WORLD) != 0,
			"view-model camera sees only layer 10, %Camera everything else")
	check(is_equal_approx(vm.fov, p.camera.fov) and vm.near < p.camera.near and vm.far <= Player.VIEW_MODEL_FAR,
			"view-model camera: same FOV (%.0f), nearer near plane (%.3f), short far plane" % [vm.fov, vm.near])
	var env := vm.environment
	check(env != null and env.background_mode == Environment.BG_COLOR and env.background_color == Color(0, 0, 0, 0)
			and not env.glow_enabled and not env.ssao_enabled and not env.sdfgi_enabled,
			"view-model Environment: black transparent background, no per-viewport effects")
	var world_env := p.get_world_3d().environment
	check(world_env != null and env != world_env and env.ambient_light_source == world_env.ambient_light_source
			and env.ambient_light_color == world_env.ambient_light_color
			and is_equal_approx(env.ambient_light_energy, world_env.ambient_light_energy)
			and env.tonemap_mode == world_env.tonemap_mode and env.adjustment_enabled == world_env.adjustment_enabled,
			"view-model Environment copies the world's ambient light, tonemap and adjustments")
	var hud := world.get_node_or_null(^"HUD") as CanvasLayer
	check(layer.layer == Player.VIEW_MODEL_CANVAS_LAYER and hud != null and layer.layer < hud.layer,
			"view-model CanvasLayer (%d) below the HUD (%d)" % [layer.layer, hud.layer if hud else 0])
	check(screen.mouse_filter == Control.MOUSE_FILTER_IGNORE and screen.texture == sv.get_texture()
			and is_equal_approx(screen.anchor_right, 1.0) and is_equal_approx(screen.anchor_bottom, 1.0)
			and screen.anchor_left == 0.0 and screen.anchor_top == 0.0,
			"Screen: full-rect TextureRect showing the SubViewport, ignores the mouse")
	var mat := screen.material as CanvasItemMaterial
	check(mat != null and mat.blend_mode == CanvasItemMaterial.BLEND_MODE_PREMULT_ALPHA, "Screen composites premultiplied alpha")
	check(sv.size == Player._main_render_size(root) and sv.msaa_3d == root.msaa_3d,
			"SubViewport matches the main viewport (size %s, MSAA %d)" % [sv.size, sv.msaa_3d])
	check(not p.is_view_model_active() and sv.render_target_update_mode == SubViewport.UPDATE_DISABLED and not screen.visible,
			"empty hands: the view-model pass is off (UPDATE_DISABLED, Screen hidden)")
	# Lights: every light %Camera sees also lights the view model, lights added later too, other worlds untouched.
	check(_lights_shared(world, p.camera), "every world light carries (and lights) the view-model layer")
	var late := OmniLight3D.new()
	late.name = "LateLight"
	world.room.add_child(late)
	var vm_only_light := OmniLight3D.new()
	vm_only_light.layers = VM # lights only the view model (%Camera does not see it): left as it is
	world.room.add_child(vm_only_light)
	var other := SubViewport.new()
	other.own_world_3d = true
	var other_light := OmniLight3D.new()
	other.add_child(other_light)
	root.add_child(other)
	await frames(1)
	check((late.layers & VM) != 0 and (late.light_cull_mask & VM) != 0, "a light added later gets the view-model bit")
	check(vm_only_light.layers == VM and not vm_only_light.has_meta(Player.META_VIEW_MODEL_LIGHT)
			and (other_light.layers & VM) == 0 and not other_light.has_meta(Player.META_VIEW_MODEL_LIGHT),
			"a view-model-only light and a light in another World3D are left alone")
	late.queue_free()
	vm_only_light.queue_free()
	other.queue_free()
	await frames(1)
	# A (fake) remote peer 2: no view model.
	Net.players[2] = {"name": "Remote", "color": Net.PALETTE[1]}
	var p2 := world.server_spawn_player(2)
	await frames(3)
	check(p2 != null and not p2.is_local() and not p2.uses_view_model() and p2.get_view_model_viewport() == null
			and p2.get_node_or_null(^"ViewModel") == null, "remote player 2: no view model")
	check(_sub_viewports().size() == 1, "still exactly one SubViewport with a remote player present")
	if p2 == null:
		return
	# Holding toggles for all three item types (the player at rest first: physics moving it between the item's follow
	# and a check would read as an offset).
	check(await wait_until(func() -> bool: return p.is_on_floor() and p.velocity.length() < 0.001, 5.0),
			"local player standing still on the floor")
	var mgr := world.items
	var feet := p.global_position
	var items: Array[Item] = [
		mgr.server_spawn_item(Const.ITEM_WATERING_CAN, {"charges": 3}, feet + Vector3(0.6, 0, 0.6)),
		mgr.server_spawn_item(Const.ITEM_SEED_PACKET, {"strain_id": &"purple"}, feet + Vector3(-0.6, 0, 0.6)),
		mgr.server_spawn_item(Const.ITEM_PRODUCT, {"strain_id": &"golden", "amount": 2}, feet + Vector3(0, 0, 0.9)),
	]
	await frames(2)
	for item in items:
		await _toggle_item(item, p, p2, mgr, sv, screen)
	var can := items[0] as WateringCan
	var packet := items[1] as SeedPacket
	var product := items[2] as Product
	check(_count_hulls(can) > 0 and _count_labels(packet) >= 2, "layer checks covered outline hulls (%d on the can) and Label3Ds (%d on the packet)"
			% [_count_hulls(can), _count_labels(packet)])
	# Frame order: a camera change at priority 0 (after the player, before the items) shows up in both the item and
	# the view-model camera in the same frame; so does crouching (head moves in the player's _process).
	check(p.process_priority < can.process_priority, "players (%d) process before items (%d)" % [p.process_priority, can.process_priority])
	mgr.server_give_item(can, 1)
	var nudger := CameraNudger.new()
	nudger.target = p.camera
	var probe := OrderProbe.new()
	probe.player = p
	probe.item = can
	add_child(nudger)
	add_child(probe)
	await frames(20)
	Input.action_press(&"crouch")
	await frames(15)
	check(p.crouching and p.head.position.y < Player.STAND_CAMERA_Y - 0.05, "crouching lowers the camera during the order check")
	Input.action_release(&"crouch")
	await frames(15)
	check(probe.frames >= 45 and probe.cam_bad == 0,
			"view-model camera == %%Camera at the end of every frame (%d frames, max err %.5f)" % [probe.frames, probe.max_cam_err])
	check(probe.item_bad == 0,
			"held item sits exactly at the hand socket as seen by the view-model camera (%d frames, max err %.5f)"
			% [probe.frames, probe.max_item_err])
	nudger.queue_free()
	probe.queue_free()
	p.camera.rotation = Vector3.ZERO
	await frames(1)
	# Viewport settings follow the main viewport.
	var old_msaa := root.msaa_3d
	var old_scale := root.scaling_3d_scale
	root.msaa_3d = Viewport.MSAA_2X if old_msaa != Viewport.MSAA_2X else Viewport.MSAA_8X
	root.scaling_3d_scale = 0.75
	await frames(2)
	check(sv.msaa_3d == root.msaa_3d and is_equal_approx(sv.scaling_3d_scale, 0.75),
			"MSAA / 3D scaling changes on the main viewport reach the view model")
	root.msaa_3d = old_msaa
	root.scaling_3d_scale = old_scale
	var old_size := root.size
	root.size = Vector2i(900, 500)
	await frames(2)
	if root.size == Vector2i(900, 500):
		check(sv.size == Player._main_render_size(root), "window resize reaches the view model (%s)" % sv.size)
	else:
		print("SKIP: the headless display server ignores window resizes (covered by review_viewmodel_preview.gd)")
	root.size = old_size
	await frames(2)
	# Disable / enable.
	p.view_model_enabled = false
	check(not can.is_in_view_model() and _all_on(can, WORLD) and not p.is_view_model_active() and not screen.visible,
			"view_model_enabled = false: the held item is drawn in the world again at once, pass off")
	await frames(2)
	check(not can.is_in_view_model() and can.visible, "... and stays there while disabled")
	p.view_model_enabled = true
	await frames(2)
	check(can.is_in_view_model() and _all_on(can, VM) and p.is_view_model_active(), "re-enabled: back in the view model")
	# Another camera takes over the main viewport (overview / debug camera): the held item goes back to the world
	# pass (the overlay would show %Camera's view otherwise), and returns when %Camera is current again.
	var overview := world.get_node_or_null(^"OverviewCamera") as Camera3D
	if check(overview != null, "world has its OverviewCamera"):
		overview.current = true
		await frames(2)
		check(not p.uses_view_model() and not can.is_in_view_model() and _all_on(can, WORLD) and not p.is_view_model_active()
				and not screen.visible, "another camera current: held item in the world pass, view model off")
		p.camera.current = true
		await frames(2)
		check(p.uses_view_model() and can.is_in_view_model() and _all_on(can, VM) and p.is_view_model_active() and screen.visible,
				"%Camera current again: back in the view model")
	# Despawned while held (sold / reset): the pass switches off.
	mgr.server_drop_item(can, feet + Vector3(0.6, 0, 0.6))
	mgr.server_give_item(product, 1)
	await frames(1)
	check(product.is_in_view_model() and _only(p.get_view_model_users(), product), "product held in the view model")
	mgr.server_despawn_item(product)
	await frames(2)
	check(not p.is_view_model_active() and p.get_view_model_users().is_empty() and sv.render_target_update_mode == SubViewport.UPDATE_DISABLED,
			"item despawned while held: view model idle, no stale user")
	# return_to_menu while holding: nothing left behind.
	mgr.server_give_item(packet, 1)
	await frames(2)
	check(packet.is_in_view_model(), "holding the packet before returning to the menu")
	Game.return_to_menu("")
	await frames(4)
	check(Game.world == null and Game.local_player == null, "return_to_menu freed the world")
	check(_sub_viewports().is_empty() and _view_model_nodes().is_empty(), "return_to_menu: no SubViewport / ViewModel left")
	check(not get_tree().node_added.get_connections().any(func(c: Dictionary) -> bool: return not is_instance_valid(c["callable"].get_object())),
			"no dangling node_added connection")
	var nodes_now := _scene_node_count()
	check(nodes_now == nodes_baseline, "scene node count back to the menu baseline (%d vs %d)" % [nodes_now, nodes_baseline])

## Floor -> local hand (view model) -> floor -> remote hand (world) -> floor, checking every GeometryInstance3D.
func _toggle_item(item: Item, p: Player, p2: Player, mgr: ItemManager, sv: SubViewport, screen: TextureRect) -> void:
	var tag := String(item.item_type)
	var baseline := _layers_of(item)
	check(not baseline.is_empty() and _all_on(item, WORLD) and not item.is_in_view_model(),
			"%s on the floor: all %d GeometryInstance3D on world layer 1" % [tag, baseline.size()])
	var spot := item.global_position
	check(mgr.server_give_item(item, 1), "%s: give to the local player" % tag)
	check(item.is_in_view_model() and _all_on(item, VM), "%s: in the local hand -> view-model layer only, at once" % tag)
	await frames(2)
	check(_all_on(item, VM) and p.is_view_model_active() and sv.render_target_update_mode == SubViewport.UPDATE_ALWAYS
			and screen.visible and _only(p.get_view_model_users(), item),
			"%s: view-model pass renders (UPDATE_ALWAYS, Screen shown, one user)" % tag)
	var socket := p.get_node("%HandSocket") as Node3D
	check(item.global_position.distance_to((socket.global_transform * item._get_hold_transform()).origin) < 0.001,
			"%s: follows %%HandSocket" % tag)
	mgr.server_drop_item(item, spot)
	check(not item.is_in_view_model() and _restored(item, baseline), "%s: dropped -> world layers restored exactly" % tag)
	await frames(2)
	check(not p.is_view_model_active() and sv.render_target_update_mode == SubViewport.UPDATE_DISABLED and not screen.visible,
			"%s: dropped -> view-model pass off" % tag)
	check(mgr.server_give_item(item, 2), "%s: give to remote player 2" % tag)
	await frames(2)
	var body_socket := p2.get_node("%BodyHandSocket") as Node3D
	check(not item.is_in_view_model() and _restored(item, baseline) and not p.is_view_model_active(),
			"%s: held by a remote player -> stays on world layers, no view-model pass" % tag)
	check(item.visible and item.global_position.distance_to((body_socket.global_transform * item._get_hold_transform()).origin) < 0.001,
			"%s: remote holder -> visible at %%BodyHandSocket" % tag)
	mgr.server_drop_item(item, spot)
	# Hand-over remote -> local -> remote without touching the floor in between (drop + give in one frame).
	mgr.server_give_item(item, 1)
	check(item.is_in_view_model(), "%s: local again" % tag)
	mgr.server_drop_item(item, spot)
	mgr.server_give_item(item, 2)
	await frames(1)
	check(not item.is_in_view_model() and _restored(item, baseline), "%s: local -> remote in one frame restores the layers" % tag)
	mgr.server_drop_item(item, spot)
	await frames(1)

# ================================================================================================ 4. network

func _test_network() -> void:
	var port := _take_port()
	if not check(Game.start_host("Host", port) == OK, "network: hosting on port %d" % port):
		return
	await wait_until(func() -> bool: return Game.local_player != null, 5.0)
	var args := PackedStringArray(["--headless", "--path", ProjectSettings.globalize_path("res://"),
			"-s", "res://tools/tests/review_viewmodel_test.gd", "--", "--role=client", "--port=%d" % port])
	_pid = OS.create_process(OS.get_executable_path(), args)
	check(_pid > 0, "network: launched the client process")
	if not check(await wait_until(func() -> bool: return Game.world != null and Game.world.get_players().size() == 2, 20.0),
			"network: client player spawned on the host"):
		return
	for pl in Game.world.get_players():
		if pl.peer_id != Const.SERVER_PEER_ID:
			_client_id = pl.peer_id
	var cp := Game.get_player(_client_id)
	check(await wait_until(func() -> bool: return _client_step == "ready"), "network: client ready")
	var mgr := Game.world.items
	var can := mgr.server_spawn_item(Const.ITEM_WATERING_CAN, {}, cp.global_position + Vector3(0.7, 0, 0)) as WateringCan
	await frames(5)
	mgr.server_give_item(can, _client_id)
	_rpc_host_step.rpc_id(_client_id, "holding:" + String(can.name))
	check(await wait_until(func() -> bool: return _client_step == "held"), "network: client checked its view model")
	await frames(5)
	var socket := cp.get_node("%BodyHandSocket") as Node3D
	check(not can.is_in_view_model() and _all_on(can, WORLD) and not Game.local_player.is_view_model_active(),
			"network host: the client's can is on world layers, the host's view model idle")
	check(can.visible and can.global_position.distance_to((socket.global_transform * can._get_hold_transform()).origin) < 0.05,
			"network host: the can is drawn at the client's %BodyHandSocket")
	mgr.server_drop_item(can, cp.global_position + Vector3(0.7, 0, 0))
	_rpc_host_step.rpc_id(_client_id, "dropped")
	check(await wait_until(func() -> bool: return not OS.is_process_running(_pid), 25.0), "network: client finished")
	var code := OS.get_process_exit_code(_pid)
	check(code == 0, "network: client process exited with 0 (got %d)" % code)
	Game.return_to_menu("")
	await frames(3)

func _run_client(port: int) -> void:
	var err := Game.start_join("127.0.0.1", port, "Client")
	if err != OK or not await wait_until(func() -> bool: return Game.local_player != null, 20.0):
		print("FAIL: [client] could not join (err %s)" % error_string(err))
		_end(1)
		return
	var me := Game.local_player
	await frames(3)
	# At rest first: the camera moving in physics between the view-model sync (process) and a check reads as drift.
	check(await wait_until(func() -> bool: return me.is_on_floor() and me.velocity.length() < 0.001, 10.0),
			"client player standing still on the floor")
	check(me.uses_view_model() and me.get_view_model_viewport() != null, "joined: the client's own player has a view model")
	var host_player := Game.get_player(Const.SERVER_PEER_ID)
	check(host_player != null and not host_player.uses_view_model() and host_player.get_view_model_viewport() == null
			and _sub_viewports().size() == 1, "the host's player is remote here: no view model, one SubViewport total")
	check(_lights_shared(Game.world, me.camera), "client: world lights shared with its view model")
	_rpc_client_step.rpc_id(1, "ready")
	check(await wait_until(func() -> bool: return _host_step.begins_with("holding:")), "host put a can in our hands")
	var can_name := _host_step.substr(8)
	var items := Game.world.items
	check(await wait_until(func() -> bool:
			var c := items.get_node_or_null(NodePath(can_name)) as Item
			return c != null and c.holder_id == me.peer_id and c.is_in_view_model()), "client: the can is in our view model")
	var can := items.get_node(NodePath(can_name)) as WateringCan
	var baseline_ok := _all_on(can, VM)
	await frames(3)
	check(baseline_ok and _all_on(can, VM) and me.is_view_model_active()
			and me.get_view_model_viewport().render_target_update_mode == SubViewport.UPDATE_ALWAYS,
			"client: every mesh of the held can on the view-model layer, pass rendering")
	check(me.get_view_model_camera().global_transform.is_equal_approx(me.camera.global_transform),
			"client: view-model camera follows %Camera")
	_rpc_client_step.rpc_id(1, "held")
	check(await wait_until(func() -> bool: return _host_step == "dropped"), "host dropped the can")
	check(await wait_until(func() -> bool: return can.holder_id == 0 and not can.is_in_view_model()), "client: can on the floor")
	await frames(2)
	check(_all_on(can, WORLD) and not me.is_view_model_active(), "client: dropped can back on world layers, pass off")
	Game.return_to_menu("")
	await frames(4)
	check(Game.world == null and _sub_viewports().is_empty() and _view_model_nodes().is_empty(),
			"client: return_to_menu leaves no view-model nodes")
	# Report the end over a fresh connection is impossible (we left): the host watches the process exit instead.
	_end(1 if _fails > 0 else 0)

@rpc("any_peer", "call_remote", "reliable")
func _rpc_report(ok: bool) -> void:
	# Client checks are counted on the host as well, so the host's exit code covers both processes.
	if ok:
		_passes += 1
	else:
		_fails += 1

@rpc("any_peer", "call_remote", "reliable")
func _rpc_client_step(step: String) -> void:
	_client_step = step

@rpc("authority", "call_remote", "reliable")
func _rpc_host_step(step: String) -> void:
	_host_step = step

func _end(code: int) -> void:
	if _role == "host" and _pid > 0 and OS.is_process_running(_pid):
		OS.kill(_pid)
	Net.leave()
	get_tree().quit(code)
