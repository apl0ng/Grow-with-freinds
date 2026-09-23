extends SceneTree
## Renders art previews to PNG so the look can be checked without the editor (art agent tool).
## Needs a real renderer; under --headless it prints a hint and exits 0.
##
##   xvfb-run -a -s "-screen 0 1280x720x24" godot --path . --rendering-driver opengl3 \
##       --rendering-method gl_compatibility --resolution 1280x720 \
##       -s res://tools/tests/art_preview.gd -- --out=/tmp/art_preview [--shot=materials,ui,kit,juice]
##
## Shots: materials (every toon_*.tres on a sphere), ui (theme + every type variation),
## kit (reference diorama: plot stages, well, bin, items, players, shopkeeper), juice (mid-animation frames).
## Note: the preview uses the Compatibility renderer (llvmpipe); the game uses Forward+, which looks close.

const KitBuilder := preload("res://tools/tests/art_kit.gd")

var _out := "user://art_preview"

func _initialize() -> void:
	_run.call_deferred()

func _run() -> void:
	var driver := RenderingServer.get_current_rendering_driver_name()
	if DisplayServer.get_name() == "headless" or driver == "" or driver == "dummy":
		print("art_preview: needs a real renderer (run it under xvfb-run with --rendering-driver opengl3); skipping")
		quit(0)
		return
	var shots: PackedStringArray = ["materials", "ui", "kit", "juice"]
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--out="):
			_out = a.substr(6)
		elif a.begins_with("--shot="):
			shots = a.substr(7).split(",")
	DirAccess.make_dir_recursive_absolute(_out)
	for shot in shots:
		var node: Node = null
		match shot:
			"materials":
				node = _materials_scene()
			"ui":
				node = _ui_scene()
			"kit":
				node = KitBuilder.build_diorama()
			"juice":
				node = KitBuilder.build_diorama()
		if node == null:
			continue
		root.add_child(node)
		if node.has_node(^"ToonLighting"):
			_preview_safe_light(node.get_node(^"ToonLighting"))
		if shot == "kit":
			KitBuilder.aim_camera(node, 0)
		if shot == "juice":
			KitBuilder.aim_camera(node, 4)
			await _frames(4)
			KitBuilder.play_juice(node)
			await _frames(2)
		else:
			await _frames(8)
		_save(shot)
		if shot == "kit":
			for view in [1, 2, 3]:
				KitBuilder.aim_camera(node, view)
				await _frames(4)
				_save("kit_%d" % view)
		if shot == "juice":
			for i in 3:
				await _frames(3)
				_save("juice_%d" % (i + 1))
		node.queue_free()
		await _frames(2)
	print("art_preview: wrote %s" % ProjectSettings.globalize_path(_out))
	quit(0)

## The Compatibility renderer on llvmpipe roughly doubles the lit side of surfaces when a directional light
## casts shadows (extra additive shadow pass), which makes every colour look blown out. Forward+ (the game's
## renderer) does not do this, so previews render with sun shadows off to show true colours.
static func _preview_safe_light(lighting: Node) -> void:
	var sun := lighting.get_node_or_null("Sun") as DirectionalLight3D
	if sun:
		sun.shadow_enabled = false

func _frames(n: int) -> void:
	for i in n:
		await process_frame

func _save(name: String) -> void:
	var img := root.get_texture().get_image()
	var path := _out.path_join(name + ".png")
	img.save_png(path)
	print("art_preview: ", path)

