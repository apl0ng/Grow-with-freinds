class_name Product
extends Item
## Harvested product: a taped bag of product (art/models/product_bundle.glb instanced as Visual/Cluster) whose
## buds (Cluster/Buds/Bud0) take the graded strain colour; the whole Cluster grows with the amount.
## Created by harvesting a READY GrowPlot, destroyed when sold at the TurnInStation.
##
## M14 loop (drying, see DryingRack): three more synced props. `rack` is true while the bundle hangs on a rack hook,
## `dry_left` is the hanging time it still needs (0 = never hung, or done) and `cured` marks a bundle that hung for
## the whole Config.balance.cure_sec: it is tinted darker, its label reads "Cured" and the chute pays 1 + cure_bonus
## for it. Only the host's DryingRack writes them. In the replication config `rack` comes BEFORE `holder_id`: the
## release that puts a bundle on a hook then already knows it is a hang (the `rack_hang` sound instead of the floor
## thud), on the host and on every client alike.

## Tint used when the strain id is unknown.
const UNKNOWN_COLOR := Color(0.7, 0.7, 0.7)
## Visual scale per extra unit of product (amount 1 = 1.0), capped at MAX_VISUAL_SCALE.
const SCALE_PER_UNIT: float = 0.15
const MAX_VISUAL_SCALE: float = 1.6
## M14 loop: how much darker a cured bundle's strain colour is.
const CURED_DARKEN: float = 0.4

## Strain id (SeedDef.id), synced (server authority).
var strain_id: StringName = &"":
	set = _set_strain_id
## Units of product, synced (server authority).
var amount: int = 1:
	set = _set_amount
## M14 loop, synced (server authority): true while the bundle hangs on a DryingRack hook.
var rack: bool = false:
	set = _set_rack
## M14 loop, synced (server authority): seconds of hanging the bundle still needs (0 = never hung, or cured). The
## rack writes it in DryingRack.SYNC_STEP steps while the bundle hangs and exactly when it is taken off.
var dry_left: float = 0.0:
	set = _set_dry_left
## M14 loop, synced (server authority): the bundle hung for the whole cure time.
var cured: bool = false:
	set = _set_cured

var _tint: StandardMaterial3D = null
var _label_rest_y: float = -1.0

@onready var _cluster: Node3D = $Visual/Cluster
@onready var _buds: Node3D = $Visual/Cluster/Buds
@onready var _label: Label3D = $AmountLabel

func get_seed() -> SeedDef:
	return Config.balance.get_seed(strain_id)

func get_strain_name() -> String:
	var def := get_seed()
	return def.display_name if def != null else "Unmarked product"

## "<Strain> x<amount>", e.g. "Purple Haze x2"; M23 fragile: "Purple Haze x2, bruised" once it took a knock.
func get_display_name() -> String:
	return "%s x%d" % [get_strain_name(), amount] + get_bruise_tag() # M23 fragile

## M14 loop: what the worker needs to know about the bundle in hand or under the crosshair: "Heavy", "Cured",
## "Drying 14 s" (on a hook), "6 s to dry" (taken off early). "" for a plain fresh bundle.
func get_status_text() -> String:
	var parts := PackedStringArray()
	if is_heavy():
		parts.append("Heavy")
	if cured:
		parts.append("Cured")
	elif rack:
		parts.append("Drying %d s" % ceili(dry_left))
	elif dry_left > 0.0:
		parts.append("%d s to dry" % ceili(dry_left))
	return ", ".join(parts)

## M14 loop: the strain's bundle is heavy (SeedDef.heavy): its carrier walks slower and cannot sprint (Player).
func is_heavy() -> bool:
	var def := get_seed()
	return def != null and def.heavy

## M14 loop: true while the bundle hangs on a rack hook and is not cured yet.
func is_drying() -> bool:
	return rack and not cured

## M14 loop: the floating label over a bundle that lies or hangs somewhere: "x2", "x2 · 14 s" on a hook, "Cured x2".
## M23 fragile: ", bruised" after any of them once it took a knock ("Cured x2, bruised").
func get_tag_text() -> String:
	if cured:
		return "Cured x%d" % amount + get_bruise_tag() # M23 fragile
	if rack:
		return "x%d · %d s" % [amount, ceili(dry_left)] + get_bruise_tag() # M23 fragile
	return "x%d" % amount + get_bruise_tag() # M23 fragile

