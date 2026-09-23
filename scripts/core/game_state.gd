extends Node
## Autoload "GameState": money, quota, timer, rounds, upgrades. Owned by the game-flow/UI agent.
## Do NOT add a class_name (autoload).
##
## Phases:  MENU -> WAITING -> PLAYING -> ROUND_SUCCESS -> PLAYING (next round) ...
##                                      \-> ROUND_FAILED  -> WAITING (retry = full reset)
##   MENU           no session (main menu). reset_local() puts any peer back here.
##   WAITING        world is up, timer paused. Buying/planting allowed, growth paused (is_playing() false).
##   PLAYING        timer runs on the host; growth / water drain tick.
##   ROUND_SUCCESS  quota met. Host: request_next_round() -> next round.
##   ROUND_FAILED   timer hit 0 below quota = game over. Host: request_retry() -> server_reset_game().
##
## Sync (server-authoritative): only the host mutates. Every mutation builds the complete new state
## dictionary (it is tiny) and broadcasts it with a reliable call_local RPC, so the host applies it
## through exactly the same code path as the clients. `_apply_state()` diffs the incoming state
## against the current one and emits the *_changed signals on every peer; event RPCs
## (_rpc_sale, _rpc_purchase, _rpc_round_started, _rpc_round_ended, _rpc_game_reset) additionally
## emit their event signal on every peer, after the state has been applied.
## The countdown is separate: the host ticks `time_left` and sends `_rpc_time` every
## TIME_SYNC_INTERVAL seconds (unreliable_ordered); clients tick locally in between (never below 0)
## and never end a round themselves - the host's reliable _rpc_round_ended does that.

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
## Emitted on EVERY peer when the host resets a running session (RETRY after a game over, or any
## server_reset_game() call made while a session is already live). It is NOT emitted for the first
## reset of a session (MENU -> WAITING when the world comes up; use Game.world_ready for that).
## Emitted after the fresh state (round 1, starting money, no upgrades, WAITING) has been applied.
## Server-side handlers should put the world back to its starting layout idempotently:
## clear grow plots, despawn loose items/products/seed packets, reset / respawn the starting cans.
signal game_reset

## Seconds between host -> client timer syncs (unreliable_ordered).
const TIME_SYNC_INTERVAL: float = 0.5

var phase: int = Phase.MENU
var money: int = 0
var round_number: int = 1
var quota: int = 0
var round_sales: int = 0
var time_left: float = 0.0
var upgrades: Dictionary = {}   # StringName upgrade_id -> int level

## True on the peer that initialised the current session with server_reset_game() (= the host).
var _authoritative: bool = false
## Incremented by every round start / reset; timer syncs carrying an old serial are ignored.
var _serial: int = 0
var _time_sync_accum: float = 0.0
## False until this peer has applied its first state of the session (then every signal is emitted).
var _has_state: bool = false


func _ready() -> void:
	# Keep ticking even if someone pauses the tree (the game never pauses: multiplayer).
	process_mode = Node.PROCESS_MODE_ALWAYS
	# Safety nets (no-ops in the normal flow, where Game.start_host() calls server_reset_game() and
	# Game._return_to_menu_now() calls reset_local(); Game also calls server_send_full_state() when a
	# peer registers):
	#  - host: initialise the session if the world came up while still in MENU.
	#  - any peer: back to MENU (reset_local) once that world has left the tree.
	if Game.has_signal(&"world_ready"):
		Game.world_ready.connect(_on_world_ready)


# ---------------------------------------------------------------------------------------------
# Queries (any peer)
# ---------------------------------------------------------------------------------------------

func is_playing() -> bool:
	return phase == Phase.PLAYING

## True on the host (the authority that may call server_* / whose request_* are honoured).
func is_local_host() -> bool:
	if not multiplayer.has_multiplayer_peer():
		return false
	return multiplayer.is_server() and (Net.is_host or _authoritative)

## True while a round has ended (success or failure) and the end screen is up.
func is_round_over() -> bool:
	return phase == Phase.ROUND_SUCCESS or phase == Phase.ROUND_FAILED

## Sales progress towards the quota, 0..1 (1 when quota is 0).
func get_quota_progress() -> float:
	if quota <= 0:
		return 1.0
	return clampf(float(round_sales) / float(quota), 0.0, 1.0)

## "mm:ss" of the remaining round time (rounded up, so it shows 00:00 only when time is up).
func get_time_string() -> String:
	var total: int = ceili(maxf(time_left, 0.0))
	@warning_ignore("integer_division")
	var minutes: int = total / 60
	return "%02d:%02d" % [minutes, total % 60]

