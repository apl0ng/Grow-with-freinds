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
	_career_ready() # M15 career: the shift's job (region at the end of the file)
	_final_ready() # M17 finale: the final notice (region at the end of the file)


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
	if _final_refuse_next("server_start_round"): return # M17 finale: a cleared run has no next shift
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
	_run_seed_dice(_run_seed, next_round) # M16 variety: this shift's dice from the run seed (once per shift)
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
	_run_reset(s) # M16 variety: the run's seed and cover, shift 1's dice (before anything is rolled from them)
	_final_reset(s) # M17 finale: a new run: the team seen so far is this one, nothing cleared (before shift 1's roll)
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
	if _final_cleared: return # M17 finale: a cleared run has no next shift (NEW RUN is request_retry)
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
	if not reset and _final_refuse_next("server_return_to_lobby"): return # M17 finale: a cleared run has no next shift
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
	_run_seed_dice(_run_seed, next_round) # M16 variety: the coming shift's dice from the run seed (once per shift)
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
	count = _final_condition_count(round_n, count) # M17 finale: the final notice always has two (when any are rolled)
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
	_career_shift_ending(success) # M15 career: a job judged at the end is settled before the end state goes out
	var s := _snapshot()
	_final_end_round(s, success) # M17 finale: paying the final notice clears the run (in the same end state)
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
		"run": _run_snapshot(), # M16 variety: the run's seed and cover layout
		"final": _final_snapshot(), # M17 finale: the run's last shift and whether it was paid
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
	_run_apply(state, force) # M16 variety: the run's seed and cover (the Room moves its cover before the phase is heard)
	_final_apply(state, force) # M17 finale: the last shift and the cleared flag (final_changed / run_cleared before the phase)

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


# --- M15 career ------------------------------------------------------------------------------------------------
# One optional job per shift (FRIENDSLOP 9.3, CONTRACTS "Career"; the catalog and the copy: scripts/core/contracts.gd).
# The HOST rolls it with replay on (Config.replay_enabled): when the game enters WAITING for a shift with the lobby
# on (so the alley can show it), else when the shift starts. It counts progress from what already happens on the
# host (the chute's and the trays' one-line hooks, worker_written_up, sale_made, Events / Hostiles signals), pays
# Config.balance.contract_reward into cash on hand the moment the job is met (STAT_CONTRACTS +1 for peer 1, "the
# floor") and tells every peer. Jobs judged at the end ("clean", "cash") are settled in _server_end_round before the
# end state goes out, and only when the payment was made. A job that needs an event which has not come by half
# time is swapped for one that needs nothing (Contracts.fallback_id).
# The job is NOT part of the state dictionary: it has its own reliable RPC on this node (same channel, so it stays in
# order with the state), and the host sends it to a late joiner when the peer registers. Peers keep what they are
# sent; a peer back in MENU forgets it. With replay off nothing is rolled and every handler below returns at once.
# M16 polish, three more jobs: "variety" counts the different strains deposited since the job went up (the chute's
# hook), "keep" fails on the first plant a tray loses (GrowPlot's hook server_note_crop_lost: eaten, burnt, collected,
# walked off) and is judged at the end like "clean", "raid" fails on Events.raid_took and is met when a raid that
# looked in at least once ends (an event job: pool and half-time swap like "leak" and "driveby").

## Every peer: the job changed in any way (put up, progress, settled, cleared).
signal contract_changed
## Every peer: a job was put up. swapped = it replaces a job whose event never came.
signal contract_offered(contract: Dictionary, swapped: bool)
## Every peer present, once per job: it was met and `contract.reward` went into cash on hand.
signal contract_met(contract: Dictionary)
## Every peer: the job can no longer be met this shift.
signal contract_failed(contract: Dictionary)
## The host and the seller's own peer: one deposit at the chute (what the career file counts per strain).
signal deposit_noted(strain: StringName, amount: int, cured: bool, value: int, seller_peer: int)

const CONTRACT_EVENT_NONE: StringName = &""
const CONTRACT_EVENT_OFFER: StringName = &"offer"
const CONTRACT_EVENT_SWAP: StringName = &"swap"
const CONTRACT_EVENT_MET: StringName = &"met"
const CONTRACT_EVENT_FAILED: StringName = &"failed"

## The shift's job ({} = none): id, text, goal, progress, reward, done, failed, round (+ strain). See Contracts.
var contract: Dictionary = {}

var _career_rng := RandomNumberGenerator.new()
## HOST: the last job rolled (the next roll picks another kind).
var _career_prev_id: StringName = &""
## HOST: the length of the running shift (time_left when it started), for the half-time swap.
var _career_shift_len: float = 0.0
## HOST: what the job needs (a leak, a drive-by, a hostile plant) has shown up this shift.
var _career_need_seen: bool = false
# --- M16 polish ---
## HOST, "variety": the strains deposited since the job went up (each counts once).
var _career_strains_seen: PackedStringArray = []
## HOST, "raid": the raid has looked in at least once since the job went up (a raid cut short settles nothing).
var _career_raid_looked: bool = false
# --- end M16 polish ---


