extends SceneTree
## Headless test for the art layer (materials, theme, Toon, Sfx, Juice, face prop). Exit code 0 = pass.
##   godot --headless --path . -s res://tools/tests/art_test.gd
## (add --fixed-fps 60 to make it finish in ~1 s of wall time; it also passes without it, ~4 s).

const REQUIRED_MATERIALS: Array[String] = [
	"red", "orange", "yellow", "lime", "green", "teal", "blue", "purple", "pink", "brown", "wood", "soil",
	"soil_wet", "water", "leaf", "bud", "white", "gray", "dark", "floor", "wall", "metal", "skin",
]
const EXTRA_MATERIALS: Array[String] = [
	"gold", "cream", "stone", "leaf_dry", "eye_white", "eye_black", "blush", "sparkle", "glass",
	"blob_shadow", "outline", "outline_thin", "eyelid", "eyebag",
]
## variation -> [base type, expected font size or -1]
const VARIATIONS := {
	&"TitleLabel": [&"Label", 48], &"BannerLabel": [&"Label", 72], &"HeaderLabel": [&"Label", 32],
	&"HudLabel": [&"Label", 24], &"MoneyLabel": [&"Label", 32], &"TimerLabel": [&"Label", 32],
	&"SubtleLabel": [&"Label", 16], &"ErrorLabel": [&"Label", 20], &"SuccessLabel": [&"Label", 20],
	&"BigButton": [&"Button", 30], &"DangerButton": [&"Button", -1], &"GoldButton": [&"Button", -1],
	&"SmallButton": [&"Button", 16], &"HudPanel": [&"PanelContainer", -1], &"Toast": [&"PanelContainer", -1],
	&"ToastError": [&"PanelContainer", -1], &"ToastSuccess": [&"PanelContainer", -1],
	&"Card": [&"PanelContainer", -1], &"QuotaBar": [&"ProgressBar", 22], &"OverlayPanel": [&"Panel", -1],
	&"CrosshairDot": [&"Panel", -1], &"KeyCap": [&"PanelContainer", -1], &"KeyCapLabel": [&"Label", 20],
}
const CONTRACT_SOUNDS: Array[StringName] = [
	&"buy", &"plant", &"water", &"harvest", &"sell", &"pickup", &"drop", &"error", &"grow", &"round_win",
	&"round_lose", &"tick", &"ui_click", &"ui_open", &"ui_close",
]

var _fails: PackedStringArray = []
var _checks := 0

func _initialize() -> void:
	# Watchdog: a script error inside _run would otherwise leave the SceneTree running forever.
	create_timer(60.0).timeout.connect(func() -> void:
		printerr("art_test: WATCHDOG timeout")
		quit(2))
	_run.call_deferred()

func _check(ok: bool, what: String) -> void:
	_checks += 1
	if not ok:
		_fails.append(what)
		printerr("  FAIL: " + what)

func _frames(n: int) -> void:
	for i in n:
		await process_frame

func _wait(seconds: float) -> void:
	await create_timer(seconds).timeout

func _run() -> void:
	print("art_test: materials")
	_test_materials()
	print("art_test: theme")
	await _test_theme()
	print("art_test: toon + props")
	await _test_toon_and_props()
	print("art_test: sfx")
	await _test_sfx()
	print("art_test: juice")
	await _test_juice()
	await _frames(60)
	# Let the audio mixer retire every playback before quitting (avoids a harmless leak warning).
	var sfx: Node = root.get_node_or_null(^"Sfx")
	if sfx:
		sfx.stop_all()
	for i in 8:
		OS.delay_msec(10)
		await process_frame
	print("art_test: %d checks, %d failures" % [_checks, _fails.size()])
	for f in _fails:
		print("  FAIL: " + f)
	quit(1 if _fails.size() > 0 else 0)