## props: {"strain_id": StringName, "amount": int} plus, optionally, the M14 drying state {"rack": bool,
## "dry_left": float, "cured": bool}. Other keys (e.g. a precomputed "value") are ignored.
func apply_props(props: Dictionary) -> void:
	strain_id = StringName(str(props.get("strain_id", strain_id)))
	amount = int(props.get("amount", amount))
	rack = bool(props.get("rack", rack))
	dry_left = float(props.get("dry_left", dry_left))
	cured = bool(props.get("cured", cured))
	var knocks: Variant = props.get("bruises", bruises) # M23 fragile
	bruises = int(knocks) if (knocks is int or knocks is float) else bruises # M23 fragile

## The drying keys only appear once they differ from a fresh bundle's, so a plain bundle's props stay the two it
## always had (M23 fragile: so does "bruises").
func get_props() -> Dictionary:
	var props := {"strain_id": String(strain_id), "amount": amount}
	if rack:
		props["rack"] = true
	if dry_left > 0.0:
		props["dry_left"] = dry_left
	if cured:
		props["cured"] = true
	if bruises > 0:
		props["bruises"] = bruises # M23 fragile
	return props

func _set_strain_id(value: StringName) -> void:
	if value == strain_id:
		return
	strain_id = value
	_notify_props_changed()

func _set_amount(value: int) -> void:
	value = maxi(value, 1)
	if value == amount:
		return
	amount = value
	_notify_props_changed()

func _set_rack(value: bool) -> void:
	if value == rack:
		return
	rack = value
	_notify_props_changed()

func _set_dry_left(value: float) -> void:
	value = maxf(value, 0.0) if is_finite(value) else 0.0
	if value == dry_left:
		return
	dry_left = value
	_notify_props_changed()

func _set_cured(value: bool) -> void:
	if value == cured:
		return
	cured = value
	if value and is_node_ready() and is_inside_tree():
		# Every peer (the setter runs from the sync too): a dry rustle, a little dust, no celebration.
		Sfx.play(&"cured", global_position)
		Juice.puff(global_position + Vector3.UP * 0.2, Juice.GLOOM, 4)
		Juice.bounce(get_visual(), 0.2)
	_notify_props_changed()

## M14 loop: a release that leaves the bundle on a rack hook is a hang (`rack` is set before the holder is cleared, on
## every peer): the hook takes the weight instead of the floor thud.
func _play_holder_effects(old_holder: int, new_holder: int) -> void:
	if new_holder == 0 and old_holder != 0 and rack and not is_flying() and is_inside_tree():
		Sfx.play(&"rack_hang", global_position)
		Juice.bounce(get_visual())
		return
	super(old_holder, new_holder)

func _refresh_visuals() -> void:
	var def := get_seed()
	# Data colours are mood-graded (STYLE.md): the same colour the plant's buds and the seed packet use.
	var color := Toon.grade(def.color if def != null else UNKNOWN_COLOR)
	if cured:
		color = color.darkened(CURED_DARKEN) # M14 loop: dried buds are darker
	color = bruised_color(color, bruises) # M23 fragile: and knocked ones darker again
	var model := _cluster as Toonify
	if model != null and model.tint != color: # (the drying countdown refreshes the label twice a second: no re-toonify)
		model.tint = color # any other TINT part of the bundle model
	if _tint == null:
		# Per-instance copy of the buds' Toonify material, re-tinted in place (never the shared cache).
		var first := _buds.get_child(0) as MeshInstance3D
		var src := first.mesh.surface_get_material(0) if first != null and first.mesh != null else null
		var base := Toonify.toon_material(src, -1.0, color) as StandardMaterial3D
		_tint = base.duplicate() as StandardMaterial3D if base != null else Toon.make(color)
		for child in _buds.get_children():
			var mesh := child as MeshInstance3D
			if mesh != null:
				mesh.material_override = _tint
	_tint.albedo_color = color
	if _tint.emission_enabled:
		_tint.emission = color
	var s := minf(1.0 + SCALE_PER_UNIT * float(amount - 1), MAX_VISUAL_SCALE)
	_cluster.scale = Vector3.ONE * s
	# The floating label rides above the (scaled) bundle: its scene height is the amount-1 height.
	if _label_rest_y < 0.0:
		_label_rest_y = _label.position.y
	_label.position.y = _label_rest_y * s
	_label.text = get_tag_text()
	_label.visible = not is_held()
	_fragile_refresh(s) # M23 fragile: the dent and the grubby bag


