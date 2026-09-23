extends Node
## Autoload "Juice": tween + particle feedback helpers (owned by the art agent; usage rules in STYLE.md).
##
##   Juice.pop_in(node)                      # appear: scale 0 -> overshoot -> 1 (Node3D, Control, Node2D)
##   Juice.bounce(node, 0.2)                 # squash & stretch, returns to the original scale
##   Juice.pulse(node) / Juice.stop(node)    # looping attention pulse
##   Juice.punch_ui(label)                   # quick scale punch for HUD numbers
##   Juice.burst(pos, color, 12)             # one-shot 3D candy burst (+ pop flash)
##   Juice.float_text(pos, "+$120", Toon.GOLD)
##   extras: grow_to, pop_out, shake, confetti, puff, splash, sparkle
##
## Rules: Juice the VISUAL child (e.g. a "Visual"/"Mesh" Node3D), never a physics body, an Interactable
## root, or anything whose scale/transform is synced over the network. Everything here is local-only
## cosmetics: trigger it from code that runs on every peer (synced setters, call_local RPCs, signals).
## Safe on freed nodes (tweens are bound to the node; callbacks check is_instance_valid) and never stacks
## tweens on one node: a new scale effect replaces the running one and starts from the node's rest scale.
## Do NOT add a class_name (autoload).

const META_BASE := &"_juice_base_scale"
const META_TWEEN := &"_juice_tween"
const META_PULSE := &"_juice_pulsing"
const META_SHAKE := &"_juice_shake"
const META_ROT := &"_juice_base_rot"

## Default durations (seconds) - documented in STYLE.md "Animation".
const POP_IN_OVERSHOOT := 0.18
const BOUNCE_TIME := 0.38
const PULSE_PERIOD := 0.9
const PULSE_AMOUNT := 0.07
const PUNCH_TIME := 0.3
const PUNCH_AMOUNT := 0.3
const GROW_TIME := 0.45

const DUST := Color("eadbc0")
const CONFETTI_COLORS: Array[Color] = [
	Color("ff5a5f"), Color("ffd23f"), Color("4fcb6b"), Color("4da8f7"), Color("9a6bff"), Color("ff7eb6"),
]

## Global switch (e.g. reduced-motion setting, or perf tests). When false every call is a no-op except
## that pop_in/grow_to still set the final scale/visibility so gameplay state never looks wrong.
var enabled: bool = true

var _sphere: SphereMesh
var _chunk: BoxMesh
var _particle_mat: StandardMaterial3D
var _flat_particle_mat: StandardMaterial3D
var _text_font: FontVariation

func _ready() -> void:
	_sphere = SphereMesh.new()
	_sphere.radius = 0.085
	_sphere.height = 0.17
	_sphere.radial_segments = 10
	_sphere.rings = 5
	_chunk = BoxMesh.new()
	_chunk.size = Vector3(0.1, 0.02, 0.06)
	_particle_mat = StandardMaterial3D.new()
	_particle_mat.vertex_color_use_as_albedo = true
	_particle_mat.diffuse_mode = BaseMaterial3D.DIFFUSE_TOON
	_particle_mat.specular_mode = BaseMaterial3D.SPECULAR_TOON
	_particle_mat.roughness = 0.4
	_particle_mat.rim_enabled = true
	_particle_mat.rim = 0.3
	_particle_mat.rim_tint = 0.5
	_flat_particle_mat = StandardMaterial3D.new()
	_flat_particle_mat.vertex_color_use_as_albedo = true
	_flat_particle_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_flat_particle_mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	_text_font = FontVariation.new()   # engine font, extra bold (matches the UI theme's chunky font)
	_text_font.variation_embolden = 0.9

# ================================================================================ scale effects (contract)

## Appear: scale from ~0 to the node's rest scale with a ~18% overshoot and a little squash & stretch.
## Also makes the node visible. Works for Node3D, Control (pivot = centre) and Node2D.
func pop_in(node: Node, duration: float = 0.35) -> void:
	if not _scalable(node):
		return
	var base := _rest_scale(node)
	if node is Control:
		(node as Control).pivot_offset_ratio = Vector2(0.5, 0.5)
	if "visible" in node:
		node.set(&"visible", true)
	if not enabled:
		_set_scale(node, base)
		return
	_set_scale(node, base * 0.01)
	var tw := _begin(node)
	tw.tween_method(func(t: float) -> void: _apply(node, base, _pop_curve(t)), 0.0, 1.0, maxf(duration, 0.05))
	_end(node, tw, base)

