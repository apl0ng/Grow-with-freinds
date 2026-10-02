extends Node
## Autoload "GameState": money, quota, timer, rounds, upgrades. Owned by the game-flow/UI agent.
## M10 (lead): per-worker shift stats, write-ups + fines, the back room, audits. Do NOT add a class_name (autoload).
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
## (_rpc_sale, _rpc_purchase, _rpc_round_started, _rpc_round_ended, _rpc_game_reset, _rpc_written_up)
## additionally emit their event signal on every peer, after the state has been applied.
## The countdown is separate: the host ticks `time_left` and sends `_rpc_time` every
## TIME_SYNC_INTERVAL seconds (unreliable_ordered); clients tick locally in between (never below 0)
## and never end a round themselves - the host's reliable _rpc_round_ended does that.
##
## M10 state (all in the same state dictionary, CONTRACTS.md "GameState additions"):
##   stats      peer_id -> {Const.STAT_* -> int}: this shift's ledger (the shift report). Reset when a shift starts
##              and on a game reset; kept through the end screen. Deposits are counted here in server_add_sale.
##   write_ups  peer_id -> strikes this shift. At Config.balance.write_ups_to_backroom the worker goes to the
##              back room and the strikes clear. Cleared at shift end / reset. Each write-up docks write_up_fine.
##   backroom   peer_id -> the round time_left at which the worker is released (uses the shift timer, so no extra
##              sync): the host releases them in _process, at shift end and when the peer leaves. PLAYING only.

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
## M10, every peer: the per-worker ledger changed (any stat of any worker, or a reset).
signal stats_changed
## M10, every peer: `peer_id` was written up for `reason` (Const.WRITE_UP_*); `count` = strikes after this one,
## 0 when this one sent them to the back room (backroom_changed(peer_id, true) follows in the same frame).
signal worker_written_up(peer_id: int, reason: String, count: int)
## M10, every peer: `peer_id` entered (true) / left (false) the back room.
signal backroom_changed(peer_id: int, active: bool)

## Seconds between host -> client timer syncs (unreliable_ordered).
const TIME_SYNC_INTERVAL: float = 0.5

var phase: int = Phase.MENU
var money: int = 0
var round_number: int = 1
var quota: int = 0
var round_sales: int = 0
var time_left: float = 0.0
var upgrades: Dictionary = {}   # StringName upgrade_id -> int level
## M10: peer_id (int) -> {StringName stat -> int}. Read with get_stat(); mutate only through server_*.
var stats: Dictionary = {}
## M10: peer_id (int) -> int strikes this shift.
var write_ups: Dictionary = {}
## M10: peer_id (int) -> float round time_left at which the worker is released.
var backroom: Dictionary = {}

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
	# Host, WAITING: the coming shift's payment follows the team size while workers clock in.
	Net.players_changed.connect(_on_players_changed)
	# Host: a departing worker leaves the back room and loses their strikes (their stats stay for the report).
	Net.peer_left.connect(_on_peer_left)


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

## Workers in the session (Net registry size, at least 1). The payment due scales with it:
## Config.balance.quota_for_round(round, get_team_size()) (+quota_per_extra_player per extra worker).
func get_team_size() -> int:
	return maxi(Net.players.size(), 1)

## Payment due for shift `round_n` with the current team (what the next shift will ask for).
func get_quota_for(round_n: int) -> int:
	return Config.balance.quota_for_round(round_n, get_team_size())

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

## M10: one stat of one worker this shift (0 when unknown).
func get_stat(peer_id: int, key: StringName) -> int:
	var row: Variant = stats.get(peer_id)
	if row is Dictionary:
		return int((row as Dictionary).get(key, 0))
	return 0

## M10: a copy of a worker's ledger ({} when unknown).
func get_worker_stats(peer_id: int) -> Dictionary:
	var row: Variant = stats.get(peer_id)
	return (row as Dictionary).duplicate() if row is Dictionary else {}

## M10: strikes a worker carries this shift.
func get_write_ups(peer_id: int) -> int:
	return int(write_ups.get(peer_id, 0))

## M10: true while the worker sits in the back room.
func is_in_backroom(peer_id: int) -> bool:
	return backroom.has(peer_id)

## M10: seconds until the worker is released (0 when not in the back room; counts down with the shift timer).
func get_backroom_time_left(peer_id: int) -> float:
	if not backroom.has(peer_id):
		return 0.0
	return maxf(time_left - float(backroom[peer_id]), 0.0)

## M10: peers in the back room, sorted.
func get_backroom_peers() -> Array[int]:
	var out: Array[int] = []
	for k in backroom.keys():
		out.append(int(k))
	out.sort()
	return out


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
	return (1.0 + get_effect_total(Const.EFFECT_GROWTH_SPEED)) * Config.growth_speed_override * condition_value(&"growth_speed", 1.0) # M15 replay: * the conditions' growth

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
	if seller_peer > 0:
		_bump_stat(s["stats"], seller_peer, Const.STAT_DEPOSITED, amount)
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

