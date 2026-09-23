class_name PlantVisual
extends Node3D
## Cannabis plant model used by GrowPlot (scenes/stations/plant_visual.tscn). Pure presentation:
## it holds no game state and every setter is idempotent and cheap (called from synced-property setters
## on every peer, possibly every frame).
##
## Stage index matches GrowPlot.Stage: 0 = nothing, 1 seedling, 2 vegetative, 3 flowering, 4 ready.
## The stage models are Blender GLBs (tools/blender/models/plant.py, Toonify roots) instanced AS the stage nodes:
##   Tilt (lean when dry) / Bouncer (Juice.bounce) / Grow (scale 0.8..1 with stage progress)
##     / Seedling | Vegetative | Flowering | Ready        (plant_<stage>.glb, Juice.pop_in on stage change)
##         Leaves (+ Buds on Flowering)                  the healthy plant
##         Dry                                           plant_<stage>_dry.glb: the same plant wilted
##     Ready/Buds/ColaTop, Cola1..                       one mesh per cola, each pulses in place while READY
##   DryIndicator / Bob (bobbing water drop + "DRY" label, stays upright)
## Strain colour: every model's TINT parts (calyxes, frosty tips) take Toon.grade(seed colour) via Toonify.tint.
## get_tint_material() is the material the READY crown cola renders its calyxes with (the plot's tag card uses
## it). Leaves are library greens (never tinted); the wilted models use toon_leaf_dry.
##
## Wilting is one blend value, 0 = healthy .. 1 = wilted, driven by a single Tween (_wilt_tween, WILT_TIME,
## cubic ease-out: quick in, slow settle). Everything wilt-related is a pure function of it (_apply_wilt): the
## incoming model swells up out of the outgoing one early, the outgoing one holds, then sinks and narrows into
## it, and Tilt leans by DROOP_ROTATION * blend. The healthy parts show while blend < 1 and the wilted model
## while blend > 0, so at rest exactly one of them is visible. Repeating set_dry() is a no-op, the opposite
## call mid-blend reverses from the current value (no jump), and animate = false (late-join sync, first
## frames) or no plant on screen snaps. Nothing here touches collision: the plot owns its PlantShape.
## (The watering squash is the plot's bounce() on top; wilting gets no bounce, it just slumps.)

const STAGE_COUNT := 5
## Local height of the top of each stage's model at full growth (index = stage; measured on the GLBs).
const STAGE_HEIGHTS: Array[float] = [0.0, 0.31, 0.66, 0.98, 1.07]
## Scale of the Grow node at the start of a stage; it reaches 1.0 when the stage completes.
const GROW_MIN_SCALE := 0.8
## Lean applied to Tilt while the plant is dry (radians). The wilted models already hang their leaves and nod
## their tops over; this adds a tired slump of the whole plant.
const DROOP_ROTATION := Vector3(0.14, 0.0, -0.09)
## Ink outline of the buds / colas (Toonify.outline; parts 0.1-0.25 m get 48 % of it). The leaves keep the
## thinner outline set on the model instances in the scene, so their fingers do not drown in ink.
const BUD_OUTLINE := 0.024
## Seconds of a full healthy <-> wilted crossfade (a reversal mid-blend takes its share of it).
const WILT_TIME := 0.4
## Scale (about the soil point) of the healthy model when fully wilted, and of the wilted model when fully
## watered: small enough to sit inside the other model, so hiding it at the end of the blend does not pop.
const HEALTHY_HIDDEN_SCALE := Vector3(0.6, 0.35, 0.6)
const WILTED_HIDDEN_SCALE := Vector3(0.65, 0.45, 0.65)
const DRY_INDICATOR_GAP := 0.22
const DRY_BOB_HEIGHT := 0.06
const DRY_BOB_TIME := 0.55
const DRY_NODE := &"Dry"
## The READY crown cola and the Blender material of its calyxes (get_tint_material()).
const CROWN_COLA := &"ColaTop"
const BUD_TINT_SURFACE := "TINT_bud"

@onready var _tilt: Node3D = %Tilt
@onready var _bouncer: Node3D = %Bouncer
@onready var _grow: Node3D = %Grow
@onready var _dry_indicator: Node3D = %DryIndicator
@onready var _dry_bob: Node3D = %Bob
@onready var _stage_nodes: Array[Node3D] = [null, %Seedling, %Vegetative, %Flowering, %Ready]
@onready var _ready_buds: Node3D = (%Ready as Node3D).get_node(^"Buds") as Node3D

var _stage: int = 0
var _progress: float = 0.0
var _dry: bool = false
var _tint: Color = Color(0.55, 0.85, 0.35)
## Every Toonify model root below (stage models + their Dry variants), for the strain tint.
var _models: Array[Toonify] = []
## Wilt crossfade parts: [node, rest Transform3D, is the wilted model] for every stage that has a Dry variant.
var _wilt_parts: Array[Array] = []
## 0 = healthy .. 1 = wilted.
var _wilt: float = 0.0
var _wilt_tween: Tween
var _bob_tween: Tween
## The READY crown cola and the index of its TINT_bud surface (get_tint_material()).
var _crown: MeshInstance3D
var _crown_surface: int = -1