# --- M23 fragile ----------------------------------------------------------------------------------------------------------
# CONTRACTS "M23", "Fragile"; FRIENDSLOP 13 (R.E.P.O.'s fragile cargo: the fumble and the cost are the same moment).
# A bundle that hits the floor, a wall, a station or a worker at speed takes a bruise. Every flight ends through one
# impact path (ItemManager, its "M23 fragile" region): the speed the bundle had when it struck is_bruising_impact() (a
# throw always is; so is anything falling from more than BRUISE_FALL_M), so the host calls server_bruise(). A flight that
# ends at the deposit chute (a chute shot, sold or refused) never bruises; nor does a drop (Q), a hang on a rack, the hand
# truck or anything a station puts down: none of them is a flight.
# `bruises` (synced, host-owned, spawn state on) counts the knocks, at most Config.balance.bruise_max. Each takes
# bruise_share of the bundle's value off, ADDITIVE: 1 - bruise_share x bruises (the shipped 0.2 / 2: -20 %, then -40 %),
# TurnInStation.bruise_factor() inside compute_sale_value. So the chute, its prompt, the hand truck's total, the market,
# cured, the job, the stats, the collector and the cost ledger all see the bruised value.
# Every peer: the buds a shade darker, the bag squashed and leaning (the dent) under a grubby overlay; the names gain
# ", bruised" (", badly bruised" from two); the landing's thud is the `bruise` one (a soft, damp thud) instead of `drop`,
# with a little grey dust. The host bruises a bundle before it ends the flight, and `bruises` comes BEFORE
# `flight_serial` in the replication config, so on every peer the count goes up while the bundle is still in the air
# (the setter only marks the landing) and the landing plays the bruise (_play_landing_effects). A bruise outside a
# flight (a test, a late packet) thuds at once. The hand truck keeps "bruises" in its cargo entries.

## Anything that strikes at least as fast as a fall from this high (metres) bruises: sqrt(2 g h), about 5.4 m/s.
const BRUISE_FALL_M: float = 1.5
## How much darker each bruise makes the strain colour (after the cure's darkening), at most BRUISE_DARKEN_MAX.
const BRUISE_DARKEN: float = 0.15
const BRUISE_DARKEN_MAX: float = 0.45
## The dent, per bruise: the bundle squashed (added to its scale on x / y / z) and leaning over (degrees about z).
const BRUISE_DENT := Vector3(0.05, -0.11, 0.04)
const BRUISE_LEAN_DEG: float = 7.0
## The dent stops growing after this many bruises (whatever bruise_max says).
const BRUISE_DENT_MAX: int = 3
## A bruised bundle's bag is drawn once more through this grey, multiplied: a grubbier, darker bag.
const BRUISE_GRIME := Color(0.72, 0.69, 0.7)
## Never more than this many, whatever arrives over the wire (the value only counts up to bruise_max).
const BRUISE_WIRE_MAX: int = 9
## The thrower's toast (ItemManager: the first bundle of theirs that bruises in a shift).
const TOAST_BRUISED := "Bruised. It pays less."

## M23 fragile, synced (server authority): knocks taken (0 = clean). Only server_bruise() raises it; spawn props carry it
## (a bundle off the hand truck).
var bruises: int = 0:
	set = _set_bruises

static var _grime: StandardMaterial3D = null
var _bag_meshes: Array[MeshInstance3D] = []
var _bag_meshes_found: bool = false
## Every peer: a bruise arrived while the bundle was in the air; its landing plays the bruise thud.
var _knock_pending: bool = false


func is_bruised() -> bool:
	return bruises > 0


## True while another knock would still count (fewer than bruise_max).
func can_bruise() -> bool:
	return bruises < maxi(Config.balance.bruise_max, 0)


## What the bruises leave of the bundle's value (1.0 clean).
func get_bruise_factor() -> float:
	return TurnInStation.bruise_factor(bruises)


## ", bruised" / ", badly bruised" / "" (clean).
func get_bruise_tag() -> String:
	return bruise_tag(bruises)


static func bruise_tag(count: int) -> String:
	if count <= 0:
		return ""
	return ", bruised" if count == 1 else ", badly bruised"


## The strain colour of a bundle (or a bag on the hand truck) with `count` bruises: darker per bruise.
static func bruised_color(color: Color, count: int) -> Color:
	if count <= 0:
		return color
	return color.darkened(minf(BRUISE_DARKEN * float(count), BRUISE_DARKEN_MAX))


## The speed (m/s) at which a strike bruises: as fast as a fall from BRUISE_FALL_M.
static func get_bruise_speed() -> float:
	return sqrt(2.0 * absf(Item.FLIGHT_GRAVITY.y) * BRUISE_FALL_M)