## M10. Adds `amount` to one stat of one worker (Const.STAT_*) and broadcasts the state.
func server_add_stat(peer_id: int, key: StringName, amount: int = 1) -> void:
	if not _require_server("server_add_stat"):
		return
	if peer_id <= 0 or amount == 0 or phase == Phase.MENU:
		return
	var s := _snapshot()
	_bump_stat(s["stats"], peer_id, key, amount)
	_rpc_state.rpc(s)

## M10. The Boss writes `peer_id` up for `reason` (Const.WRITE_UP_*): the team is docked write_up_fine, the
## worker's STAT_WRITE_UPS and strikes go up; at write_ups_to_backroom strikes the worker goes to the back room
## (PLAYING only; otherwise the strikes just stay at the threshold). Returns the strikes after this write-up
## (0 = sent to the back room). Emits worker_written_up on every peer.
func server_write_up(peer_id: int, reason: String) -> int:
	if not _require_server("server_write_up"):
		return 0
	if peer_id <= 0 or phase == Phase.MENU:
		return 0
	var s := _snapshot()
	s["money"] = maxi(money - maxi(Config.balance.write_up_fine, 0), 0)
	_bump_stat(s["stats"], peer_id, Const.STAT_WRITE_UPS, 1)
	var strikes := get_write_ups(peer_id) + 1
	var wu: Dictionary = s["write_ups"]
	var br: Dictionary = s["backroom"]
	if strikes >= maxi(Config.balance.write_ups_to_backroom, 1) and phase == Phase.PLAYING:
		strikes = 0
		wu.erase(peer_id)
		br[peer_id] = _release_time(Config.balance.backroom_sec)
	else:
		wu[peer_id] = strikes
	_rpc_written_up.rpc(s, peer_id, reason, strikes)
	return strikes

## M10. Sends a worker to the back room for `seconds` (backroom_sec when negative). PLAYING only: the release
## time rides on the shift timer. False when not playing / unknown peer. Emits backroom_changed on every peer.
func server_send_to_backroom(peer_id: int, seconds: float = -1.0) -> bool:
	if not _require_server("server_send_to_backroom"):
		return false
	if peer_id <= 0 or phase != Phase.PLAYING:
		return false
	var s := _snapshot()
	var br: Dictionary = s["backroom"]
	br[peer_id] = _release_time(Config.balance.backroom_sec if seconds < 0.0 else seconds)
	var wu: Dictionary = s["write_ups"]
	wu.erase(peer_id)
	_rpc_state.rpc(s)
	return true

## M10. Lets a worker out of the back room now (no-op if they are not in it).
func server_release_from_backroom(peer_id: int) -> void:
	if not _require_server("server_release_from_backroom"):
		return
	if not backroom.has(peer_id):
		return
	var s := _snapshot()
	var br: Dictionary = s["backroom"]
	br.erase(peer_id)
	_rpc_state.rpc(s)

## M10 (audit). Raises the payment due by `fraction` of its current value (at least $1) while PLAYING.
## Returns the new quota (unchanged when not playing). Ends the shift at once if sales already cover it.
func server_raise_quota(fraction: float) -> int:
	if not _require_server("server_raise_quota"):
		return quota
	if phase != Phase.PLAYING or fraction <= 0.0:
		return quota
	var s := _snapshot()
	s["quota"] = quota + maxi(int(round(float(quota) * fraction)), 1)
	_rpc_state.rpc(s)
	if Config.balance.end_round_on_quota_met and round_sales >= quota:
		_server_end_round(true)
	return quota

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
	s["quota"] = get_quota_for(next_round)
	s["sales"] = 0 # quota = sales made during THIS round
	s["time"] = Config.balance.round_length_sec
	_replay_begin_shift(s, next_round) # M15 replay: this shift's conditions and market (unless the alley rolled them), their quota factor and seconds
	s["serial"] = _serial + 1
	s["stats"] = {}      # a fresh ledger every shift
	s["write_ups"] = {}
	s["backroom"] = {}
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
		"quota": get_quota_for(1),
		"sales": 0,
		"time": Config.balance.round_length_sec,
		"upgrades": {},
		"serial": _serial + 1,
		"stats": {},
		"write_ups": {},
		"backroom": {},
	}
	_replay_reset(s) # M15 replay: nothing carried over; shift 1's roll
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
		if Config.lobby_enabled: # M14 lobby: the host's Enter leaves without waiting for stragglers
			server_begin_shift_from_lobby() # M14 lobby
			return # M14 lobby
		server_start_round()

func request_next_round() -> void:
	if not is_local_host():
		return
	if phase == Phase.ROUND_SUCCESS:
		if Config.lobby_enabled: # M14 lobby: back to the alley, the next shift starts from the van
			server_return_to_lobby(false) # M14 lobby
			return # M14 lobby
		server_start_round()

