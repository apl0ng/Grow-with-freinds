extends Node
## Autoload "Story": the narrative glue of the factory (PLAN.md task 8.2). Owned by the narrative agent.
## Do NOT add a class_name (autoload).
##
## Every peer runs this on its own. It only listens to GameState / Net / Game signals, which fire on every peer
## from synced state, so the debt board and the Boss's lines need no RPCs and cannot desync.
##
## DEBT BOARD (Game.world.room.set_debt_board_text):
##   WAITING / PLAYING   "OWED $<payment due - deposited> / SHIFT <n>"
##   ROUND_SUCCESS       "PAID… FOR NOW"
##   ROUND_FAILED        "YOU'RE DONE"
##   (MENU / no session  the room's own default, "PAY UP")
##
## BOSS BARKS go through the ShopkeeperNPC's bark(text), found under the ShopCounter station (any node with a
## bark() method; the rest of the room is searched as a fallback). An old NPC without bark() gets the line as a
## toast ("Boss: …"). Without a world nothing is shown; every line still lands in `bark_log` / `last_bark`.
##   event                                       line key      weight
##   shift starts (GameState.round_started)      shift_start   MAJOR
##   30 s left and still short                   last_call     MAJOR
##   payment met / missed (round_ended)          paid / missed MAJOR
##   deposits pass 50 % of the payment           halfway       PROGRESS
##   first deposit of a shift                    first_sale    CHATTER
##   anything bought (seeds or a favor)          purchase      CHATTER
##   a worker joins / leaves                     joined / left CHATTER
##   M10 (ui agent), from Events / GameState signals (Events only emits; Story owns every line of copy):
##   inspection starts / ends (Events.event_started/ended)   inspection_start MAJOR / inspection_end PROGRESS
##   power cut / audit / rat starts                          power_cut / audit / rat  PROGRESS
##   power back on (Events.power_changed(true))              power_back    PROGRESS
##   a write-up (GameState.worker_written_up)                skimming / loitering / write_up_other  MAJOR ("%s" = name)
##   sent to / let out of the back room (backroom_changed)   backroom / backroom_release MAJOR (release only while
##                                                           PLAYING; a write-up that sends someone to the back room
##                                                           says only the back-room line)
##   "confiscated" ("That's mine now.") is a line for whoever takes the product: Story.bark_now(Story.line("confiscated")).
##   Shift report verdicts: get_report_verdicts() (round_end.gd shows them), format strings verdict_*.
## Rate limit: MAJOR lines always show at once. A lighter line shows only if the last Story line is at least
## MIN_BARK_GAP_SEC old, or was a lighter non-MAJOR line (PROGRESS cuts off CHATTER); otherwise it waits in a
## one-slot queue (heavier wins, ties keep the newest) and is dropped after PENDING_TTL_SEC or when the phase /
## shift changes. The Boss's own idle lines (ShopkeeperNPC.auto_bark) are simply talked over, and every bark()
## restarts his 20-40 s idle timer, so idle lines never crowd event lines.
## A deposit that completes the payment says nothing itself: the round_ended line covers it.

signal bark_shown(text: String)

## Minimum seconds between two Story lines (MAJOR lines and escalations excepted, see above).
const MIN_BARK_GAP_SEC: float = 6.0
## A queued line older than this is dropped instead of shown late.
const PENDING_TTL_SEC: float = 8.0
## "Tick tock." once per shift when the timer crosses this and the payment is still short.
const LAST_CALL_SEC: float = 30.0
const BARK_LOG_MAX: int = 32
const BOSS_TOAST_FORMAT: String = "Boss: %s"
## Node-name hints for an old NPC that has no bark() (toast fallback).
const BOSS_NAME_HINTS: PackedStringArray = ["Shopkeeper", "Boss"]

enum Weight { IDLE, CHATTER, PROGRESS, MAJOR }

## Every line of copy Story owns. Tests read these; board_* are format strings.
var lines: Dictionary = {
	"shift_start": "Shift's on. Don't waste my time.",
	"first_sale": "That's it?",
	"halfway": "Halfway. Keep going.",
	"paid": "…Acceptable. Next number's bigger.",
	"missed": "You're done. Nobody leaves.",
	"purchase": "On your tab.",
	"joined": "Another one. Get to work.",
	"left": "One less to pay.",
	"last_call": "Tick tock.",
	# M10: inspections, write-ups, the back room, events (flat, no "!"; "%s" = the worker's name).
	"inspection_start": "Walking the floor. Don't make me stop.",
	"inspection_end": "…Back to the window.",
	"skimming": "Skimming, %s.",
	"loitering": "Standing around, %s.",
	"write_up_other": "Written up, %s.",
	"backroom": "%s. Back room. Now.",
	"backroom_release": "Back to work, %s.",
	"confiscated": "That's mine now.",
	"power_cut": "Not my problem.",
	"power_back": "…Took you long enough.",
	"audit": "The number went up.",
	"rat": "Rats. Not my problem either.",
	# M10: shift report verdicts (round_end.gd), "%s" = the worker's name.
	"verdict_least": "Least useful: %s.",
	"verdict_noticed": "He noticed: %s.",
	"verdict_worst": "Worst behaved: %s.",
	"board_owed": "OWED %s / SHIFT %d",
	"board_paid": "PAID… FOR NOW",
	"board_done": "YOU'RE DONE",
	"board_closed": "PAY UP",
}

## Flat one-liners for the SUPPLY WINDOW cards, by seed / upgrade id (the data descriptions are the fallback).
## Number-free on purpose: the cards compute the real numbers from balance.tres next to them.
var blurbs: Dictionary = {
	"budget": "Cheap. Fast. Pays almost nothing.",
	"purple": "Slower. Pays better.",
	"golden": "Slow. Bigger yield. Don't mess it up.",
	# --- M12 strains ---
	"nightshift": "Pays the best. Some of them get up and walk.",
	"creeper": "Cheap. Quick. It twitches. Keep your distance.",
	"brick": "Slow. Heavy yield. Some of them walk off with it.",
	# --- end M12 strains ---
	"fertilizer": "They grow faster. Don't ask what's in it.",
	"big_can": "Bigger cans. Fewer trips to the tank.",
	"sweet_talk": "He takes a smaller cut of every deposit.",
}

## Test hooks: when set, used instead of the Boss / debt board found in Game.world.
## boss_override: any Object (with bark(text) or not); board_override: any Object with set_debt_board_text(text).
var boss_override: Object = null
var board_override: Object = null

## The most recent line shown (or that would have been shown without a world), newest last.
var last_bark: String = ""
var bark_log: PackedStringArray = []
## The most recent debt board text Story wrote (or would have written without a world).
var board_text: String = ""

var _clock: float = 0.0
var _last_at: float = -INF
var _last_weight: int = Weight.IDLE
## {"text", "weight", "at", "context"} or empty.
var _pending: Dictionary = {}
var _first_sale_done: bool = false
var _halfway_done: bool = false
var _last_call_armed: bool = false
var _boss_cache: Object = null


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	GameState.phase_changed.connect(_on_phase_changed)
	GameState.sales_changed.connect(_on_sales_changed)
	GameState.round_started.connect(_on_round_started)
	GameState.round_ended.connect(_on_round_ended)
	GameState.sale_made.connect(_on_sale_made)
	GameState.purchase_made.connect(_on_purchase_made)
	GameState.time_changed.connect(_on_time_changed)
	GameState.game_reset.connect(_on_game_reset)
	Net.peer_joined.connect(_on_peer_joined)
	Net.peer_left.connect(_on_peer_left)
	Game.world_ready.connect(_on_world_ready)
	# M10: discipline + events. Guarded so a renamed sibling surface degrades to silence, never to a crash.
	if GameState.has_signal(&"worker_written_up"):
		GameState.worker_written_up.connect(_on_worker_written_up)
	if GameState.has_signal(&"backroom_changed"):
		GameState.backroom_changed.connect(_on_backroom_changed)
	var events: Node = Events
	if events != null:
		if events.has_signal(&"event_started"):
			events.connect(&"event_started", _on_event_started)
		if events.has_signal(&"event_ended"):
			events.connect(&"event_ended", _on_event_ended)
		if events.has_signal(&"power_changed"):
			events.connect(&"power_changed", _on_power_changed)
	_connect_hostile_signals() # --- M12 hostile --- (lines + handlers live in the region at the end of this file)
	_disrupt_setup()  # M12 disrupt: its lines + event hooks (region at the end of the file)
	_m13_setup()  # M13 lead: report verdicts for burns / scorched / bitten (region at the end of the file)
	_mayhem_setup()  # M14 mayhem: the leak and the drive-by (region at the end of the file)
	_replay_setup()  # M15 replay: the shift conditions (region at the end of the file)
	_mayhem2_setup()  # M15 mayhem2: the raid, the sprinklers, the collector (region after the M14 mayhem one)
	_mayhem3_setup()  # M17 mayhem3: the scale, the phone (region after the M15 mayhem2 one)
	_career_setup()  # M15 career: the shift's job (region at the end of the file)
	_finale_setup()  # M17 finale: the final notice (region at the end of the file)