## Squash & stretch (strength 0.2 = 20% squash), volume-preserving, back to the rest scale.
## Put the node's origin at its base so it squashes into the ground instead of shrinking to its centre.
func bounce(node: Node, strength: float = 0.2) -> void:
	if not enabled or not _scalable(node):
		return
	var base := _rest_scale(node)
	if node is Control:
		(node as Control).pivot_offset_ratio = Vector2(0.5, 1.0)
	var s := clampf(strength, 0.0, 0.8)
	var tw := _begin(node)
	tw.tween_method(func(t: float) -> void: _apply(node, base, _bounce_curve(t, s)), 0.0, 1.0, BOUNCE_TIME)
	_end(node, tw, base)

## Looping subtle pulse (+-7% every 0.9 s) until Juice.stop(node). Other effects pause it and it resumes after.
func pulse(node: Node) -> void:
	if not _scalable(node):
		return
	node.set_meta(META_PULSE, true)
	if not enabled:
		return
	var base := _rest_scale(node)
	if node is Control:
		(node as Control).pivot_offset_ratio = Vector2(0.5, 0.5)
	var tw := _begin(node)
	tw.set_loops()
	tw.tween_method(func(t: float) -> void: _apply(node, base, _pulse_curve(t)), 0.0, 1.0, PULSE_PERIOD)

## Stops pulse / any running scale effect and snaps back to the rest scale.
func stop(node: Node) -> void:
	if node == null or not is_instance_valid(node):
		return
	if node.has_meta(META_PULSE):
		node.remove_meta(META_PULSE)
	var had_tween := _kill(node)
	if had_tween and node.has_meta(META_BASE):
		_set_scale(node, node.get_meta(META_BASE))

## Quick scale punch (to ~1.3x and back with a small undershoot) for HUD numbers / buttons.
func punch_ui(control: Control) -> void:
	if not enabled or not _scalable(control):
		return
	var base := _rest_scale(control)
	control.pivot_offset_ratio = Vector2(0.5, 0.5)
	var tw := _begin(control)
	tw.tween_method(func(t: float) -> void: _apply(control, base, _punch_curve(t)), 0.0, 1.0, PUNCH_TIME)
	_end(control, tw, base)

# ================================================================================ scale effects (extras)

## Animate to a NEW rest scale with overshoot + squash (plant stage "puff up"). Later effects use it as base.
func grow_to(node: Node, target_scale: Vector3, duration: float = GROW_TIME) -> void:
	if not _scalable(node):
		return
	var from := _get_scale(node)
	if node.has_meta(META_TWEEN) and node.has_meta(META_BASE):
		from = node.get_meta(META_BASE)
	_kill(node)
	node.set_meta(META_BASE, target_scale)
	if not enabled or from.is_equal_approx(target_scale):
		_set_scale(node, target_scale)
		return
	if node is Control:
		(node as Control).pivot_offset_ratio = Vector2(0.5, 1.0)
	var tw := _begin(node)
	var step := func(t: float) -> void:
		if not is_instance_valid(node):
			return
		# Size follows an overshooting ease; the squash & stretch wobble is relative to the size, so even a
		# small stage change visibly "puffs".
		var c1 := 2.4
		var u := t - 1.0
		var s := 1.0 + (c1 + 1.0) * u * u * u + c1 * u * u
		var w := 0.2 * sin(TAU * t) * (1.0 - t)
		var size := from + (target_scale - from) * s
		_set_scale(node, Vector3(size.x * (1.0 - w * 0.5), size.y * (1.0 + w), size.z * (1.0 - w * 0.5)))
	tw.tween_method(step, 0.0, 1.0, maxf(duration, 0.05))
	_end(node, tw, target_scale)