# ------------------------------------------------------------------------------------------ materials
func _test_materials() -> void:
	for n in REQUIRED_MATERIALS + EXTRA_MATERIALS:
		var path := "res://art/materials/toon_%s.tres" % n
		var m := load(path) as StandardMaterial3D
		_check(m != null, "material loads: " + path)
		if m == null:
			continue
		if n in REQUIRED_MATERIALS or n in ["gold", "cream", "stone", "leaf_dry"]:
			_check(m.diffuse_mode == BaseMaterial3D.DIFFUSE_TOON, n + " uses DIFFUSE_TOON")
			_check(m.specular_mode == BaseMaterial3D.SPECULAR_TOON, n + " uses SPECULAR_TOON")
			_check(m.rim_enabled and m.rim > 0.0, n + " has rim light")
			_check(m.roughness < 0.95, n + " roughness < 0.95 (rim would flatten the colour)")
			_check(m.rim <= 0.2, n + " rim toned down (mood: <= 0.2, got %.2f)" % m.rim)
	for n in ["bud", "water", "gold"]:
		var m := load("res://art/materials/toon_%s.tres" % n) as StandardMaterial3D
		_check(m != null and m.emission_enabled and m.emission_energy_multiplier <= 0.15, n + " glows only faintly (mood)")
	var blush := load("res://art/materials/toon_blush.tres") as StandardMaterial3D
	_check(blush != null and blush.albedo_color.a <= 0.25 and blush.albedo_color.s < 0.3, "blush is a faint grey flush, not pink (mood)")
	var o := load("res://art/materials/toon_outline.tres") as StandardMaterial3D
	_check(o != null and o.grow and o.cull_mode == BaseMaterial3D.CULL_FRONT, "outline = grow + cull front")
	var env := load("res://art/env/toon_environment.tres") as Environment
	_check(env != null, "toon_environment loads")
	if env:
		_check(env.ambient_light_energy <= 0.5 and env.ambient_light_color.b > env.ambient_light_color.r, "ambient is dim and cold (mood)")
		_check(env.background_color.v < 0.5 and not env.glow_enabled, "background darker, no glow (mood)")
	var vig := load("res://art/props/vignette.tscn") as PackedScene
	_check(vig != null and vig.can_instantiate(), "vignette.tscn loads")
	if vig:
		var vi := vig.instantiate()
		_check(vi is CanvasLayer and (vi as CanvasLayer).layer < 0, "vignette is a CanvasLayer below the HUD")
		var shade := vi.get_node_or_null(^"Shade") as Control
		_check(shade != null and shade.mouse_filter == Control.MOUSE_FILTER_IGNORE, "vignette ignores the mouse")
		vi.free()
	var lighting := load("res://art/env/toon_lighting.tscn") as PackedScene
	_check(lighting != null and lighting.can_instantiate(), "toon_lighting.tscn instantiates")
	if lighting:
		var li := lighting.instantiate()
		_check(li.get_node_or_null(^"WorldEnvironment") is WorldEnvironment and li.get_node_or_null(^"Sun") is DirectionalLight3D, "toon_lighting has WorldEnvironment + Sun")
		li.free()
	var sh := load("res://art/shaders/toon_example.tres") as ShaderMaterial
	_check(sh != null and sh.shader != null, "shader example loads")

# ---------------------------------------------------------------------------------------------- theme
func _test_theme() -> void:
	var th := load("res://art/ui/theme.tres") as Theme
	_check(th != null, "theme loads")
	if th == null:
		return
	_check(ProjectSettings.get_setting("gui/theme/custom", "") == "res://art/ui/theme.tres", "theme is the project theme")
	_check(th.default_font_size == 20, "default font size 20")
	_check(th.default_font != null, "default font set (bold variation)")
	for v: StringName in VARIATIONS:
		var spec: Array = VARIATIONS[v]
		_check(th.is_type_variation(v, spec[0]), "variation %s -> %s" % [v, spec[0]])
	for t in ["normal", "hover", "pressed", "disabled", "focus"]:
		_check(th.has_stylebox(t, &"Button"), "Button/" + t)
	for t in ["normal", "focus", "read_only"]:
		_check(th.has_stylebox(t, &"LineEdit"), "LineEdit/" + t)
	for t in ["background", "fill"]:
		_check(th.has_stylebox(t, &"ProgressBar"), "ProgressBar/" + t)
		_check(th.has_stylebox(t, &"QuotaBar"), "QuotaBar/" + t)
	for t in ["tab_selected", "tab_unselected", "tab_hovered", "panel"]:
		_check(th.has_stylebox(t, &"TabContainer"), "TabContainer/" + t)
	for t in ["checked", "unchecked", "radio_checked", "radio_unchecked"]:
		_check(th.get_icon(t, &"CheckBox") is DPITexture, "CheckBox icon " + t)
	_check(th.has_stylebox(&"panel", &"PanelContainer") and th.has_stylebox(&"panel", &"Panel"), "panel styles")
	var sb := th.get_stylebox(&"panel", &"PanelContainer") as StyleBoxFlat
	_check(sb != null and sb.corner_radius_top_left >= 16, "panels are rounded")
	# Resolution through real controls using the PROJECT theme (no explicit .theme on the nodes).
	var ui := Control.new()
	root.add_child(ui)
	var probes := {}
	for v: StringName in VARIATIONS:
		var base: StringName = VARIATIONS[v][0]
		var c: Control = ClassDB.instantiate(base)
		c.theme_type_variation = v
		ui.add_child(c)
		probes[v] = c
	var plain := Label.new()
	ui.add_child(plain)
	await _frames(2)
	for v: StringName in VARIATIONS:
		var want: int = VARIATIONS[v][1]
		var c: Control = probes[v]
		if want > 0:
			_check(c.get_theme_font_size(&"font_size") == want, "%s resolves font_size %d (got %d)" % [v, want, c.get_theme_font_size(&"font_size")])
	_check(plain.get_theme_font_size(&"font_size") == 20, "plain Label resolves 20px")
	_check((probes[&"HudPanel"] as Control).get_theme_stylebox(&"panel") == th.get_stylebox(&"panel", &"HudPanel"), "HudPanel stylebox resolves")
	_check((probes[&"QuotaBar"] as Control).get_theme_stylebox(&"fill") == th.get_stylebox(&"fill", &"QuotaBar"), "QuotaBar fill resolves")
	_check((probes[&"Card"] as Control).get_theme_stylebox(&"panel") != th.get_stylebox(&"panel", &"PanelContainer"), "Card differs from Panel")
	var err_panel := (probes[&"ToastError"] as Control).get_theme_stylebox(&"panel") as StyleBoxFlat
	_check(err_panel != null and err_panel.bg_color.is_equal_approx(Toon.ERROR), "ToastError is red")
	var cb := CheckBox.new()
	ui.add_child(cb)
	await _frames(1)
	_check(cb.get_theme_stylebox(&"normal") is StyleBoxEmpty, "CheckBox does not inherit the Button pill")
	ui.queue_free()
	await _frames(1)