func _process(delta: float) -> void:
	tick(delta)


# ---------------------------------------------------------------------------------------------
# Public API
# ---------------------------------------------------------------------------------------------

## A line of copy by key ("" if unknown).
func line(key: String) -> String:
	return String(lines.get(key, ""))


## Flat card blurb for a seed / upgrade id, or `fallback` (the data description).
func get_blurb(id: StringName, fallback: String = "") -> String:
	return String(blurbs.get(String(id), fallback))


## The Boss says `text` right now, skipping the rate limit (the gap still counts from here).
func bark_now(text: String, weight: int = Weight.PROGRESS) -> void:
	if text.strip_edges() == "":
		return
	_show(text, weight)


## Advances Story's clock and shows a queued line once the gap allows it (called every frame; tests call it to
## skip time).
func tick(delta: float) -> void:
	_clock += maxf(delta, 0.0)
	if _pending.is_empty():
		return
	if _clock - float(_pending["at"]) > PENDING_TTL_SEC or String(_pending["context"]) != _context():
		_pending = {}
		return
	if _clock - _last_at >= MIN_BARK_GAP_SEC:
		_show(String(_pending["text"]), int(_pending["weight"]))


## The queued line ("" when nothing waits).
func get_pending_text() -> String:
	return String(_pending.get("text", ""))


## Debt board text for the current GameState.
func get_board_text() -> String:
	match GameState.phase:
		GameState.Phase.WAITING, GameState.Phase.PLAYING:
			var owed := maxi(GameState.quota - GameState.round_sales, 0)
			return line("board_owed") % [format_money(owed), GameState.round_number]
		GameState.Phase.ROUND_SUCCESS:
			if GameState.is_run_cleared(): return line("board_cleared")  # M17 finale: the run's last payment
			return line("board_paid")
		GameState.Phase.ROUND_FAILED:
			return line("board_done")
	return line("board_closed")


## Writes get_board_text() to the debt board (null-safe without a world).
func refresh_board() -> void:
	board_text = get_board_text()
	var board := _find_board()
	if board != null:
		board.call(&"set_debt_board_text", board_text)


## The node the Boss lines go to (bark() or the old-NPC toast fallback), or null.
func find_boss() -> Object:
	if boss_override != null:
		return boss_override if is_instance_valid(boss_override) else null
	if is_instance_valid(_boss_cache) and (_boss_cache as Node).is_inside_tree():
		return _boss_cache
	_boss_cache = null
	var room := _get_room()
	if room == null:
		return null
	var counter: Node = null
	if room.has_method(&"get_station"):
		counter = room.call(&"get_station", "ShopCounter") as Node
	if counter == null:
		counter = room.get_node_or_null(^"Stations/ShopCounter")
	var found: Node = _find_descendant(counter, true) if counter != null else null
	if found == null:
		found = _find_descendant(room, true)
	if found == null and counter != null:
		found = _find_descendant(counter, false) # an old NPC without bark(): toast fallback
	_boss_cache = found
	return found


## Forgets queued lines, flags, the log and the clock gap (tests; also on MENU). Overrides are kept.
func reset_state() -> void:
	_pending = {}
	_last_at = -INF
	_last_weight = Weight.IDLE
	_first_sale_done = false
	_halfway_done = false
	_last_call_armed = false
	_boss_cache = null
	last_bark = ""
	bark_log = PackedStringArray()


## "$1,234" (same format as HUD.format_money, kept here so this autoload does not load UI scripts).
static func format_money(amount: int) -> String:
	var digits := str(absi(amount))
	var grouped := ""
	var count := 0
	for i in range(digits.length() - 1, -1, -1):
		grouped = digits[i] + grouped
		count += 1
		if count % 3 == 0 and i > 0:
			grouped = "," + grouped
	return ("-$" if amount < 0 else "$") + grouped


## M10: the workers on the shift report: every registered peer plus every peer with a ledger entry that left
## (Net.get_player_name still knows departed names), sorted by id.
static func get_report_peers() -> Array[int]:
	var ids: Dictionary = {}
	for k in Net.players.keys():
		ids[int(k)] = true
	for k in GameState.stats.keys():
		ids[int(k)] = true
	var out: Array[int] = []
	for k in ids.keys():
		out.append(int(k))
	out.sort()
	return out


## M10: a worker's usefulness this shift: deposited + 20 x (planted + watered + harvested) - 50 x write-ups.
static func get_report_score(peer_id: int) -> int:
	var gs: Node = GameState
	var doing: int = gs.get_stat(peer_id, Const.STAT_PLANTED) + gs.get_stat(peer_id, Const.STAT_WATERED) \
			+ gs.get_stat(peer_id, Const.STAT_HARVESTED)
	return gs.get_stat(peer_id, Const.STAT_DEPOSITED) + 20 * doing - 50 * gs.get_stat(peer_id, Const.STAT_WRITE_UPS)


## M10: the shift report's verdict lines, in order (round_end.gd shows them under the per-worker table):
##   "Least useful: <name>."  the lowest score (get_report_score; ties: the lowest peer id)
##   "He noticed: <name>."    the most deposited, only if somebody deposited anything (ties: lowest id)
##   "Worst behaved: <name>." the most write-ups, only if there were any (ties: lowest id)
## With a single worker: only "Least useful" when they deposited nothing, else only "He noticed".
func _base_report_verdicts() -> PackedStringArray:
	var out := PackedStringArray()
	var peers := get_report_peers()
	if peers.is_empty():
		return out
	var least := peers[0]
	var least_score := get_report_score(least)
	var noticed := peers[0]
	var noticed_amount := GameState.get_stat(noticed, Const.STAT_DEPOSITED)
	var worst := peers[0]
	var worst_count := GameState.get_stat(worst, Const.STAT_WRITE_UPS)
	for id in peers:
		var score := get_report_score(id)
		if score < least_score:
			least = id
			least_score = score
		var deposited := GameState.get_stat(id, Const.STAT_DEPOSITED)
		if deposited > noticed_amount:
			noticed = id
			noticed_amount = deposited
		var strikes := GameState.get_stat(id, Const.STAT_WRITE_UPS)
		if strikes > worst_count:
			worst = id
			worst_count = strikes
	if peers.size() == 1:
		if noticed_amount > 0:
			out.append(line("verdict_noticed") % Net.get_player_name(noticed))
		else:
			out.append(line("verdict_least") % Net.get_player_name(least))
		return out
	out.append(line("verdict_least") % Net.get_player_name(least))
	if noticed_amount > 0:
		out.append(line("verdict_noticed") % Net.get_player_name(noticed))
	if worst_count > 0:
		out.append(line("verdict_worst") % Net.get_player_name(worst))
	return out


# ---------------------------------------------------------------------------------------------
# Signal handlers (every peer)
# ---------------------------------------------------------------------------------------------

func _on_phase_changed(new_phase: int) -> void:
	refresh_board()
	if new_phase == GameState.Phase.MENU:
		reset_state()
		return
	if new_phase == GameState.Phase.PLAYING:
		# Re-derive the per-shift flags from the synced state (a late joiner must not hear old news).
		_first_sale_done = GameState.round_sales > 0
		_halfway_done = GameState.quota > 0 and GameState.round_sales * 2 >= GameState.quota
		_last_call_armed = GameState.time_left > LAST_CALL_SEC
	else:
		_last_call_armed = false


func _on_sales_changed(_sales: int, _quota: int) -> void:
	refresh_board()


func _on_round_started(_round_number: int) -> void:
	_request("shift_start", Weight.MAJOR)


func _on_round_ended(success: bool, _round_number: int) -> void:
	if success and GameState.is_run_cleared(): _request("final_cleared", Weight.MAJOR); return  # M17 finale: no next number
	_request("paid" if success else "missed", Weight.MAJOR)


func _on_sale_made(amount: int, _seller_peer: int) -> void:
	if amount <= 0 or GameState.phase != GameState.Phase.PLAYING:
		return
	var sales := GameState.round_sales
	var quota := GameState.quota
	if quota > 0 and sales >= quota:
		_first_sale_done = true
		_halfway_done = true
		return # the round_ended line (or the HUD's "covered" toast) says it
	if not _halfway_done and quota > 0 and sales * 2 >= quota:
		_halfway_done = true
		_first_sale_done = true
		_request("halfway", Weight.PROGRESS)
		return
	if not _first_sale_done:
		_first_sale_done = true
		_request("first_sale", Weight.CHATTER)


func _on_purchase_made(cost: int, _buyer_peer: int, _what: String) -> void:
	if cost > 0 and _in_session():
		_request("purchase", Weight.CHATTER)


