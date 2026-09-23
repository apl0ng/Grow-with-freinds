extends Node
## Render check for the first-person view-model layer (task 9.6). Needs a real renderer (xvfb); under --headless
## it prints a hint and exits 0. Run it as a body of the generic launcher, in either renderer:
##
##   xvfb-run -a -s "-screen 0 1280x720x24" godot --path . --rendering-driver opengl3 \
##       --rendering-method gl_compatibility --resolution 1280x720 --audio-driver Dummy \
##       -s res://tools/tests/run_test.gd -- --body=res://tools/tests/review_viewmodel_preview.gd --out=/tmp/vm_gl
##   (Forward+, e.g. with Mesa lavapipe:  --rendering-driver vulkan --rendering-method forward_plus)
##
## Hosts a solo game and renders, from the local player's first-person camera:
##   wall_before_after.png   pushed into a wall holding the watering can: view model OFF (the old behaviour: the can
##                           clips) | view model ON (the can is whole)
##   tank_before_after.png   the same against the water tank (Well), looking down at it
##   remote_view.png         a second (remote) worker holding a can, seen from the local player (who holds one too:
##                           view model bottom right, the remote can in the world at the other body's hand) | the
##                           same remote worker from an overview camera (the local view model switches off)
##   resized.png             the window resized to 1000x700: the view model follows (size + placement)
## and prints PASS/FAIL lines: the share of the can's pixels (its view-model alpha mask) that actually show in each
## capture, the composite alignment, the SubViewport following the window.

const PORT := 29777
const THRESHOLD := 0.07 # colour distance at which a pixel counts as "changed by the can"

var _out := "user://viewmodel_preview"
var _passes := 0
var _fails := 0

func _ready() -> void:
	_run()

func check(cond: bool, what: String) -> bool:
	if cond:
		_passes += 1
	else:
		_fails += 1
	print("%s: %s" % ["PASS" if cond else "FAIL", what])
	return cond

func frames(n: int) -> void:
	for i in n:
		await get_tree().process_frame

func physics_frames(n: int) -> void:
	for i in n:
		await get_tree().physics_frame