func request_retry() -> void:
	if not is_local_host():
		return
	if phase != Phase.MENU:
		if Config.lobby_enabled: # M14 lobby: the reset happens in the dark, everyone wakes up in the alley
			server_return_to_lobby(true) # M14 lobby
			return # M14 lobby
		server_reset_game()


# --- M14 lobby -----------------------------------------------------------------------------------------------
# The van ride and the way back (FRIENDSLOP 8.1, CONTRACTS "Lobby + van"). With Config.lobby_enabled workers wait in
# the alley (World/Lobby) while the phase is WAITING. A transition is: the host tells every peer (_rpc_transition ->
# transition_started: the HUD fades to black over `seconds`, holds TRANSITION_HOLD_SEC, fades back in), waits until
# the screens are black (`seconds` + half the hold), then does the work in the dark:
#   to_floor  every worker to Room.get_arrival_transform(spawn_index), then server_start_round()
#   to_lobby  what the workers carry stays on the floor; the state becomes what the old path would have at the start
#             of the next shift (NEXT SHIFT: round + 1, its payment, the money carried over or not, a fresh ledger;
#             START OVER: server_reset_game()) but in WAITING; every worker to the alley
# One transition at a time: requests made while one runs are ignored. reset_local() cancels a pending one.

## Every peer: the screen goes black for a ride. `kind` is TRANSITION_TO_FLOOR or TRANSITION_TO_LOBBY, `seconds` the
## length of the fade to black (the same again back in, with TRANSITION_HOLD_SEC of black in between).
signal transition_started(kind: StringName, seconds: float)

const TRANSITION_TO_FLOOR: StringName = &"to_floor"
const TRANSITION_TO_LOBBY: StringName = &"to_lobby"
## Seconds every screen stays black between the fade out and the fade in (the host moves the workers half way in).
const TRANSITION_HOLD_SEC: float = 0.3

## HOST: the transition that is running (&"" = none).
var _transition: StringName = &""
var _transition_token: int = 0

## True on the host while a ride is under way (between _rpc_transition and the work done in the dark).
func is_transitioning() -> bool:
	return _transition != &""

## HOST. The van leaves: fade, every worker to the loading dock, then server_start_round(). WAITING only (from MENU
## the session is initialised first); ignored while another transition runs. The van calls it when everyone is in;
## the host's Enter (request_start_round) calls it without waiting for stragglers.
func server_begin_shift_from_lobby() -> void:
	if not _require_server("server_begin_shift_from_lobby"):
		return
	if phase == Phase.MENU:
		server_reset_game()
	if phase != Phase.WAITING or _transition != &"":
		return
	_begin_transition(TRANSITION_TO_FLOOR, false)

## HOST. After a shift: fade, then everyone is back in the alley and the game waits (WAITING) for the van again.
## reset = false (NEXT SHIFT, ROUND_SUCCESS only): the next shift's round number / payment / money, as
## server_start_round() would set them. reset = true (START OVER, any live phase): server_reset_game().
func server_return_to_lobby(reset: bool) -> void:
	if not _require_server("server_return_to_lobby"):
		return
	if phase == Phase.MENU or _transition != &"":
		return
	if not reset and phase != Phase.ROUND_SUCCESS:
		push_warning("GameState.server_return_to_lobby: ignored in phase %s" % get_phase_name())
		return
	_begin_transition(TRANSITION_TO_LOBBY, reset)

func _begin_transition(kind: StringName, reset: bool) -> void:
	var seconds := maxf(Config.balance.transition_fade_sec, 0.0)
	_transition = kind
	_transition_token += 1
	_rpc_transition.rpc(kind, seconds)
	get_tree().create_timer(seconds + TRANSITION_HOLD_SEC * 0.5, true).timeout.connect(
			_finish_transition.bind(kind, reset, _transition_token))

## HOST, in the dark: the work of a transition (see the region header).
func _finish_transition(kind: StringName, reset: bool, token: int) -> void:
	if token != _transition_token or _transition != kind:
		return # cancelled (back to the menu) or superseded
	_transition = &""
	if phase == Phase.MENU or not (multiplayer.has_multiplayer_peer() and multiplayer.is_server()):
		return
	var w: World = Game.world
	if w != null and not (is_instance_valid(w) and w.is_inside_tree()):
		w = null
	if kind == TRANSITION_TO_FLOOR:
		if phase != Phase.WAITING and phase != Phase.PLAYING:
			return
		if w != null:
			w.server_move_players_to_floor()
		if phase == Phase.WAITING:
			server_start_round()
		return
	if reset:
		# The reset first: it empties the back room, and Events walks a released worker to a room spawn. The move to
		# the alley has to be the last word.
		server_reset_game()
		if w != null:
			w.server_move_players_to_lobby()
	elif phase == Phase.ROUND_SUCCESS:
		if w != null:
			w.server_move_players_to_lobby()
		_server_wait_for_next_shift()