func _on_time_changed(time_left: float) -> void:
	if not _last_call_armed or GameState.phase != GameState.Phase.PLAYING:
		return
	if time_left > LAST_CALL_SEC or time_left <= 0.0:
		return
	_last_call_armed = false
	if GameState.round_sales < GameState.quota:
		_request("last_call", Weight.MAJOR)


func _on_game_reset() -> void:
	_pending = {}
	refresh_board()


func _on_peer_joined(_peer_id: int) -> void:
	if _in_session():
		_request("joined", Weight.CHATTER)


func _on_peer_left(peer_id: int) -> void:
	if not _in_session() or peer_id == _local_peer_id():
		return
	_request("left", Weight.CHATTER)


func _on_world_ready(_world: Node) -> void:
	_boss_cache = null
	refresh_board()


# --- M10: discipline + events ------------------------------------------------------------------

## A write-up names the worker. count == 0 means this one sent them to the back room: backroom_changed follows in
## the same frame and its line is the one that matters, so the write-up itself stays quiet then.
func _on_worker_written_up(peer_id: int, reason: String, count: int) -> void:
	if not _in_session() or count == 0:
		return
	var key := "write_up_other"
	if reason == Const.WRITE_UP_SKIMMING:
		key = "skimming"
	elif reason == Const.WRITE_UP_LOITERING:
		key = "loitering"
	elif reason == Const.WRITE_UP_ABSENT:  # M12 disrupt: missed the head count
		key = "absent"
	elif reason == Const.WRITE_UP_RAID:  # M15 mayhem2: held a bundle when the raid looked
		key = "raid_caught"
	_request_named(key, Net.get_player_name(peer_id), Weight.MAJOR)


func _on_backroom_changed(peer_id: int, active: bool) -> void:
	if not _in_session():
		return
	if active:
		_request_named("backroom", Net.get_player_name(peer_id), Weight.MAJOR)
	elif GameState.phase == GameState.Phase.PLAYING and Net.players.has(peer_id):
		# Released by the timer or the host; the shift end lets everyone out silently (paid / missed says it), and a
		# worker who dropped out of the session mid-stay is not told to get back to work (M11 review).
		_request_named("backroom_release", Net.get_player_name(peer_id), Weight.MAJOR)


func _on_event_started(kind: StringName, _params: Dictionary) -> void:
	if not _in_session():
		return
	match kind:
		&"inspection":
			_request("inspection_start", Weight.MAJOR)
		&"power_cut":
			_request("power_cut", Weight.PROGRESS)
		&"audit":
			_request("audit", Weight.PROGRESS)
		&"rat":
			_request("rat", Weight.PROGRESS)


func _on_event_ended(kind: StringName) -> void:
	if not _in_session():
		return
	if kind == &"inspection":
		_request("inspection_end", Weight.PROGRESS)


## The mains came back (fuse box reset). Going dark is announced by the power_cut event itself.
func _on_power_changed(on: bool) -> void:
	if on and _in_session():
		_request("power_back", Weight.PROGRESS)


# ---------------------------------------------------------------------------------------------
# Internals
# ---------------------------------------------------------------------------------------------

func _request(key: String, weight: int) -> void:
	var text := line(key)
	if text == "":
		return
	if weight >= Weight.MAJOR or _can_show_now(weight):
		_show(text, weight)
		return
	if _pending.is_empty() or weight >= int(_pending["weight"]):
		_pending = {"text": text, "weight": weight, "at": _clock, "context": _context()}


## _request for a line with one "%s" (the worker's name).
func _request_named(key: String, worker_name: String, weight: int) -> void:
	var fmt := line(key)
	if fmt == "":
		return
	var text := fmt % worker_name if fmt.contains("%s") else fmt
	if weight >= Weight.MAJOR or _can_show_now(weight):
		_show(text, weight)
		return
	if _pending.is_empty() or weight >= int(_pending["weight"]):
		_pending = {"text": text, "weight": weight, "at": _clock, "context": _context()}


func _can_show_now(weight: int) -> bool:
	if _clock - _last_at >= MIN_BARK_GAP_SEC:
		return true
	return _last_weight < Weight.MAJOR and weight > _last_weight


func _show(text: String, weight: int) -> void:
	_last_at = _clock
	_last_weight = weight
	_pending = {}
	last_bark = text
	bark_log.append(text)
	if bark_log.size() > BARK_LOG_MAX:
		bark_log.remove_at(0)
	var boss := find_boss()
	if boss != null:
		if boss.has_method(&"bark"):
			boss.call(&"bark", text)
		else:
			Game.toast(BOSS_TOAST_FORMAT % text, &"info")
	bark_shown.emit(text)


## Queued lines only survive while the phase and shift stay the same.
func _context() -> String:
	return "%d:%d" % [GameState.phase, GameState.round_number]


func _in_session() -> bool:
	return GameState.phase != GameState.Phase.MENU


func _local_peer_id() -> int:
	if not multiplayer.has_multiplayer_peer():
		return 0
	return multiplayer.get_unique_id()


func _get_room() -> Node:
	var world: Node = Game.world
	if not is_instance_valid(world) or not world.is_inside_tree():
		return null
	var room: Variant = world.get(&"room")
	if room is Node and is_instance_valid(room):
		return room
	return world.get_node_or_null(^"Room")


func _find_board() -> Object:
	if board_override != null:
		return board_override if is_instance_valid(board_override) else null
	var room := _get_room()
	if room != null and room.has_method(&"set_debt_board_text"):
		return room
	return null


## Breadth-first: the first node under `root` (itself included) with a bark() method (`with_bark`), or whose
## name looks like the Boss (`with_bark` false, for the toast fallback).
static func _find_descendant(root: Node, with_bark: bool) -> Node:
	if root == null:
		return null
	var queue: Array[Node] = [root]
	while not queue.is_empty():
		var node: Node = queue.pop_front()
		if with_bark:
			if node.has_method(&"bark"):
				return node
		else:
			for hint in BOSS_NAME_HINTS:
				if String(node.name).contains(hint):
					return node
		queue.append_array(node.get_children())
	return null


# --- M12 hostile --------------------------------------------------------------------------------------------------
## The hostile plant (hostile agent). Hostiles only emits signals (on every peer, from its call_local RPCs); every line
## is here, flat, in the house tone:
##   hostile_spawned   "Something came out of GrowPlot 3."   MAJOR     (the tray nearest the spawn point)
##   hostile_eating    "It is eating GrowPlot 2."            PROGRESS
##   hostile_ate       "GrowPlot 2 is gone."                 PROGRESS
##   hostile_bit       "It bit Dale."                        PROGRESS  ("%s" = the worker's name)
##   hostile_died      "It stopped moving."                  MAJOR
## The keys are merged into `lines` at startup so the copy audit and line() see them like any other line.

const HOSTILE_LINES: Dictionary = {
	"plot_turning": "%s is moving.",
	"hostile_spawned": "Something came out of %s.",
	"hostile_eating": "It is eating %s.",
	"hostile_ate": "%s is gone.",
	"hostile_bit": "It bit %s.",
	"hostile_died": "It stopped moving.",
}
## A spawn within this distance of a tray's centre is "out of" that tray.
const HOSTILE_PLOT_RANGE := 1.5
const HOSTILE_PLOT_NAME := "GrowPlot %d"
const HOSTILE_PLOT_FALLBACK := "the trays"


## Every peer, from GrowPlot's `turning` setter: "GrowPlot 3 is moving." (MAJOR: six seconds to harvest it or step back).
func hostile_plot_turning(plot_label: String) -> void:
	if _in_session():
		# The Boss only speaks at his window: the floor also gets it on screen (every peer, local).
		Game.toast(String(lines.get("plot_turning", "%s is moving.")) % plot_label, &"error")
		_request_named("plot_turning", plot_label, Weight.MAJOR)

func _connect_hostile_signals() -> void:
	for k in HOSTILE_LINES:
		if not lines.has(k):
			lines[k] = HOSTILE_LINES[k]
	var hostiles: Node = get_node_or_null(^"/root/Hostiles")
	if hostiles == null:
		hostiles = Hostiles
	if hostiles == null:
		return
	if hostiles.has_signal(&"hostile_spawned"):
		hostiles.connect(&"hostile_spawned", _on_hostile_spawned)
	if hostiles.has_signal(&"hostile_eating"):
		hostiles.connect(&"hostile_eating", _on_hostile_eating)
	if hostiles.has_signal(&"hostile_ate"):
		hostiles.connect(&"hostile_ate", _on_hostile_ate)
	if hostiles.has_signal(&"hostile_bit"):
		hostiles.connect(&"hostile_bit", _on_hostile_bit)
	if hostiles.has_signal(&"hostile_died"):
		hostiles.connect(&"hostile_died", _on_hostile_died)