## Enum key of the current phase: "MENU", "WAITING", "PLAYING", "ROUND_SUCCESS", "ROUND_FAILED".
func get_phase_name() -> String:
	var keys: Array = Phase.keys()
	if phase >= 0 and phase < keys.size():
		return String(keys[phase])
	return "UNKNOWN"


# ---------------------------------------------------------------------------------------------
# Effect helpers (any peer)
# ---------------------------------------------------------------------------------------------

func get_effect_total(effect_key: StringName) -> float:
	var total := 0.0
	for def: UpgradeDef in Config.balance.upgrades:
		if def != null and def.effect_key == effect_key:
			total += def.effect_per_level * float(get_upgrade_level(def.id))
	return total

func get_growth_speed_multiplier() -> float:
	return (1.0 + get_effect_total(Const.EFFECT_GROWTH_SPEED)) * Config.growth_speed_override

func get_can_capacity() -> int:
	return Config.balance.can_capacity + int(get_effect_total(Const.EFFECT_CAN_CAPACITY))

func get_sale_multiplier() -> float:
	return 1.0 + get_effect_total(Const.EFFECT_SALE_BONUS)

func get_water_drain_multiplier() -> float:
	return 1.0 / (1.0 + get_effect_total(Const.EFFECT_WATER_RETENTION))

func get_upgrade_level(upgrade_id: StringName) -> int:
	return int(upgrades.get(StringName(upgrade_id), 0))

## Cost of the next level of an upgrade, or -1 if it does not exist / is maxed.
func get_upgrade_next_cost(upgrade_id: StringName) -> int:
	var def: UpgradeDef = Config.balance.get_upgrade(upgrade_id)
	if def == null:
		return -1
	var level := get_upgrade_level(upgrade_id)
	if level >= def.max_level:
		return -1
	return def.cost_for_level(level + 1)


# ---------------------------------------------------------------------------------------------
# SERVER ONLY mutators. Each validates, builds the new state and broadcasts it (call_local).
# ---------------------------------------------------------------------------------------------

func server_try_spend(amount: int, buyer_peer: int, what: String) -> bool:
	if not _require_server("server_try_spend"):
		return false
	if amount < 0 or amount > money:
		return false
	var s := _snapshot()
	s["money"] = money - amount
	_rpc_purchase.rpc(s, amount, buyer_peer, what)
	return true

func server_add_sale(amount: int, seller_peer: int) -> void:
	if not _require_server("server_add_sale"):
		return
	if amount < 0:
		push_warning("GameState.server_add_sale: negative amount %d ignored" % amount)
		return
	var s := _snapshot()
	s["money"] = money + amount
	s["sales"] = round_sales + amount
	_rpc_sale.rpc(s, amount, seller_peer)
	if Config.balance.end_round_on_quota_met and phase == Phase.PLAYING and round_sales >= quota:
		_server_end_round(true)

func server_add_money(amount: int) -> void:
	if not _require_server("server_add_money"):
		return
	var s := _snapshot()
	s["money"] = maxi(money + amount, 0)
	_rpc_state.rpc(s)

func server_buy_upgrade(upgrade_id: StringName, buyer_peer: int) -> bool:
	if not _require_server("server_buy_upgrade"):
		return false
	var def: UpgradeDef = Config.balance.get_upgrade(upgrade_id)
	if def == null:
		return false
	var level := get_upgrade_level(upgrade_id)
	if level >= def.max_level:
		return false
	var cost := def.cost_for_level(level + 1)
	if cost < 0 or cost > money:
		return false
	var s := _snapshot()
	s["money"] = money - cost
	var ups: Dictionary = s["upgrades"]
	ups[StringName(def.id)] = level + 1
	_rpc_purchase.rpc(s, cost, buyer_peer, "%s Lv %d" % [def.display_name, level + 1])
	return true

## WAITING -> PLAYING (same round) or ROUND_SUCCESS -> PLAYING (next round). From MENU it first
## initialises the session. Ignored while PLAYING or after a failure (use server_reset_game()).
func server_start_round() -> void:
	if not _require_server("server_start_round"):
		return
	if phase == Phase.MENU:
		server_reset_game()
	var s := _snapshot()
	match phase:
		Phase.WAITING:
			pass # round number stays (1 after a reset)
		Phase.ROUND_SUCCESS:
			s["round"] = round_number + 1
			if not Config.balance.carry_over_money:
				s["money"] = Config.balance.starting_money
		_:
			push_warning("GameState.server_start_round: ignored in phase %s" % get_phase_name())
			return
	var next_round: int = s["round"]
	s["phase"] = Phase.PLAYING
	s["quota"] = Config.balance.quota_for_round(next_round)
	s["sales"] = 0 # quota = sales made during THIS round
	s["time"] = Config.balance.round_length_sec
	s["serial"] = _serial + 1
	_authoritative = true
	_time_sync_accum = 0.0
	_rpc_round_started.rpc(s)