## HOST: ROUND_SUCCESS -> WAITING with everything server_start_round() would set for the next shift except the
## phase, so the shift the van starts later (WAITING -> PLAYING, round number kept) is exactly the old next shift.
func _server_wait_for_next_shift() -> void:
	var s := _snapshot()
	var next_round := round_number + 1
	s["phase"] = Phase.WAITING
	s["round"] = next_round
	if not Config.balance.carry_over_money:
		s["money"] = Config.balance.starting_money
	s["quota"] = get_quota_for(next_round)
	s["sales"] = 0
	s["time"] = Config.balance.round_length_sec
	_replay_begin_shift(s, next_round) # M15 replay: rolled here, so the alley shows the coming shift before boarding
	s["serial"] = _serial + 1
	s["stats"] = {}
	s["write_ups"] = {}
	s["backroom"] = {}
	_time_sync_accum = 0.0
	_rpc_state.rpc(s)

func _cancel_transition() -> void:
	_transition = &""
	_transition_token += 1

## Host -> every peer (the host through call_local): a ride begins.
@rpc("authority", "call_local", "reliable")
func _rpc_transition(kind: StringName, seconds: float) -> void:
	transition_started.emit(kind, clampf(seconds, 0.0, 10.0) if is_finite(seconds) else 0.0)

# --- end M14 lobby ---------------------------------------------------------------------------------------------


# --- M15 replay ----------------------------------------------------------------------------------------------------
# No two shifts alike, and a run that builds (FRIENDSLOP 9.1 / 9.2, CONTRACTS "M15", "Replay"). Everything here is
# behind the HOST's Config.replay_enabled: with it off nothing is rolled, the state below stays empty on every peer,
# and every query answers as if this region did not exist (condition_value -> the default, the market 1.0, every
# strain on sale, no briefing, the event gap factor 1.0).
#
# State (one entry of the state dictionary, "replay": {"on", "conditions", "market"}; it rides on every broadcast and
# on the full state a late joiner gets, like the upgrades do):
#   on          the host runs with replay: clients read it from here, never from their own Config
#   conditions  the ids of this shift's conditions (ShiftConditions; `buyer:purple` carries its strain)
#   market      strain id -> today's factor on its deposit value (1 - market_swing .. 1 + market_swing, 5% steps)
# When it is rolled (host): for shift N, once, either when the game enters WAITING for it (the lobby's way back,
# _server_wait_for_next_shift: the alley board shows it before anyone boards) or when it starts (lobby off). Shift 1
# is plain: conditions AND the market begin with shift `conditions_from_round`. Never a condition of the shift before,
# never an incompatible pair, never one that would do nothing today (ShiftConditions.roll).
# What applies when: `quota` and `round_sec_add` are applied to the payment due and the clock when they are set
# (entering WAITING for the shift, starting it, re-pricing for the team size); every other key is read live by its
# consumer through condition_value(). The conditions stay up through the end screen (the report names them) and are
# replaced by the next roll; a reset or the menu clears them.
# Unlocks: SeedDef.unlock_round against the round number, nothing stored. Event gaps: get_event_gap_factor().

## Every peer: the active conditions changed (rolled, set by a test, cleared).
signal conditions_changed
## Every peer: the market changed.
signal market_changed

## HOST: the dice for the conditions and the market. Tests seed it (GameState.replay_rng.seed = 7).
var replay_rng := RandomNumberGenerator.new()

var _replay_on: bool = false
var _conditions: Array[StringName] = []
var _market: Dictionary = {}                      # StringName strain id -> float
## Every key of the active conditions -> its combined value (ShiftConditions.combine); what condition_value() reads.
var _condition_values: Dictionary = {}
## Strain id -> market x the conditions' sale factors for it (rebuilt with the two above).
var _strain_deposit: Dictionary = {}
## The conditions of the last shift that started (kept through the way back to the alley, for the report line).
var _report_conditions: Array[StringName] = []
## HOST: the shift the state above was rolled for (0 = none yet). A shift is rolled once: what a test sets while the
## game is WAITING for a shift is what that shift starts with.
var _replay_round: int = 0


## True when the host runs with replay (synced; false before the first state arrives).
func is_replay_on() -> bool:
	return _replay_on


## The ids of the active conditions (a copy). In WAITING they are the coming shift's.
func get_conditions() -> Array[StringName]:
	return _conditions.duplicate()


## The conditions of the last shift that started (the report's line; the alley keeps them after the way back).
func get_report_conditions() -> Array[StringName]:
	return _report_conditions.duplicate()


## The combined value of `key` over the active conditions: the PRODUCT of their values, or the SUM for an additive
## key (`round_sec_add`, `floor_wet`: ShiftConditions.is_additive). `default` when no active condition has the key
## (always, with replay off). The keys are listed in shift_conditions.gd.
func condition_value(key: StringName, default: float) -> float:
	if _condition_values.is_empty():
		return default
	return float(_condition_values.get(key, default))