func _on_hostile_spawned(_id: int, _strain_id: StringName, position: Vector3) -> void:
	if not _in_session():
		return
	var idx := _hostile_plot_index_near(position)
	var where: String = HOSTILE_PLOT_NAME % idx if idx > 0 else HOSTILE_PLOT_FALLBACK
	Game.toast(String(lines.get("hostile_spawned", "Something came out of %s.")) % where, &"error")
	_request_named("hostile_spawned", where, Weight.MAJOR)


func _on_hostile_eating(_id: int, plot_index: int) -> void:
	if _in_session() and plot_index > 0:
		_request_named("hostile_eating", HOSTILE_PLOT_NAME % plot_index, Weight.PROGRESS)


func _on_hostile_ate(_id: int, plot_index: int) -> void:
	if _in_session() and plot_index > 0:
		_request_named("hostile_ate", HOSTILE_PLOT_NAME % plot_index, Weight.PROGRESS)


func _on_hostile_bit(_id: int, peer_id: int) -> void:
	if _in_session():
		_request_named("hostile_bit", Net.get_player_name(peer_id), Weight.PROGRESS)


func _on_hostile_died(_id: int, _by_peer: int) -> void:
	if _in_session():
		_request("hostile_died", Weight.MAJOR)


## The GrowPlot index (1..6) whose tray is within HOSTILE_PLOT_RANGE of `position`, 0 when none.
func _hostile_plot_index_near(position: Vector3) -> int:
	var room := _get_room()
	if room == null or not room.has_method(&"get_station"):
		return 0
	var best := 0
	var best_d := HOSTILE_PLOT_RANGE
	for i in range(1, Room.GROW_PLOT_COUNT + 1): # M14 level: the hall's trays too
		var plot := room.call(&"get_station", "GrowPlot%d" % i) as Node3D
		if plot == null or not plot.is_inside_tree():
			continue
		var d := Vector2(plot.global_position.x - position.x, plot.global_position.z - position.z).length()
		if d <= best_d:
			best_d = d
			best = i
	return best


# --- M12 flame (flame agent): the emergency cabinet and the flamethrower ----------------------------------------
# Lines are requested from every-peer cosmetic code (the cabinet's glass-break RPC, GrowPlot's scorch RPC, Player's
# ignite RPC), so each peer shows its own copy without any Story RPC. All three are PROGRESS: the write-up that
# usually follows them (misuse / arson, MAJOR) takes the Boss's mouth first and these come out of the queue after it.

## Copy for the cabinet / flamethrower; installed into `lines` when Story is built (the initializer below runs after
## `lines`), so Story.line("glass_broke") works like any other key. The lead may fold them into the dict at merge.
const FLAME_LINES: Dictionary = {
	"glass_broke": "Glass broke.",
	"on_fire": "%s is on fire.",
	"plot_burnt": "%s burnt.",
}
var _flame_lines_installed: bool = _install_flame_lines()


func _install_flame_lines() -> bool:
	for key in FLAME_LINES:
		if not lines.has(key):
			lines[key] = FLAME_LINES[key]
	return true


## Every peer, from EmergencyCabinet._rpc_glass_break: "Glass broke."
func flame_glass_broke() -> void:
	if _in_session():
		_request("glass_broke", Weight.PROGRESS)


## Every peer, from Player._rpc_ignited: "Dale is on fire."
func flame_worker_ignited(peer_id: int) -> void:
	if _in_session():
		_request_named("on_fire", Net.get_player_name(peer_id), Weight.PROGRESS)


## Every peer, from GrowPlot._rpc_scorched: "GrowPlot 2 burnt." (`plot_label` = GrowPlot.get_scorch_label()).
func flame_plot_burnt(plot_label: String) -> void:
	if _in_session():
		_request_named("plot_burnt", plot_label, Weight.PROGRESS)


# --- M12 disrupt: the head count, the water main, the supply shortage ---------------------------------------------
# Lines and hooks for the three M12 interruptions (Events emits; Story owns the copy). _ready() calls _disrupt_setup();
# _on_worker_written_up maps the reason WRITE_UP_ABSENT to the "absent" line. Everything else lives here.

## Copy for the interruptions, merged into `lines` at start-up ("%s" = the worker's name / the strain's name).
const DISRUPT_LINES: Dictionary = {
	"headcount": "Head count. The line. Now.",
	"headcount_end": "Counted. Back to work.",
	"absent": "Not on the line, %s.",
	"water_off": "Water main is off.",
	"water_back": "Water's back. Still not drinkable.",
	"shortage": "No more %s this shift.",
	"shortage_end": "%s is back in. Same price.",
}

## The strain a running shortage hit (display name), kept for the line when it ends.
var _disrupt_shortage_name: String = ""


func _disrupt_setup() -> void:
	lines.merge(DISRUPT_LINES)
	var events: Node = get_node_or_null(^"/root/Events")
	if events == null:
		return
	if events.has_signal(&"event_started"):
		events.connect(&"event_started", _disrupt_on_event_started)
	if events.has_signal(&"event_ended"):
		events.connect(&"event_ended", _disrupt_on_event_ended)


func _disrupt_on_event_started(kind: StringName, params: Dictionary) -> void:
	if not _in_session():
		return
	match kind:
		&"headcount":
			_request("headcount", Weight.MAJOR)
		&"water_off":
			_request("water_off", Weight.PROGRESS)
		&"shortage":
			_disrupt_shortage_name = _disrupt_strain_name(params.get("strain", ""))
			_request_named("shortage", _disrupt_shortage_name, Weight.PROGRESS)


func _disrupt_on_event_ended(kind: StringName) -> void:
	if not _in_session():
		return
	match kind:
		&"headcount":
			_request("headcount_end", Weight.PROGRESS)
		&"water_off":
			_request("water_back", Weight.PROGRESS)
		&"shortage":
			var who := _disrupt_shortage_name if _disrupt_shortage_name != "" else "Stock"
			_disrupt_shortage_name = ""
			_request_named("shortage_end", who, Weight.PROGRESS)


## A strain's display name ("Night Shift"); an unknown id made readable.
func _disrupt_strain_name(strain: Variant) -> String:
	var id := StringName(str(strain))
	if id == &"":
		return "Stock"
	var def: SeedDef = Config.balance.get_seed(id)
	return def.display_name if def != null else String(id).capitalize()


# --- M13 lead: the shift report notices the M12 trouble ----------------------------------------------------------
## Extra verdict lines under the report (after least / noticed / worst), each only when somebody's stat is above zero:
## the worker who burnt the most hostile plants, the one who burnt the most crops, the one bitten most.
const M13_LINES: Dictionary = {
	"verdict_burns": "%s dealt with it. Noted. Not thanked.",
	"verdict_scorched": "%s burnt stock. The fine came out of cash on hand.",
	"verdict_bitten": "%s got bitten. No claim was filed.",
}


func _m13_setup() -> void:
	for k in M13_LINES:
		if not lines.has(k):
			lines[k] = M13_LINES[k]


func get_report_verdicts() -> PackedStringArray:
	var out := _base_report_verdicts()
	var peers := get_report_peers()
	for entry: Array in [[Const.STAT_BURNS, "verdict_burns"], [Const.STAT_SCORCHED, "verdict_scorched"], [Const.STAT_BITTEN, "verdict_bitten"]]:
		var best: int = 0
		var best_amount: int = 0
		for id in peers:
			var amount: int = GameState.get_stat(id, entry[0])
			if amount > best_amount:
				best = id
				best_amount = amount
		if best_amount > 0:
			out.append(line(String(entry[1])) % Net.get_player_name(best))
	out.append_array(_mayhem_report_verdicts(peers))  # M14 mayhem: shot / slips (region below)
	out.append_array(_replay_report_lines())  # M15 replay: which conditions ran (region at the end of the file)
	return out


# --- M14 mayhem: the tank springs a leak, a drive-by ------------------------------------------------------------
# Lines and hooks for the two M14 events (Events emits on every peer; Story owns the copy). _ready() calls
# _mayhem_setup(). The Boss only speaks at his window, so what the whole floor has to know also goes out as a toast
# (the M13 pattern): the leak, who patched it, the empty tank, the drive-by warning, the bill.
#   leak starts                      leak            MAJOR     + toast (error)
#   patched (Events.leak_resolved)   leak_patched    PROGRESS  + toast (info, names the worker)
#   ran out unpatched                leak_empty      MAJOR     + toast (error)
#   the tank fills again             tank_refilled   PROGRESS  + toast (info)
#   a worker slips                   slipped         CHATTER   ("%s" = the worker)
#   drive-by starts                  driveby         MAJOR     + toast (error)
#   a worker is knocked down         driveby_hit     PROGRESS  ("%s" = the worker)
#   the bill                         driveby_bill / _short / _broke   MAJOR + toast (error)