# --------------------------------------------------------------------------------------- toon + props
func _test_toon_and_props() -> void:
	var a := Toon.material(Color(0.2, 0.8, 0.3))
	var b := Toon.material(Color(0.2, 0.8, 0.3))
	_check(a == b, "Toon.material caches per colour")
	_check(a.diffuse_mode == BaseMaterial3D.DIFFUSE_TOON, "Toon.material is toon")
	_check(Toon.material(Color.RED, Toon.Finish.GLOW).emission_enabled, "Toon GLOW finish emits")
	_check(Toon.material(Color.RED, Toon.Finish.FLAT).shading_mode == BaseMaterial3D.SHADING_MODE_UNSHADED, "Toon FLAT is unshaded")
	_check(Toon.lib(&"leaf") == load("res://art/materials/toon_leaf.tres"), "Toon.lib returns the library material")
	_check(Toon.outline() is StandardMaterial3D and Toon.outline(true) is StandardMaterial3D, "Toon.outline loads")
	var lib_red := load("res://art/materials/toon_red.tres") as StandardMaterial3D
	_check(lib_red.albedo_color.is_equal_approx(Toon.TOMATO), "library red == Toon.TOMATO (generator in sync)")
	var raw := Color("ff5a5f")
	var g := Toon.grade(raw)
	_check(g.s < raw.s and g.v < raw.v, "Toon.grade darkens + desaturates")
	_check(g.is_equal_approx(Toon.TOMATO) or g.to_html(false) == Toon.TOMATO.to_html(false) or absf(g.r - Toon.TOMATO.r) < 0.01, "palette constants are grade(base hue)")
	_check(Toon.tint(raw) == Toon.material(Toon.grade(raw)), "Toon.tint = material(grade(c))")
	var face_scene := load("res://art/props/face.tscn") as PackedScene
	_check(face_scene != null and face_scene.can_instantiate(), "face.tscn loads")
	if face_scene:
		var face := face_scene.instantiate() as ToonFace
		_check(face != null, "face root is ToonFace")
		if face:
			_check(face.find_child("Blush*", true, false) == null, "face has no blush (mood)")
			_check(face.find_child("Lid", true, false) != null and face.find_child("MouthL", true, false) != null, "face has lids + mouth")
			root.add_child(face)
			await _frames(1)
			_check(face.mood == &"sad", "default mood is sad")
			for m: StringName in [&"tired", &"grim", &"neutral", &"sad"]:
				face.set_mood(m)
				await _frames(1)
				_check(face.mood == m, "set_mood(%s)" % m)
			face.set_happy(true)
			_check(face.mood == &"neutral", "set_happy(true) is at most neutral")
			face.set_happy(false)
			_check(face.mood == &"sad", "set_happy(false) -> default mood")
			face.set_mood(&"ecstatic")   # unknown -> warns, falls back to sad
			_check(face.mood == &"sad", "unknown mood falls back to sad")
			face.blink()
			face.surprise()
			face.look(Vector2(1, 0.5))
			face.show_blush = true       # deprecated no-op
			await _wait(0.6)
			_check(face.mood == &"sad", "surprise returns to the mood")
			var mouth_l := face.find_child("MouthL", true, false) as Node3D
			_check(mouth_l != null and mouth_l.position.y < -0.005, "sad mouth is a frown (segments droop)")
			face.queue_free()
		# Null-safety: a Blender-style face with parts under a "Visual" child and most parts missing.
		var partial := Node3D.new()
		partial.set_script(load("res://scripts/art/toon_face.gd"))
		var visual := Node3D.new()
		visual.name = "Visual"
		partial.add_child(visual)
		var eye := Node3D.new()
		eye.name = "EyeL"
		visual.add_child(eye)
		root.add_child(partial)
		await _frames(1)
		var pf := partial as ToonFace
		pf.set_mood(&"tired")
		pf.blink()
		pf.surprise()
		pf.look(Vector2.ONE)
		pf.set_happy(true)
		await _wait(0.5)
		_check(pf.mood == &"neutral" and is_equal_approx(eye.scale.y, 1.0), "partial face (EyeL under Visual only) works null-safe")
		partial.queue_free()
		await _frames(1)