## True when something moving at `velocity` as it strikes bruises.
static func is_bruising_impact(velocity: Vector3) -> bool:
	return velocity.is_finite() and velocity.length() >= get_bruise_speed()


## SERVER. One more bruise, up to bruise_max. True when it took one (every peer thuds: at the landing while the bundle
## is in the air, at once otherwise).
func server_bruise() -> bool:
	if not is_inside_tree() or not multiplayer.is_server():
		push_error("Product.server_bruise called on a client")
		return false
	if is_queued_for_deletion() or has_meta(TurnInStation.SOLD_META) or not can_bruise():
		return false
	bruises += 1
	return true


func _set_bruises(value: int) -> void:
	value = clampi(value, 0, BRUISE_WIRE_MAX)
	if value == bruises:
		return
	var knocked := value > bruises
	bruises = value
	if knocked and is_node_ready() and is_inside_tree():
		# Every peer (the setter runs from the sync too): in the air the landing does it, otherwise right here.
		if is_flying():
			_knock_pending = true
		else:
			_play_knock()
	_notify_props_changed()


## Every peer: the bruise thud (a soft, damp thud) and a little grey dust where the bundle is.
func _play_knock() -> void:
	Sfx.play(&"bruise", global_position)
	Juice.puff(global_position + Vector3.UP * 0.15, Juice.GLOOM, 3)


## Item hook (every peer, the flight just ended): a landing that bruised the bundle thuds softer and wetter.
func _play_landing_effects() -> void:
	if not _knock_pending:
		super()
		return
	_knock_pending = false
	_play_knock()
	Juice.bounce(get_visual(), 0.3)


## From _refresh_visuals (`s` = the amount's scale): the dent (squashed, leaning) and the grubby bag, or neither.
func _fragile_refresh(s: float) -> void:
	var n := clampi(bruises, 0, BRUISE_DENT_MAX)
	if n > 0:
		_cluster.scale = Vector3.ONE * s + BRUISE_DENT * (s * float(n))
		_cluster.rotation = Vector3(0.0, 0.0, deg_to_rad(BRUISE_LEAN_DEG * float(n)))
	elif _cluster.rotation != Vector3.ZERO:
		_cluster.rotation = Vector3.ZERO
	var grime: Material = _get_grime() if n > 0 else null
	for mesh in _get_bag_meshes():
		if mesh.material_overlay != grime:
			mesh.material_overlay = grime


## The bag's meshes (everything in the model but the buds and the ink outline hulls), found once.
func _get_bag_meshes() -> Array[MeshInstance3D]:
	if not _bag_meshes_found:
		_bag_meshes_found = true
		for n in _cluster.find_children("*", "MeshInstance3D", true, false):
			var mesh := n as MeshInstance3D
			if mesh != null and not mesh.has_meta(&"toonify_outline") and not _buds.is_ancestor_of(mesh):
				_bag_meshes.append(mesh)
	return _bag_meshes


## One shared material for every bruised bag: unshaded grey, multiplied over the bag (a darker, grubbier plastic).
static func _get_grime() -> StandardMaterial3D:
	if _grime == null:
		_grime = StandardMaterial3D.new()
		_grime.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		_grime.blend_mode = BaseMaterial3D.BLEND_MODE_MUL
		_grime.albedo_color = BRUISE_GRIME
	return _grime

# --- end M23 fragile ------------------------------------------------------------------------------------------------------


# --- M17 cart -----------------------------------------------------------------------------------------------------------
# A worker holding the hand truck (HandTruck) who presses E on a bundle nobody else holds (on the floor, on a rack) loads
# it onto the truck instead of picking it up: the prompt, the check and the host's action are the truck's. Without a
# truck in hand everything is the plain item interaction.

func get_prompt(player: Player) -> String:
	var truck := HandTruck.held_by(player)
	if truck != null:
		return truck.get_load_prompt(self)
	return super(player)


func can_interact(player: Player) -> bool:
	var truck := HandTruck.held_by(player)
	if truck != null:
		return truck.get_load_denial(self, player) == ""
	return super(player)


func get_denied_reason(player: Player) -> String:
	var truck := HandTruck.held_by(player)
	if truck != null:
		return truck.get_load_denial(self, player)
	return super(player)


func _server_interact(player: Player) -> void:
	var truck := HandTruck.held_by(player)
	if truck != null:
		truck.server_load(self, player.peer_id)
		return
	super(player)

# --- end M17 cart -------------------------------------------------------------------------------------------------------