## Disappear: squash down to ~0, then hide (or queue_free when free_after). The node's rest scale is kept
## so a later pop_in() brings it back at the right size.
func pop_out(node: Node, duration: float = 0.2, free_after: bool = false) -> void:
	if not _scalable(node):
		return
	var base := _rest_scale(node)
	if not enabled:
		_finish_pop_out(node, base, free_after)
		return
	if node is Control:
		(node as Control).pivot_offset_ratio = Vector2(0.5, 0.5)
	var tw := _begin(node)
	tw.tween_method(func(t: float) -> void: _apply(node, base, _pop_out_curve(t)), 0.0, 1.0, maxf(duration, 0.05))
	tw.finished.connect(func() -> void: _finish_pop_out(node, base, free_after))

## "Nope" wiggle (rotation, damped, 0.4 s). Controls wiggle around their centre; Node3D shakes its head (yaw).
## Runs alongside scale effects. Great with Sfx.play(&"error").
func shake(node: Node, strength: float = 1.0) -> void:
	if not enabled or node == null or not is_instance_valid(node):
		return
	if not (node is Control or node is Node3D or node is Node2D):
		return
	var old: Tween = node.get_meta(META_SHAKE) if node.has_meta(META_SHAKE) else null
	var base_rot: Variant
	if old != null and old.is_valid():
		old.kill()
		base_rot = node.get_meta(META_ROT)
	else:
		base_rot = node.get(&"rotation")
		node.set_meta(META_ROT, base_rot)
	if node is Control:
		(node as Control).pivot_offset_ratio = Vector2(0.5, 0.5)
	var amp := deg_to_rad(7.0) * strength
	var tw := node.create_tween()
	var tw_id := tw.get_instance_id()
	node.set_meta(META_SHAKE, tw)
	tw.tween_method(func(t: float) -> void:
		if not is_instance_valid(node):
			return
		var a := sin(t * TAU * 3.5) * (1.0 - t) * amp
		if node is Node3D:
			(node as Node3D).rotation = (base_rot as Vector3) + Vector3(0.0, a, 0.0)
		else:
			node.set(&"rotation", (base_rot as float) + a), 0.0, 1.0, 0.4)
	tw.finished.connect(func() -> void:
		if is_instance_valid(node):
			node.set(&"rotation", base_rot)
			if _meta_tween_id(node, META_SHAKE) == tw_id:
				node.remove_meta(META_SHAKE))

# ======================================================================================= 3D spawns

## One-shot burst of little toon candies + a quick pop flash. Frees itself (~1 s).
func burst(position: Vector3, color: Color, count: int = 12) -> void:
	if not enabled:
		return
	var p := _particles(position, clampi(count, 1, 96), 0.65, _sphere, _particle_mat)
	if p == null:
		return
	p.direction = Vector3.UP
	p.spread = 75.0
	p.initial_velocity_min = 2.4
	p.initial_velocity_max = 4.6
	p.gravity = Vector3(0, -11.0, 0)
	p.damping_min = 0.5
	p.damping_max = 1.5
	p.scale_amount_min = 0.8
	p.scale_amount_max = 1.6
	p.color = Color.WHITE
	p.color_initial_ramp = _ramp([color.lightened(0.35), color, color.darkened(0.12)])
	_flash(position, color.lightened(0.45), 0.42)

## Rising, fading billboard text ("+$120"). Always drawn on top, outlined in ink, frees itself (~1.3 s).
func float_text(position: Vector3, text: String, color: Color = Color.WHITE) -> void:
	if not enabled:
		return
	var parent := _fx_parent()
	if parent == null:
		return
	var l := Label3D.new()
	l.name = "FloatText"
	l.text = text
	l.font = _text_font
	l.font_size = 72
	l.outline_size = 22
	l.pixel_size = 0.005
	l.modulate = color
	l.outline_modulate = Color("2e2a3d")
	l.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	l.no_depth_test = true
	l.fixed_size = false
	l.double_sided = true
	l.render_priority = 10
	l.outline_render_priority = 9
	l.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	parent.add_child(l)
	var start := position + Vector3(randf_range(-0.15, 0.15), 0.0, randf_range(-0.15, 0.15))
	l.global_position = start
	l.scale = Vector3.ONE * 0.2
	var tw := l.create_tween()
	tw.set_parallel(true)
	tw.tween_property(l, "global_position", start + Vector3(0, 1.1, 0), 1.2).set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
	tw.tween_property(l, "scale", Vector3.ONE * 1.25, 0.12).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
	tw.tween_property(l, "scale", Vector3.ONE, 0.18).set_delay(0.12).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	var clear := Color(color, 0.0)
	tw.tween_property(l, "modulate", clear, 0.4).set_delay(0.8)
	tw.tween_property(l, "outline_modulate", Color(0.18, 0.165, 0.24, 0.0), 0.4).set_delay(0.8)
	tw.chain().tween_callback(l.queue_free)