# ------------------------------------------------------------------------------------------------ sfx
func _test_sfx() -> void:
	var sfx: Node = root.get_node_or_null(^"Sfx")
	_check(sfx != null, "Sfx autoload present")
	if sfx == null:
		return
	var names: Array[StringName] = sfx.get_sound_names()
	for n in CONTRACT_SOUNDS:
		_check(names.has(n), "Sfx has contract sound " + n)
	# Play everything 2D and 3D straight away (before the worker finished: exercises on-demand synthesis).
	for n in names:
		sfx.play(n)
		sfx.play(n, Vector3(1, 0, 2))
	sfx.play(&"definitely_not_a_sound")   # warns once, must not crash
	sfx.wait_until_ready()
	_check(sfx.is_ready(), "Sfx synthesised everything")
	for n in names:
		var w: AudioStreamWAV = sfx.get_stream(n)
		_check(w != null and w.format == AudioStreamWAV.FORMAT_16_BITS and w.data.size() > 200, "stream ok: " + n)
		if w == null:
			continue
		var count := w.data.size() / 2
		var peak := 0
		for i in range(0, count, 3):
			peak = maxi(peak, absi(w.data.decode_s16(i * 2)))
		var tail := absi(w.data.decode_s16((count - 1) * 2))
		_check(peak > 16000 and peak <= 32767, "%s normalised (peak %d)" % [n, peak])
		_check(tail < 2500, "%s ends quietly, no click (last sample %d)" % [n, tail])
	for i in 60:
		sfx.play(CONTRACT_SOUNDS[i % CONTRACT_SOUNDS.size()], Vector3(i, 0, 0))
	_check(sfx.get_active_voice_count() <= sfx.MAX_2D + sfx.MAX_3D, "voice cap respected")
	await _frames(5)