## Copy for the two events, merged into `lines` at start-up. "%s" = a worker's name or an amount in words.
const MAYHEM_LINES: Dictionary = {
	"leak": "The tank is leaking. Somebody hold it shut.",
	"leak_patched": "Patched. It will not hold forever.",
	"leak_empty": "Tank's empty. That one is on the floor.",
	"tank_refilled": "Tank's full. Keep it in there this time.",
	"slipped": "Wet floor, %s.",
	"driveby": "Get down.",
	"driveby_hit": "%s got hit. Still on the clock.",
	"driveby_bill": "Glass and holes: %s. It comes out of cash on hand.",
	"driveby_bill_short": "Glass and holes: %s. You had %s. I took it.",
	"driveby_bill_broke": "Glass and holes: %s. Nothing to take. Noted.",
	"toast_leak": "The tank is leaking. Hold it shut.",
	"toast_leak_patched": "%s patched the tank.",
	"toast_leak_empty": "The tank is empty.",
	"toast_tank_refilled": "The tank has water again.",
	"toast_driveby": "Drive-by. Get down.",
	"toast_driveby_bill": "Drive-by: $%d out of cash on hand.",
	"toast_driveby_bill_broke": "Drive-by: nothing left to take.",
	"verdict_shot": "%s stood in the way. The holes are on the bill.",
	"verdict_slips": "%s kept falling over. The floor was wet. Noted.",
}

const MAYHEM_ONES: PackedStringArray = ["nothing", "one", "two", "three", "four", "five", "six", "seven", "eight", "nine", "ten",
		"eleven", "twelve", "thirteen", "fourteen", "fifteen", "sixteen", "seventeen", "eighteen", "nineteen"]
const MAYHEM_TENS: PackedStringArray = ["", "", "twenty", "thirty", "forty", "fifty", "sixty", "seventy", "eighty", "ninety"]


func _mayhem_setup() -> void:
	for k in MAYHEM_LINES:
		if not lines.has(k):
			lines[k] = MAYHEM_LINES[k]
	var events: Node = get_node_or_null(^"/root/Events")
	if events == null:
		return
	if events.has_signal(&"event_started"):
		events.connect(&"event_started", _mayhem_on_event_started)
	if events.has_signal(&"leak_resolved"):
		events.connect(&"leak_resolved", _mayhem_on_leak_resolved)
	if events.has_signal(&"tank_refilled"):
		events.connect(&"tank_refilled", _mayhem_on_tank_refilled)
	if events.has_signal(&"worker_slipped"):
		events.connect(&"worker_slipped", _mayhem_on_worker_slipped)
	if events.has_signal(&"worker_shot"):
		events.connect(&"worker_shot", _mayhem_on_worker_shot)
	if events.has_signal(&"driveby_billed"):
		events.connect(&"driveby_billed", _mayhem_on_driveby_billed)


func _mayhem_on_event_started(kind: StringName, _params: Dictionary) -> void:
	if not _in_session():
		return
	match kind:
		&"leak":
			Game.toast(line("toast_leak"), &"error")
			_request("leak", Weight.MAJOR)
		&"driveby":
			Game.toast(line("toast_driveby"), &"error")
			_request("driveby", Weight.MAJOR)


func _mayhem_on_leak_resolved(patched: bool, by_peer: int) -> void:
	if not _in_session():
		return
	if patched:
		if by_peer > 0:
			Game.toast(line("toast_leak_patched") % Net.get_player_name(by_peer), &"info")
		_request("leak_patched", Weight.PROGRESS)
	else:
		Game.toast(line("toast_leak_empty"), &"error")
		_request("leak_empty", Weight.MAJOR)


func _mayhem_on_tank_refilled() -> void:
	if not _in_session():
		return
	Game.toast(line("toast_tank_refilled"), &"info")
	_request("tank_refilled", Weight.PROGRESS)


func _mayhem_on_worker_slipped(peer_id: int) -> void:
	if _in_session():
		_request_named("slipped", Net.get_player_name(peer_id), Weight.CHATTER)


func _mayhem_on_worker_shot(peer_id: int) -> void:
	if _in_session():
		_request_named("driveby_hit", Net.get_player_name(peer_id), Weight.PROGRESS)


## Shift report lines (get_report_verdicts appends them, each only when somebody's stat is above zero): the worker
## gunfire knocked down most, the one who slipped most.
func _mayhem_report_verdicts(peers: Array) -> PackedStringArray:
	var out := PackedStringArray()
	for entry: Array in [[Const.STAT_SHOT, "verdict_shot"], [Const.STAT_SLIPS, "verdict_slips"]]:
		var best: int = 0
		var best_amount: int = 0
		for id: int in peers:
			var amount: int = GameState.get_stat(id, entry[0])
			if amount > best_amount:
				best = id
				best_amount = amount
		if best_amount > 0:
			out.append(line(String(entry[1])) % Net.get_player_name(best))
	return out


## The bill after a drive-by: the whole fine, what cash on hand covered of it, or nothing at all.
func _mayhem_on_driveby_billed(fine: int, taken: int) -> void:
	if not _in_session():
		return
	var text := mayhem_bill_line(fine, taken)
	if taken > 0:
		Game.toast(line("toast_driveby_bill") % taken, &"error")
	else:
		Game.toast(line("toast_driveby_bill_broke"), &"error")
	if text != "":
		_show(text, Weight.MAJOR)


## The Boss's line for a bill of `fine` of which `taken` was paid ("" when nothing was owed).
func mayhem_bill_line(fine: int, taken: int) -> String:
	if fine <= 0:
		return ""
	if taken >= fine:
		return line("driveby_bill") % mayhem_amount_words(fine)
	if taken > 0:
		return line("driveby_bill_short") % [mayhem_amount_words(fine), mayhem_amount_words(taken)]
	return line("driveby_bill_broke") % mayhem_amount_words(fine)


## An amount the way the Boss says it: "thirty", "twenty-five"; "$120" from a hundred up.
func mayhem_amount_words(amount: int) -> String:
	if amount < 0 or amount >= 100:
		return "$%d" % amount
	if amount < 20:
		return MAYHEM_ONES[amount]
	@warning_ignore("integer_division")
	var tens: String = MAYHEM_TENS[amount / 10]
	return tens if amount % 10 == 0 else "%s-%s" % [tens, MAYHEM_ONES[amount % 10]]


# --- M15 mayhem2: a raid, the sprinklers, the collector ----------------------------------------------------------
# Lines and hooks for the three M15 events (Events emits on every peer; Story owns the copy). _ready() calls
# _mayhem2_setup(); _on_worker_written_up maps the reason WRITE_UP_RAID to "raid_caught". As in M14, what the whole
# floor has to know also goes out as a toast, because the Boss only speaks at his window.
#   raid starts                       raid                MAJOR     + toast (error)
#   the first look                    (toast only)        "They are looking in."
#   a worker caught holding           raid_caught         MAJOR     ("%s" = the worker; from the write-up)
#   raid over, after at least a look  mayhem2_raid_line() MAJOR / PROGRESS + toast: "They took three. Dale was
#                                     holding one." / "They looked. They found nothing."
#   sprinklers start                  sprinklers          MAJOR     + toast (error)
#   sprinklers stop, the floor wet    sprinklers_end      PROGRESS  + toast (info)
#   the floor dried                   (toast only)        "The floor is dry."
#   collection starts                 collection          MAJOR     + toast (error); the collector says "Forty. Now."
#   paid (Events.collector_paid)      collector_paid      PROGRESS  + toast (info, names the worker)
#   unpaid (Events.collector_took)    collector_took_bundle / _tray / _nothing   MAJOR + toast (error)

## Copy for the three events, merged into `lines` at start-up. "%s" = a worker, a strain, a tray or an amount in
## words; "%d" = dollars.
const MAYHEM2_LINES: Dictionary = {
	"raid": "They are outside. Get it out of sight.",
	"raid_caught": "%s was holding. Written up.",
	"raid_clean": "They looked. They found nothing.",
	"raid_took": "They took %s.",
	"raid_held_one": "%s was holding one.",
	"raid_held_many": "%s were holding.",
	"sprinklers": "Sprinklers. Everything is watered. Do not run.",
	"sprinklers_end": "Sprinklers are off. The floor is still wet.",
	"collection": "He wants %s. He is on the dock.",
	"collector_ask": "%s. Now.",
	"collector_paid": "Paid. He left.",
	"collector_took_bundle": "Not paid. He took the %s.",
	"collector_took_tray": "Not paid. He took the plant in %s.",
	"collector_took_nothing": "Not paid. Nothing to take. He will be back.",
	"toast_raid": "Raid. Get the product out of sight.",
	"toast_raid_look": "They are looking in.",
	"toast_sprinklers": "Sprinklers. Everything is watered. Do not run.",
	"toast_sprinklers_end": "Sprinklers are off. The floor is still wet.",
	"toast_floor_dry": "The floor is dry.",
	"toast_collection": "Collection. He wants $%d. He is on the dock.",
	"toast_collector_paid": "%s paid the collector $%d.",
}