## A copy of the shift's job ({} when there is none).
func get_contract() -> Dictionary:
	return contract.duplicate()


## HOST (tests, debug): puts up the catalog job `id` for the current shift, replacing the one in force (&"" = none).
## `overrides` are merged into the build context (e.g. {"strain": &"purple"} for "strain"). Works with replay off too.
func server_set_contract(id: StringName, overrides: Dictionary = {}) -> void:
	if not _require_server("server_set_contract"):
		return
	if phase == Phase.MENU:
		return
	if id == &"":
		_rpc_contract.rpc({}, CONTRACT_EVENT_NONE)
		return
	var ctx := _career_context()
	ctx.merge(overrides, true)
	var c := Contracts.build(id, ctx)
	if c.is_empty():
		push_warning("GameState.server_set_contract: unknown job '%s'" % id)
		return
	_career_prev_id = id
	_career_put_up(c, CONTRACT_EVENT_OFFER)


## HOST: rolls a job for the current shift from the pool that makes sense now (never the last shift's kind).
func server_roll_contract() -> void:
	if not _require_server("server_roll_contract"):
		return
	if phase == Phase.MENU:
		return
	var ctx := _career_context()
	var id := Contracts.roll(ctx, _career_rng, _career_prev_id)
	if id == &"":
		return
	_career_prev_id = id
	_career_put_up(Contracts.build(id, ctx), CONTRACT_EVENT_OFFER)


## HOST, from TurnInStation._server_sell (before the sale is booked: the sale may end the shift): one deposit.
## Counts for "cured" / "strain" and is passed on to the seller's own peer for its career file.
func server_note_deposit(strain: StringName, amount: int, cured: bool, value: int, seller_peer: int) -> void:
	if not _require_server("server_note_deposit"):
		return
	if phase == Phase.MENU:
		return
	if seller_peer > 0 and seller_peer != multiplayer.get_unique_id() and seller_peer in multiplayer.get_peers():
		_rpc_deposit_noted.rpc_id(seller_peer, strain, amount, cured, value, seller_peer)
	deposit_noted.emit(strain, amount, cured, value, seller_peer)
	if not _career_active():
		return
	match _career_id():
		Contracts.ID_CURED:
			if cured:
				_career_add_progress()
		Contracts.ID_STRAIN:
			if String(strain) != "" and String(strain) == String(contract.get("strain", "")):
				_career_add_progress()
		Contracts.ID_VARIETY: # M16 polish: a strain counts once, wet or cured, whoever deposits it
			if String(strain) != "" and not _career_strains_seen.has(String(strain)):
				_career_strains_seen.append(String(strain))
				_career_add_progress()


## HOST, from GrowPlot._server_interact: `plot` was harvested by a worker. The grow hall's trays count for "hall".
func server_note_harvest(plot: Node3D, _peer_id: int) -> void:
	if not _require_server("server_note_harvest"):
		return
	if not _career_active() or _career_id() != Contracts.ID_HALL:
		return
	var w: World = Game.world
	if plot == null or w == null or not is_instance_valid(w) or w.room == null or not plot.is_inside_tree():
		return
	if w.room.get_area_index(plot.global_position) == Contracts.HALL_AREA_INDEX:
		_career_add_progress()


# --- M16 polish ---
## HOST, from GrowPlot (server_crop_lost and the uprooting in server_tick_mutation), before the tray is reset: the
## plant in `plot` is lost to `cause` (GrowPlot.LOSS_*). Any loss fails "keep". A harvest is not a loss, and gunfire
## only sets a plant back.
func server_note_crop_lost(_plot: Node3D, _cause: StringName) -> void:
	if not _require_server("server_note_crop_lost"):
		return
	if _career_active() and _career_id() == Contracts.ID_KEEP:
		_career_fail()
# --- end M16 polish ---


func _career_ready() -> void:
	_career_rng.randomize()
	phase_changed.connect(_career_on_phase)
	round_started.connect(_career_on_round_started)
	game_reset.connect(_career_on_game_reset)
	worker_written_up.connect(_career_on_written_up)
	sale_made.connect(_career_on_sale)
	time_changed.connect(_career_on_time)
	Net.peer_registered.connect(_career_on_peer_registered)
	# Events and Hostiles come later in the autoload order: their nodes exist already, their signals are plain.
	var events := get_node_or_null(^"/root/Events")
	if events != null:
		for pair: Array in [[&"event_started", _career_on_event_started], [&"event_ended", _career_on_event_ended],
				[&"leak_resolved", _career_on_leak_resolved], [&"worker_shot", _career_on_worker_shot],
				[&"raid_took", _career_on_raid_took], [&"raid_swept", _career_on_raid_swept]]: # M16 polish: the raid job
			if events.has_signal(pair[0]):
				events.connect(pair[0], pair[1])
	var hostiles := get_node_or_null(^"/root/Hostiles")
	if hostiles != null:
		if hostiles.has_signal(&"hostile_spawned"):
			hostiles.connect(&"hostile_spawned", _career_on_hostile_spawned)
		if hostiles.has_signal(&"hostile_died"):
			hostiles.connect(&"hostile_died", _career_on_hostile_died)