# ---------------------------------------------------------------------------------------------- juice
func _test_juice() -> void:
	var juice: Node = root.get_node_or_null(^"Juice")
	_check(juice != null, "Juice autoload present")
	if juice == null:
		return
	var world := Node3D.new()
	world.name = "TestWorld"
	root.add_child(world)
	var n3 := Node3D.new()
	n3.scale = Vector3(2, 2, 2)
	world.add_child(n3)
	var ctrl := Label.new()
	ctrl.text = "$1,250"
	root.add_child(ctrl)
	await _frames(1)

	juice.pop_in(n3)
	juice.pop_in(ctrl, 0.25)
	await _frames(2)
	_check(n3.scale.x < 2.0, "pop_in starts small")
	await _wait(0.5)
	_check(n3.scale.is_equal_approx(Vector3(2, 2, 2)), "pop_in ends at rest scale (got %s)" % n3.scale)
	_check(ctrl.scale.is_equal_approx(Vector2.ONE), "Control pop_in ends at 1")

	juice.bounce(n3, 0.3)
	juice.bounce(n3, 0.3)   # re-trigger mid-animation must not drift
	await _frames(3)
	_check(not n3.scale.is_equal_approx(Vector3(2, 2, 2)), "bounce deforms")
	await _wait(0.5)
	_check(n3.scale.is_equal_approx(Vector3(2, 2, 2)), "bounce returns to rest (got %s)" % n3.scale)

	juice.pulse(n3)
	await _wait(0.25)
	_check(not n3.scale.is_equal_approx(Vector3(2, 2, 2)), "pulse animates")
	juice.bounce(n3, 0.2)       # interrupts the pulse, pulse resumes after
	await _wait(0.5)
	_check(n3.has_meta(juice.META_TWEEN), "pulse resumed after bounce")
	juice.stop(n3)
	_check(n3.scale.is_equal_approx(Vector3(2, 2, 2)), "stop restores rest scale")
	await _wait(0.2)
	_check(n3.scale.is_equal_approx(Vector3(2, 2, 2)), "stop really stops")

	juice.punch_ui(ctrl)
	await _frames(2)
	_check(not ctrl.scale.is_equal_approx(Vector2.ONE), "punch_ui scales")
	await _wait(0.45)
	_check(ctrl.scale.is_equal_approx(Vector2.ONE), "punch_ui returns to 1 (got %s)" % ctrl.scale)

	juice.grow_to(n3, Vector3(3, 3, 3), 0.2)
	await _wait(0.4)
	_check(n3.scale.is_equal_approx(Vector3(3, 3, 3)), "grow_to reaches target (got %s)" % n3.scale)
	juice.bounce(n3)
	await _wait(0.5)
	_check(n3.scale.is_equal_approx(Vector3(3, 3, 3)), "bounce after grow_to keeps new rest scale")

	juice.pop_out(ctrl, 0.1)
	await _wait(0.3)
	_check(not ctrl.visible and ctrl.scale.is_equal_approx(Vector2.ONE), "pop_out hides and keeps rest scale")
	juice.pop_in(ctrl)
	await _wait(0.5)
	_check(ctrl.visible and ctrl.scale.is_equal_approx(Vector2.ONE), "pop_in after pop_out")

	var rot_before := n3.rotation
	juice.shake(n3)
	juice.shake(ctrl)
	await _wait(0.55)
	_check(n3.rotation.is_equal_approx(rot_before) and is_zero_approx(ctrl.rotation), "shake restores rotation")

	# Freed mid-tween must be harmless.
	var doomed := Node3D.new()
	world.add_child(doomed)
	juice.pop_in(doomed)
	juice.pulse(doomed)
	juice.shake(doomed)
	await _frames(2)
	doomed.queue_free()
	var doomed_ui := Button.new()
	root.add_child(doomed_ui)
	juice.punch_ui(doomed_ui)
	await _frames(1)
	doomed_ui.free()
	await _frames(3)
	juice.stop(null)
	juice.bounce(null)

	# 3D spawns: all free themselves.
	var before := _count_fx()
	juice.burst(Vector3(0, 1, 0), Color("ff5a5f"))
	juice.burst(Vector3(0, 1, 0), Color("4fcb6b"), 30)
	juice.float_text(Vector3(0, 2, 0), "+$120", Color("ffd23f"))
	juice.puff(Vector3.ZERO)
	juice.splash(Vector3.ZERO)
	juice.sparkle(Vector3.ZERO)
	await _frames(2)
	_check(_count_fx() > before, "3D effects spawned")
	await _wait(3.5)
	_check(_count_fx() == before, "3D effects freed themselves (left: %d)" % (_count_fx() - before))
	# MOOD: confetti is a no-op unless celebration is explicitly allowed.
	_check(juice.allow_celebration == false, "celebration is off by default")
	juice.confetti(Vector3.ZERO)
	await _frames(2)
	_check(_count_fx() == before, "confetti does nothing by default")
	juice.allow_celebration = true
	juice.confetti(Vector3.ZERO)
	juice.sparkle(Vector3.ZERO)
	juice.burst(Vector3.ZERO, Color.RED)
	await _frames(2)
	_check(_count_fx() > before, "confetti works when allow_celebration")
	juice.allow_celebration = false
	await _wait(3.0)
	_check(_count_fx() == before, "celebration effects freed themselves")
	world.queue_free()
	ctrl.queue_free()

func _count_fx() -> int:
	var c := 0
	for n in root.find_children("*", "CPUParticles3D", true, false):
		c += 1
	for n in root.find_children("FloatText*", "Label3D", true, false):
		c += 1
	for n in root.find_children("JuiceFlash*", "MeshInstance3D", true, false):
		c += 1
	return c