# ------------------------------------------------------------------------------------------ materials
func _materials_scene() -> Node3D:
	var w := Node3D.new()
	var lighting: Node3D = (load("res://art/env/toon_lighting.tscn") as PackedScene).instantiate()
	w.add_child(lighting)
	# Light from the upper right so the toon terminator + rim are visible on every swatch.
	(lighting.get_node("Sun") as Node3D).rotation_degrees = Vector3(-35, 70, 0)
	_preview_safe_light(lighting)
	var names: Array[String] = []
	var dir := DirAccess.open("res://art/materials")
	for f in dir.get_files():
		if f.ends_with(".tres") and f.begins_with("toon_") and not f.begins_with("toon_outline"):
			names.append(f.get_basename())
	names.sort()
	var cols := 9
	var floor_mi := MeshInstance3D.new()
	var floor_mesh := BoxMesh.new()
	floor_mesh.size = Vector3(16, 0.1, 9)
	floor_mi.mesh = floor_mesh
	floor_mi.material_override = load("res://art/materials/toon_floor.tres")
	floor_mi.position = Vector3(0, -0.5, -2.2)
	w.add_child(floor_mi)
	for i in names.size():
		var x := (i % cols - (cols - 1) * 0.5) * 1.3
		var z := -float(i / cols) * 1.45
		var mi := MeshInstance3D.new()
		var sm := SphereMesh.new()
		sm.radius = 0.42
		sm.height = 0.84
		mi.mesh = sm
		mi.material_override = load("res://art/materials/%s.tres" % names[i])
		if i % 2 == 0:
			mi.material_overlay = load("res://art/materials/toon_outline.tres")
		mi.position = Vector3(x, 0, z)
		w.add_child(mi)
		var l := Label3D.new()
		l.text = names[i].trim_prefix("toon_")
		l.font_size = 64
		l.outline_size = 18
		l.pixel_size = 0.0035
		l.billboard = BaseMaterial3D.BILLBOARD_ENABLED
		l.no_depth_test = true
		l.position = Vector3(x, -0.38, z + 0.45)
		w.add_child(l)
	# The optional hand-written shader (compiles only under a real renderer, so it is checked here).
	var sh := MeshInstance3D.new()
	var shm := SphereMesh.new()
	shm.radius = 0.42
	shm.height = 0.84
	sh.mesh = shm
	sh.material_override = load("res://art/shaders/toon_example.tres")
	sh.position = Vector3((names.size() % cols - (cols - 1) * 0.5) * 1.3, 0, -float(names.size() / cols) * 1.45)
	w.add_child(sh)
	var shl := Label3D.new()
	shl.text = "toon.gdshader"
	shl.font_size = 64
	shl.outline_size = 18
	shl.pixel_size = 0.0035
	shl.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	shl.no_depth_test = true
	shl.position = sh.position + Vector3(0, -0.38, 0.45)
	w.add_child(shl)
	var cam := Camera3D.new()
	cam.fov = 42
	w.add_child(cam)
	cam.position = Vector3(0, 6.5, 9.0)
	cam.look_at_from_position(cam.position, Vector3(0, -0.4, -2.3))
	cam.current = true
	return w