func _career_id() -> StringName:
	return StringName(str(contract.get("id", "")))


## HOST: true while the job in force can still be met (this shift, running, not settled).
func _career_active() -> bool:
	if contract.is_empty() or phase != Phase.PLAYING:
		return false
	if bool(contract.get("done", false)) or bool(contract.get("failed", false)):
		return false
	return int(contract.get("round", 0)) == round_number and is_local_host()


## HOST: what a job is built and rolled from.
func _career_context() -> Dictionary:
	var on_sale: Array[StringName] = []
	var can_mutate := false
	for s: SeedDef in Config.balance.seeds:
		if s == null or (Config.replay_enabled and s.unlock_round > round_number):
			continue
		on_sale.append(s.id)
		if s.mutation_chance > 0.0:
			can_mutate = true
	var events := get_node_or_null(^"/root/Events")
	var events_on := events != null and events.has_method(&"are_events_enabled") and bool(events.call(&"are_events_enabled"))
	return {
		"team": get_team_size(), "round": round_number, "money": money, "owed": maxi(quota - round_sales, 0),
		"reward": maxi(Config.balance.contract_reward, 0),
		"strain": on_sale[_career_rng.randi_range(0, on_sale.size() - 1)] if not on_sale.is_empty() else &"",
		"events": events_on, "can_mutate": can_mutate,
		"strains": on_sale.size(), # M16 polish: "variety" needs three on sale
		"early_ok": Config.balance.round_length_sec >= Contracts.EARLY_SECONDS * 3.0,
	}


## HOST: `c` becomes the job in force (every peer hears `event`).
func _career_put_up(c: Dictionary, event: StringName) -> void:
	_career_need_seen = _career_need_live(Contracts.get_need(StringName(str(c.get("id", "")))))
	_career_strains_seen = PackedStringArray() # M16 polish: a new job counts from nothing
	_career_raid_looked = false # M16 polish
	_rpc_contract.rpc(c, event)


## HOST: is the thing a job needs on the floor right now.
func _career_need_live(need: StringName) -> bool:
	match need:
		Contracts.NEED_LEAK, Contracts.NEED_DRIVEBY, Contracts.NEED_RAID: # M16 polish: + raid
			var events := get_node_or_null(^"/root/Events")
			return events != null and events.has_method(&"is_event_active") and bool(events.call(&"is_event_active", need))
		Contracts.NEED_HOSTILE:
			var hostiles := get_node_or_null(^"/root/Hostiles")
			return hostiles != null and hostiles.has_method(&"is_any_alive") and bool(hostiles.call(&"is_any_alive"))
	return false


func _career_add_progress(amount: int = 1) -> void:
	var c := contract.duplicate()
	var goal := int(c.get("goal", 1))
	c["progress"] = mini(int(c.get("progress", 0)) + amount, goal)
	if int(c["progress"]) >= goal:
		_career_meet(c)
	else:
		_rpc_contract.rpc(c, CONTRACT_EVENT_NONE)


## HOST: the job is met. The reward and the floor's stat go out in one state, then every peer hears it.
func _career_meet(c: Dictionary) -> void:
	c["progress"] = int(c.get("goal", 1))
	c["done"] = true
	c["failed"] = false
	var s := _snapshot()
	s["money"] = money + maxi(int(c.get("reward", 0)), 0)
	_bump_stat(s["stats"], Const.SERVER_PEER_ID, Const.STAT_CONTRACTS, 1)
	_rpc_state.rpc(s)
	_rpc_contract.rpc(c, CONTRACT_EVENT_MET)


func _career_fail() -> void:
	var c := contract.duplicate()
	c["failed"] = true
	_rpc_contract.rpc(c, CONTRACT_EVENT_FAILED)


## HOST: the job's event has not come by half time: another job that needs nothing, with nothing lost.
func _career_swap() -> void:
	var any_write_up := false
	for pid: Variant in stats:
		if get_stat(int(pid), Const.STAT_WRITE_UPS) > 0:
			any_write_up = true
	var id := Contracts.fallback_id(any_write_up)
	_career_prev_id = id
	_career_put_up(Contracts.build(id, _career_context()), CONTRACT_EVENT_SWAP)


## HOST, from _server_end_round while the phase is still PLAYING: the jobs judged at the end. They need the payment.
func _career_shift_ending(success: bool) -> void:
	if not _career_active():
		return
	var id := _career_id()
	if Contracts.get_judge(id) != Contracts.JUDGE_END:
		return
	var met := success
	if id == Contracts.ID_CASH:
		met = success and money > int(contract.get("goal", 0))
	if met:
		_career_meet(contract.duplicate())
	else:
		_career_fail()