func _ready() -> void:
	for i in range(1, STAGE_COUNT):
		var n := _stage_nodes[i]
		var dry_model := n.get_node_or_null(NodePath(DRY_NODE)) as Node3D
		for m in [n, dry_model]:
			if m is Toonify:
				_models.append(m as Toonify)
		if dry_model == null:
			continue
		for c in n.get_children():
			if c is Node3D:
				_wilt_parts.append([c, (c as Node3D).transform, c == dry_model])
	# Buds get a heavier ink line than the leaves (the model roots already outlined everything thinly).
	for bud in _bud_nodes():
		Toonify.outline(bud, BUD_OUTLINE)
	_find_crown()
	_apply_tint()
	_apply_stage_visibility()
	_apply_growth()
	_wilt = 1.0 if _dry else 0.0
	_apply_wilt()
	_apply_dry_indicator(false)

## Shows the model for `stage`. `animate` pops the new model in (use only for real, live transitions).
func set_stage(stage: int, animate: bool) -> void:
	stage = clampi(stage, 0, STAGE_COUNT - 1)
	if stage == _stage:
		return
	var old := _stage
	_stage = stage
	if not is_node_ready():
		return
	if old == STAGE_COUNT - 1:
		_stop_bud_pulse()
	if stage == 0:
		_finish_wilt() # nothing left on screen to blend
	_apply_stage_visibility()
	_apply_growth()
	if stage > 0 and animate:
		Juice.pop_in(_stage_nodes[stage])

## 0..1 progress through the current stage: the model swells from GROW_MIN_SCALE to full size.
func set_growth(progress: float) -> void:
	progress = clampf(progress, 0.0, 1.0)
	if is_equal_approx(progress, _progress):
		return
	_progress = progress
	if is_node_ready():
		_apply_growth()

## Strain colour, normally SeedDef.color (raw data colour: the models show Toon.grade() of it).
func set_tint(color: Color) -> void:
	if color == _tint and is_node_ready():
		return
	_tint = color
	if is_node_ready():
		_apply_tint()

## The raw colour last passed to set_tint().
func get_tint() -> Color:
	return _tint

## The strain material the buds render with: the TINT_bud surface of the READY crown cola (Toonify's shared,
## cached material, albedo = Toon.grade(get_tint())). Shared: never modify it. A new tint swaps in another
## material, so fetch it again after set_tint(). Null before _ready.
func get_tint_material() -> Material:
	if _crown == null or _crown_surface < 0:
		return null
	return _crown.get_active_material(_crown_surface)

## Wilts the plant (crossfades to the stage's wilted model, slumps it) and shows the bobbing "DRY" drop;
## false revives it. `animate` = false snaps (also finishing a blend that is still running).
func set_dry(dry: bool, animate: bool) -> void:
	if dry == _dry:
		if not animate and is_wilt_blending():
			_finish_wilt()
		return
	_dry = dry
	if is_node_ready():
		_apply_wilt_target(animate)
		_apply_dry_indicator(animate)

func is_dry() -> bool:
	return _dry

## 0 = healthy .. 1 = wilted; strictly in between only while blending.
func get_wilt() -> float:
	return _wilt

## True while the healthy <-> wilted crossfade runs.
func is_wilt_blending() -> bool:
	return _wilt_tween != null and _wilt_tween.is_valid()

## Squash & stretch the whole plant (watering, growth).
func bounce(strength: float = 0.2) -> void:
	if is_node_ready() and _stage > 0:
		Juice.bounce(_bouncer, strength)

## Global position of the top of the current model (for bursts / floating text).
func get_top_global_position() -> Vector3:
	var h: float = STAGE_HEIGHTS[_stage] * _grow_scale()
	if not is_inside_tree():
		return position + Vector3(0.0, h, 0.0)
	return global_transform * Vector3(0.0, h, 0.0)

func _apply_stage_visibility() -> void:
	for i in range(1, STAGE_COUNT):
		var n := _stage_nodes[i]
		n.visible = i == _stage
		if i != _stage:
			n.scale = Vector3.ONE
	if _stage == STAGE_COUNT - 1:
		for cola in _pulse_nodes():
			Juice.pulse(cola)
	_dry_indicator.position.y = STAGE_HEIGHTS[_stage] + DRY_INDICATOR_GAP

func _apply_growth() -> void:
	var s := _grow_scale()
	_grow.scale = Vector3(s, s, s)

func _grow_scale() -> float:
	if _stage <= 0 or _stage >= STAGE_COUNT - 1:
		return 1.0
	return lerpf(GROW_MIN_SCALE, 1.0, _progress)