## This peer's count of the running raid: bundles taken, the workers who held one (in the order they were caught),
## and whether anybody looked in yet (a raid cut short during the sirens says nothing at its end).
var _mayhem2_raid_taken: int = 0
var _mayhem2_raid_holders: Array[int] = []
var _mayhem2_raid_looked: bool = false


func _mayhem2_setup() -> void:
	for k in MAYHEM2_LINES:
		if not lines.has(k):
			lines[k] = MAYHEM2_LINES[k]
	var events: Node = get_node_or_null(^"/root/Events")
	if events == null:
		return
	for entry: Array in [[&"event_started", _mayhem2_on_event_started], [&"event_ended", _mayhem2_on_event_ended],
			[&"raid_swept", _mayhem2_on_raid_swept], [&"raid_took", _mayhem2_on_raid_took],
			[&"floor_wet_changed", _mayhem2_on_floor_wet_changed], [&"collector_paid", _mayhem2_on_collector_paid],
			[&"collector_took", _mayhem2_on_collector_took]]:
		if events.has_signal(entry[0]):
			events.connect(entry[0], entry[1])


func _mayhem2_on_event_started(kind: StringName, params: Dictionary) -> void:
	if kind == &"raid":
		_mayhem2_raid_taken = 0
		_mayhem2_raid_holders.clear()
		_mayhem2_raid_looked = false
	if not _in_session():
		return
	match kind:
		&"raid":
			Game.toast(line("toast_raid"), &"error")
			_request("raid", Weight.MAJOR)
		&"sprinklers":
			Game.toast(line("toast_sprinklers"), &"error")
			_request("sprinklers", Weight.MAJOR)
		&"collection":
			var fee_v: Variant = params.get("fee", 0)
			var fee: int = int(fee_v) if fee_v is int or fee_v is float else 0
			Game.toast(line("toast_collection") % fee, &"error")
			_request_named("collection", mayhem_amount_words(fee), Weight.MAJOR)
			var events: Node = get_node_or_null(^"/root/Events")
			var man: Variant = events.call(&"get_collector") if events != null and events.has_method(&"get_collector") else null
			if is_instance_valid(man) and (man as Object).has_method(&"bark"):
				(man as Object).call(&"bark", line("collector_ask") % loop_amount_words(fee), 4.0)


func _mayhem2_on_event_ended(kind: StringName) -> void:
	if not _in_session():
		return
	match kind:
		&"raid":
			if not _mayhem2_raid_looked:
				return
			var names := PackedStringArray()
			for id in _mayhem2_raid_holders:
				names.append(Net.get_player_name(id))
			var text := mayhem2_raid_line(_mayhem2_raid_taken, names)
			Game.toast(text, &"error" if _mayhem2_raid_taken > 0 else &"info")
			_show(text, Weight.MAJOR if _mayhem2_raid_taken > 0 else Weight.PROGRESS)
		&"sprinklers":
			# The shift end stops the water and dries the floor in one go: nothing to say then.
			var events: Node = get_node_or_null(^"/root/Events")
			if GameState.is_playing() and events != null and events.has_method(&"is_floor_wet") and bool(events.call(&"is_floor_wet")):
				Game.toast(line("toast_sprinklers_end"), &"info")
				_request("sprinklers_end", Weight.PROGRESS)


func _mayhem2_on_raid_swept(_point_index: int, _taken: int) -> void:
	var first := not _mayhem2_raid_looked
	_mayhem2_raid_looked = true
	if first and _in_session():
		Game.toast(line("toast_raid_look"), &"error")


func _mayhem2_on_raid_took(_item_name: String, holder_peer: int) -> void:
	_mayhem2_raid_taken += 1
	if holder_peer > 0 and not _mayhem2_raid_holders.has(holder_peer):
		_mayhem2_raid_holders.append(holder_peer)


func _mayhem2_on_floor_wet_changed(wet: bool) -> void:
	if not wet and _in_session() and GameState.is_playing():
		Game.toast(line("toast_floor_dry"), &"info")


func _mayhem2_on_collector_paid(peer_id: int, fee: int) -> void:
	if not _in_session():
		return
	Game.toast(line("toast_collector_paid") % [Net.get_player_name(peer_id), fee], &"info")
	_request("collector_paid", Weight.PROGRESS)


func _mayhem2_on_collector_took(what: StringName, strain: StringName, where: String) -> void:
	if not _in_session():
		return
	var text := mayhem2_collector_line(what, strain, where)
	Game.toast(text, &"error")
	_show(text, Weight.MAJOR)


## What the floor hears when a raid is over: "They took three. Dale was holding one.", "They took two. Dale and Kim
## were holding.", "They took one.", "They looked. They found nothing." (`holders` = the names of the workers caught).
func mayhem2_raid_line(taken: int, holders: PackedStringArray) -> String:
	if taken <= 0:
		return line("raid_clean")
	var text := line("raid_took") % mayhem_amount_words(taken)
	if holders.size() == 1:
		text += " " + line("raid_held_one") % holders[0]
	elif holders.size() > 1:
		var all_but_last := ", ".join(holders.slice(0, holders.size() - 1))
		text += " " + line("raid_held_many") % ("%s and %s" % [all_but_last, holders[holders.size() - 1]])
	return text


## What the floor hears when the collector was not paid: the bundle's strain, the tray ("GrowPlot 3"), or nothing.
func mayhem2_collector_line(what: StringName, strain: StringName, where: String) -> String:
	match what:
		&"bundle":
			return line("collector_took_bundle") % _disrupt_strain_name(strain)
		&"tray":
			var digits := ""
			for ch in where:
				if ch.is_valid_int():
					digits += ch
			return line("collector_took_tray") % (HOSTILE_PLOT_NAME % int(digits) if digits != "" else "a tray")
	return line("collector_took_nothing")
# --- end M15 mayhem2 ---------------------------------------------------------------------------------------------


# --- M17 mayhem3 --- the scale reads light, the phone rings --------------------------------------------------------
# Lines and hooks for the two M17 events (Events emits on every peer; Story owns the copy). _ready() calls
# _mayhem3_setup(). As in M14 and M15, what the whole floor has to know also goes out as a toast.
#   scale starts                     scale             MAJOR     + toast (error): the cut and how to fix it (the key)
#   somebody hit it (scale_fixed)    scale_fixed       PROGRESS  + toast (info, names the worker)
#   it ran out unfixed               scale_back        PROGRESS  + toast (info); nothing at the end of a shift
#   phone starts                     phone             MAJOR     + toast (error)
#   taken, a tip (phone_answered)    mayhem3_tip_line  MAJOR     + toast (info): "Dale took the call. Next: a raid."
#   taken, a favor                   phone_favor       PROGRESS  + toast (info): the discount and how long it runs
#   taken, a wrong number            phone_wrong       PROGRESS  + toast (info)
#   the favor ran out                (toast only)      "Seeds are back to full price."
#   nobody picked up (phone_missed)  mayhem3_missed_line  MAJOR  + toast (error): "He called. Nobody picked up. Thirty."

## Copy for the two events, merged into `lines` at start-up. "%s" = an amount in words, a worker, or what a tip names;
## "%d" = dollars, a percentage or seconds.
const MAYHEM3_LINES: Dictionary = {
	"scale": "The scale reads light. Somebody hit it.",
	"scale_fixed": "Scale reads right. Back to work.",
	"scale_back": "Scale came back by itself. You paid for the wait.",
	"phone": "That's the phone. Pick it up.",
	"phone_tip": "Next: %s.",
	"phone_favor": "A favor. Seeds are cheap. Not for long.",
	"phone_wrong": "Wrong number.",
	"phone_missed": "He called. Nobody picked up. %s.",
	"phone_missed_short": "He called. Nobody picked up. %s. You had %s. I took it.",
	"phone_missed_broke": "He called. Nobody picked up. %s. Nothing to take.",
	"toast_scale": "The scale reads light: deposits pay %d%% less. Hit the chute (%s) or throw something at it.",
	"toast_scale_fixed": "%s hit the scale. It reads right.",
	"toast_scale_fixed_nobody": "The scale took a hit. It reads right.",
	"toast_scale_back": "The scale reads right again.",
	"toast_phone": "The phone is ringing. Somebody pick that up.",
	"toast_phone_taken": "%s took the call. %s",
	"toast_phone_favor": "Seeds %d%% off for %d seconds.",
	"toast_favor_over": "Seeds are back to full price.",
	"toast_phone_missed": "Nobody picked up. $%d out of cash on hand.",
	"toast_phone_missed_broke": "Nobody picked up. Nothing left to take.",
}
## What a tip calls the next event, by kind ("Next: a raid."). An unknown kind is "trouble".
const MAYHEM3_TIP_WORDS: Dictionary = {
	"inspection": "an inspection", "power_cut": "a power cut", "audit": "an audit", "rat": "a rat",
	"headcount": "a head count", "water_off": "no water", "shortage": "a shortage", "leak": "a leak",
	"driveby": "a drive-by", "raid": "a raid", "sprinklers": "the sprinklers", "collection": "a collection",
	"scale": "a bad scale", "phone": "another call",
}