## HOST, deferred from the phase change (a reset clears the old job first): roll when the alley opens for a shift.
func _career_roll_for_waiting() -> void:
	if not Config.replay_enabled or not Config.lobby_enabled or phase != Phase.WAITING or not is_local_host():
		return
	if not contract.is_empty() and int(contract.get("round", 0)) == round_number:
		return
	server_roll_contract()


func _career_on_phase(new_phase: int) -> void:
	if new_phase == Phase.MENU:
		_career_prev_id = &""
		if not contract.is_empty():
			contract = {}
			contract_changed.emit()
	elif new_phase == Phase.WAITING and Config.replay_enabled and Config.lobby_enabled:
		_career_roll_for_waiting.call_deferred()


func _career_on_round_started(_round_number: int) -> void:
	if not is_local_host():
		return
	_career_shift_len = time_left
	_career_need_seen = false
	if not Config.replay_enabled:
		return
	if contract.is_empty() or int(contract.get("round", 0)) != round_number \
			or bool(contract.get("done", false)) or bool(contract.get("failed", false)):
		server_roll_contract()


func _career_on_game_reset() -> void:
	if not is_local_host():
		return
	if not contract.is_empty():
		_rpc_contract.rpc({}, CONTRACT_EVENT_NONE)


func _career_on_peer_registered(peer_id: int) -> void:
	if contract.is_empty() or not is_local_host():
		return
	if peer_id != multiplayer.get_unique_id() and peer_id in multiplayer.get_peers():
		_rpc_contract.rpc_id(peer_id, contract, CONTRACT_EVENT_NONE)


func _career_on_written_up(_peer_id: int, _reason: String, _count: int) -> void:
	if _career_active() and _career_id() == Contracts.ID_CLEAN:
		_career_fail()


func _career_on_sale(_amount: int, _seller_peer: int) -> void:
	if _career_active() and _career_id() == Contracts.ID_EARLY \
			and round_sales >= quota and time_left >= Contracts.EARLY_SECONDS:
		_career_meet(contract.duplicate())


func _career_on_time(left: float) -> void:
	if contract.is_empty() or not _career_active():
		return
	var id := _career_id()
	if id == Contracts.ID_EARLY:
		if left < Contracts.EARLY_SECONDS and round_sales < quota:
			_career_fail()
		return
	if Contracts.get_need(id) != Contracts.NEED_NONE and not _career_need_seen and _career_shift_len > 0.0 \
			and left <= _career_shift_len * (1.0 - Contracts.SWAP_AT_FRACTION):
		_career_swap()


func _career_on_event_started(kind: StringName, _params: Dictionary) -> void:
	if _career_active() and Contracts.get_need(_career_id()) == kind:
		_career_need_seen = true


## A drive-by that ran its course with nobody knocked down (a shift that ends first settles nothing: not active).
func _career_on_event_ended(kind: StringName) -> void:
	if kind == &"driveby" and _career_active() and _career_id() == Contracts.ID_DRIVEBY and _career_need_seen:
		_career_meet(contract.duplicate())
	# M16 polish: a raid that came, looked and left with nothing (one that took a bundle failed the job already).
	if kind == &"raid" and _career_active() and _career_id() == Contracts.ID_RAID and _career_need_seen and _career_raid_looked:
		_career_meet(contract.duplicate())


# --- M16 polish ---
func _career_on_raid_swept(_point_index: int, _taken: int) -> void:
	if _career_active() and _career_id() == Contracts.ID_RAID:
		_career_raid_looked = true


## The raid took a bundle (off the floor, off a rack or out of somebody's hands): the job is gone.
func _career_on_raid_took(_item_name: String, _holder_peer: int) -> void:
	if _career_active() and _career_id() == Contracts.ID_RAID:
		_career_fail()
# --- end M16 polish ---


func _career_on_worker_shot(_peer_id: int) -> void:
	if _career_active() and _career_id() == Contracts.ID_DRIVEBY:
		_career_fail()


## Patched inside Contracts.LEAK_SECONDS of the leak event's start (the event still runs when this arrives, so its
## own clock says how long it took); patched late or not at all: failed.
func _career_on_leak_resolved(patched: bool, _by_peer: int) -> void:
	if not _career_active() or _career_id() != Contracts.ID_LEAK:
		return
	var events := get_node_or_null(^"/root/Events")
	if events == null or not bool(events.call(&"is_event_active", &"leak")):
		return # a leak outside the event (tests, a late patch after the shift's event ended): nothing to time
	var params: Dictionary = events.call(&"get_event_params")
	var elapsed := float(params.get("seconds", 0.0)) - float(events.call(&"get_event_time_left"))
	if patched and elapsed <= Contracts.LEAK_SECONDS + 0.001:
		_career_meet(contract.duplicate())
	else:
		_career_fail()