## Fresh session: WAITING, round 1, starting money, no sales, fresh timer, upgrades cleared.
## Emits game_reset on every peer when a session was already running (see the signal docs).
func server_reset_game() -> void:
	if not _require_server("server_reset_game"):
		return
	var was_live := phase != Phase.MENU
	_authoritative = true
	_time_sync_accum = 0.0
	var s := {
		"phase": Phase.WAITING,
		"money": Config.balance.starting_money,
		"round": 1,
		"quota": Config.balance.quota_for_round(1),
		"sales": 0,
		"time": Config.balance.round_length_sec,
		"upgrades": {},
		"serial": _serial + 1,
	}
	if was_live:
		_rpc_game_reset.rpc(s)
	else:
		_rpc_full_state.rpc(s)

## Called (on the server) when a peer has registered: sends it the complete state.
func server_send_full_state(peer_id: int) -> void:
	if not _require_server("server_send_full_state"):
		return
	if peer_id == multiplayer.get_unique_id():
		_apply_state(_snapshot(), true)
		return
	if peer_id not in multiplayer.get_peers():
		return
	_rpc_full_state.rpc_id(peer_id, _snapshot())


# ---------------------------------------------------------------------------------------------
# Host-only requests from the UI (ignored on clients; clients never see those buttons).
# ---------------------------------------------------------------------------------------------

func request_start_round() -> void:
	if not is_local_host():
		return
	if phase == Phase.WAITING or phase == Phase.MENU:
		server_start_round()

func request_next_round() -> void:
	if not is_local_host():
		return
	if phase == Phase.ROUND_SUCCESS:
		server_start_round()

func request_retry() -> void:
	if not is_local_host():
		return
	if phase != Phase.MENU:
		server_reset_game()


# ---------------------------------------------------------------------------------------------
# Local (any peer)
# ---------------------------------------------------------------------------------------------

## Back to MENU defaults on THIS peer only (no network). Called by Game/Net when returning to the menu.
func reset_local() -> void:
	_authoritative = false
	_serial = 0
	_time_sync_accum = 0.0
	_has_state = false
	var s := {
		"phase": Phase.MENU, "money": 0, "round": 1, "quota": 0, "sales": 0,
		"time": 0.0, "upgrades": {}, "serial": 0,
	}
	_apply_state(s, true)


# ---------------------------------------------------------------------------------------------
# Timer
# ---------------------------------------------------------------------------------------------

func _process(delta: float) -> void:
	if phase != Phase.PLAYING:
		return
	time_left = maxf(time_left - delta, 0.0)
	time_changed.emit(time_left)
	if not (_authoritative and multiplayer.has_multiplayer_peer() and multiplayer.is_server()):
		return # clients just tick locally; the host ends the round
	if time_left <= 0.0:
		_server_end_round(round_sales >= quota)
		return
	_time_sync_accum += delta
	if _time_sync_accum >= TIME_SYNC_INTERVAL:
		_time_sync_accum = 0.0
		if not multiplayer.get_peers().is_empty():
			_rpc_time.rpc(time_left, _serial)

func _server_end_round(success: bool) -> void:
	if phase != Phase.PLAYING:
		return
	var s := _snapshot()
	s["phase"] = Phase.ROUND_SUCCESS if success else Phase.ROUND_FAILED
	if not success:
		s["time"] = 0.0
	_rpc_round_ended.rpc(s, success)


# ---------------------------------------------------------------------------------------------
# RPC receivers (run on every peer, the host included via call_local)
# ---------------------------------------------------------------------------------------------

@rpc("authority", "call_local", "reliable")
func _rpc_full_state(state: Dictionary) -> void:
	_mark_client_if_remote()
	_apply_state(state, true)

@rpc("authority", "call_local", "reliable")
func _rpc_state(state: Dictionary) -> void:
	_mark_client_if_remote()
	_apply_state(state, false)

@rpc("authority", "call_local", "reliable")
func _rpc_sale(state: Dictionary, amount: int, seller_peer: int) -> void:
	_mark_client_if_remote()
	_apply_state(state, false)
	sale_made.emit(amount, seller_peer)

@rpc("authority", "call_local", "reliable")
func _rpc_purchase(state: Dictionary, cost: int, buyer_peer: int, what: String) -> void:
	_mark_client_if_remote()
	_apply_state(state, false)
	purchase_made.emit(cost, buyer_peer, what)