## This peer's view of the running scale event / phone: somebody hit the scale (its end then says nothing more).
var _mayhem3_scale_fixed: bool = false


func _mayhem3_setup() -> void:
	for k in MAYHEM3_LINES:
		if not lines.has(k):
			lines[k] = MAYHEM3_LINES[k]
	var events: Node = get_node_or_null(^"/root/Events")
	if events == null:
		return
	for entry: Array in [[&"event_started", _mayhem3_on_event_started], [&"event_ended", _mayhem3_on_event_ended],
			[&"scale_fixed", _mayhem3_on_scale_fixed], [&"phone_answered", _mayhem3_on_phone_answered],
			[&"phone_missed", _mayhem3_on_phone_missed], [&"phone_discount_changed", _mayhem3_on_discount_changed]]:
		if events.has_signal(entry[0]):
			events.connect(entry[0], entry[1])


func _mayhem3_on_event_started(kind: StringName, params: Dictionary) -> void:
	if kind == &"scale":
		_mayhem3_scale_fixed = false
	if not _in_session():
		return
	match kind:
		&"scale":
			var cut_v: Variant = params.get("cut", Config.balance.scale_cut)
			var cut: float = float(cut_v) if (cut_v is float or cut_v is int) else Config.balance.scale_cut
			Game.toast(line("toast_scale") % [roundi(cut * 100.0), HUD.action_key_text(&"shove", "F")], &"error")
			_request("scale", Weight.MAJOR)
		&"phone":
			Game.toast(line("toast_phone"), &"error")
			_request("phone", Weight.MAJOR)


func _mayhem3_on_event_ended(kind: StringName) -> void:
	# The shift end closes a running event too: nothing to say then.
	if kind != &"scale" or _mayhem3_scale_fixed or not _in_session() or not GameState.is_playing():
		return
	Game.toast(line("toast_scale_back"), &"info")
	_request("scale_back", Weight.PROGRESS)


func _mayhem3_on_scale_fixed(peer_id: int) -> void:
	_mayhem3_scale_fixed = true
	if not _in_session():
		return
	if peer_id > 0:
		Game.toast(line("toast_scale_fixed") % Net.get_player_name(peer_id), &"info")
	else:
		Game.toast(line("toast_scale_fixed_nobody"), &"info")
	_request("scale_fixed", Weight.PROGRESS)


func _mayhem3_on_phone_answered(peer_id: int, outcome: StringName) -> void:
	if not _in_session():
		return
	var who := Net.get_player_name(peer_id)
	match outcome:
		&"tip":
			var events: Node = get_node_or_null(^"/root/Events")
			var kind: StringName = StringName(str(events.call(&"get_phone_tip"))) if events != null and events.has_method(&"get_phone_tip") else &""
			var text := mayhem3_tip_line(kind)
			Game.toast(line("toast_phone_taken") % [who, text], &"info")
			_show(text, Weight.MAJOR)
		&"favor":
			var b: BalanceConfig = Config.balance
			var favor := line("toast_phone_favor") % [roundi(clampf(b.phone_discount, 0.0, 0.95) * 100.0), roundi(maxf(b.phone_discount_sec, 0.0))]
			Game.toast(line("toast_phone_taken") % [who, favor], &"info")
			_request("phone_favor", Weight.PROGRESS)
		_:
			Game.toast(line("toast_phone_taken") % [who, line("phone_wrong")], &"info")
			_request("phone_wrong", Weight.PROGRESS)


func _mayhem3_on_phone_missed(fine: int) -> void:
	if not _in_session():
		return
	var events: Node = get_node_or_null(^"/root/Events")
	var taken: int = int(events.call(&"get_phone_fine_taken")) if events != null and events.has_method(&"get_phone_fine_taken") else 0
	if taken > 0:
		Game.toast(line("toast_phone_missed") % taken, &"error")
	else:
		Game.toast(line("toast_phone_missed_broke"), &"error")
	var text := mayhem3_missed_line(fine, taken)
	if text != "":
		_show(text, Weight.MAJOR)


func _mayhem3_on_discount_changed(factor: float) -> void:
	if factor >= 1.0 and _in_session() and GameState.is_playing():
		Game.toast(line("toast_favor_over"), &"info")


## What the floor hears from a tip: "Next: a raid." (`kind` = the event kind it names).
func mayhem3_tip_line(kind: StringName) -> String:
	return line("phone_tip") % String(MAYHEM3_TIP_WORDS.get(String(kind), "trouble"))


## The Boss's line when nobody picked up: the whole fine in words, what cash on hand covered of it, or nothing
## ("He called. Nobody picked up. Thirty."). "" when nothing was billed.
func mayhem3_missed_line(fine: int, taken: int) -> String:
	if fine <= 0:
		return ""
	var said := loop_amount_words(fine)
	if taken >= fine:
		return line("phone_missed") % said
	if taken > 0:
		return line("phone_missed_short") % [said, mayhem_amount_words(taken)]
	return line("phone_missed_broke") % said
# --- end M17 mayhem3 ---------------------------------------------------------------------------------------------


# --- M14 loop: strain traits and the drying rack -----------------------------------------------------------------
## The fine for a counted plant (Golden Kush) that was eaten, burnt or shot: requested from GrowPlot's every-peer
## cosmetic RPC (_rpc_crop_lost), so each peer shows its own copy without a Story RPC. MAJOR: cash left the floor, and
## the line must not be swept out of the one-slot queue by "GrowPlot 2 is gone." / "GrowPlot 2 burnt." beside it.
##   counted_fine    "He counted those. Twenty-five."   ("%s" = the fine in words)
##   counted_broke   "He counted those. Nothing left to take."   (the cash on hand was already zero)

const LOOP_LINES: Dictionary = {
	"counted_fine": "He counted those. %s.",
	"counted_broke": "He counted those. Nothing left to take.",
}
## The supply cards' one-liners now say what each strain's trait does (number-free like the rest; they replace the
## M12 entries of `blurbs` when Story is built). Budget Bud has no trait and keeps its line.
const LOOP_BLURBS: Dictionary = {
	"purple": "Slower. Pays better. Drinks more than the rest.",
	"golden": "Slow. Bigger yield. Lose one and it costs.",
	"nightshift": "Pays the best. Grows in the dark. Some walk.",
	"creeper": "Cheap. Quick. Some leave a seedling. Some walk.",
	"brick": "Slow. Heavy yield. Slow to carry. Some walk off.",
}
const LOOP_ONES: PackedStringArray = ["zero", "one", "two", "three", "four", "five", "six", "seven", "eight", "nine", "ten",
		"eleven", "twelve", "thirteen", "fourteen", "fifteen", "sixteen", "seventeen", "eighteen", "nineteen"]
const LOOP_TENS: PackedStringArray = ["", "", "twenty", "thirty", "forty", "fifty", "sixty", "seventy", "eighty", "ninety"]
var _loop_lines_installed: bool = _install_loop_lines()


func _install_loop_lines() -> bool:
	for key in LOOP_LINES:
		if not lines.has(key):
			lines[key] = LOOP_LINES[key]
	for id in LOOP_BLURBS:
		blurbs[id] = LOOP_BLURBS[id]
	return true


## Every peer, from GrowPlot._rpc_crop_lost: the Boss names the fine (`fine` = what was actually taken).
func loop_counted_fine(fine: int) -> void:
	if not _in_session():
		return
	if fine > 0:
		_request_named("counted_fine", loop_amount_words(fine), Weight.MAJOR)
	else:
		_request("counted_broke", Weight.MAJOR)


## A dollar amount the way the Boss says it: "Twenty-five" for 25. Outside 0..99 it is the plain figure ("$140").
func loop_amount_words(amount: int) -> String:
	if amount < 0 or amount > 99:
		return "$%d" % amount
	var words: String
	if amount < 20:
		words = LOOP_ONES[amount]
	else:
		words = LOOP_TENS[int(floor(amount / 10.0))]
		if amount % 10 != 0:
			words += "-" + LOOP_ONES[amount % 10]
	return words.substr(0, 1).to_upper() + words.substr(1)


# --- M15 replay: shift conditions ----------------------------------------------------------------------------------
# What the Boss has to say about a shift that is not like the others (replay agent, CONTRACTS "M15", "Replay").
# GameState syncs the conditions, so every peer derives the same lines without a Story RPC.
#   shift starts with conditions     cond_<id>  PROGRESS: ONE line, for the first condition only. It waits in the
#                                    one-slot queue behind "Shift's on." and is said six seconds later, or dropped
#                                    when something heavier comes first. The HUD toasts every condition's flat line.
#   the shift report                 report_conditions: "Conditions: Dry air, Short clock." as the last line under
#                                    the table (the conditions of the last shift that started), so a missed payment
#                                    has a reason on the page. No line when none ran.