func _career_on_hostile_spawned(_id: int, _strain_id: StringName, _position: Vector3) -> void:
	if _career_active() and _career_id() == Contracts.ID_BURN:
		_career_need_seen = true


func _career_on_hostile_died(_id: int, by_peer: int) -> void:
	if by_peer > 0 and _career_active() and _career_id() == Contracts.ID_BURN:
		_career_meet(contract.duplicate())


## Host -> every peer (the host through call_local): the job as it stands, and what just happened to it.
@rpc("authority", "call_local", "reliable")
func _rpc_contract(raw: Dictionary, event: StringName) -> void:
	contract = Contracts.parse(raw)
	contract_changed.emit()
	if contract.is_empty():
		return
	match event:
		CONTRACT_EVENT_OFFER:
			contract_offered.emit(get_contract(), false)
		CONTRACT_EVENT_SWAP:
			contract_offered.emit(get_contract(), true)
		CONTRACT_EVENT_MET:
			contract_met.emit(get_contract())
		CONTRACT_EVENT_FAILED:
			contract_failed.emit(get_contract())


## Host -> the seller: your deposit (the host emits deposit_noted itself).
@rpc("authority", "call_remote", "reliable")
func _rpc_deposit_noted(strain: StringName, amount: int, cured: bool, value: int, seller_peer: int) -> void:
	deposit_noted.emit(strain, amount, cured, value, seller_peer)

# --- end M15 career ----------------------------------------------------------------------------------------------


# --- M16 variety ---------------------------------------------------------------------------------------------------
# The run code, the dice it seeds, the cover it picks (FRIENDSLOP 10.1, CONTRACTS "M16", "Variety"; the code itself:
# scripts/core/run_seed.gd). Everything here is behind the HOST's Config.replay_enabled: with it off the seed is 0,
# the code "", the cover layout 0, nothing is seeded and nothing changes.
#
# State (one entry of the state dictionary, "run": {"seed", "cover"}; it rides on every broadcast and on the full
# state a late joiner gets):
#   seed    1 .. RunSeed.SEED_COUNT, 0 = no run. The code on the alley board is RunSeed.to_code(seed).
#   cover   the index into Room.COVER_LAYOUTS the host derived from the seed. Every peer's Room applies it from here.
# When it is picked (host): in server_reset_game, which is both a session's first set-up and START OVER. From
# Config.run_code when that reads as a code, else random. server_set_run_seed changes it while the game is WAITING.
# The cover therefore only ever changes while nobody is on a shift; a late joiner applies it when its state arrives.
# The dice (host): every shift has its own sub-seeds (RunSeed.stream(seed, "<consumer>:<shift>")), given once when
# the shift's card is about to be rolled: at the reset for shift 1, on the way back to the alley or at the start for
# the others. So shift 4 of a code deals the same card whatever happened in shifts 1 to 3: the conditions and the
# market (replay_rng), the job (_career_rng), the order and gaps of events and their picks (Events.server_seed), the
# hostile plants' dice (Hostiles.server_seed) and the spread roll (GrowPlot.spread_rng). What the workers do is not
# seeded. The two dice a test may seed itself (replay_rng, GrowPlot.spread_rng) are left alone from the moment
# somebody else has seeded them: `GameState.replay_rng.seed = 7` still means what it meant.

## Every peer: the run's seed or its cover layout changed (picked, set by a test, cleared in the menu).
signal run_changed

var _run_seed: int = 0
var _run_cover: int = 0
## HOST: picks a seed when no code was asked for (made and randomized on first use).
var _run_rng: RandomNumberGenerator = null
## HOST: the shift the dice were last seeded for (0 = none): a shift is seeded once.
var _run_dice_round: int = 0
## HOST: the seed each public die last had from this region (at start: the one it was made with). A die whose seed
## is not this any more was seeded by a test and is the test's.
var _run_dice_given: Dictionary = {&"replay": replay_rng.seed, &"spread": GrowPlot.spread_rng.seed}


## The run's seed (1 .. RunSeed.SEED_COUNT), 0 when there is none: replay off, or no session.
func get_run_seed() -> int:
	return _run_seed


## The run's code as the alley board shows it ("7K2M"); "" when there is none.
func get_run_code() -> String:
	return RunSeed.to_code(_run_seed)


## The index into Room.COVER_LAYOUTS the run stands in (0 = the scene's own arrangement, and with replay off).
func get_run_cover() -> int:
	return _run_cover


