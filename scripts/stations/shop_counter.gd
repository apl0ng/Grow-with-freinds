class_name ShopCounter
extends Interactable
## Shopkeeper counter (owner: economy agent). Front (customer side) is local +Z.
##
## OPENING THE SHOP IS LOCAL ONLY. Pressing E on the counter opens the ShopUI on the interacting client; no
## shared state changes, so there is no server round trip. That is why this class overrides `interact()`
## (the one documented exception to "never override interact()") and keeps `_server_interact()` a no-op.
##
## PURCHASES ARE SERVER-AUTHORITATIVE RPCs on this node (same path on every peer: World/Room/Stations/ShopCounter):
##   client  request_buy_seed(id)          -> _rpc_request_buy_seed.rpc_id(1, id)
##   server  server_buy_seed(sender, id)   -> validates: player exists, range, seed exists, empty hands, money
##                                            -> GameState.server_try_spend -> ItemManager.server_spawn_item (in hands)
##   server  _rpc_buy_result.rpc_id(sender, ok, message, kind, id)  -> toast + sfx + shop UI feedback (buyer only)
##   server  _rpc_purchase_fx.rpc(buyer, color)                     -> cosmetic burst/bounce/sfx (everyone)
## Upgrades use request_buy_upgrade / server_buy_upgrade the same way (validates player, range, upgrade, max level,
## then GameState.server_buy_upgrade).

const SHOP_UI_SCENE_PATH := "res://scenes/ui/shop_ui.tscn"
const UI_LOCK_SOURCE: StringName = &"shop"
const KIND_SEED: StringName = &"seed"
const KIND_UPGRADE: StringName = &"upgrade"

const REASON_NOT_SERVER := "Only the host can process purchases"
const REASON_NO_PLAYER := "Player not found"
const REASON_TOO_FAR := "Too far away"
const REASON_UNKNOWN_SEED := "Unknown seed"
const REASON_UNKNOWN_UPGRADE := "Unknown upgrade"
const REASON_HANDS_FULL := "Hands full — drop your item first"
const REASON_NO_MONEY := "Not enough money"
const REASON_MAXED := "Already at max level"
const REASON_UNAVAILABLE := "The shop is closed right now"
const REASON_FAILED := "Can't buy that right now"
const REASON_REFUNDED := "Something went wrong, money refunded"
const REASON_NOT_CONNECTED := "Not connected to the host"

## An open shop UI closes itself when the local player walks further than this from the counter (metres).
## If the shop was opened from further away than this, the UI allows a little slack instead of closing at once,
## but it always closes before the server's range check (interact_distance + server_range_slack) would fail.
@export var ui_close_distance: float = 4.0
## Where purchased seed packets appear (local space, above the counter top). Only visible if the item is not
## put into the buyer's hands for some reason.
@export var item_spawn_offset: Vector3 = Vector3(0.0, 1.35, 0.35)

var _ui: ShopUI = null
var _seed_materials: Dictionary = {}   # StringName seed id -> StandardMaterial3D

@onready var _keeper_anchor: Node3D = get_node_or_null(^"ShopkeeperAnchor") as Node3D
@onready var _keeper: Node3D = get_node_or_null(^"ShopkeeperAnchor/Shopkeeper") as Node3D
@onready var _jars: Node3D = get_node_or_null(^"Visual/Jars") as Node3D
@onready var _badges: Node3D = get_node_or_null(^"Visual/Badges") as Node3D


func _ready() -> void:
	_decorate_from_balance()


func _exit_tree() -> void:
	# The UI lives under the viewport root (so its input runs before the HUD's); free it with the counter.
	if _ui != null and is_instance_valid(_ui):
		_ui.close(false)
		_ui.queue_free()
	_ui = null


# --- Interactable overrides ---------------------------------------------------------------------------------------

func get_prompt(_player: Player) -> String:
	return "Browse seeds & upgrades"


func can_interact(_player: Player) -> bool:
	return true


func get_denied_reason(_player: Player) -> String:
	return ""