## "%s" in cond_buyer = the strain's name; in report_conditions = the chip titles, comma separated.
const REPLAY_LINES: Dictionary = {
	"cond_dry_air": "Air's dry. Water them more.",
	"cond_twitchy": "This batch twitches. Watch the ready ones.",
	"cond_buyer": "Somebody wants %s. Grow it.",
	"cond_clearance": "Seeds are cheap today. Don't get used to it.",
	"cond_inspection_week": "Inspection week. I'll be out there. Often.",
	"cond_bad_wiring": "The wiring's bad. Learn where the breaker is.",
	"cond_short_clock": "Short shift. Smaller number. Same door.",
	"cond_overtime": "You're staying late. The number went up with it.",
	"cond_slick_floor": "Floor's wet. Walk.",
	"cond_thin_walls": "They can hear you through these walls. Stay low.",
	"cond_heat_wave": "It's hot. They grow fast and they drink.",
	"cond_quiet_night": "Quiet tonight. Prices are down. Make it up in bulk.",
	"cond_cured_order": "The order wants it cured. Use the racks.",
	"report_conditions": "Conditions: %s.",
}


func _replay_setup() -> void:
	for k in REPLAY_LINES:
		if not lines.has(k):
			lines[k] = REPLAY_LINES[k]
	if GameState.has_signal(&"conditions_changed"):
		GameState.round_started.connect(_replay_on_round_started)


## Every peer, after the shift_start line: the Boss names the first condition (see the region header).
func _replay_on_round_started(_round_number: int) -> void:
	if not _in_session():
		return
	var ids: Array[StringName] = GameState.get_conditions()
	if ids.is_empty():
		return
	var key := "cond_%s" % ShiftConditions.base_of(ids[0])
	var strain := ShiftConditions.param_of(ids[0])
	if strain != &"":
		_request_named(key, _disrupt_strain_name(strain), Weight.PROGRESS)
	else:
		_request(key, Weight.PROGRESS)


## The shift report's last line: the conditions that ran ("Conditions: Dry air, Short clock."); none, no line.
func _replay_report_lines() -> PackedStringArray:
	var out := PackedStringArray()
	var titles := PackedStringArray()
	for id in GameState.get_report_conditions():
		titles.append(ShiftConditions.get_title(id))
	if not titles.is_empty():
		out.append(line("report_conditions") % ", ".join(titles))
	return out


# --- M15 career: the shift's job ---------------------------------------------------------------------------------
# GameState tells every peer what happens to the job (contract_offered / contract_met / contract_failed); Story owns
# the copy. _ready() calls _career_setup(). What the whole floor has to know goes out as a toast (the Boss only speaks
# at his window):
#   a job is put up                  toast_job (info)           + job_offered, PROGRESS, a little after the shift's
#                                                                 opening line (it must not be swept away by it)
#   swapped (its event never came)   toast_job_swapped (info)   + job_swapped, PROGRESS
#   met                              toast_job_done (success)   + job_done, MAJOR ("%s" = the reward in words); a job
#                                                                 judged at the end of the shift gets the toast only:
#                                                                 the Boss is busy with "paid", the report has the line
#   failed                           toast_job_failed (error)

## Copy for the job, merged into `lines` at start-up. Toasts: "%s" = the job's text, then the reward as "$60".
const CAREER_LINES: Dictionary = {
	"job_offered": "There's a job on top of the payment. It's posted.",
	"job_swapped": "That job's off. There's another.",
	"job_done": "That was the job. %s.",
	"toast_job": "Job: %s. %s.",
	"toast_job_swapped": "Job changed: %s. %s.",
	"toast_job_done": "Job done: %s. %s to cash on hand.",
	"toast_job_failed": "Job failed: %s.",
}
## The Boss names the job this long after it could first be said (the shift's opening line is MAJOR and comes first).
const CAREER_OFFER_DELAY_SEC: float = MIN_BARK_GAP_SEC + 0.5

var _career_offer_queued: bool = false


func _career_setup() -> void:
	for k in CAREER_LINES:
		if not lines.has(k):
			lines[k] = CAREER_LINES[k]
	if GameState.has_signal(&"contract_offered"):
		GameState.connect(&"contract_offered", _career_on_offered)
	if GameState.has_signal(&"contract_met"):
		GameState.connect(&"contract_met", _career_on_met)
	if GameState.has_signal(&"contract_failed"):
		GameState.connect(&"contract_failed", _career_on_failed)
	GameState.round_started.connect(_career_on_round_started)


func _career_on_offered(contract: Dictionary, swapped: bool) -> void:
	if not _in_session():
		return
	var text := String(contract.get("text", ""))
	var reward := format_money(int(contract.get("reward", 0)))
	if swapped:
		Game.toast(line("toast_job_swapped") % [text, reward], &"info")
		_request("job_swapped", Weight.PROGRESS)
		return
	Game.toast(line("toast_job") % [text, reward], &"info")
	if GameState.is_playing():
		_career_queue_offer_line()


## A job put up in the alley is named by the Boss once the shift runs.
func _career_on_round_started(_round_number: int) -> void:
	var gs: Node = GameState
	if gs.has_method(&"get_contract") and _career_is_open(gs.call(&"get_contract")):
		_career_queue_offer_line()


func _career_queue_offer_line() -> void:
	if _career_offer_queued or not is_inside_tree():
		return
	_career_offer_queued = true
	get_tree().create_timer(CAREER_OFFER_DELAY_SEC).timeout.connect(_career_say_offer.bind(GameState.round_number))


func _career_say_offer(round_number: int) -> void:
	_career_offer_queued = false
	var gs: Node = GameState
	if not _in_session() or not GameState.is_playing() or GameState.round_number != round_number:
		return
	if gs.has_method(&"get_contract") and _career_is_open(gs.call(&"get_contract")):
		_request("job_offered", Weight.PROGRESS)


static func _career_is_open(contract: Dictionary) -> bool:
	return not contract.is_empty() and not bool(contract.get("done", false)) and not bool(contract.get("failed", false))


func _career_on_met(contract: Dictionary) -> void:
	if not _in_session():
		return
	var reward := int(contract.get("reward", 0))
	Game.toast(line("toast_job_done") % [String(contract.get("text", "")), format_money(reward)], &"success")
	if Contracts.get_judge(StringName(str(contract.get("id", "")))) != Contracts.JUDGE_END:
		_request_named("job_done", loop_amount_words(reward), Weight.MAJOR)


func _career_on_failed(contract: Dictionary) -> void:
	if _in_session():
		Game.toast(line("toast_job_failed") % String(contract.get("text", "")), &"error")

# --- end M15 career ----------------------------------------------------------------------------------------------


# --- M17 finale: the final notice ----------------------------------------------------------------------------------
# The run's last shift (GameState's "M17 finale" region; CONTRACTS "M17", "Finale"). GameState syncs it, so every peer
# derives the same lines without a Story RPC. _ready() calls _finale_setup().
#   the final notice starts          toast_final (info)                 "Final notice. Pay it and the debt is cleared."
#   half time, under the share       toast_final_raised (error)         "Payment due up $132."
#                                    + final_short, MAJOR               "Half the clock. Not half the money."
#   half time, on schedule           final_on_schedule, MAJOR           "On schedule. Keep it there." (nothing else)
#   paid: the run is cleared         final_cleared, MAJOR, said instead of "paid" (there is no next number);
#                                    the debt board reads board_cleared ("PAID IN FULL") on the end screen

const FINALE_LINES: Dictionary = {
	"final_short": "Half the clock. Not half the money.",
	"final_on_schedule": "On schedule. Keep it there.",
	"final_cleared": "That's all of it. I'll think of something.",
	"toast_final": "Final notice. Pay it and the debt is cleared.",
	"toast_final_raised": "Payment due up %s.",
	"board_cleared": "PAID IN FULL",
}


func _finale_setup() -> void:
	for k in FINALE_LINES:
		if not lines.has(k):
			lines[k] = FINALE_LINES[k]
	if GameState.has_signal(&"final_look"):
		GameState.connect(&"final_look", _finale_on_look)
	GameState.round_started.connect(_finale_on_round_started)


## Every peer, when a shift starts: the final notice is announced on the floor (the HUD's title says it too).
func _finale_on_round_started(_round_number: int) -> void:
	if _in_session() and GameState.is_final_shift():
		Game.toast(line("toast_final"), &"info")


## Every peer: the host looked at the payment at half time of the final notice (GameState.final_look).
func _finale_on_look(short: bool, raised: int) -> void:
	if not _in_session():
		return
	if short:
		if raised > 0:
			Game.toast(line("toast_final_raised") % format_money(raised), &"error")
		_request("final_short", Weight.MAJOR)
	else:
		_request("final_on_schedule", Weight.MAJOR)

# --- end M17 finale ------------------------------------------------------------------------------------------------