## SERVER ONLY (tests, debug). Makes `run_seed` the run's seed (folded into range by RunSeed.normalize) while the game
## is WAITING: the code and the cover change on every peer, and the dice of the shift the game waits for are seeded
## again. What is on the board for that shift already (conditions, market, job) stays; every later roll comes from
## the new seed. Refused with a warning in any other phase, for a seed below 1, and with replay off.
func server_set_run_seed(run_seed: int) -> void:
	if not _require_server("server_set_run_seed") or not Config.replay_enabled:
		return
	var canonical := RunSeed.normalize(run_seed)
	if phase != Phase.WAITING or canonical == 0:
		push_warning("GameState.server_set_run_seed: ignored (phase %s, seed %d)" % [get_phase_name(), run_seed])
		return
	_run_dice_round = 0
	_run_seed_dice(canonical, round_number)
	var s := _snapshot()
	s["run"] = _run_entry(canonical)
	_rpc_state.rpc(s)


## HOST, from server_reset_game before the replay region rolls shift 1: the run's seed into `s` and shift 1's dice.
func _run_reset(s: Dictionary) -> void:
	_run_dice_round = 0
	if not Config.replay_enabled:
		s["run"] = {"seed": 0, "cover": 0}
		return
	var run_seed := RunSeed.from_code(Config.run_code)
	if run_seed == 0:
		if _run_rng == null:
			_run_rng = RandomNumberGenerator.new()
			_run_rng.randomize()
		run_seed = RunSeed.roll(_run_rng)
	s["run"] = _run_entry(run_seed)
	_run_seed_dice(run_seed, 1)


## HOST: the "run" entry for `run_seed`: the seed and the cover layout it stands for.
func _run_entry(run_seed: int) -> Dictionary:
	return {"seed": run_seed, "cover": int(RunSeed.stream(run_seed, &"cover") % maxi(Room.COVER_LAYOUTS.size(), 1))}


## HOST: the "run" entry of a snapshot.
func _run_snapshot() -> Dictionary:
	return {"seed": _run_seed, "cover": _run_cover}


## HOST: gives every die its sub-seed for shift `round_n` of `run_seed`, once per shift (see the region header).
func _run_seed_dice(run_seed: int, round_n: int) -> void:
	if not Config.replay_enabled or run_seed <= 0 or _run_dice_round == round_n:
		return
	_run_dice_round = round_n
	_run_give(&"replay", replay_rng, RunSeed.stream(run_seed, StringName("replay:%d" % round_n)))
	_run_give(&"spread", GrowPlot.spread_rng, RunSeed.stream(run_seed, StringName("spread:%d" % round_n)))
	_career_rng.seed = RunSeed.stream(run_seed, StringName("job:%d" % round_n))
	# Events and Hostiles come later in the autoload order: looked up by path, like the career region does.
	for pair: Array in [[^"/root/Events", "events"], [^"/root/Hostiles", "hostiles"]]:
		var node := get_node_or_null(pair[0])
		if node != null and node.has_method(&"server_seed"):
			node.call(&"server_seed", RunSeed.stream(run_seed, StringName("%s:%d" % [pair[1], round_n])))


## HOST: seeds a public die unless a test has seeded it since this region last did.
func _run_give(key: StringName, rng: RandomNumberGenerator, value: int) -> void:
	if int(_run_dice_given.get(key, rng.seed)) != rng.seed:
		return
	rng.seed = value
	_run_dice_given[key] = rng.seed


## Every peer, from _apply_state (after the replay entry, before the plain signals): takes the "run" entry of `state`
## (kept as it is when the state has none; cleared in MENU), checked and clamped, and emits run_changed when it moved.
## The Room moves its cover on that signal, so the floor is in place before phase_changed and game_reset are heard.
func _run_apply(state: Dictionary, force: bool) -> void:
	var new_seed := _run_seed
	var new_cover := _run_cover
	var raw: Variant = state.get("run")
	if phase == Phase.MENU:
		new_seed = 0
		new_cover = 0
	elif raw is Dictionary:
		var raw_seed: Variant = (raw as Dictionary).get("seed", 0)
		var raw_cover: Variant = (raw as Dictionary).get("cover", 0)
		new_seed = clampi(int(raw_seed), 0, RunSeed.SEED_COUNT) if raw_seed is int else 0
		new_cover = clampi(int(raw_cover), 0, maxi(Room.COVER_LAYOUTS.size() - 1, 0)) if raw_cover is int else 0
	var cover_moved := new_cover != _run_cover
	var differs := cover_moved or new_seed != _run_seed
	_run_seed = new_seed
	_run_cover = new_cover
	if force or differs:
		run_changed.emit()
	if cover_moved and phase != Phase.MENU:
		_run_clear_cover()


## HOST, after the cover moved: a worker a crate now stands on is put back on their spawn point (a reset with the
## lobby off leaves the workers where they stood; with the lobby on they are in the alley and nothing happens).
func _run_clear_cover() -> void:
	if not is_local_host():
		return
	var w: World = Game.world
	if w == null or not is_instance_valid(w) or not w.is_inside_tree() or w.room == null:
		return
	for player in w.get_players():
		if not player.is_inside_tree() or not w.room.is_in_cover(player.global_position, Room.COVER_BODY_MARGIN):
			continue
		var xf := w.get_spawn_transform(player.spawn_index)
		if player.is_local() or multiplayer.get_peers().has(player.peer_id):
			player.server_teleport(xf)
		else:
			player.place_at(xf)

