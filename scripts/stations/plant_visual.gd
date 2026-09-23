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
##         Dry                                           plant_<stage>_dry.glb: the same plant wilted, shown
##                                                       instead of the healthy parts while the plot is dry
##     Ready/Buds/ColaTop, Cola1..                       one mesh per cola, each pulses in place while READY
##     Ready/Buds/BudTop                                 an empty MeshInstance3D (no mesh) that carries the
##                                                       per-plant strain material (get_tint_material(), which
##                                                       the plot's tag card shares; the farm tests read it)
##   DryIndicator / Bob (bobbing water drop + "DRY" label, stays upright)
## Strain colour: every model's TINT parts (calyxes, frosty tips) take Toon.grade(seed colour) via Toonify.tint.
## Leaves are library greens (never tinted); the wilted models use toon_leaf_dry.

const BUD_MATERIAL: Material = preload("res://art/materials/toon_bud.tres")

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
## Squash when the plant wilts (the model swap happens inside it).
const WILT_BOUNCE := 0.14
const DRY_INDICATOR_GAP := 0.22
const DRY_BOB_HEIGHT := 0.06
const DRY_BOB_TIME := 0.55
const DRY_NODE := &"Dry"
const TINT_CARRIER := &"BudTop"

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
var _bud_material: Material
## Every Toonify model root below (stage models + their Dry variants), for the strain tint.
var _models: Array[Toonify] = []
var _tilt_tween: Tween
var _bob_tween: Tween

func _ready() -> void:
	# Per-plant strain material (raw seed colour) for the plot's tag card; BudTop carries it.
	_bud_material = _make_instance_material(BUD_MATERIAL)
	var carrier := _ready_buds.get_node_or_null(NodePath(TINT_CARRIER)) as MeshInstance3D
	if carrier != null:
		carrier.material_override = _bud_material
	for n in _stage_nodes:
		if n == null:
			continue
		for m in [n, n.get_node_or_null(NodePath(DRY_NODE))]:
			if m is Toonify:
				_models.append(m as Toonify)
	# Buds get a heavier ink line than the leaves (the model roots already outlined everything thinly).
	for bud in _bud_nodes():
		Toonify.outline(bud, BUD_OUTLINE)
	_set_albedo(_bud_material, _tint)
	_apply_tint()
	_apply_stage_visibility()
	_apply_growth()
	_apply_dry(false)

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
	if color == _tint and is_node_ready() and not _models.is_empty() and _models[0].tint.a > 0.0:
		return
	_tint = color
	_set_albedo(_bud_material, color)
	if is_node_ready():
		_apply_tint()

func get_tint() -> Color:
	return _tint

## The per-plant tinted material, so the plot can reuse it (e.g. for its plant tag).
func get_tint_material() -> Material:
	return _bud_material

## Wilts the plant (swaps in the stage's wilted model, slumps it) and shows the bobbing "DRY" drop.
func set_dry(dry: bool, animate: bool) -> void:
	if dry == _dry:
		return
	_dry = dry
	if is_node_ready():
		_apply_dry(animate)

func is_dry() -> bool:
	return _dry

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

## Healthy parts visible when watered, the wilted model when dry (every growing stage, so a stage change while
## dry already shows the right one).
func _apply_wilt_models() -> void:
	for i in range(1, STAGE_COUNT):
		var n := _stage_nodes[i]
		var dry_model := n.get_node_or_null(NodePath(DRY_NODE)) as Node3D
		if dry_model == null:
			continue
		for c in n.get_children():
			if c is Node3D:
				(c as Node3D).visible = _dry if c == dry_model else not _dry

func _apply_dry(animate: bool) -> void:
	_apply_wilt_models()
	var target := DROOP_ROTATION if _dry else Vector3.ZERO
	if _tilt_tween != null:
		_tilt_tween.kill()
		_tilt_tween = null
	if animate and is_inside_tree():
		_tilt_tween = create_tween()
		_tilt_tween.set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
		_tilt_tween.tween_property(_tilt, "rotation", target, 0.45)
		if _dry and _stage > 0:
			Juice.bounce(_bouncer, WILT_BOUNCE)
	else:
		_tilt.rotation = target
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

## The colas of the READY model (each pulses around its own base, so none tears off its branch).
func _pulse_nodes() -> Array[Node3D]:
	var out: Array[Node3D] = []
	for c in _ready_buds.get_children():
		if c is MeshInstance3D and c.name != TINT_CARRIER:
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

static func _make_instance_material(base: Material) -> Material:
	if base == null:
		var m := StandardMaterial3D.new()
		m.diffuse_mode = BaseMaterial3D.DIFFUSE_TOON
		m.specular_mode = BaseMaterial3D.SPECULAR_TOON
		return m
	return base.duplicate() as Material

## Tints a per-instance material. If the base material glows (toon_bud has emission = its albedo), the
## emission follows the tint too, otherwise e.g. purple buds would glow green and wash out.
static func _set_albedo(material: Material, color: Color) -> void:
	if material is BaseMaterial3D:
		var m := material as BaseMaterial3D
		m.albedo_color = color
		if m.emission_enabled:
			m.emission = color
