class_name EmergencyCabinet
extends Interactable
## The red "break glass" cabinet on the west wall (scenes/stations/emergency_cabinet.tscn, owner: flame agent, M12).
## Wall-mounted like the FuseBox: the scene origin is the mount point on the wall (back centre), front = local +Z.
##
## It holds ONE flamethrower. A worker with empty hands and enough cash on hand presses E:
##   client  interact(player)              Interactable's local check + _rpc_request_interact (range, back room)
##   server  _server_interact(player)      -> server_break(player): GameState.server_try_spend(cabinet_deposit,
##                                          peer, DEPOSIT_WHAT) must succeed; the flamethrower spawns straight into
##                                          the hands ({"fuel": flamethrower_fuel_sec}); `broken` = true and the
##                                          restock countdown starts (host); the glass break is a cosmetic RPC on
##                                          every peer; breaking it while no hostile plant is alive is a write-up
##                                          (Const.WRITE_UP_MISUSE: "misuse of emergency equipment").
## Synced ($Sync, server authority, both ON_CHANGE): `broken` and `restock_left` (whole seconds; the host keeps the
## exact countdown in _restock_exact and only writes the synced value when the second changes, so the countdown
## costs one small reliable packet per second instead of a stream). After cabinet_restock_sec the host restocks
## (`broken` false, the placeholder flamethrower reappears behind new glass).
## Prompt: "Break glass" / greyed "Restocking (42 s)" / "Cash short" / "Hands full" (CONTRACTS.md "M12").
## A full game reset (GameState.game_reset) restocks the cabinet at once and despawns every flamethrower on the
## floor or in hands (seed packets / products get the same treatment from the ItemManager).
## Visual: `Visual/Glass` (the pane) and `Visual/Stock` (the placeholder flamethrower inside) are hidden while broken;
## the lead swaps `emergency_cabinet.glb` in under `Visual` (keep a `Glass` child, or point GLASS_PATH at the pane).

## Every peer: the glass was broken by `by_peer` (cosmetic RPC; the flamethrower is already in their hands).
signal glass_broken(by_peer: int)
## Every peer: the cabinet holds a flamethrower again.
signal restocked

## Item type of the flamethrower (Const.ITEM_FLAMETHROWER once the lead adds it; kept local until the merge).
const ITEM_FLAMETHROWER: StringName = &"flamethrower"
const PROMPT_BREAK := "Break glass"
const PROMPT_RESTOCKING := "Restocking (%d s)"
const REASON_CASH_SHORT := "Cash short"
const REASON_HANDS_FULL := "Hands full"
const REASON_UNAVAILABLE := "Cabinet's jammed."
## The `what` of the deposit (GameState.purchase_made / server_try_spend).
const DEPOSIT_WHAT := "Emergency equipment deposit"
## Glass shard colour for the break burst (Toon.lib glass is a pale blue-grey).
const GLASS_COLOR := Color("b7c6cf")
const GLASS_PATH := ^"Visual/Glass"
const STOCK_PATH := ^"Visual/Stock"

## Synced (server authority). True while the glass is broken and the cabinet is empty.
var broken: bool = false:
	set = _set_broken
## Synced (server authority). Whole seconds until the cabinet is restocked (0 while stocked).
var restock_left: int = 0:
	set = _set_restock_left

var _restock_exact: float = 0.0   # host: the exact countdown
var _glass: Node3D
var _stock: Node3D


func _ready() -> void:
	_glass = get_node_or_null(GLASS_PATH) as Node3D
	_stock = get_node_or_null(STOCK_PATH) as Node3D
	GameState.game_reset.connect(_on_game_reset)
	_refresh_visuals()


func _process(delta: float) -> void:
	if not broken or not Net.is_host or not GrowPlot.is_server_peer(self):
		return
	_restock_exact = maxf(_restock_exact - delta, 0.0)
	if _restock_exact <= 0.0:
		server_restock()
		return
	var whole := ceili(_restock_exact)
	if whole != restock_left:
		restock_left = whole


# --- queries (any peer) ---------------------------------------------------------------------------------------------

func is_broken() -> bool:
	return broken


## Seconds until the cabinet is restocked (whole seconds, as synced; 0 while stocked).
func get_restock_left() -> float:
	return float(restock_left) if broken else 0.0


func get_deposit() -> int:
	return maxi(Config.balance.cabinet_deposit, 0)


## Where the flamethrower would appear if it had to be placed instead of handed over (just in front of the pane).
func get_item_spawn_position() -> Vector3:
	return global_position + global_basis.z * 0.6


# --- Interactable overrides -----------------------------------------------------------------------------------------

func get_prompt(_player: Player) -> String:
	if broken:
		return PROMPT_RESTOCKING % maxi(restock_left, 1)
	return PROMPT_BREAK


