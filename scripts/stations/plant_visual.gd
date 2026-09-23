class_name PlantVisual
extends Node3D
## Cartoon plant model used by GrowPlot (scenes/stations/plant_visual.tscn). Pure presentation:
## it holds no game state and every setter is idempotent and cheap (called from synced-property setters
## on every peer, possibly every frame).
##
## Stage index matches GrowPlot.Stage: 0 = nothing, 1 seedling, 2 vegetative, 3 flowering, 4 ready.
## Node layout (Juice targets always keep a nominal scale of 1):
##   Tilt (droop rotation when dry) / Bouncer (Juice.bounce) / Grow (scale 0.8..1 with stage progress)
##     / Seedling | Vegetative | Flowering | Ready   (Juice.pop_in on stage change)
##     Ready/Buds (Juice.pulse while READY)
##   DryIndicator / Bob (bobbing water drop + "DRY!" label, stays upright)

const BUD_MATERIAL: Material = preload("res://art/materials/toon_bud.tres")
const LEAF_MATERIAL: Material = preload("res://art/materials/toon_leaf.tres")

const STAGE_COUNT := 5
## Local height of the top of each stage's model at full growth (index = stage).
const STAGE_HEIGHTS: Array[float] = [0.0, 0.24, 0.58, 0.8, 1.05]
## Scale of the Grow node at the start of a stage; it reaches 1.0 when the stage completes.
const GROW_MIN_SCALE := 0.8
## Droop applied to Tilt while the plant is dry (radians).
const DROOP_ROTATION := Vector3(0.3, 0.0, -0.16)
## Thirsty leaves take the art library's dry-leaf colour (fallback if the material is missing).
const LEAF_DRY_MATERIAL_PATH := "res://art/materials/toon_leaf_dry.tres"
const DRY_LEAF_FALLBACK := Color(0.72, 0.69, 0.29)
## How far the leaves move from their normal colour towards the dry colour.
const DRY_LEAF_BLEND := 0.8
const DRY_INDICATOR_GAP := 0.22
const DRY_BOB_HEIGHT := 0.06
const DRY_BOB_TIME := 0.55

@onready var _tilt: Node3D = %Tilt
@onready var _bouncer: Node3D = %Bouncer
@onready var _grow: Node3D = %Grow
@onready var _ready_buds: Node3D = %Buds
@onready var _dry_indicator: Node3D = %DryIndicator
@onready var _dry_bob: Node3D = %Bob
@onready var _stage_nodes: Array[Node3D] = [null, %Seedling, %Vegetative, %Flowering, %Ready]

var _stage: int = 0
var _progress: float = 0.0
var _dry: bool = false
var _tint: Color = Color(0.55, 0.85, 0.35)
var _bud_material: Material
var _leaf_material: Material
var _leaf_base_color: Color = Color(0.25, 0.75, 0.35)
var _leaf_dry_color: Color = DRY_LEAF_FALLBACK
var _tilt_tween: Tween
var _bob_tween: Tween

func _ready() -> void:
	# Per-plant material copies so each plot can tint its buds (seed colour) and yellow its leaves (dry).
	_bud_material = _make_instance_material(BUD_MATERIAL)
	_leaf_material = _make_instance_material(LEAF_MATERIAL)
	if _leaf_material is BaseMaterial3D:
		_leaf_base_color = (_leaf_material as BaseMaterial3D).albedo_color
	if ResourceLoader.exists(LEAF_DRY_MATERIAL_PATH):
		var dry_mat := load(LEAF_DRY_MATERIAL_PATH) as BaseMaterial3D
		if dry_mat != null:
			_leaf_dry_color = dry_mat.albedo_color
	for node in find_children("*", "MeshInstance3D", true, false):
		var mi := node as MeshInstance3D
		if mi.name.begins_with("Bud"):
			mi.material_override = _bud_material
		elif mi.name.begins_with("Leaf") or mi.name.begins_with("Bush"):
			mi.material_override = _leaf_material
	_set_albedo(_bud_material, _tint)
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
		Juice.stop(_ready_buds)
		_ready_buds.scale = Vector3.ONE
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

## Bud (and plant tag) colour, normally SeedDef.color.
func set_tint(color: Color) -> void:
	_tint = color
	_set_albedo(_bud_material, color)

func get_tint() -> Color:
	return _tint

## The per-plant tinted material, so the plot can reuse it (e.g. for its plant tag).
func get_tint_material() -> Material:
	return _bud_material

## Droops the plant, yellows the leaves and shows the bobbing "DRY!" drop.
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
		Juice.pulse(_ready_buds)
	_dry_indicator.position.y = STAGE_HEIGHTS[_stage] + DRY_INDICATOR_GAP

func _apply_growth() -> void:
	var s := _grow_scale()
	_grow.scale = Vector3(s, s, s)

func _grow_scale() -> float:
	if _stage <= 0 or _stage >= STAGE_COUNT - 1:
		return 1.0
	return lerpf(GROW_MIN_SCALE, 1.0, _progress)

func _apply_dry(animate: bool) -> void:
	var target := DROOP_ROTATION if _dry else Vector3.ZERO
	if _tilt_tween != null:
		_tilt_tween.kill()
		_tilt_tween = null
	if animate and is_inside_tree():
		_tilt_tween = create_tween()
		_tilt_tween.set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
		_tilt_tween.tween_property(_tilt, "rotation", target, 0.45)
	else:
		_tilt.rotation = target
	var leaf_color := _leaf_base_color.lerp(_leaf_dry_color, DRY_LEAF_BLEND) if _dry else _leaf_base_color
	_set_albedo(_leaf_material, leaf_color)
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