## Today's factor on `strain_id`'s deposit value (1.0 with replay off, on shift 1 and for an unknown strain).
func get_market_multiplier(strain_id: StringName) -> float:
	return float(_market.get(strain_id, 1.0))


## Strain id -> today's factor (a copy; empty with replay off and on shift 1).
func get_market() -> Dictionary:
	return _market.duplicate()


## False while `strain_id` is not sold yet (SeedDef.unlock_round against the round number; in WAITING that is the
## coming shift). Always true with replay off and for an unknown strain.
func is_strain_unlocked(strain_id: StringName) -> bool:
	return round_number >= get_unlock_round(strain_id)


## The first shift `strain_id` is sold in (1 with replay off).
func get_unlock_round(strain_id: StringName) -> int:
	if not _replay_on:
		return 1
	var def: SeedDef = Config.balance.get_seed(strain_id)
	return maxi(def.unlock_round, 1) if def != null else 1


## What a packet of `seed_def` costs today: its cost x the conditions' `seed_cost`, at least $1. The card shows it,
## the counter charges it.
func get_seed_cost(seed_def: SeedDef) -> int:
	if seed_def == null:
		return 0
	var factor := condition_value(&"seed_cost", 1.0)
	return seed_def.cost if factor == 1.0 else maxi(int(round(seed_def.cost * factor)), 1)


## Today's factor on a deposit of `strain_id`: the market x the conditions' `sale_value` and `sale_value:<strain>`;
## for a cured bundle also what `cure_bonus` adds to the bonus. 1.0 with replay off. TurnInStation.compute_sale_value
## multiplies by it, so the chute's prompt, the sale and the supply card all show the same number.
func get_deposit_factor(strain_id: StringName, cured: bool = false) -> float:
	var factor := float(_strain_deposit.get(strain_id, 1.0))
	if cured and not _condition_values.is_empty():
		var bonus := maxf(Config.balance.cure_bonus, 0.0)
		factor *= (1.0 + bonus * condition_value(&"cure_bonus", 1.0)) / (1.0 + bonus)
	return factor


## The factor on Events' gaps (and its first delay): they shrink by event_gap_shrink_per_round per shift after the
## first, never below half, times the conditions' `event_gap`. 1.0 with replay off.
func get_event_gap_factor() -> float:
	if not _replay_on:
		return 1.0
	var shrink := clampf(1.0 - Config.balance.event_gap_shrink_per_round * float(round_number - 1), 0.5, 1.0)
	return shrink * condition_value(&"event_gap", 1.0)


## The strains that are sold for the first time in shift `round_n` (none on shift 1 and with replay off).
func get_new_strains(round_n: int) -> Array[StringName]:
	var out: Array[StringName] = []
	if not _replay_on or round_n <= 1:
		return out
	for def: SeedDef in Config.balance.seeds:
		if def != null and def.unlock_round == round_n:
			out.append(def.id)
	return out


## The best and the worst strain on sale today: [best id or &"", worst id or &""], by the market x the conditions
## that single a strain out (`sale_value:<strain>`: a strain with a buyer is never called bad). What moves every
## strain alike (`sale_value`) is left out: it has its own line on the board and would name the first strain "bad"
## for no reason. A strain only counts as best above 1.0 and as worst below it; ties go to the first in balance order.
func get_market_extremes() -> Array[StringName]:
	var best: StringName = &""
	var worst: StringName = &""
	var best_value := 1.0005
	var worst_value := 0.9995
	for def: SeedDef in Config.balance.seeds:
		if def == null or not is_strain_unlocked(def.id):
			continue
		var value := get_market_multiplier(def.id) * condition_value(StringName("sale_value:%s" % def.id), 1.0)
		if value > best_value:
			best = def.id
			best_value = value
		if value < worst_value:
			worst = def.id
			worst_value = value
	return [best, worst]


## For the alley board (and anyone else): what is different about the shift `round_number` names. One line per
## condition, then "Paying well: Purple Haze. Paying badly: Creeper." (strains on sale; each half only when one is
## off par), then "New at the window: Night Shift." on the shift a strain unlocks. Empty with replay off.
func get_shift_briefing() -> Array[String]:
	var out: Array[String] = []
	if not _replay_on:
		return out
	for id in _conditions:
		out.append(ShiftConditions.get_line(id))
	var extremes := get_market_extremes()
	var market_parts: PackedStringArray = []
	if extremes[0] != &"":
		market_parts.append("Paying well: %s." % _replay_strain_name(extremes[0]))
	if extremes[1] != &"":
		market_parts.append("Paying badly: %s." % _replay_strain_name(extremes[1]))
	if not market_parts.is_empty():
		out.append(" ".join(market_parts))
	var fresh := PackedStringArray()
	for id in get_new_strains(round_number):
		fresh.append(_replay_strain_name(id))
	if not fresh.is_empty():
		out.append("New at the window: %s." % ", ".join(fresh))
	return out