## Local only: opens the shop UI for the local player. Deliberately does NOT call super() (no server RPC needed).
func interact(player: Player) -> void:
	if player == null or not player.is_local():
		return
	open_shop_for(player)


## Never reached (interact() does not send the base RPC); kept explicit so a stray request is a harmless no-op.
func _server_interact(_player: Player) -> void:
	pass


# --- Shop UI (local) ------------------------------------------------------------------------------------------------

## Opens the ShopUI for `player`. Ignored for remote players: the UI only ever opens on the player's own machine.
func open_shop_for(player: Player) -> void:
	if player == null or not is_instance_valid(player) or not player.is_local():
		return
	if not is_inside_tree():
		return
	_ensure_ui()
	if _ui == null:
		return
	_ui.open(self, player)
	_keeper_react(&"wave", 0.12)


func close_shop() -> void:
	if _ui != null and is_instance_valid(_ui):
		_ui.close()


func is_shop_open() -> bool:
	return _ui != null and is_instance_valid(_ui) and _ui.is_open()


## The lazily created ShopUI (null until the shop was opened once on this peer).
func get_shop_ui() -> ShopUI:
	return _ui if (_ui != null and is_instance_valid(_ui)) else null


## Maximum distance (metres, from this node's origin) at which the server accepts purchases.
func get_server_range() -> float:
	return Config.balance.interact_distance + server_range_slack


func get_item_spawn_position() -> Vector3:
	return to_global(item_spawn_offset)


func _ensure_ui() -> void:
	if _ui != null and is_instance_valid(_ui):
		return
	var scene := load(SHOP_UI_SCENE_PATH) as PackedScene
	if scene == null:
		push_error("ShopCounter: could not load %s" % SHOP_UI_SCENE_PATH)
		return
	_ui = scene.instantiate() as ShopUI
	if _ui == null:
		push_error("ShopCounter: %s root is not a ShopUI" % SHOP_UI_SCENE_PATH)
		return
	# A CanvasLayer draws the same from anywhere; under the root it is the last node to exist, so its _input
	# (Esc/E to close) runs before the HUD's and can mark the event handled.
	get_tree().root.add_child(_ui)


# --- Client requests ------------------------------------------------------------------------------------------------

## Any peer (normally from the ShopUI). Asks the host to buy one packet of `seed_id` for the local player.
func request_buy_seed(seed_id: StringName) -> void:
	if not _can_send():
		_show_result(false, REASON_NOT_CONNECTED, KIND_SEED, seed_id)
		return
	_rpc_request_buy_seed.rpc_id(Const.SERVER_PEER_ID, seed_id)


## Any peer (normally from the ShopUI). Asks the host to buy the next level of `upgrade_id` for the team.
func request_buy_upgrade(upgrade_id: StringName) -> void:
	if not _can_send():
		_show_result(false, REASON_NOT_CONNECTED, KIND_UPGRADE, upgrade_id)
		return
	_rpc_request_buy_upgrade.rpc_id(Const.SERVER_PEER_ID, upgrade_id)


func _can_send() -> bool:
	if not is_inside_tree():
		return false
	var peer := multiplayer.multiplayer_peer
	return peer != null and peer.get_connection_status() == MultiplayerPeer.CONNECTION_CONNECTED


# --- Server side ----------------------------------------------------------------------------------------------------

@rpc("any_peer", "call_local", "reliable")
func _rpc_request_buy_seed(seed_id: StringName) -> void:
	if not multiplayer.is_server():
		return
	var sender := _get_sender_id()
	var result := server_buy_seed(sender, seed_id)
	_rpc_buy_result.rpc_id(sender, bool(result["ok"]), String(result["message"]), KIND_SEED, seed_id)


@rpc("any_peer", "call_local", "reliable")
func _rpc_request_buy_upgrade(upgrade_id: StringName) -> void:
	if not multiplayer.is_server():
		return
	var sender := _get_sender_id()
	var result := server_buy_upgrade(sender, upgrade_id)
	_rpc_buy_result.rpc_id(sender, bool(result["ok"]), String(result["message"]), KIND_UPGRADE, upgrade_id)


