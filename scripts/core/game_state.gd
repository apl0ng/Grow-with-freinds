extends Node
## Autoload "GameState": money, quota, timer, rounds, upgrades. (STUB - owned by the game-flow/UI agent; see CONTRACTS.md)
enum Phase { MENU, WAITING, PLAYING, ROUND_SUCCESS, ROUND_FAILED }
signal money_changed(money: int)
signal sales_changed(round_sales: int, quota: int)
signal time_changed(time_left: float)
signal phase_changed(phase: int)
signal round_started(round_number: int)
signal round_ended(success: bool, round_number: int)
signal sale_made(amount: int, seller_peer: int)
signal purchase_made(cost: int, buyer_peer: int, what: String)
signal upgrade_level_changed(upgrade_id: StringName, level: int)
var phase: int = Phase.MENU
var money: int = 0
var round_number: int = 1
var quota: int = 0
var round_sales: int = 0
var time_left: float = 0.0
var upgrades: Dictionary = {}
func is_playing() -> bool: return phase == Phase.PLAYING
func server_try_spend(_amount: int, _buyer_peer: int, _what: String) -> bool: return false
func server_add_sale(_amount: int, _seller_peer: int) -> void: pass
func server_add_money(_amount: int) -> void: pass
func server_buy_upgrade(_upgrade_id: StringName, _buyer_peer: int) -> bool: return false
func server_start_round() -> void: pass
func server_reset_game() -> void: pass
func server_send_full_state(_peer_id: int) -> void: pass
func request_start_round() -> void: pass
func request_next_round() -> void: pass
func request_retry() -> void: pass
func get_effect_total(_effect_key: StringName) -> float: return 0.0
func get_growth_speed_multiplier() -> float: return (1.0 + get_effect_total(Const.EFFECT_GROWTH_SPEED)) * Config.growth_speed_override
func get_can_capacity() -> int: return Config.balance.can_capacity + int(get_effect_total(Const.EFFECT_CAN_CAPACITY))
func get_sale_multiplier() -> float: return 1.0 + get_effect_total(Const.EFFECT_SALE_BONUS)
func get_water_drain_multiplier() -> float: return 1.0 / (1.0 + get_effect_total(Const.EFFECT_WATER_RETENTION))
func get_upgrade_level(upgrade_id: StringName) -> int: return int(upgrades.get(upgrade_id, 0))
