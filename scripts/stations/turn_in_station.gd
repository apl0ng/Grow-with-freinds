class_name TurnInStation
extends Interactable
## Sell point (owner: economy agent). Front (the slot + sign side) is local +Z.
##
## Holding a Product and pressing E sells it through the base Interactable flow:
##   client  interact() -> can_interact() prediction -> base RPC to the host
##   server  base re-validates range + can_interact() -> _server_interact(player):
##           value = round(amount * seed.sale_value_per_unit * GameState.get_sale_multiplier())  (recomputed here)
##           GameState.server_add_sale(value, peer) -> ItemManager.server_despawn_item(product)
##           _rpc_sold_fx.rpc(value, color)  (cosmetic: float text, burst, bounce, sound on every peer)
## The floating "Sold: $x / $quota" label follows GameState.sales_changed on every peer.
##
## Products are read by duck typing (item_type == Const.ITEM_PRODUCT, properties strain_id / amount) so this
## station does not depend on the Product class being loaded.

const REASON_EMPTY := "Nothing to deposit."
const REASON_NOT_PRODUCT := "Product only."
const REASON_BAD_PRODUCT := "Won't take that."
const REASON_NOT_PLAYING := "Chute opens when the shift starts."
const SOLD_META: StringName = &"econ_sold"

## If true, product can only be sold while a round is running (GameState.is_playing()). Sales between rounds
## would otherwise count toward a round that has already ended and be lost for the next quota.
@export var sell_only_while_playing: bool = true
## Radians per second the coin above the sign spins (purely cosmetic, local).
@export var coin_spin_speed: float = 1.8

@onready var _visual: Node3D = get_node_or_null(^"Visual") as Node3D
@onready var _coin: Node3D = get_node_or_null(^"Visual/Sign/Coin") as Node3D
@onready var _sold_label: Label3D = get_node_or_null(^"SoldLabel") as Label3D

var _last_sales: int = -1


func _ready() -> void:
	GameState.sales_changed.connect(_on_sales_changed)
	_on_sales_changed(GameState.round_sales, GameState.quota)
	set_process(_coin != null)


func _process(delta: float) -> void:
	_coin.rotate_y(coin_spin_speed * delta)


# --- Interactable overrides -----------------------------------------------------------------------------------------

func get_prompt(player: Player) -> String:
	var product := _get_held_product(player)
	if product == null:
		return "Deposit product"
	var seed_def := _get_product_seed(product)
	var strain := seed_def.display_name if seed_def != null else str(product.get(&"strain_id"))
	return "Deposit %s x%d (+$%d)" % [strain, _get_product_amount(product), get_sale_value(product)]


func can_interact(player: Player) -> bool:
	return _get_denial(player) == ""


func get_denied_reason(player: Player) -> String:
	return _get_denial(player)


## SERVER ONLY (called by the base after range + can_interact() validation).
func _server_interact(player: Player) -> void:
	if _get_denial(player) != "":
		return
	var product := _get_held_product(player)
	var seed_def := _get_product_seed(product)
	var value := get_sale_value(product)
	if value <= 0:
		return
	var items := _get_item_manager()
	if items == null:
		return
	# Mark first: a second sell request processed before the despawn lands can never pay twice.
	product.set_meta(SOLD_META, true)
	GameState.server_add_sale(value, player.peer_id)
	items.server_despawn_item(product)
	_rpc_sold_fx.rpc(value, seed_def.color)


# --- Value helpers --------------------------------------------------------------------------------------------------

## Pure sale formula: round(amount * seed.sale_value_per_unit * multiplier). 0 for unknown seeds / empty stacks.
static func compute_sale_value(seed_def: SeedDef, amount: int, multiplier: float) -> int:
	if seed_def == null or amount <= 0:
		return 0
	return int(round(amount * seed_def.sale_value_per_unit * multiplier))


## Value of `product` right now, including the team's sale upgrades.
func get_sale_value(product: Item) -> int:
	if product == null:
		return 0
	return compute_sale_value(_get_product_seed(product), _get_product_amount(product),
			GameState.get_sale_multiplier())


## The product `player` is holding (null if empty hands, not a product, or already sold).
func _get_held_product(player: Player) -> Item:
	var item := _get_held_item(player)
	if item == null or item.item_type != Const.ITEM_PRODUCT or item.has_meta(SOLD_META):
		return null
	return item


func _get_denial(player: Player) -> String:
	var item := _get_held_item(player)
	if item == null:
		return REASON_EMPTY
	if item.item_type != Const.ITEM_PRODUCT:
		return REASON_NOT_PRODUCT
	if item.has_meta(SOLD_META) or get_sale_value(item) <= 0:
		return REASON_BAD_PRODUCT
	if sell_only_while_playing and not GameState.is_playing():
		return REASON_NOT_PLAYING
	return ""


static func _get_held_item(player: Player) -> Item:
	if player == null or not is_instance_valid(player):
		return null
	var item: Item = player.get_held_item()
	if item == null or not is_instance_valid(item) or item.is_queued_for_deletion():
		return null
	return item


static func _get_product_seed(product: Item) -> SeedDef:
	var strain: Variant = product.get(&"strain_id")
	if strain == null:
		return null
	return Config.balance.get_seed(StringName(str(strain)))


static func _get_product_amount(product: Item) -> int:
	var amount: Variant = product.get(&"amount")
	if amount is int or amount is float:
		return int(amount)
	return 0


func _get_item_manager() -> ItemManager:
	if Game.world == null or not is_instance_valid(Game.world):
		return null
	return Game.world.items


# --- Cosmetics ------------------------------------------------------------------------------------------------------

@rpc("authority", "call_local", "reliable")
func _rpc_sold_fx(value: int, color: Color) -> void:
	Juice.float_text(global_position + Vector3.UP * 1.5, "+$%d" % value, color)
	Juice.burst(to_global(Vector3(0.0, 1.1, 0.2)), color, 16)
	if _visual != null:
		Juice.bounce(_visual, 0.25)
	Sfx.play(&"sell", global_position)


func _on_sales_changed(round_sales: int, quota: int) -> void:
	if _sold_label == null:
		return
	_sold_label.text = get_sold_text(round_sales, quota)
	var met := quota > 0 and round_sales >= quota
	_sold_label.modulate = Color("b2f2bb") if met else Color.WHITE
	if _last_sales >= 0 and round_sales > _last_sales:
		Juice.bounce(_sold_label, 0.15)
	_last_sales = round_sales


## Text of the floating progress label, e.g. "DEPOSITED $120 / $400" (flat copy: it is a deposit chute).
static func get_sold_text(round_sales: int, quota: int) -> String:
	if quota <= 0:
		return "DEPOSITED $%d" % round_sales
	if round_sales >= quota:
		return "DEPOSITED $%d / $%d\nPAID… FOR NOW" % [round_sales, quota]
	return "DEPOSITED $%d / $%d" % [round_sales, quota]
