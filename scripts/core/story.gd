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
