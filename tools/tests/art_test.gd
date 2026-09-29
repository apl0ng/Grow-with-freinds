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
## M10 friendslop set (CONTRACTS.md "Sounds added by the lead"); hum and keys are loops.
const M10_SOUNDS: Array[StringName] = [
	&"step", &"throw", &"bonk", &"shove", &"ping", &"chat", &"alarm", &"power_down", &"power_up", &"keys",
	&"write_up", &"door_slam", &"confiscate", &"hum", &"rat",
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
	for n in M10_SOUNDS:
		_check(names.has(n), "Sfx has M10 sound " + n)
	for n: StringName in sfx.LOOPING:
		_check(names.has(n), "looping sound is a sound: " + n)
	# Play everything 2D and 3D straight away (before the worker finished: exercises on-demand synthesis).
	for n in names:
		sfx.play(n)
		sfx.play(n, Vector3(1, 0, 2))
	sfx.play(&"definitely_not_a_sound")   # warns once, must not crash
	sfx.wait_until_ready()
	_check(sfx.is_ready(), "Sfx synthesised everything")
	# Every stream: 16-bit mono 22.05 kHz, peak-normalised to 0.89, no DC offset, no clipping, quiet ends.
	# The table (loudest first) is for the lead: loud = 20*log10(rms) + SETTINGS volume, in dB.
	print("  sound          sec   peak    rms      dc    rmsdB   vol   loud")
	var rows: Array = []
	for n in names:
		var w: AudioStreamWAV = sfx.get_stream(n)
		_check(w != null and w.format == AudioStreamWAV.FORMAT_16_BITS and w.data.size() > 200, "stream ok: " + n)
		if w == null:
			continue
		_check(w.mix_rate == sfx.MIX_RATE and not w.stereo, "%s is mono %d Hz" % [n, sfx.MIX_RATE])
		var m: Dictionary = sfx.measure(w)
		var count: int = m.samples
		_check(count * 2 == w.data.size() and m.seconds > 0.02, "%s measure() sizes (samples %d, %.3f s)" % [n, count, m.seconds])
		_check(m.peak >= 0.85 and m.peak <= 0.9, "%s normalised (peak %.3f)" % [n, m.peak])
		_check(absf(m.dc) < 0.01, "%s no DC offset (dc %.4f)" % [n, m.dc])
		_check(m.clipped == 0, "%s no clipping (%d samples at full scale)" % [n, m.clipped])
		_check(m.rms > 0.01, "%s not silent (rms %.3f)" % [n, m.rms])
		var first := absi(w.data.decode_s16(0))
		var tail := absi(w.data.decode_s16((count - 1) * 2))
		var looping: bool = sfx.LOOPING.has(n)
		_check(first < 1000, "%s starts quietly, no click (first sample %d)" % [n, first])
		if not looping:   # a seamless loop may end mid-slope (hum: one 60 Hz step from zero); the wrap test below covers it
			_check(tail < 1000, "%s ends quietly, no click (last sample %d)" % [n, tail])
		_check(w.loop_mode == (AudioStreamWAV.LOOP_FORWARD if looping else AudioStreamWAV.LOOP_DISABLED), "%s loop mode" % n)
		if looping:
			_check(w.loop_begin == 0 and w.loop_end == count, "%s loops over the whole buffer (end %d of %d)" % [n, w.loop_end, count])
		var vol: float = sfx.SETTINGS[n][0]
		var rms_db := 20.0 * log(maxf(m.rms, 1e-6)) / log(10.0)
		rows.append([rms_db + vol, "  %-12s %5.2f  %.3f  %.3f  %+.4f  %6.1f  %5.1f  %5.1f" % [n, m.seconds, m.peak, m.rms, m.dc, rms_db, vol, rms_db + vol]])
	rows.sort_custom(func(a: Array, b: Array) -> bool: return a[0] > b[0])
	for r in rows:
		print(r[1])
	# Loop lengths and seamlessness.
	var hw: AudioStreamWAV = sfx.get_stream(&"hum")
	var hm: Dictionary = sfx.measure(hw)
	_check(hm.samples == sfx.MIX_RATE and is_equal_approx(hm.seconds, 1.0), "hum is exactly 1.0 s (%d samples)" % hm.samples)
	_check(hm.rms > 0.3 and hm.rms < 0.75 and absf(hm.dc) < 0.002 and is_equal_approx(hm.peak, 29162.0 / 32767.0), "hum measure() sane (rms %.3f, dc %.4f, peak %.4f)" % [hm.rms, hm.dc, hm.peak])
	_check(sfx.measure(null).samples == 0, "measure(null) is empty, no error")
	var hn := hw.data.size() / 2
	var ring: PackedFloat32Array = []      # the last 8 samples, then the first 8: one continuous stretch if seamless
	for i in range(hn - 8, hn):
		ring.append(hw.data.decode_s16(i * 2) / 32767.0)
	for i in 8:
		ring.append(hw.data.decode_s16(i * 2) / 32767.0)
	var worst_bend := 0.0
	for i in range(1, ring.size() - 1):
		worst_bend = maxf(worst_bend, absf(ring[i + 1] - 2.0 * ring[i] + ring[i - 1]))
	_check(absf(ring[8]) < 0.02 and absf(ring[7]) < 0.05, "hum starts/ends at the 60 Hz zero crossing (first %.4f, last %.4f)" % [ring[8], ring[7]])
	_check(worst_bend < 0.01, "hum wraps seamlessly (worst second difference across the loop point %.4f)" % worst_bend)
	var kw: AudioStreamWAV = sfx.get_stream(&"keys")
	var km: Dictionary = sfx.measure(kw)
	_check(is_equal_approx(km.seconds, 0.5) and km.samples == sfx.MIX_RATE / 2, "keys is exactly 0.5 s (%d samples)" % km.samples)
	var kn := kw.data.size() / 2
	var edge := 0.0
	for i in 8:
		edge = maxf(edge, absf(kw.data.decode_s16(i * 2) / 32767.0))
		edge = maxf(edge, absf(kw.data.decode_s16((kn - 1 - i) * 2) / 32767.0))
	_check(edge <= 0.02, "keys begins and ends within +-0.02 (edge %.4f)" % edge)
	_check(km.rms > 0.03, "keys has content between the fades (rms %.3f)" % km.rms)
	await _test_sfx_loops(sfx)
	await _test_sfx_offset(sfx)
	for i in 60:
		sfx.play(CONTRACT_SOUNDS[i % CONTRACT_SOUNDS.size()], Vector3(i, 0, 0))
	_check(sfx.get_active_voice_count() <= sfx.MAX_2D + sfx.MAX_3D, "voice cap respected")
	await _frames(5)

func _test_sfx_loops(sfx: Node) -> void:
	var h1: int = sfx.play_loop(&"hum")
	_check(h1 > 0 and sfx.is_loop_playing(h1), "play_loop(hum) 2D returns a handle (%d)" % h1)
	var lp1: Node = sfx.get_loop_player(h1)
	_check(lp1 is AudioStreamPlayer and lp1.playing and lp1.bus == sfx.BUS_NAME and lp1.process_mode == Node.PROCESS_MODE_ALWAYS, "2D loop player: AudioStreamPlayer on the SFX bus, process always")
	_check(lp1 != null and lp1.stream == sfx.get_stream(&"hum") and lp1.volume_db == sfx.SETTINGS[&"hum"][0] and String(lp1.name).begins_with("Loop2D_"), "2D loop plays the hum stream at its SETTINGS volume, outside the voice pools")
	var h2: int = sfx.play_loop(&"keys", Vector3(3, 0, -1))
	_check(h2 > h1 and sfx.is_loop_playing(h2), "play_loop(keys, Vector3) returns a new handle (%d)" % h2)
	var lp2: Node = sfx.get_loop_player(h2)
	_check(lp2 is AudioStreamPlayer3D and lp2.playing and lp2.global_position.is_equal_approx(Vector3(3, 0, -1)), "3D loop sits at the given point")
	_check(lp2 != null and lp2.bus == sfx.BUS_NAME and lp2.process_mode == Node.PROCESS_MODE_ALWAYS and lp2.unit_size == sfx.SETTINGS[&"keys"][2], "3D loop player: SFX bus, process always, unit_size from SETTINGS")
	# Following a Node3D.
	var mover := Node3D.new()
	root.add_child(mover)
	mover.global_position = Vector3(1, 0, 1)
	var h3: int = sfx.play_loop(&"keys", mover)
	_check(h3 > h2 and sfx.is_loop_playing(h3), "play_loop(keys, Node3D) returns a handle (%d)" % h3)
	var lp3: Node = sfx.get_loop_player(h3)
	_check(lp3 is AudioStreamPlayer3D and lp3.global_position.is_equal_approx(Vector3(1, 0, 1)), "loop starts at the node's position")
	mover.global_position = Vector3(5, 0, -2)
	await _frames(2)
	var followed: bool = is_instance_valid(lp3) and lp3.global_position.is_equal_approx(Vector3(5, 0, -2))
	_check(followed, "loop follows the node after a frame")
	mover.free()
	await _frames(2)
	_check(not sfx.is_loop_playing(h3) and not is_instance_valid(lp3), "loop stops itself and frees its player when the node is freed")
	sfx.stop_loop(h3)   # already gone: no-op
	# stop_loop: at once, and with the default fade.
	sfx.stop_loop(h2, 0.0)
	_check(not sfx.is_loop_playing(h2) and sfx.get_loop_player(h2) == null, "stop_loop(handle, 0) stops at once")
	sfx.stop_loop(h1)
	_check(not sfx.is_loop_playing(h1) and sfx.get_active_loop_count() == 0, "stop_loop(handle) counts as stopped immediately")
	_check(is_instance_valid(lp1) and lp1.playing, "a fading loop still plays during its fade")
	await _wait(0.4)
	_check(not is_instance_valid(lp1), "the faded loop's player is freed after the fade")
	# Refusals: unknown, non-looping, bad target, disabled.
	_check(sfx.play_loop(&"definitely_not_a_loop") == 0, "play_loop(unknown) -> 0")
	_check(sfx.play_loop(&"bonk") == 0, "play_loop(non-looping sound) -> 0")
	_check(sfx.play_loop(&"hum", "not a target") == 0, "play_loop(bad target) -> 0")
	sfx.enabled = false
	_check(sfx.play_loop(&"hum") == 0, "play_loop while disabled -> 0")
	sfx.enabled = true
	# Cap: MAX_LOOPS run, the next is refused; handles unique and rising.
	var handles: Array = []
	for i in sfx.MAX_LOOPS:
		var h: int = sfx.play_loop(&"hum" if i % 2 == 0 else &"keys", Vector3(i, 0, 0))
		if h > 0:
			handles.append(h)
	_check(handles.size() == sfx.MAX_LOOPS and sfx.get_active_loop_count() == sfx.MAX_LOOPS, "%d loops run at once" % sfx.MAX_LOOPS)
	_check(sfx.play_loop(&"hum") == 0, "loop number %d is refused (cap)" % (sfx.MAX_LOOPS + 1))
	var seen := {}
	var unique := true
	for h in handles + [h1, h2, h3]:
		if seen.has(h):
			unique = false
		seen[h] = true
	_check(unique and handles[0] > h3, "handles are unique and never reused")
	sfx.set_loop_volume(handles[0], -30.0)
	_check(sfx.get_loop_player(handles[0]).volume_db == -30.0, "set_loop_volume applies to the loop player")
	sfx.set_loop_volume(h2, -30.0)   # stopped: no-op
	sfx.stop_all_loops()
	_check(sfx.get_active_loop_count() == 0 and not sfx.is_loop_playing(handles[0]), "stop_all_loops stops everything")
	var h4: int = sfx.play_loop(&"hum")
	_check(h4 > handles[handles.size() - 1], "a slot is free again after stop_all_loops, the handle keeps rising")
	sfx.stop_all()
	_check(sfx.get_active_loop_count() == 0 and sfx.get_active_voice_count() == 0, "stop_all stops loops and voices")
	await _frames(2)
	var leftovers := 0
	for c in sfx.get_children():
		if String(c.name).begins_with("Loop"):
			leftovers += 1
	_check(leftovers == 0, "no loop players left after stop_all (%d)" % leftovers)

func _test_sfx_offset(sfx: Node) -> void:
	# play(sound, position, volume_offset_db): the chosen voice gets SETTINGS volume + offset.
	OS.delay_msec(45)   # past the retrigger guard (wall clock)
	sfx.play(&"throw")
	var v0: Node = sfx.get_last_voice()
	_check(v0 is AudioStreamPlayer and is_equal_approx(v0.volume_db, sfx.SETTINGS[&"throw"][0]), "play() uses the SETTINGS volume")
	OS.delay_msec(45)
	sfx.play(&"throw", Vector3.INF, -8.0)
	var v1: Node = sfx.get_last_voice()
	_check(v1 is AudioStreamPlayer and is_equal_approx(v1.volume_db, sfx.SETTINGS[&"throw"][0] - 8.0), "play(sound, INF, -8) is 8 dB quieter (%.1f)" % (v1.volume_db if v1 else NAN))
	sfx.play(&"step", Vector3(2, 0, 2), -3.0)
	var v2: Node = sfx.get_last_voice()
	_check(v2 is AudioStreamPlayer3D and is_equal_approx(v2.volume_db, sfx.SETTINGS[&"step"][0] - 3.0) and v2.unit_size == sfx.SETTINGS[&"step"][2], "3D play with an offset (%.1f)" % (v2.volume_db if v2 else NAN))
	OS.delay_msec(45)
	sfx.play_at(&"step", null, -2.0)   # no node -> 2D, no error
	var v3: Node = sfx.get_last_voice()
	_check(v3 is AudioStreamPlayer and is_equal_approx(v3.volume_db, sfx.SETTINGS[&"step"][0] - 2.0), "play_at(null node) falls back to 2D with the offset")

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