func _apply_tint() -> void:
	var graded := Toon.grade(_tint)
	for m in _models:
		m.tint = graded

func _find_crown() -> void:
	var colas := _pulse_nodes()
	var crown := _ready_buds.get_node_or_null(NodePath(CROWN_COLA)) as MeshInstance3D
	if crown == null and not colas.is_empty():
		crown = colas[0] as MeshInstance3D
	if crown == null or crown.mesh == null:
		push_warning("PlantVisual: the READY model has no cola mesh; get_tint_material() returns null")
		return
	for s in crown.mesh.get_surface_count():
		if Toonify.material_name(crown.mesh.surface_get_material(s)) == BUD_TINT_SURFACE:
			_crown = crown
			_crown_surface = s
			return
	push_warning("PlantVisual: %s has no %s surface; get_tint_material() returns null" % [crown.name, BUD_TINT_SURFACE])

# ------------------------------------------------------------------------------------------ wilt crossfade

## Blends towards the current _dry state: one Tween from the current blend value, or a snap.
func _apply_wilt_target(animate: bool) -> void:
	var target := 1.0 if _dry else 0.0
	_kill_wilt_tween()
	var span := absf(target - _wilt)
	if not animate or _stage <= 0 or not is_inside_tree() or not Juice.enabled or span < 0.001:
		_wilt = target
		_apply_wilt()
		return
	_wilt_tween = create_tween()
	_wilt_tween.tween_method(_set_wilt, _wilt, target, WILT_TIME * clampf(span, 0.35, 1.0)) \
			.set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
	_wilt_tween.tween_callback(_on_wilt_tween_done)

func _set_wilt(value: float) -> void:
	_wilt = value
	_apply_wilt()

## End of the blend: land exactly on the rest state (never both models visible at rest).
func _on_wilt_tween_done() -> void:
	_wilt_tween = null
	_wilt = 1.0 if _dry else 0.0
	_apply_wilt()

## Snaps a running blend to its end state.
func _finish_wilt() -> void:
	_kill_wilt_tween()
	_wilt = 1.0 if _dry else 0.0
	_apply_wilt()

func _kill_wilt_tween() -> void:
	if _wilt_tween != null:
		_wilt_tween.kill()
		_wilt_tween = null

## Every wilt visual as a pure function of _wilt (0 healthy .. 1 wilted), for every growing stage at once, so
## a stage change mid-blend (or while dry) already shows the new stage in the same state.
func _apply_wilt() -> void:
	var w := clampf(_wilt, 0.0, 1.0)
	# Whichever way it runs, the outgoing model holds its size, then sinks in late, and the incoming one swells
	# up early: the healthy one follows w^2, the wilted one (1 - w)^2.
	var healthy_k := Vector3.ONE.lerp(HEALTHY_HIDDEN_SCALE, w * w)
	var wilted_k := Vector3.ONE.lerp(WILTED_HIDDEN_SCALE, (1.0 - w) * (1.0 - w))
	for part in _wilt_parts:
		var n: Node3D = part[0]
		var rest: Transform3D = part[1]
		var wilted: bool = part[2]
		var k := wilted_k if wilted else healthy_k
		n.visible = w > 0.0 if wilted else w < 1.0
		n.transform = Transform3D(Basis.from_scale(k) * rest.basis, rest.origin * k)
	_tilt.rotation = DROOP_ROTATION * w

func _apply_dry_indicator(animate: bool) -> void:
	_dry_indicator.visible = _dry
	if _bob_tween != null:
		_bob_tween.kill()
		_bob_tween = null
	_dry_bob.position = Vector3.ZERO
	if _dry and is_inside_tree():
		_bob_tween = create_tween().set_loops()
		_bob_tween.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
		_bob_tween.tween_property(_dry_bob, "position:y", DRY_BOB_HEIGHT, DRY_BOB_TIME)
		_bob_tween.tween_property(_dry_bob, "position:y", 0.0, DRY_BOB_TIME)
		if animate:
			Juice.pop_in(_dry_indicator)

# ------------------------------------------------------------------------------------------ buds

## The colas of the READY model (each pulses around its own base, so none tears off its branch).
func _pulse_nodes() -> Array[Node3D]:
	var out: Array[Node3D] = []
	for c in _ready_buds.get_children():
		if c is MeshInstance3D:
			out.append(c as Node3D)
	return out

## Bud meshes of every model (heavier outline): Flowering/Buds (+ its wilted twin) and the READY colas.
func _bud_nodes() -> Array[Node3D]:
	var out: Array[Node3D] = _pulse_nodes()
	for m in _models:
		var b := m.get_node_or_null(^"Buds") as Node3D
		if b != null and b != _ready_buds:
			out.append(b)
	return out

func _stop_bud_pulse() -> void:
	for cola in _pulse_nodes():
		Juice.stop(cola)
		cola.scale = Vector3.ONE