## SERVER ONLY (tests, debug). Replaces the active conditions with `ids` (unknown ids are dropped with a warning).
## Live keys apply at once. `quota` and `round_sec_add` are terms of a shift: set while the game is WAITING they
## apply to that shift (at once, and it starts with them, not with a roll); set while a shift runs they change
## nothing about it. The roll for the next shift replaces whatever was set; a test that wants every shift plain sets
## Config.balance.conditions_per_shift to 0 (and market_swing to 0). A no-op with replay off.
func server_set_conditions(ids: Array[StringName]) -> void:
	if not _require_server("server_set_conditions") or not Config.replay_enabled or phase == Phase.MENU:
		return
	var clean: Array[StringName] = []
	for id in ids:
		if ShiftConditions.has(id) and not clean.has(id):
			clean.append(id)
		else:
			push_warning("GameState.server_set_conditions: '%s' dropped (unknown or twice)" % id)
	var s := _snapshot()
	(s["replay"] as Dictionary)["conditions"] = clean
	if phase == Phase.WAITING:
		s["quota"] = get_quota_for(round_number)
		s["time"] = Config.balance.round_length_sec
		_replay_apply_terms(s)
	_rpc_state.rpc(s)


## SERVER ONLY (tests, debug). Replaces the market with `d` (strain id -> factor, snapped to 5% and kept within
## 0.05 .. 5; a strain left out pays 1.0). It lasts like server_set_conditions: until the next shift's roll. A no-op
## with replay off.
func server_set_market(d: Dictionary) -> void:
	if not _require_server("server_set_market") or not Config.replay_enabled or phase == Phase.MENU:
		return
	var s := _snapshot()
	(s["replay"] as Dictionary)["market"] = _replay_parse_market(d)
	_rpc_state.rpc(s)


## HOST, from server_start_round and _server_wait_for_next_shift, after `s` got the shift's plain quota and length:
## rolls the conditions and the market for shift `round_n` unless that shift has its roll already (made in the
## alley), then applies the conditions' quota factor and seconds to `s`.
func _replay_begin_shift(s: Dictionary, round_n: int) -> void:
	if not Config.replay_enabled:
		_replay_round = 0
		return
	if _replay_round != round_n:
		_replay_roll(s["replay"], round_n, _conditions)
		_replay_round = round_n
	_replay_apply_terms(s)


## HOST, from server_reset_game: a fresh session has nothing rolled before it; shift 1 gets its roll here (nothing,
## unless conditions_from_round is 1), so the alley shows it before the first ride.
func _replay_reset(s: Dictionary) -> void:
	_replay_round = 0
	var r := {"on": Config.replay_enabled, "conditions": [], "market": {}}
	s["replay"] = r
	if not Config.replay_enabled:
		return
	_replay_roll(r, 1, [])
	_replay_round = 1
	_replay_apply_terms(s)


## HOST: the roll for shift `round_n` into the "replay" entry `r`. `previous`: the conditions of the shift before.
func _replay_roll(r: Dictionary, round_n: int, previous: Array) -> void:
	var b: BalanceConfig = Config.balance
	var every: Array[StringName] = []
	var on_sale: Array[StringName] = []
	var mutating := false
	for def: SeedDef in b.seeds:
		if def == null:
			continue
		every.append(def.id)
		if def.unlock_round <= round_n:
			on_sale.append(def.id)
			if def.mutation_chance > 0.0:
				mutating = true
	var events: Node = get_node_or_null(^"/root/Events")
	var events_on: bool = events != null and bool(events.call(&"are_events_enabled"))
	var count := ShiftConditions.count_for_round(round_n, b.conditions_from_round, b.conditions_per_shift)
	r["conditions"] = ShiftConditions.roll(count, previous, replay_rng, events_on, on_sale, mutating)
	if round_n >= maxi(b.conditions_from_round, 1):
		r["market"] = ShiftConditions.roll_market(replay_rng, b.market_swing, every, on_sale)
	else:
		r["market"] = {}


## HOST: the conditions in `s` applied to its payment due and its clock (both must hold the plain values).
func _replay_apply_terms(s: Dictionary) -> void:
	var r: Variant = s.get("replay")
	if not r is Dictionary:
		return
	var values := ShiftConditions.combine((r as Dictionary).get("conditions", []))
	if values.has(&"quota"):
		s["quota"] = int(round(float(s["quota"]) * float(values[&"quota"])))
	if values.has(&"round_sec_add"):
		var base := float(s["time"])
		s["time"] = maxf(base + float(values[&"round_sec_add"]), base * 0.5) # never below half a shift


## HOST: `plain_quota` with the active conditions' factor (the WAITING re-price for the team size).
func _replay_quota(plain_quota: int) -> int:
	var factor := condition_value(&"quota", 1.0)
	return plain_quota if factor == 1.0 else int(round(float(plain_quota) * factor))