## Party confetti (multi-colour tumbling chips) for round wins / big sales. Frees itself (~2 s).
func confetti(position: Vector3, count: int = 40) -> void:
	if not enabled:
		return
	var p := _particles(position, clampi(count, 1, 160), 1.8, _chunk, _particle_mat)
	if p == null:
		return
	p.direction = Vector3.UP
	p.spread = 40.0
	p.initial_velocity_min = 5.0
	p.initial_velocity_max = 7.5
	p.gravity = Vector3(0, -7.0, 0)
	p.damping_min = 2.0
	p.damping_max = 3.5
	p.angular_velocity_min = -540.0
	p.angular_velocity_max = 540.0
	p.angle_min = 0.0
	p.angle_max = 360.0
	p.particle_flag_rotate_y = true
	p.scale_amount_min = 0.8
	p.scale_amount_max = 1.4
	p.color = Color.WHITE
	var g := Gradient.new()
	g.interpolation_mode = Gradient.GRADIENT_INTERPOLATE_CONSTANT
	var offsets := PackedFloat32Array()
	var colors := PackedColorArray()
	for i in CONFETTI_COLORS.size():
		offsets.append(float(i) / CONFETTI_COLORS.size())
		colors.append(CONFETTI_COLORS[i])
	g.offsets = offsets
	g.colors = colors
	p.color_initial_ramp = g

## Soft dust puff (plant, drop, footfalls). Frees itself (~0.7 s).
func puff(position: Vector3, color: Color = DUST, count: int = 8) -> void:
	if not enabled:
		return
	var p := _particles(position, clampi(count, 1, 48), 0.55, _sphere, _particle_mat)
	if p == null:
		return
	p.emission_shape = CPUParticles3D.EMISSION_SHAPE_SPHERE
	p.emission_sphere_radius = 0.15
	p.direction = Vector3.UP
	p.spread = 90.0
	p.flatness = 0.7
	p.initial_velocity_min = 0.8
	p.initial_velocity_max = 1.6
	p.gravity = Vector3(0, 0.6, 0)
	p.damping_min = 2.0
	p.damping_max = 3.0
	p.scale_amount_min = 1.6
	p.scale_amount_max = 2.6
	p.color = Color.WHITE
	p.color_initial_ramp = _ramp([color.lightened(0.2), color])

## Water droplets (watering, well refill). Frees itself (~0.8 s).
func splash(position: Vector3, count: int = 14) -> void:
	if not enabled:
		return
	var p := _particles(position, clampi(count, 1, 64), 0.55, _sphere, _particle_mat)
	if p == null:
		return
	p.direction = Vector3.UP
	p.spread = 55.0
	p.initial_velocity_min = 2.0
	p.initial_velocity_max = 3.8
	p.gravity = Vector3(0, -14.0, 0)
	p.scale_amount_min = 0.5
	p.scale_amount_max = 1.0
	p.color = Color.WHITE
	p.color_initial_ramp = _ramp([Color("9fe3ff"), Color("45c4ff"), Color("2f9be0")])

## Floating glints (plant READY, upgrades, "you can do this now"). Frees itself (~1.2 s).
func sparkle(position: Vector3, color: Color = Color("ffd23f"), count: int = 10) -> void:
	if not enabled:
		return
	var p := _particles(position, clampi(count, 1, 48), 1.0, _sphere, _flat_particle_mat)
	if p == null:
		return
	p.explosiveness = 0.6
	p.emission_shape = CPUParticles3D.EMISSION_SHAPE_SPHERE
	p.emission_sphere_radius = 0.35
	p.direction = Vector3.UP
	p.spread = 25.0
	p.initial_velocity_min = 0.6
	p.initial_velocity_max = 1.3
	p.gravity = Vector3(0, 0.4, 0)
	p.scale_amount_min = 0.35
	p.scale_amount_max = 0.7
	p.color = Color.WHITE
	p.color_initial_ramp = _ramp([Color(1, 1, 0.9), color.lightened(0.3), color])