# --- end M16 variety -------------------------------------------------------------------------------------------------


# --- M17 finale ----------------------------------------------------------------------------------------------------
# A run has an end: the final notice (FRIENDSLOP 11.1, CONTRACTS "M17", "Finale"). Everything here is behind the HOST's
# Config.replay_enabled: with it off the last shift is 0, nothing is final, nothing is cleared, and a run goes on until
# a payment is missed, as before.
#
# The last shift is Config.balance.final_shift_by_team[team - 1] for the LARGEST team seen in this run (a team past
# the table's end takes its last entry; an empty table means no end). The host counts the team from
# Net.players_changed: it never goes down within a run, and a new run (server_reset_game: a session's first set-up,
# START OVER, NEW RUN) starts it again from the team that is there. Once the final notice has STARTED the number is
# locked: a worker who joins in the middle of it does not move the end of the run (one who joins while the alley
# waits for it does: the board follows). Every shift from the last one on is final (is_final_shift: round >= shift).
#
# State (one entry of the state dictionary, "final": {"shift", "cleared"}; it rides on every broadcast and on the full
# state a late joiner gets; type-checked and clamped on receive):
#   shift    the run's last shift, 0 = none
#   cleared  the final notice was paid: the run is over, ROUND_SUCCESS is its end screen
# What is different about the final notice: it always rolls two conditions (the hook in _replay_roll: only when any
# are rolled at all, so a test that wants plain shifts keeps them), and at half time the host looks at the payment
# once: under final_interim_share of it deposited, the payment due rises by final_interim_raise through the audit's
# own path (server_raise_quota) and every peer hears final_look(true, raised); at or over it, final_look(false, 0).
# Paying it: _server_end_round puts cleared into the end state, every peer present hears run_cleared (a late joiner
# who arrives afterwards gets the flag with the state, not the signal), and the only way on is a reset
# (request_retry: NEW RUN; server_start_round / server_return_to_lobby(false) / request_next_round refuse). Missing
# it is a missed payment like any other.

## Every peer: the run's last shift, whether the current shift is it, or the cleared flag changed.
signal final_changed
## Every peer present when the final notice is paid: the run is cleared (once per run; before round_ended).
signal run_cleared
## Every peer: the host looked at the payment at half time of the final notice. `short` = under the share deposited,
## and the payment due rose by `raised` dollars; otherwise raised is 0.
signal final_look(short: bool, raised: int)

## Conditions the final notice rolls (when the shift rolls any).
const FINAL_CONDITIONS: int = 2
## The host looks at the payment when this share of the shift's clock has run.
const FINAL_LOOK_AT: float = 0.5
## A last shift past this is junk from the wire.
const MAX_FINAL_SHIFT: int = 99

## Synced: the run's last shift (0 = none) and whether it was paid.
var _final_shift: int = 0
var _final_cleared: bool = false
## HOST: the largest team seen in this run.
var _final_team_max: int = 0
## HOST: the final notice has started; its number stays for the rest of the run.
var _final_locked: bool = false
## HOST: the half-time look happened this shift.
var _final_looked: bool = false
## HOST: the running shift's length (time_left when it started) and which shift it is, for half time.
var _final_shift_len: float = 0.0
var _final_len_round: int = 0
## What is_final_shift() answered after the last state (final_changed fires when it flips).
var _final_was_final: bool = false


## The run's last shift (1 .. MAX_FINAL_SHIFT); 0 when the run has no end: replay off, no session, an empty table.
func get_final_shift() -> int:
	return _final_shift


## True while the current shift is the final notice (in WAITING: the coming shift is it; it stays true on its end screen).
func is_final_shift() -> bool:
	return _final_shift > 0 and phase != Phase.MENU and round_number >= _final_shift


## True once the final notice was paid: the run is over and ROUND_SUCCESS is its end screen (until a reset).
func is_run_cleared() -> bool:
	return _final_cleared


## HOST: the largest team seen in this run (what the last shift follows). 0 before a session.
func get_largest_team() -> int:
	return _final_team_max


func _final_ready() -> void:
	Net.players_changed.connect(_final_on_players_changed)
	round_started.connect(_final_on_round_started)
	time_changed.connect(_final_on_time)


## The table's entry for a team of `team` (the last entry past its end; 0 for an empty table or a junk entry).
static func _final_table(team: int) -> int:
	var table: Array[int] = Config.balance.final_shift_by_team
	if table.is_empty():
		return 0
	return clampi(int(table[clampi(team, 1, table.size()) - 1]), 0, MAX_FINAL_SHIFT)