## HOST: the "replay" entry of a snapshot.
func _replay_snapshot() -> Dictionary:
	if not Config.replay_enabled:
		return {"on": false, "conditions": [], "market": {}}
	return {"on": true, "conditions": _conditions.duplicate(), "market": _market.duplicate()}


## Every peer, from _apply_state (after the plain fields were set, before their signals): takes the "replay" entry of
## `state` (kept as it is when the state has none; cleared in MENU) and emits the two signals when something changed.
func _replay_apply(state: Dictionary, force: bool) -> void:
	var on := _replay_on
	var new_conditions := _conditions
	var new_market := _market
	var raw: Variant = state.get("replay")
	if phase == Phase.MENU:
		on = false
		new_conditions = []
		new_market = {}
	elif raw is Dictionary:
		on = bool((raw as Dictionary).get("on", false))
		new_conditions = []
		var raw_ids: Variant = (raw as Dictionary).get("conditions", [])
		if raw_ids is Array:
			for id: Variant in raw_ids:
				var clean := StringName(str(id))
				if ShiftConditions.has(clean) and not new_conditions.has(clean):
					new_conditions.append(clean)
		new_market = _replay_parse_market((raw as Dictionary).get("market", {}))
	var conditions_differ := new_conditions != _conditions
	var market_differs := new_market != _market
	_replay_on = on
	_conditions = new_conditions
	_market = new_market
	if conditions_differ or market_differs:
		_condition_values = ShiftConditions.combine(_conditions)
		_strain_deposit = {}
		for def: SeedDef in Config.balance.seeds:
			if def == null:
				continue
			var factor := get_market_multiplier(def.id) * float(_condition_values.get(&"sale_value", 1.0)) \
					* float(_condition_values.get(StringName("sale_value:%s" % def.id), 1.0))
			if factor != 1.0:
				_strain_deposit[def.id] = factor
	if phase == Phase.PLAYING or phase == Phase.ROUND_SUCCESS or phase == Phase.ROUND_FAILED:
		_report_conditions = _conditions.duplicate()
	elif phase == Phase.MENU or round_number <= 1:
		_report_conditions = []
	if force or conditions_differ:
		conditions_changed.emit()
	if force or market_differs:
		market_changed.emit()


## {strain id -> factor} from a test or from the wire: StringName keys, factors on the 5% grid within 0.05 .. 5.
static func _replay_parse_market(raw: Variant) -> Dictionary:
	var out: Dictionary = {}
	if not raw is Dictionary:
		return out
	for key: Variant in (raw as Dictionary):
		var value: Variant = (raw as Dictionary)[key]
		if value is float or value is int:
			out[StringName(str(key))] = clampf(ShiftConditions.snap_market(float(value)), 0.05, 5.0)
	return out


func _replay_strain_name(strain_id: StringName) -> String:
	var def: SeedDef = Config.balance.get_seed(strain_id)
	return def.display_name if def != null else String(strain_id).capitalize()

# --- end M15 replay ------------------------------------------------------------------------------------------------


# ---------------------------------------------------------------------------------------------
# Local (any peer)
# ---------------------------------------------------------------------------------------------