## SERVER ONLY. Validates and performs a seed purchase for `peer_id`; the packet spawns in that player's hands.
## Returns {"ok": bool, "reason": String (why it failed, "" on success), "message": String (text for the buyer)}.
## Validation order: host, player exists, in range, seed exists, empty hands, item manager present, money.
func server_buy_seed(peer_id: int, seed_id: StringName) -> Dictionary:
	if not _is_server():
		return _fail(REASON_NOT_SERVER)
	var player: Player = Game.get_player(peer_id)
	if player == null or not is_instance_valid(player):
		return _fail(REASON_NO_PLAYER)
	if not _server_in_range(player):
		return _fail(REASON_TOO_FAR)
	var seed_def: SeedDef = Config.balance.get_seed(seed_id)
	if seed_def == null:
		return _fail(REASON_UNKNOWN_SEED)
	if player.get_held_item() != null:
		return _fail(REASON_HANDS_FULL)
	var items := _get_item_manager()
	if items == null:
		return _fail(REASON_UNAVAILABLE)
	if not GameState.server_try_spend(seed_def.cost, peer_id, "seed:" + String(seed_def.id)):
		return _fail(REASON_NO_MONEY)
	var packet: Item = items.server_spawn_item(Const.ITEM_SEED_PACKET, {"strain_id": seed_def.id},
			get_item_spawn_position(), peer_id)
	if packet == null:
		# The money is already gone: refund so a spawn bug never eats the team's cash.
		push_warning("ShopCounter: seed packet spawn failed for peer %d, refunding %d" % [peer_id, seed_def.cost])
		GameState.server_add_money(seed_def.cost)
		return _fail(REASON_REFUNDED)
	_rpc_purchase_fx.rpc(peer_id, seed_def.color)
	return _ok("Bought %s seeds!" % seed_def.display_name)


## SERVER ONLY. Validates and buys the next level of a team upgrade for `peer_id`.
## Returns {"ok": bool, "reason": String, "message": String} like server_buy_seed().
## Validation order: host, player exists, in range, upgrade exists, not maxed, GameState.server_buy_upgrade (money).
func server_buy_upgrade(peer_id: int, upgrade_id: StringName) -> Dictionary:
	if not _is_server():
		return _fail(REASON_NOT_SERVER)
	var player: Player = Game.get_player(peer_id)
	if player == null or not is_instance_valid(player):
		return _fail(REASON_NO_PLAYER)
	if not _server_in_range(player):
		return _fail(REASON_TOO_FAR)
	var def: UpgradeDef = Config.balance.get_upgrade(upgrade_id)
	if def == null:
		return _fail(REASON_UNKNOWN_UPGRADE)
	var level := GameState.get_upgrade_level(upgrade_id)
	if level >= def.max_level:
		return _fail(REASON_MAXED)
	var cost := def.cost_for_level(level + 1)
	if not GameState.server_buy_upgrade(upgrade_id, peer_id):
		return _fail(REASON_NO_MONEY if GameState.money < cost else REASON_FAILED)
	var new_level := maxi(GameState.get_upgrade_level(upgrade_id), level + 1)
	_rpc_purchase_fx.rpc(peer_id, get_effect_color(def.effect_key))
	return _ok("%s upgraded to level %d!" % [def.display_name, new_level])


func _server_in_range(player: Player) -> bool:
	if not player.is_inside_tree() or not is_inside_tree():
		return false
	return player.global_position.distance_to(global_position) <= get_server_range()


func _get_item_manager() -> ItemManager:
	if Game.world == null or not is_instance_valid(Game.world):
		return null
	return Game.world.items


func _get_sender_id() -> int:
	var sender := multiplayer.get_remote_sender_id()
	return Const.SERVER_PEER_ID if sender == 0 else sender


func _is_server() -> bool:
	return is_inside_tree() and multiplayer.is_server()