func _run() -> void:
	await get_tree().process_frame
	var driver := RenderingServer.get_current_rendering_driver_name()
	if DisplayServer.get_name() == "headless" or driver == "" or driver == "dummy":
		print("review_viewmodel_preview: needs a real renderer (xvfb-run + --rendering-driver opengl3/vulkan); skipping")
		get_tree().quit(0)
		return
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--out="):
			_out = a.substr(6)
	DirAccess.make_dir_recursive_absolute(_out)
	var method := RenderingServer.get_current_rendering_method()
	print("review_viewmodel_preview: %s / %s, window %s -> %s" % [driver, method, get_tree().root.size, _out])
	Juice.enabled = false # items appear at full size at once (no pop-in scale while capturing)
	if not check(Game.start_host("Alice", PORT + randi() % 100) == OK, "hosted a solo game"):
		get_tree().quit(1)
		return
	await frames(30)
	var p: Player = Game.local_player
	var world: World = Game.world
	var mgr := world.items
	var can := mgr.server_spawn_item(Const.ITEM_WATERING_CAN, {}, Vector3(0, 0, 3.0), 1) as WateringCan
	await frames(10)
	check(can != null and can.is_in_view_model(), "the local player holds a watering can in the view model")

	# --- 1. pushed into a wall -------------------------------------------------------------------------------------
	# Walk into the west wall north of the tank (a plain cinder-block stretch) until the capsule touches it.
	await _walk_into(p, Vector3(-8.0, 0.0, -3.4), PI * 0.5, -0.12)
	await _before_after(p, can, "wall")

	# --- 2. pushed into the water tank ---------------------------------------------------------------------------------
	var well := world.room.get_station("Well") as Node3D
	var tank := well.global_position
	await _walk_into(p, tank + Vector3(2.2, 0.0, 0.25), PI * 0.5, -0.55)
	await _before_after(p, can, "tank")

	# --- 3. remote view ------------------------------------------------------------------------------------------------
	Net.players[2] = {"name": "Bob", "color": Net.PALETTE[1]}
	var bob := world.server_spawn_player(2)
	await frames(5)
	var can2 := mgr.server_spawn_item(Const.ITEM_WATERING_CAN, {"charges": 1}, Vector3(1, 0, 3.0), 2) as WateringCan
	p.place_at(Transform3D(Basis.IDENTITY, Vector3(0.0, 0.05, 3.2)))
	p.head.rotation.x = -0.12
	var bob_pos := Vector3(0.35, 0.05, 1.3)
	bob.net_position = bob_pos
	bob.net_yaw = PI - 0.5 # facing Alice, turned a little so the can at his hand shows
	bob.net_pitch = -0.1
	bob.position = bob_pos
	await frames(40)
	check(not can2.is_in_view_model() and can2.visible and _all_on(can2, Player.WORLD_RENDER_LAYER),
			"remote worker's can: world layers, visible")
	var socket := bob.get_node("%BodyHandSocket") as Node3D
	check(can2.global_position.distance_to((socket.global_transform * can2._get_hold_transform()).origin) < 0.02,
			"remote worker's can sits at his %BodyHandSocket")
	var first_person := await _capture()
	var cam := Camera3D.new()
	world.add_child(cam)
	cam.global_position = bob_pos + Vector3(-1.7, 1.45, -0.6)
	cam.look_at(bob_pos + Vector3(0.0, 1.0, 0.0))
	cam.fov = 60.0
	cam.current = true
	await frames(10)
	check(not p.is_view_model_active() and not can.is_in_view_model(),
			"overview camera current: the local view model switches off")
	var overview := await _capture()
	_side_by_side([first_person, overview], [Color(0.3, 0.5, 1.0), Color(0.3, 0.5, 1.0)], "remote_view.png")
	p.camera.current = true
	cam.queue_free()
	await frames(10)
	check(p.is_view_model_active() and can.is_in_view_model(), "back to the first-person camera: view model on again")

	# --- 4. resize -------------------------------------------------------------------------------------------------
	var root := get_tree().root
	root.size = Vector2i(1000, 700)
	await frames(10)
	var sv := p.get_view_model_viewport()
	check(root.size == Vector2i(1000, 700) and sv.size == Vector2i(1000, 700),
			"window resized to %s: the view-model SubViewport follows (%s)" % [root.size, sv.size])
	var resized := await _capture()
	var mask := _mask(p)
	check(_aligned(p, can, mask), "resized: the composite lines up with where %Camera projects the can")
	resized.save_png(_out.path_join("resized.png"))

	print("review_viewmodel_preview: %d passed, %d failed -> %s" % [_passes, _fails, ProjectSettings.globalize_path(_out)])
	Game.return_to_menu("")
	await frames(3)
	get_tree().quit(1 if _fails > 0 else 0)

## Places the player at `from` facing `yaw` (0 = -Z), pitches the head, then walks forward until blocked.
func _walk_into(p: Player, from: Vector3, yaw: float, pitch: float) -> void:
	p.place_at(Transform3D(Basis(Vector3.UP, yaw), from + Vector3(0, 0.05, 0)))
	p.head.rotation.x = pitch
	await physics_frames(10)
	Input.action_press(&"move_forward")
	var last := p.global_position
	var still := 0
	for i in 150:
		await get_tree().physics_frame
		still = still + 1 if p.global_position.distance_to(last) < 0.002 else 0
		last = p.global_position
		if still >= 8:
			break
	Input.action_release(&"move_forward")
	await physics_frames(10)
	p.head.rotation.x = pitch
	await frames(5)
	print("   player at %s facing yaw %.2f, pitch %.2f" % [p.global_position, p.rotation.y, p.head.rotation.x])