## HOST: the run's last shift as this host sees it now: locked, the synced number; else the table for the largest team.
func _final_host_shift() -> int:
	if not Config.replay_enabled:
		return 0
	if _final_locked:
		return _final_shift
	return _final_table(_final_team_max)


## HOST: the "final" entry of a snapshot.
func _final_snapshot() -> Dictionary:
	return {"shift": _final_host_shift(), "cleared": _final_cleared}


## HOST, from server_reset_game (before the replay region rolls shift 1): a new run.
func _final_reset(s: Dictionary) -> void:
	_final_team_max = get_team_size()
	_final_locked = false
	_final_looked = false
	s["final"] = {"shift": _final_table(_final_team_max) if Config.replay_enabled else 0, "cleared": false}


## HOST, from _replay_roll: the final notice rolls FINAL_CONDITIONS (never fewer than the shift would have had, and
## none when the shift rolls none).
func _final_condition_count(round_n: int, count: int) -> int:
	var last := _final_host_shift()
	if count <= 0 or last <= 0 or round_n < last:
		return count
	return maxi(count, FINAL_CONDITIONS)


## HOST, from _server_end_round (the end state `s` is built, its phase not yet set): paying the final notice clears it.
func _final_end_round(s: Dictionary, success: bool) -> void:
	if not success or not Config.replay_enabled or not is_final_shift():
		return
	var f: Variant = s.get("final")
	if f is Dictionary:
		(f as Dictionary)["cleared"] = true


## HOST: true, with a warning, when the run is cleared: nothing follows the final notice but a reset.
func _final_refuse_next(fn_name: String) -> bool:
	if not _final_cleared:
		return false
	push_warning("GameState.%s: the run is cleared; NEW RUN (request_retry / server_reset_game) is the way on" % fn_name)
	return true


## HOST: a bigger team than any seen this run moves the end of the run (unless the final notice has started).
func _final_on_players_changed() -> void:
	if phase == Phase.MENU or not is_local_host() or not Config.replay_enabled:
		return
	var team := get_team_size()
	if team <= _final_team_max:
		return
	_final_team_max = team
	if _final_locked or _final_host_shift() == _final_shift:
		return
	_rpc_state.rpc(_snapshot())


## HOST: the final notice has started: its number is locked for the run; the half-time look is armed.
func _final_on_round_started(_round_number: int) -> void:
	if not is_local_host():
		return
	_final_shift_len = time_left
	_final_len_round = round_number
	_final_looked = false
	if Config.replay_enabled and is_final_shift():
		_final_locked = true


## HOST: half time of the final notice, once: the look at the payment (see the region header).
func _final_on_time(left: float) -> void:
	if _final_looked or phase != Phase.PLAYING or _final_shift_len <= 0.0 or _final_len_round != round_number or not is_final_shift():
		return
	if left > _final_shift_len * FINAL_LOOK_AT or not is_local_host() or not Config.replay_enabled:
		return
	_final_looked = true
	var short := float(round_sales) < float(quota) * clampf(Config.balance.final_interim_share, 0.0, 1.0)
	var raised := 0
	if short:
		var before := quota
		raised = maxi(server_raise_quota(maxf(Config.balance.final_interim_raise, 0.0)) - before, 0)
	_rpc_final_look.rpc(short, raised)


## Every peer, from _apply_state (after the run entry, before the plain signals): takes the "final" entry of `state`
## (kept as it is when the state has none; cleared in MENU), checked and clamped; final_changed when anything moved,
## run_cleared on the state that cleared the run (not on a late joiner's first state).
func _final_apply(state: Dictionary, force: bool) -> void:
	var new_shift := _final_shift
	var new_cleared := _final_cleared
	var raw: Variant = state.get("final")
	if phase == Phase.MENU:
		new_shift = 0
		new_cleared = false
		_final_locked = false
		_final_looked = false
	elif raw is Dictionary:
		var raw_shift: Variant = (raw as Dictionary).get("shift", 0)
		var raw_cleared: Variant = (raw as Dictionary).get("cleared", false)
		new_shift = clampi(int(raw_shift), 0, MAX_FINAL_SHIFT) if raw_shift is int else 0
		new_cleared = bool(raw_cleared) if raw_cleared is bool else false
	var just_cleared := new_cleared and not _final_cleared and not force
	var differs := new_shift != _final_shift or new_cleared != _final_cleared
	_final_shift = new_shift
	_final_cleared = new_cleared
	var now_final := is_final_shift()
	if force or differs or now_final != _final_was_final:
		final_changed.emit()
	_final_was_final = now_final
	if just_cleared:
		run_cleared.emit()


## Host -> every peer (the host through call_local): the half-time look and what it did to the payment due.
@rpc("authority", "call_local", "reliable")
func _rpc_final_look(short: bool, raised: int) -> void:
	final_look.emit(short, clampi(raised, 0, 1000000))

# --- end M17 finale --------------------------------------------------------------------------------------------------