# ====================================================================================== internals

func _scalable(node: Node) -> bool:
	return node != null and is_instance_valid(node) and (node is Node3D or node is Control or node is Node2D)

func _get_scale(node: Node) -> Vector3:
	if node is Node3D:
		return (node as Node3D).scale
	var s2: Vector2 = node.get(&"scale")
	return Vector3(s2.x, s2.y, 1.0)

func _set_scale(node: Node, s: Vector3) -> void:
	if not is_instance_valid(node):
		return
	if node is Node3D:
		# Never exactly 0: a zero basis breaks physics/camera math on children.
		(node as Node3D).scale = Vector3(_nz(s.x), _nz(s.y), _nz(s.z))
	else:
		node.set(&"scale", Vector2(s.x, s.y))

func _nz(v: float) -> float:
	return v if absf(v) > 0.0001 else 0.0001

## The node's "rest" scale: the stored one while a Juice tween is running (so re-triggering mid-animation
## never drifts), otherwise its current scale (unless ~0, e.g. hidden by a previous pop_out).
func _rest_scale(node: Node) -> Vector3:
	var running: Tween = node.get_meta(META_TWEEN) if node.has_meta(META_TWEEN) else null
	var base: Vector3
	if running != null and running.is_valid() and node.has_meta(META_BASE):
		base = node.get_meta(META_BASE)
	else:
		base = _get_scale(node)
		if base.length() < 0.05:
			base = node.get_meta(META_BASE) if node.has_meta(META_BASE) else Vector3.ONE
	node.set_meta(META_BASE, base)
	return base

func _begin(node: Node) -> Tween:
	_kill(node)
	var tw := node.create_tween()
	node.set_meta(META_TWEEN, tw)
	return tw

## Kills the running scale tween (if any). Returns true if one was running.
func _kill(node: Node) -> bool:
	if not node.has_meta(META_TWEEN):
		return false
	var tw: Tween = node.get_meta(META_TWEEN)
	node.remove_meta(META_TWEEN)
	if tw != null and tw.is_valid():
		tw.kill()
		return true
	return false

## On finish: snap to the rest scale, clear the tween meta, resume a pulse that was interrupted.
## The callback captures the tween's instance id, never the Tween itself (that would be a reference cycle
## Tween -> connection -> lambda -> Tween, leaking every tween that gets killed before it finishes).
func _end(node: Node, tw: Tween, base: Vector3) -> void:
	var tw_id := tw.get_instance_id()
	tw.finished.connect(func() -> void:
		if not is_instance_valid(node):
			return
		_set_scale(node, base)
		if _meta_tween_id(node, META_TWEEN) == tw_id:
			node.remove_meta(META_TWEEN)
			if node.has_meta(META_PULSE):
				pulse(node))

func _meta_tween_id(node: Node, key: StringName) -> int:
	var t: Variant = node.get_meta(key, null)
	return (t as Tween).get_instance_id() if t is Tween else 0

func _apply(node: Node, base: Vector3, k: Vector3) -> void:
	if is_instance_valid(node):
		_set_scale(node, Vector3(base.x * k.x, base.y * k.y, base.z * k.z))

func _finish_pop_out(node: Node, base: Vector3, free_after: bool) -> void:
	if not is_instance_valid(node):
		return
	if node.get_meta(META_TWEEN, null) != null:
		node.remove_meta(META_TWEEN)
	if node.has_meta(META_PULSE):
		node.remove_meta(META_PULSE)
	if free_after:
		node.queue_free()
		return
	if "visible" in node:
		node.set(&"visible", false)
	_set_scale(node, base)   # keep the rest scale for the next pop_in (hidden, so no flash)

# Curves return per-axis multipliers (x, y, z). Controls/Node2D use x/y only.

## Overshoot "back-out" (peak ~1.18 at t~0.55) with y leading (stretch up) then a small squash.
func _pop_curve(t: float) -> Vector3:
	var c1 := 2.4
	var c3 := c1 + 1.0
	var u := t - 1.0
	var s := 1.0 + c3 * u * u * u + c1 * u * u
	var w := 0.16 * sin(TAU * t) * (1.0 - t)
	return Vector3(s * (1.0 - w * 0.5), s * (1.0 + w), s * (1.0 - w * 0.5))