@rpc("authority", "call_local", "reliable")
func _rpc_round_started(state: Dictionary) -> void:
	_mark_client_if_remote()
	_apply_state(state, false)
	round_started.emit(round_number)

@rpc("authority", "call_local", "reliable")
func _rpc_round_ended(state: Dictionary, success: bool) -> void:
	_mark_client_if_remote()
	_apply_state(state, false)
	round_ended.emit(success, round_number)

@rpc("authority", "call_local", "reliable")
func _rpc_game_reset(state: Dictionary) -> void:
	_mark_client_if_remote()
	_apply_state(state, true)
	game_reset.emit()

## Host -> clients countdown sync. Ignored unless PLAYING the same round (stale packets).
@rpc("authority", "call_remote", "unreliable_ordered")
func _rpc_time(synced_time_left: float, serial: int) -> void:
	if phase != Phase.PLAYING or serial != _serial:
		return
	time_left = maxf(synced_time_left, 0.0)
	time_changed.emit(time_left)


# ---------------------------------------------------------------------------------------------
# Internals
# ---------------------------------------------------------------------------------------------

func _snapshot() -> Dictionary:
	return {
		"phase": phase,
		"money": money,
		"round": round_number,
		"quota": quota,
		"sales": round_sales,
		"time": time_left,
		"upgrades": upgrades.duplicate(),
		"serial": _serial,
	}

## Applies a state dictionary and emits change signals. `force` emits every state signal
## (first state of a session, full resyncs, resets) so freshly joined UIs initialise.
func _apply_state(state: Dictionary, force: bool) -> void:
	force = force or not _has_state
	_has_state = true
	var old_phase := phase
	var old_money := money
	var old_sales := round_sales
	var old_quota := quota
	var old_time := time_left
	var old_upgrades := upgrades

	phase = int(state.get("phase", phase))
	money = int(state.get("money", money))
	round_number = int(state.get("round", round_number))
	quota = int(state.get("quota", quota))
	round_sales = int(state.get("sales", round_sales))
	time_left = maxf(float(state.get("time", time_left)), 0.0)
	_serial = int(state.get("serial", _serial))
	var new_upgrades: Dictionary = {}
	var raw_ups: Variant = state.get("upgrades", upgrades)
	if raw_ups is Dictionary:
		for key: Variant in (raw_ups as Dictionary):
			new_upgrades[StringName(str(key))] = int((raw_ups as Dictionary)[key])
	upgrades = new_upgrades

	if force or money != old_money:
		money_changed.emit(money)
	if force or round_sales != old_sales or quota != old_quota:
		sales_changed.emit(round_sales, quota)
	if force or not is_equal_approx(time_left, old_time):
		time_changed.emit(time_left)
	var changed_ids: Dictionary = {}
	for id: StringName in old_upgrades:
		changed_ids[id] = true
	for id: StringName in upgrades:
		changed_ids[id] = true
	if force:
		for def: UpgradeDef in Config.balance.upgrades:
			if def != null:
				changed_ids[StringName(def.id)] = true
	for id: StringName in changed_ids:
		var before := int(old_upgrades.get(id, 0))
		var after := int(upgrades.get(id, 0))
		if force or before != after:
			upgrade_level_changed.emit(id, after)
	if force or phase != old_phase:
		phase_changed.emit(phase)

## Remote-sent state means this peer is a client of someone else's session.
func _mark_client_if_remote() -> void:
	if not multiplayer.has_multiplayer_peer():
		return
	if multiplayer.get_remote_sender_id() != multiplayer.get_unique_id():
		_authoritative = false

func _require_server(fn_name: String) -> bool:
	if multiplayer.has_multiplayer_peer() and multiplayer.is_server():
		return true
	push_error("GameState.%s called on a non-server peer" % fn_name)
	return false

func _on_world_ready(world: Node) -> void:
	# The session lives as long as the World: when it leaves the tree we go back to MENU
	# (idempotent with Game/Net calling reset_local() themselves).
	if world != null and not world.tree_exited.is_connected(_on_world_exited):
		world.tree_exited.connect(_on_world_exited, CONNECT_ONE_SHOT)
	# Deferred so an explicit server_reset_game() made by Game in the same frame wins.
	_host_init_session.call_deferred()

func _on_world_exited() -> void:
	_reset_if_world_gone.call_deferred()

func _reset_if_world_gone() -> void:
	var w: Node = Game.world
	if phase != Phase.MENU and (w == null or not is_instance_valid(w) or not w.is_inside_tree()):
		reset_local()

func _host_init_session() -> void:
	if phase == Phase.MENU and Net.is_host and multiplayer.has_multiplayer_peer() and multiplayer.is_server():
		server_reset_game()