# ------------------------------------------------------------------------------------------------- ui
func _ui_scene() -> Control:
	var ui := Control.new()
	ui.set_anchors_preset(Control.PRESET_FULL_RECT)
	ui.theme = load("res://art/ui/theme.tres")
	var bg := TextureRect.new()
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	var grad := Gradient.new()
	grad.set_color(0, Color("8fd3ff"))
	grad.set_color(1, Color("5fae4a"))
	var gt := GradientTexture2D.new()
	gt.gradient = grad
	gt.fill_from = Vector2(0, 0)
	gt.fill_to = Vector2(0, 1)
	bg.texture = gt
	bg.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	bg.stretch_mode = TextureRect.STRETCH_SCALE
	ui.add_child(bg)

	# Left column: menu panel
	var menu := PanelContainer.new()
	menu.position = Vector2(24, 24)
	menu.size = Vector2(380, 0)
	ui.add_child(menu)
	var mv := VBoxContainer.new()
	menu.add_child(mv)
	_lbl(mv, "Grow With Friends", &"TitleLabel")
	_lbl(mv, "Header 32px", &"HeaderLabel")
	_lbl(mv, "Body text 20px: plant, water, harvest, sell!", &"")
	_lbl(mv, "SubtleLabel 16px hint text", &"SubtleLabel")
	var le := LineEdit.new()
	le.text = "Alice"
	mv.add_child(le)
	var le2 := LineEdit.new()
	le2.placeholder_text = "127.0.0.1"
	mv.add_child(le2)
	var cb := CheckBox.new()
	cb.text = "Fullscreen"
	cb.button_pressed = true
	mv.add_child(cb)
	var cb2 := CheckBox.new()
	cb2.text = "Unchecked"
	mv.add_child(cb2)
	var cbt := CheckButton.new()
	cbt.text = "Music"
	cbt.button_pressed = true
	mv.add_child(cbt)
	var hs := HSlider.new()
	hs.value = 60
	mv.add_child(hs)
	var big := Button.new()
	big.text = "HOST GAME"
	big.theme_type_variation = &"BigButton"
	mv.add_child(big)
	var row := HBoxContainer.new()
	mv.add_child(row)
	for v in [["Join", &""], ["Pressed", &""], ["Quit", &"DangerButton"]]:
		var b := Button.new()
		b.text = v[0]
		b.theme_type_variation = v[1]
		if v[0] == "Pressed":
			b.toggle_mode = true
			b.button_pressed = true
		row.add_child(b)
	var row2 := HBoxContainer.new()
	mv.add_child(row2)
	var gb := Button.new()
	gb.text = "Buy $45"
	gb.theme_type_variation = &"GoldButton"
	row2.add_child(gb)
	var db := Button.new()
	db.text = "Disabled"
	db.disabled = true
	row2.add_child(db)
	var sb := Button.new()
	sb.text = "Small"
	sb.theme_type_variation = &"SmallButton"
	row2.add_child(sb)

	# Middle: shop tabs with cards
	var tabs := TabContainer.new()
	tabs.position = Vector2(520, 250)
	tabs.size = Vector2(470, 300)
	ui.add_child(tabs)
	var seeds := HBoxContainer.new()
	seeds.name = "Seeds"
	tabs.add_child(seeds)
	var up := VBoxContainer.new()
	up.name = "Upgrades"
	tabs.add_child(up)
	for s in [["Budget Bud", "$20", Color(0.55, 0.85, 0.35)], ["Purple Haze", "$45", Color(0.7, 0.45, 0.9)], ["Golden Kush", "$90", Color(1, 0.8, 0.25)]]:
		var card := PanelContainer.new()
		card.theme_type_variation = &"Card"
		card.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		seeds.add_child(card)
		var cv := VBoxContainer.new()
		card.add_child(cv)
		var sw := ColorRect.new()
		sw.color = s[2]
		sw.custom_minimum_size = Vector2(0, 60)
		cv.add_child(sw)
		_lbl(cv, s[0], &"")
		_lbl(cv, s[1], &"MoneyLabel")
		_lbl(cv, "Grows fast", &"SubtleLabel")
		var buy := Button.new()
		buy.text = "Buy"
		buy.theme_type_variation = &"GoldButton"
		cv.add_child(buy)

	# Top: HUD mock
	var quota := ProgressBar.new()
	quota.theme_type_variation = &"QuotaBar"
	quota.position = Vector2(520, 24)
	quota.size = Vector2(390, 44)
	quota.value = 62
	quota.show_percentage = false
	ui.add_child(quota)
	var ql := Label.new()
	ql.theme_type_variation = &"HudLabel"
	ql.text = "$248 / $400"
	ql.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	ql.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	ql.set_anchors_preset(Control.PRESET_FULL_RECT)
	quota.add_child(ql)
	var hud := PanelContainer.new()
	hud.theme_type_variation = &"HudPanel"
	hud.position = Vector2(930, 20)
	ui.add_child(hud)
	var hh := HBoxContainer.new()
	hud.add_child(hh)
	_lbl(hh, "$1,250", &"MoneyLabel")
	_lbl(hh, "2:37", &"TimerLabel")
	var hud2 := PanelContainer.new()
	hud2.theme_type_variation = &"HudPanel"
	hud2.position = Vector2(520, 84)
	ui.add_child(hud2)
	var prompt := HBoxContainer.new()
	hud2.add_child(prompt)
	var keycap := PanelContainer.new()
	keycap.theme_type_variation = &"KeyCap"
	keycap.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	prompt.add_child(keycap)
	_lbl(keycap, "E", &"KeyCapLabel")
	_lbl(prompt, "Water plant", &"HudLabel")
	var dot := Panel.new()
	dot.theme_type_variation = &"CrosshairDot"
	dot.position = Vector2(1000, 560)
	dot.size = Vector2(10, 10)
	ui.add_child(dot)
	_lbl(ui, "Round 3", &"HudLabel").position = Vector2(790, 90)
	var tv := VBoxContainer.new()
	tv.position = Vector2(1010, 100)
	ui.add_child(tv)
	for t in [["Toast", "Round started!"], ["ToastError", "Hands full"], ["ToastSuccess", "+$120 sold!"]]:
		var tp := PanelContainer.new()
		tp.theme_type_variation = t[0]
		tv.add_child(tp)
		_lbl(tp, t[1], &"HudLabel")
	var pv := VBoxContainer.new()
	pv.position = Vector2(1010, 330)
	pv.custom_minimum_size = Vector2(240, 0)
	ui.add_child(pv)
	for v in [0.0, 4.0, 50.0, 100.0]:
		var pb := ProgressBar.new()
		pb.value = v
		pb.custom_minimum_size = Vector2(240, 26)
		pv.add_child(pb)
	var banner := _lbl(ui, "ROUND COMPLETE!", &"BannerLabel")
	banner.position = Vector2(520, 575)
	_lbl(ui, "Error: not enough money", &"ErrorLabel").position = Vector2(520, 668)
	_lbl(ui, "Success: purchased!", &"SuccessLabel").position = Vector2(840, 668)
	big.grab_focus.call_deferred()
	return ui

func _lbl(parent: Node, text: String, variation: StringName) -> Label:
	var l := Label.new()
	l.text = text
	l.theme_type_variation = variation
	parent.add_child(l)
	return l