## Damped squash -> stretch -> settle; x/z = 1/sqrt(y) keeps the volume.
func _bounce_curve(t: float, strength: float) -> Vector3:
	var y := 1.0 - strength * sin(PI * t * 3.0) * pow(1.0 - t, 1.4)
	var xz := 1.0 / sqrt(maxf(y, 0.05))
	return Vector3(xz, y, xz)

func _pulse_curve(t: float) -> Vector3:
	var a := PULSE_AMOUNT * sin(TAU * t)
	return Vector3(1.0 + a * 0.7, 1.0 + a, 1.0 + a * 0.7)

func _punch_curve(t: float) -> Vector3:
	var a := PUNCH_AMOUNT * pow(1.0 - t, 3.0) * sin(t * 9.0) / 0.6
	return Vector3(1.0 + a, 1.0 + a, 1.0 + a)

## Anticipation (swell +12%), then collapse with a vertical squash.
func _pop_out_curve(t: float) -> Vector3:
	if t < 0.3:
		var a := 1.0 + 0.12 * sin(t / 0.3 * PI * 0.5)
		return Vector3(a, a, a)
	var k := 1.12 * (1.0 - pow((t - 0.3) / 0.7, 2.0))
	return Vector3(k * 1.05, k * 0.9, k * 1.05)

## Where 3D effects live: the World if there is one, else the current scene (if 3D), else the root.
func _fx_parent() -> Node:
	var tree := get_tree()
	if tree == null:
		return null
	var game := get_node_or_null(^"/root/Game")
	if game != null:
		var w: Variant = game.get(&"world")
		if w is Node and is_instance_valid(w) and (w as Node).is_inside_tree():
			return w
	var cs := tree.current_scene
	if cs != null and is_instance_valid(cs) and cs.is_inside_tree() and cs is Node3D:
		return cs
	return tree.root

func _particles(position: Vector3, amount: int, lifetime: float, mesh: Mesh, mat: Material) -> CPUParticles3D:
	var parent := _fx_parent()
	if parent == null:
		return null
	var p := CPUParticles3D.new()
	p.name = "JuiceParticles"
	p.one_shot = true
	p.amount = amount
	p.lifetime = lifetime
	p.explosiveness = 0.92
	p.randomness = 0.4
	p.lifetime_randomness = 0.35
	p.local_coords = false
	p.mesh = mesh
	p.material_override = mat
	p.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var curve := Curve.new()
	curve.add_point(Vector2(0.0, 0.3))
	curve.add_point(Vector2(0.15, 1.0))
	curve.add_point(Vector2(0.7, 0.85))
	curve.add_point(Vector2(1.0, 0.0))
	p.scale_amount_curve = curve
	parent.add_child(p)
	p.global_position = position
	p.emitting = true
	p.finished.connect(p.queue_free)
	# Safety net in case 'finished' never fires (e.g. processing disabled): bound to p, dies with it.
	var tw := p.create_tween()
	tw.tween_interval(lifetime * 2.0 + 1.0)
	tw.tween_callback(p.queue_free)
	return p

func _ramp(colors: Array[Color]) -> Gradient:
	var g := Gradient.new()
	var offsets := PackedFloat32Array()
	var cols := PackedColorArray()
	for i in colors.size():
		offsets.append(float(i) / maxf(colors.size() - 1, 1))
		cols.append(colors[i])
	g.offsets = offsets
	g.colors = cols
	return g

## Quick pop flash: a flat sphere that swells and vanishes in 0.18 s.
func _flash(position: Vector3, color: Color, radius: float) -> void:
	var parent := _fx_parent()
	if parent == null:
		return
	var mi := MeshInstance3D.new()
	mi.name = "JuiceFlash"
	mi.mesh = _sphere
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var m := StandardMaterial3D.new()
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	m.albedo_color = Color(color, 0.7)
	mi.material_override = m
	parent.add_child(mi)
	mi.global_position = position
	mi.scale = Vector3.ONE * 0.01
	var full := Vector3.ONE * (radius / _sphere.radius)
	var tw := mi.create_tween()
	tw.tween_property(mi, "scale", full, 0.1).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
	tw.parallel().tween_property(m, "albedo_color", Color(color, 0.0), 0.18).set_delay(0.04)
	tw.tween_callback(mi.queue_free)