## Three captures of the same pose: without the can, view model OFF (world pass: clips), view model ON.
func _before_after(p: Player, can: Item, tag: String) -> void:
	await frames(4)
	var mask := _mask(p)
	var area := _count(mask)
	can.visible = false
	var empty := await _capture()
	can.visible = true
	p.view_model_enabled = false
	await frames(3)
	var before := await _capture()
	p.view_model_enabled = true
	await frames(3)
	var after := await _capture()
	mask = _mask(p)
	area = _count(mask)
	var shown_before := _shown(before, empty, mask)
	var shown_after := _shown(after, empty, mask)
	print("   %s: the can covers %d px; visible without the view model %.1f %%, with it %.1f %%"
			% [tag, area, 100.0 * shown_before / maxf(area, 1.0), 100.0 * shown_after / maxf(area, 1.0)])
	check(area > 2000, "%s: the can has a sizeable view-model mask (%d px)" % [tag, area])
	check(shown_before < 0.6 * area, "%s: without the view model the can clips (%.0f %% visible)" % [tag, 100.0 * shown_before / maxf(area, 1.0)])
	check(shown_after > 0.97 * area, "%s: with the view model the whole can shows (%.1f %%)" % [tag, 100.0 * shown_after / maxf(area, 1.0)])
	check(_aligned(p, can, mask), "%s: the composite lines up with where %%Camera projects the can" % tag)
	_side_by_side([before, after], [Color(0.9, 0.2, 0.2), Color(0.2, 0.8, 0.3)], "%s_before_after.png" % tag)

func _capture() -> Image:
	await RenderingServer.frame_post_draw
	await RenderingServer.frame_post_draw
	var img := get_viewport().get_texture().get_image()
	img.convert(Image.FORMAT_RGBA8)
	return img

## The can's pixels: alpha of the view-model SubViewport (rendered this frame; view model must be active).
func _mask(p: Player) -> Image:
	var img := p.get_view_model_viewport().get_texture().get_image()
	img.convert(Image.FORMAT_RGBA8)
	return img

func _count(mask: Image) -> int:
	var n := 0
	for y in mask.get_height():
		for x in mask.get_width():
			if mask.get_pixel(x, y).a > 0.5:
				n += 1
	return n

func _shown(img: Image, empty: Image, mask: Image) -> int:
	var n := 0
	if img.get_size() != mask.get_size() or empty.get_size() != mask.get_size():
		print("   size mismatch: capture %s, empty %s, mask %s" % [img.get_size(), empty.get_size(), mask.get_size()])
		return 0
	for y in mask.get_height():
		for x in mask.get_width():
			if mask.get_pixel(x, y).a <= 0.5:
				continue
			var a := img.get_pixel(x, y)
			var b := empty.get_pixel(x, y)
			if maxf(absf(a.r - b.r), maxf(absf(a.g - b.g), absf(a.b - b.b))) > THRESHOLD:
				n += 1
	return n

## The can's body centre projected by %Camera (canvas units -> pixels) falls inside the mask's bounding box.
func _aligned(p: Player, can: Item, mask: Image) -> bool:
	var body := can.get_node_or_null(^"Visual/Can") as MeshInstance3D
	var centre := body.global_transform * body.get_aabb().get_center() if body != null else can.global_position
	var canvas := p.camera.unproject_position(centre)
	var root := get_tree().root
	var px := canvas * Vector2(root.size) / root.get_visible_rect().size
	var used := mask.get_used_rect()
	var inside := Rect2i(Vector2i.ZERO, mask.get_size()).has_point(Vector2i(px))
	var ok := inside and used.has_area() and Rect2(used).grow(2.0).has_point(px) and mask.get_pixelv(Vector2i(px)).a > 0.5
	print("   can centre projects to %s px, mask box %s" % [px.round(), used])
	return ok

static func _all_on(item: Node, want: int) -> bool:
	for n in item.find_children("*", "GeometryInstance3D", true, false):
		if (n as GeometryInstance3D).layers != want:
			return false
	return true

## Saves images side by side with a 6 px gap and a coloured bar on top of each (red = before, green = after).
func _side_by_side(images: Array, bars: Array, file: String) -> void:
	var w := 0
	var h := 0
	for img: Image in images:
		w += img.get_width()
		h = maxi(h, img.get_height())
	w += 6 * (images.size() - 1)
	var bar := 8
	var out := Image.create(w, h + bar, false, Image.FORMAT_RGBA8)
	out.fill(Color(0.05, 0.05, 0.05))
	var x := 0
	for i in images.size():
		var img: Image = images[i]
		out.fill_rect(Rect2i(x, 0, img.get_width(), bar), bars[i])
		out.blit_rect(img, Rect2i(Vector2i.ZERO, img.get_size()), Vector2i(x, bar))
		x += img.get_width() + 6
	var path := _out.path_join(file)
	out.save_png(path)
	print("   saved %s" % ProjectSettings.globalize_path(path))