static func _fail(reason: String) -> Dictionary:
	return {"ok": false, "reason": reason, "message": reason}


static func _ok(message: String) -> Dictionary:
	return {"ok": true, "reason": "", "message": message}


# --- Server -> client results / cosmetics ----------------------------------------------------------------------------

@rpc("authority", "call_local", "reliable")
func _rpc_buy_result(ok: bool, message: String, kind: StringName, what_id: StringName) -> void:
	_show_result(ok, message, kind, what_id)


func _show_result(ok: bool, message: String, kind: StringName, what_id: StringName) -> void:
	if message != "":
		Game.toast(message, &"success" if ok else &"error")
	Sfx.play(&"buy" if ok else &"error")
	if _ui != null and is_instance_valid(_ui):
		_ui.on_purchase_result(ok, message, kind, what_id)


## Everyone: a little celebration at the counter. The buyer already heard the 2D "buy" sound from the result.
@rpc("authority", "call_local", "reliable")
func _rpc_purchase_fx(buyer_peer: int, color: Color) -> void:
	var top := to_global(Vector3(0.0, 1.3, 0.2))
	Juice.burst(top, color, 10)
	_keeper_react(&"cheer", 0.18)
	if multiplayer.get_unique_id() != buyer_peer:
		Sfx.play(&"buy", top)


# --- Visuals --------------------------------------------------------------------------------------------------------

## Plays one of the shopkeeper's optional hooks (ShopkeeperNPC.wave() / cheer()); bounces it if the hook is missing.
func _keeper_react(method: StringName, fallback_bounce: float) -> void:
	if _keeper != null and _keeper.has_method(method):
		_keeper.call(method)
	elif _keeper_anchor != null:
		Juice.bounce(_keeper_anchor, fallback_bounce)


## Colour used for an upgrade's icon / purchase burst, by effect key (art palette: grass, sky, sunshine, mint, grape).
static func get_effect_color(effect_key: StringName) -> Color:
	match effect_key:
		Const.EFFECT_GROWTH_SPEED:
			return Color("4fcb6b")
		Const.EFFECT_CAN_CAPACITY:
			return Color("4da8f7")
		Const.EFFECT_SALE_BONUS:
			return Color("ffd23f")
		Const.EFFECT_WATER_RETENTION:
			return Color("33d1b0")
	return Color("9a6bff")


## Tints the jars / front badges with the seed colours from balance.tres and writes the price tags.
func _decorate_from_balance() -> void:
	var seeds: Array[SeedDef] = Config.balance.seeds
	if _jars != null:
		var i := 0
		for jar in _jars.get_children():
			var jar3d := jar as Node3D
			if jar3d == null:
				continue
			if i >= seeds.size():
				jar3d.visible = false
				i += 1
				continue
			var seed_def := seeds[i]
			var fill := jar3d.get_node_or_null(^"Fill") as MeshInstance3D
			if fill != null:
				fill.material_override = _get_seed_material(seed_def)
			var tag := jar3d.get_node_or_null(^"PriceTag") as Label3D
			if tag != null:
				tag.text = "$%d" % seed_def.cost
			i += 1
	if _badges != null:
		var j := 0
		for badge in _badges.get_children():
			var badge3d := badge as Node3D
			if badge3d == null:
				continue
			if j >= seeds.size():
				badge3d.visible = false
				j += 1
				continue
			var face := badge3d.get_node_or_null(^"Face") as MeshInstance3D
			if face != null:
				face.material_override = _get_seed_material(seeds[j])
			j += 1


func _get_seed_material(seed_def: SeedDef) -> StandardMaterial3D:
	if _seed_materials.has(seed_def.id):
		return _seed_materials[seed_def.id]
	var base := load("res://art/materials/toon_white.tres") as StandardMaterial3D
	var mat: StandardMaterial3D = base.duplicate() if base != null else StandardMaterial3D.new()
	mat.albedo_color = seed_def.color
	_seed_materials[seed_def.id] = mat
	return mat