func can_interact(player: Player) -> bool:
	if player == null or broken:
		return false
	if GrowPlot.get_held_item_of(player) != null:
		return false
	return GameState.money >= get_deposit()


func get_denied_reason(player: Player) -> String:
	if broken:
		return PROMPT_RESTOCKING % maxi(restock_left, 1)
	if player != null and GrowPlot.get_held_item_of(player) != null:
		return REASON_HANDS_FULL
	if GameState.money < get_deposit():
		return REASON_CASH_SHORT
	return ""


func _server_interact(player: Player) -> void:
	server_break(player)


# --- server API -----------------------------------------------------------------------------------------------------

## SERVER. `player` breaks the glass: the deposit is taken, the flamethrower lands in their hands, the cabinet is
## empty until the restock. False (and a denial toast to the worker) when the cabinet is broken, the hands are full,
## the cash is short or the item could not spawn (the deposit is refunded then).
func server_break(player: Player) -> bool:
	if not GrowPlot.is_server_peer(self):
		push_error("EmergencyCabinet.server_break called on a client")
		return false
	if player == null or not is_instance_valid(player) or not player.is_inside_tree():
		return false
	var peer := player.peer_id
	if broken:
		_deny(peer, PROMPT_RESTOCKING % maxi(restock_left, 1))
		return false
	var items := ItemManager.find(self)
	if items == null:
		_deny(peer, REASON_UNAVAILABLE)
		return false
	if items.get_held_by(peer) != null:
		_deny(peer, REASON_HANDS_FULL)
		return false
	var deposit := get_deposit()
	if not GameState.server_try_spend(deposit, peer, DEPOSIT_WHAT):
		_deny(peer, REASON_CASH_SHORT)
		return false
	var props := {"fuel": maxf(Config.balance.flamethrower_fuel_sec, 0.0)}
	var item := items.server_spawn_item(ITEM_FLAMETHROWER, props, get_item_spawn_position(), peer)
	if item == null:
		push_warning("EmergencyCabinet: flamethrower spawn failed for peer %d, refunding %d" % [peer, deposit])
		GameState.server_add_money(deposit)
		_deny(peer, REASON_UNAVAILABLE)
		return false
	_restock_exact = maxf(Config.balance.cabinet_restock_sec, 0.0)
	restock_left = ceili(_restock_exact)
	broken = true
	# The write-up (MAJOR Story line) goes first: the PROGRESS "Glass broke." then waits its turn in Story's queue
	# instead of being swept away by it.
	if not Hostiles.is_any_alive():
		GameState.server_write_up(peer, Const.WRITE_UP_MISUSE)
	_rpc_glass_break.rpc(peer)
	return true


## SERVER. Puts a new flamethrower behind new glass right away (the countdown normally does this).
func server_restock() -> void:
	if not GrowPlot.is_server_peer(self):
		push_error("EmergencyCabinet.server_restock called on a client")
		return
	_restock_exact = 0.0
	restock_left = 0
	broken = false


# --- cosmetics (every peer) -----------------------------------------------------------------------------------------

@rpc("authority", "call_local", "reliable")
func _rpc_glass_break(by_peer: int) -> void:
	if not is_inside_tree():
		return
	var pane_pos := _glass.global_position if _glass != null else global_position + global_basis.z * 0.2
	Sfx.play(&"glass_break", pane_pos)
	Juice.burst(pane_pos + global_basis.z * 0.1, GLASS_COLOR, 10)
	Juice.puff(pane_pos, Juice.GLOOM, 4)
	var story: Node = Story
	if story != null and story.has_method(&"flame_glass_broke"):
		story.call(&"flame_glass_broke")
	glass_broken.emit(by_peer)


func _set_broken(value: bool) -> void:
	if value == broken:
		return
	broken = value
	if not is_node_ready():
		return
	_refresh_visuals()
	if not broken:
		if is_inside_tree():
			Juice.pop_in(_stock if _stock != null else self, 0.3)
		restocked.emit()


func _set_restock_left(value: int) -> void:
	restock_left = maxi(value, 0)


func _refresh_visuals() -> void:
	if _glass != null:
		_glass.visible = not broken
	if _stock != null:
		_stock.visible = not broken


func _deny(peer: int, reason: String) -> void:
	if peer > 0 and (peer == Const.SERVER_PEER_ID or multiplayer.get_peers().has(peer)):
		_rpc_denied.rpc_id(peer, reason)


func _on_game_reset() -> void:
	if not Net.is_host or not GrowPlot.is_server_peer(self):
		return
	server_restock()
	var items := ItemManager.find(self)
	if items != null:
		for item in items.get_items_of_type(ITEM_FLAMETHROWER):
			items.server_despawn_item(item)