## Back to MENU defaults on THIS peer only (no network). Called by Game/Net when returning to the menu.
func reset_local() -> void:
	_authoritative = false
	_serial = 0
	_time_sync_accum = 0.0
	_has_state = false
	_cancel_transition() # M14 lobby
	var s := {
		"phase": Phase.MENU, "money": 0, "round": 1, "quota": 0, "sales": 0,
		"time": 0.0, "upgrades": {}, "serial": 0, "stats": {}, "write_ups": {}, "backroom": {},
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
	_server_release_due()
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
	s["write_ups"] = {}
	s["backroom"] = {} # everyone is let out when the shift ends (the stats stay for the report)
	_rpc_round_ended.rpc(s, success)

## Host: lets out every back-room worker whose release time has passed (one broadcast for all of them).
func _server_release_due() -> void:
	if backroom.is_empty():
		return
	var due: Array[int] = []
	for k in backroom.keys():
		if time_left <= float(backroom[k]):
			due.append(int(k))
	if due.is_empty():
		return
	var s := _snapshot()
	var br: Dictionary = s["backroom"]
	for id in due:
		br.erase(id)
	_rpc_state.rpc(s)


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

## M10: a write-up. The state carries the fine, the stat and (maybe) the back-room entry; the event signal follows.
@rpc("authority", "call_local", "reliable")
func _rpc_written_up(state: Dictionary, peer_id: int, reason: String, count: int) -> void:
	_mark_client_if_remote()
	_apply_state(state, false)
	worker_written_up.emit(peer_id, reason, count)

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
		"stats": stats.duplicate(true),
		"write_ups": write_ups.duplicate(),
		"backroom": backroom.duplicate(),
		"replay": _replay_snapshot(), # M15 replay: conditions, market, whether the host runs with replay
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
	var old_stats := stats
	var old_backroom := backroom

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
	stats = _parse_stats(state.get("stats", stats))
	write_ups = _parse_int_map(state.get("write_ups", write_ups), false)
	backroom = _parse_int_map(state.get("backroom", backroom), true)
	_replay_apply(state, force) # M15 replay: conditions + market (their signals fire first: the rest reads them)

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
	if force or _stats_differ(old_stats, stats):
		stats_changed.emit()
	# Back room: entries that appeared / vanished (before the phase signal, so overlays see the phase last).
	for k in old_backroom.keys():
		if not backroom.has(k):
			backroom_changed.emit(int(k), false)
	for k in backroom.keys():
		if force or not old_backroom.has(k):
			backroom_changed.emit(int(k), true)
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

## Round time_left at which a back-room stay of `seconds` ends (never below 0: the shift end lets everyone out).
func _release_time(seconds: float) -> float:
	return maxf(time_left - maxf(seconds, 0.0), 0.0)

## stats[peer][key] += amount inside a snapshot's stats dictionary.
static func _bump_stat(stats_dict: Dictionary, peer_id: int, key: StringName, amount: int) -> void:
	var row: Variant = stats_dict.get(peer_id)
	if not row is Dictionary:
		row = {}
		stats_dict[peer_id] = row
	(row as Dictionary)[key] = int((row as Dictionary).get(key, 0)) + amount

## {peer -> {stat -> int}} from whatever arrived over the wire (keys become int / StringName, values int).
static func _parse_stats(raw: Variant) -> Dictionary:
	var out: Dictionary = {}
	if not raw is Dictionary:
		return out
	for pk: Variant in (raw as Dictionary):
		var row: Variant = (raw as Dictionary)[pk]
		if not row is Dictionary:
			continue
		var clean: Dictionary = {}
		for sk: Variant in (row as Dictionary):
			clean[StringName(str(sk))] = int((row as Dictionary)[sk])
		out[int(str(pk))] = clean
	return out

## {peer -> int | float} from the wire.
static func _parse_int_map(raw: Variant, as_float: bool) -> Dictionary:
	var out: Dictionary = {}
	if not raw is Dictionary:
		return out
	for pk: Variant in (raw as Dictionary):
		var v: Variant = (raw as Dictionary)[pk]
		out[int(str(pk))] = float(v) if as_float else int(v)
	return out

static func _stats_differ(a: Dictionary, b: Dictionary) -> bool:
	if a.size() != b.size():
		return true
	for pk: Variant in a:
		if not b.has(pk):
			return true
		var ra: Dictionary = a[pk]
		var rb: Dictionary = b[pk]
		if ra.size() != rb.size():
			return true
		for sk: Variant in ra:
			if int(rb.get(sk, -1)) != int(ra[sk]):
				return true
	return false

func _on_world_ready(world: Node) -> void:
	# The session lives as long as the World: when it leaves the tree we go back to MENU
	# (idempotent with Game/Net calling reset_local() themselves).
	if world != null and not world.tree_exited.is_connected(_on_world_exited):
		world.tree_exited.connect(_on_world_exited, CONNECT_ONE_SHOT)
	# Deferred so an explicit server_reset_game() made by Game in the same frame wins.
	_host_init_session.call_deferred()
	# Playtests / screenshots: `--auto-start[=sec]` makes the host start the shift by itself (default 3 s).
	if Net.is_host and Config.has_arg("auto-start") and world != null:
		var raw: Variant = Config.get_arg("auto-start", "3")
		var sec := float(raw) if raw is String and String(raw).is_valid_float() else 3.0
		world.get_tree().create_timer(maxf(sec, 0.1)).timeout.connect(request_start_round)

func _on_world_exited() -> void:
	_reset_if_world_gone.call_deferred()

func _reset_if_world_gone() -> void:
	var w: Node = Game.world
	if phase != Phase.MENU and (w == null or not is_instance_valid(w) or not w.is_inside_tree()):
		reset_local()

## Host, WAITING only: re-price the coming shift when workers join or leave (a running shift keeps its number).
func _on_players_changed() -> void:
	if phase != Phase.WAITING or not is_local_host():
		return
	var q := get_quota_for(round_number)
	q = _replay_quota(q) # M15 replay: the coming shift's conditions keep their share of the payment due
	if q == quota:
		return
	var s := _snapshot()
	s["quota"] = q
	_rpc_state.rpc(s)

## Host: a departed worker is out of the back room and off the strike list (their ledger stays for the report).
func _on_peer_left(peer_id: int) -> void:
	if phase == Phase.MENU or not is_local_host():
		return
	if not backroom.has(peer_id) and not write_ups.has(peer_id):
		return
	var s := _snapshot()
	(s["backroom"] as Dictionary).erase(peer_id)
	(s["write_ups"] as Dictionary).erase(peer_id)
	_rpc_state.rpc(s)

func _host_init_session() -> void:
	if phase == Phase.MENU and Net.is_host and multiplayer.has_multiplayer_peer() and multiplayer.is_server():
		server_reset_game()
