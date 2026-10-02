extends Node
## Career (autoload, M15, owner: career agent). Each player's own record, kept in a local file and never synced: shifts
## worked, best shift reached, total deposited, jobs done, plants burnt, times bitten / shot / sent to the back room,
## bundles deposited per strain. It is what makes a second session worth starting (FRIENDSLOP.md section 9.3,
## CONTRACTS.md "M15 / Career"). Do NOT add a class_name (it is an autoload).
##
## The file: `user://career.cfg`, or the path given with `--career-file=<path>` (tests always pass one: a temp file).
## WITHOUT --career-file, a run under --headless or one started with `-s <script>` (the suites, the capture and
## preview tools) reads nothing and writes nothing: the record lives in memory only, so no tool ever sees or touches
## a player's real record. The format is a plain INI (a ConfigFile reads it too):
##     [career]
##     shifts=12
##     best_round=4
##     ...
##     [strains]
##     purple=14
## read by a small tolerant parser of our own: a missing, empty, oversized or corrupt file is an empty record and
## never an error line (ConfigFile.load prints one for a parse error). Written through a temp file and a rename.
##
## What is counted, all from THIS peer's own row of the shift ledger:
##   at the end of every shift this peer was in (GameState.round_ended):
##     shifts +1; best_round = the highest shift finished with the payment made; deposited, burns, bitten, shot from
##     GameState.get_stat(me, STAT_*); backroom = times this peer was sent to the back room this shift; the bundles
##     this peer deposited per strain (GameState.deposit_noted)
##   when the floor's job is met while this peer is present (GameState.contract_met): contracts +1, saved at once
## A shift this peer leaves before it ends counts for nothing.
##
## The job title follows best_round (TITLES). It is the one thing that is sent: with replay on, this autoload hands it
## to Net (Net.send_title) once the peer is registered and whenever it changes, and the host passes the whole list to
## a late joiner (Net.server_send_titles).
##
## M16 hats: the record also issues hats (scripts/core/hats.gd). The one this player wears is kept in the file as
## `hat=<id>` under [career] and is the second thing that is sent (Net.send_hat): see the "M16 hats" region.

## Emitted after any record changed (the end of a shift, a job done, a reload).
signal changed

const DEFAULT_PATH := "user://career.cfg"
const SECTION_CAREER := "career"
const SECTION_STRAINS := "strains"
const KEY_SHIFTS := "shifts"
const KEY_BEST_ROUND := "best_round"
const KEY_DEPOSITED := "deposited"
const KEY_CONTRACTS := "contracts"
const KEY_BURNS := "burns"
const KEY_BITTEN := "bitten"
const KEY_SHOT := "shot"
const KEY_BACKROOM := "backroom"
const KEY_CLEARED := "cleared"  # M17 finale: runs cleared (the final notice paid while this peer was on the floor)
const KEYS: PackedStringArray = [KEY_SHIFTS, KEY_BEST_ROUND, KEY_DEPOSITED, KEY_CONTRACTS, KEY_BURNS, KEY_BITTEN, KEY_SHOT, KEY_BACKROOM, KEY_CLEARED]  # M17 finale: + cleared
## A file larger than this is not a career file.
const MAX_FILE_BYTES: int = 16384
## No record is allowed to grow past this (a damaged or edited file cannot overflow anything).
const MAX_VALUE: int = 999999999
## Strain rows kept at most (the game has six strains).
const MAX_STRAINS: int = 32

## The ladder: [best shift reached at least, title]. Flat job titles, in order.
const TITLES: Array = [
	[0, "New hire"],
	[1, "Floor hand"],
	[2, "Tray hand"],
	[3, "Lead hand"],
	[4, "Shift lead"],
	[6, "The Boss's problem"],
]

const TEXT_SHIFTS := "Shifts worked: %d"
const TEXT_BEST := "Best shift: %d"
const TEXT_DEPOSITED := "Deposited: %s"
const TEXT_CONTRACTS := "Jobs done: %d"
const TEXT_BURNS := "Plants burnt: %d"
const TEXT_TROUBLE := "Bitten: %d. Shot: %d. Back room: %d."

## The file this peer's record lives in.
var path: String = DEFAULT_PATH
## False under --headless or `-s <script>` without --career-file: nothing is read or written.
var persistent: bool = false

var _record: Dictionary = {}
## strain id (String) -> bundles deposited.
var _strains: Dictionary = {}
## This shift, not yet in the record: strain id -> bundles this peer deposited.
var _shift_strains: Dictionary = {}
## This shift: times this peer went into the back room.
var _shift_backroom: int = 0
var _in_backroom: bool = false
## The title last handed to Net in this session ("" = none yet).
var _sent_title: String = ""


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	var given: Variant = Config.get_arg("career-file", null)
	if given is String and String(given).strip_edges() != "":
		path = String(given).strip_edges()
		persistent = true
	else:
		persistent = DisplayServer.get_name() != "headless" and not _is_scripted_run()
	if persistent:
		load_file(path)
	GameState.round_started.connect(_on_round_started)
	GameState.round_ended.connect(_on_round_ended)
	GameState.phase_changed.connect(_on_phase_changed)
	GameState.game_reset.connect(_clear_shift)
	GameState.backroom_changed.connect(_on_backroom_changed)
	GameState.contract_met.connect(_on_contract_met)
	GameState.deposit_noted.connect(_on_deposit_noted)
	Net.players_changed.connect(_sync_title)
	Net.titles_changed.connect(_sync_title)
	Net.peer_registered.connect(_on_peer_registered)
	changed.connect(_sync_title)
	_hats_ready() # M16 hats
	_finale_ready() # M17 finale: a cleared run counts, and may issue the eyeshade


# ---------------------------------------------------------------------------------------------
# Public API
# ---------------------------------------------------------------------------------------------

## One record by key ("shifts", "best_round", "deposited", "contracts", "burns", "bitten", "shot", "backroom", or a
## strain id for the bundles of that strain this player deposited). 0 when unknown.
func get_record(key: String) -> int:
	if _record.has(key):
		return int(_record[key])
	return int(_strains.get(key, 0))


## A few flat lines for the alley board and the pause menu's Record card. Empty before the first shift.
func get_summary_lines() -> Array[String]:
	var out: Array[String] = []
	if get_record(KEY_SHIFTS) <= 0:
		return out
	out.append(TEXT_SHIFTS % get_record(KEY_SHIFTS))
	out.append(TEXT_BEST % get_record(KEY_BEST_ROUND))
	out.append(TEXT_DEPOSITED % Contracts.format_money(get_record(KEY_DEPOSITED)))
	out.append(TEXT_CONTRACTS % get_record(KEY_CONTRACTS))
	out.append(TEXT_BURNS % get_record(KEY_BURNS))
	out.append(TEXT_TROUBLE % [get_record(KEY_BITTEN), get_record(KEY_SHOT), get_record(KEY_BACKROOM)])
	if get_record(KEY_CLEARED) > 0: out.append(TEXT_CLEARED % get_record(KEY_CLEARED))  # M17 finale: only once there is one
	return out


## A flat job title that follows the best shift reached ("New hire", "Floor hand", ...).
func get_title() -> String:
	return title_for(get_record(KEY_BEST_ROUND))


## The title for a best shift of `best_round`.
static func title_for(best_round: int) -> String:
	var out := String(TITLES[0][1])
	for rung: Array in TITLES:
		if best_round >= int(rung[0]):
			out = String(rung[1])
	return out


## Every title of the ladder, lowest first.
static func get_titles() -> PackedStringArray:
	var out := PackedStringArray()
	for rung: Array in TITLES:
		out.append(String(rung[1]))
	return out


## True for a string of the ladder (what the host accepts as a title, and what a peer shows).
static func is_known_title(text: String) -> bool:
	for rung: Array in TITLES:
		if String(rung[1]) == text:
			return true
	return false


## Bundles deposited per strain: strain id (String) -> count. A copy.
func get_strain_deposits() -> Dictionary:
	return _strains.duplicate()


## Reads `file_path` into the record, replacing what was there. A missing, empty, oversized or corrupt file gives an
## empty record. Returns true when a file was read. Never logs an error. Emits `changed`.
func load_file(file_path: String) -> bool:
	_record = {}
	_strains = {}
	_hat = &"" # M16 hats
	var text := _read_text(file_path)
	var read := text != ""
	if read:
		_parse(text)
	_hats_after_load() # M16 hats
	changed.emit()
	return read


## Writes the record to `file_path` (through "<file>.tmp" and a rename). False when the file could not be written.
func save_file(file_path: String) -> bool:
	var tmp := file_path + ".tmp"
	var f := FileAccess.open(tmp, FileAccess.WRITE)
	if f == null:
		push_warning("Career: could not write %s (%s)" % [tmp, error_string(FileAccess.get_open_error())])
		return false
	f.store_string(_serialize())
	f.close()
	if DirAccess.rename_absolute(tmp, file_path) != OK:
		# The rename did not go through (a locked file): write in place and drop the temp file.
		var direct := FileAccess.open(file_path, FileAccess.WRITE)
		if direct == null:
			push_warning("Career: could not write %s" % file_path)
			return false
		direct.store_string(_serialize())
		direct.close()
		DirAccess.remove_absolute(tmp)
	return true


## True when the engine was started with a main-loop script (`-s` / `--script`): a test body or a tool, not the game.
static func _is_scripted_run() -> bool:
	for arg in OS.get_cmdline_args():
		if arg == "-s" or arg == "--script":
			return true
	return false


## Writes the record to its file when this run keeps one (see `persistent`).
func save() -> bool:
	if not persistent:
		return false
	return save_file(path)


## Tests: an empty record in memory (the file is not touched).
func clear_record() -> void:
	_record = {}
	_strains = {}
	_hat = &"" # M16 hats
	_clear_shift()
	changed.emit()


# ---------------------------------------------------------------------------------------------
# What is counted
# ---------------------------------------------------------------------------------------------

func _on_round_started(_round_number: int) -> void:
	_clear_shift()
	# A worker already in the back room when the count starts was sent there before this shift: not counted again.
	_in_backroom = GameState.is_in_backroom(_local_id())


func _on_round_ended(success: bool, round_number: int) -> void:
	var me := _local_id()
	if me <= 0 or not Net.players.has(me):
		return
	var hats_before := get_issued_hats() # M16 hats
	_add(KEY_SHIFTS, 1)
	if success and round_number > get_record(KEY_BEST_ROUND):
		_record[KEY_BEST_ROUND] = mini(round_number, MAX_VALUE)
	_add(KEY_DEPOSITED, GameState.get_stat(me, Const.STAT_DEPOSITED))
	_add(KEY_BURNS, GameState.get_stat(me, Const.STAT_BURNS))
	_add(KEY_BITTEN, GameState.get_stat(me, Const.STAT_BITTEN))
	_add(KEY_SHOT, GameState.get_stat(me, Const.STAT_SHOT))
	_add(KEY_BACKROOM, _shift_backroom)
	for strain: Variant in _shift_strains:
		_add_strain(String(strain), int(_shift_strains[strain]))
	_clear_shift()
	save()
	changed.emit()
	_hats_issue_new(hats_before) # M16 hats


func _on_phase_changed(new_phase: int) -> void:
	if new_phase == GameState.Phase.MENU:
		_clear_shift()
		_sent_title = ""
		_hats_session_over() # M16 hats


func _on_backroom_changed(peer_id: int, active: bool) -> void:
	if peer_id != _local_id():
		return
	# Counted on the way in only (a full resync repeats the signal for a worker who is already inside).
	if active and not _in_backroom and GameState.is_playing():
		_shift_backroom += 1
	_in_backroom = active


## The floor's job was met while this peer is in the session: it counts for everyone present.
func _on_contract_met(_contract: Dictionary) -> void:
	if not Net.players.has(_local_id()):
		return
	_add(KEY_CONTRACTS, 1)
	save()
	changed.emit()


func _on_deposit_noted(strain: StringName, _amount: int, _cured: bool, _value: int, seller_peer: int) -> void:
	if seller_peer != _local_id() or String(strain) == "":
		return
	_shift_strains[String(strain)] = int(_shift_strains.get(String(strain), 0)) + 1


func _clear_shift() -> void:
	_shift_strains = {}
	_shift_backroom = 0
	_in_backroom = false


func _add(key: String, amount: int) -> void:
	if amount <= 0:
		return
	_record[key] = mini(int(_record.get(key, 0)) + amount, MAX_VALUE)


func _add_strain(strain: String, amount: int) -> void:
	if amount <= 0 or not _is_key(strain) or KEYS.has(strain):
		return
	if not _strains.has(strain) and _strains.size() >= MAX_STRAINS:
		return
	_strains[strain] = mini(int(_strains.get(strain, 0)) + amount, MAX_VALUE)


func _local_id() -> int:
	if not multiplayer.has_multiplayer_peer():
		return 0
	return multiplayer.get_unique_id()


# ---------------------------------------------------------------------------------------------
# The title on the wire
# ---------------------------------------------------------------------------------------------

## Hands this peer's title to the host once it is registered, and again when it changes (replay on only).
func _sync_title() -> void:
	var me := _local_id()
	if not Net.is_online() or not Net.players.has(me):
		_sent_title = "" # between sessions: the next host has heard nothing yet
		return
	if not Config.replay_enabled:
		return
	var title := get_title()
	if title == _sent_title or Net.get_player_title(me) == title:
		_sent_title = title
		return
	_sent_title = title
	Net.send_title(title)


## HOST: a late joiner gets everyone's title.
func _on_peer_registered(peer_id: int) -> void:
	if Net.is_host:
		Net.server_send_titles(peer_id)
		Net.server_send_hats(peer_id) # M16 hats


# --- M16 hats ---------------------------------------------------------------------------------------------------------
# Issued kit (CONTRACTS "M16 / Hats", scripts/core/hats.gd). The record issues hats (Hats.issued_for(self)); the one
# this player wears is kept in the file as `hat=<id>` under [career] (no line = none; an unknown id, or one this
# record has not issued, reads as none) and is the second thing that is sent: with replay on this autoload hands it
# to Net (Net.send_hat) once the peer is registered and whenever it changes, and the host passes the whole list to a
# late joiner (Net.server_send_hats, from _on_peer_registered). The host takes at most Net.MAX_HAT_CHANGES changes
# from a peer in a session, so this side counts what it sent and refuses a change the host would drop: the hat a
# player wears here is always the one the others see.

## Emitted when the end of a shift issued a hat this record did not have before (once per hat, after `changed`).
signal hat_issued(id: StringName)

const KEY_HAT := "hat"

## The hat this player chose (&"" = none). Only ever an issued one.
var _hat: StringName = &""
## What the host has been told this session ("" = none: where every session starts).
var _sent_hat: String = ""
## Changes sent to the host this session.
var _hat_sends: int = 0


## The hats this record has issued, in catalog order.
func get_issued_hats() -> Array[StringName]:
	return Hats.issued_for(self)


## The hat this player wears (&"" = none: the worker as issued on day one).
func get_hat() -> StringName:
	return _hat


## Puts a hat on (an issued one) or takes it off (&""). False, and nothing changes, for a hat this record has not
## issued or, in a session, once the host would take no more changes. Saved at once.
func set_hat(id: StringName) -> bool:
	if id != &"" and not get_issued_hats().has(id):
		return false
	if id == _hat:
		return true
	if not can_change_hat():
		return false
	_hat = id
	save()
	changed.emit()
	return true


## Changes the host will still take from this peer in this session (the full budget while offline or with replay off:
## nothing is sent then).
func get_hat_changes_left() -> int:
	if not _hats_on_the_wire():
		return Net.MAX_HAT_CHANGES
	return maxi(Net.MAX_HAT_CHANGES - _hat_sends, 0)


## False once this session's changes are used up (the locker says so).
func can_change_hat() -> bool:
	return get_hat_changes_left() > 0


func _hats_ready() -> void:
	Net.players_changed.connect(_sync_hat)
	Net.hats_changed.connect(_sync_hat)
	changed.connect(_sync_hat)


## True while a change of hat is something the host hears about: replay on, online, registered. Never for a second
## reader of a file (a Career object outside the tree: it has no peer id).
func _hats_on_the_wire() -> bool:
	return is_inside_tree() and Config.replay_enabled and Net.is_online() and Net.players.has(_local_id())


## A hat on file that this record has not issued (an edited file, a catalog that changed) reads as none.
func _hats_after_load() -> void:
	if _hat != &"" and not get_issued_hats().has(_hat):
		_hat = &""


## What the end of a shift added to the issued list: the signal for each, and with replay on the toast.
func _hats_issue_new(before: Array[StringName]) -> void:
	for id: StringName in get_issued_hats():
		if before.has(id):
			continue
		hat_issued.emit(id)
		if Config.replay_enabled:
			Game.toast(Hats.issued_text(id), &"info")


## Hands this peer's hat to the host once it is registered, and again when it changes (replay on only).
func _sync_hat() -> void:
	if not Net.is_online() or not Net.players.has(_local_id()):
		_hats_session_over() # between sessions: the next host has heard nothing yet
		return
	if not Config.replay_enabled:
		return
	var id := String(_hat)
	if id == _sent_hat or _hat_sends >= Net.MAX_HAT_CHANGES:
		return
	_sent_hat = id
	_hat_sends += 1
	Net.send_hat(_hat)


func _hats_session_over() -> void:
	_sent_hat = ""
	_hat_sends = 0


## The file's line for the chosen hat ("" for none: an older reader skips the line either way).
func _hats_file_line() -> String:
	return "%s=%s\n" % [KEY_HAT, String(_hat)] if _hat != &"" else ""

# --- end M16 hats -----------------------------------------------------------------------------------------------------


# --- M17 finale -------------------------------------------------------------------------------------------------------
# A run has an end (CONTRACTS "M17 / Finale"). `cleared` (KEY_CLEARED, one of KEYS: written as `cleared=<n>` under
# [career], an M16 file without it reads as 0) counts the runs this player was on the floor for when the final notice
# was paid: GameState.run_cleared fires on every peer present at that moment (not on a late joiner who arrives on the
# end screen), before round_ended, so the clear is counted, saved, and the hat it issues (Hats: the green eyeshade at
# one) is announced first; the end of the shift then counts the shift itself as usual. The summary gets one more line,
# "Debts cleared: 1", only once there is one.

const TEXT_CLEARED := "Debts cleared: %d"


func _finale_ready() -> void:
	if GameState.has_signal(&"run_cleared"):
		GameState.connect(&"run_cleared", _finale_on_run_cleared)


## Every peer present when the final notice is paid: one more debt cleared on this player's record.
func _finale_on_run_cleared() -> void:
	if not Net.players.has(_local_id()):
		return
	var hats_before := get_issued_hats()
	_add(KEY_CLEARED, 1)
	save()
	changed.emit()
	_hats_issue_new(hats_before)

# --- end M17 finale ---------------------------------------------------------------------------------------------------


# ---------------------------------------------------------------------------------------------
# The file
# ---------------------------------------------------------------------------------------------

## The file as plain printable ASCII ("" when it is missing, empty, too large or unreadable). Read as bytes: a text
## read of a file that is not UTF-8 logs an error per bad sequence.
static func _read_text(file_path: String) -> String:
	if file_path == "" or not FileAccess.file_exists(file_path):
		return ""
	var f := FileAccess.open(file_path, FileAccess.READ)
	if f == null:
		return ""
	var length := f.get_length()
	if length <= 0 or length > MAX_FILE_BYTES:
		f.close()
		return ""
	var bytes := f.get_buffer(length)
	f.close()
	var chars := PackedStringArray()
	var line := ""
	for b: int in bytes:
		if b == 10:
			chars.append(line)
			line = ""
		elif b >= 32 and b < 127:
			line += String.chr(b)
	chars.append(line)
	return "\n".join(chars)


## Takes what looks like the format and ignores the rest: "[section]" lines and "key=integer" lines.
func _parse(text: String) -> void:
	var section := ""
	for raw_line: String in text.split("\n"):
		var line := raw_line.strip_edges()
		if line == "" or line.begins_with(";") or line.begins_with("#"):
			continue
		if line.begins_with("[") and line.ends_with("]"):
			section = line.substr(1, line.length() - 2).strip_edges()
			continue
		var eq := line.find("=")
		if eq <= 0:
			continue
		var key := line.substr(0, eq).strip_edges()
		var value_text := line.substr(eq + 1).strip_edges()
		if section == SECTION_CAREER and key == KEY_HAT: # M16 hats: the one line that is not a count
			_hat = StringName(value_text) if Hats.is_wire_id(value_text) else &"" # M16 hats
			continue # M16 hats
		if not _is_key(key) or not _is_count(value_text):
			continue
		var value := clampi(value_text.to_int(), 0, MAX_VALUE)
		if section == SECTION_CAREER and KEYS.has(key):
			_record[key] = value
		elif section == SECTION_STRAINS and not KEYS.has(key) and value > 0 and _strains.size() < MAX_STRAINS:
			_strains[key] = value


func _serialize() -> String:
	var out := "[%s]\n" % SECTION_CAREER
	for key in KEYS:
		out += "%s=%d\n" % [key, get_record(key)]
	out += _hats_file_line() # M16 hats
	out += "\n[%s]\n" % SECTION_STRAINS
	var ids := _strains.keys()
	ids.sort()
	for id: Variant in ids:
		out += "%s=%d\n" % [String(id), int(_strains[id])]
	return out


## A value the file may hold: 1..10 digits, no sign (String.to_int logs an error for a number that overflows).
static func _is_count(text: String) -> bool:
	if text.length() == 0 or text.length() > 10:
		return false
	for i in text.length():
		var c := text.unicode_at(i)
		if c < 48 or c > 57:
			return false
	return true


## A key the file may hold: 1..24 of a-z, 0-9 and "_".
static func _is_key(text: String) -> bool:
	if text.length() == 0 or text.length() > 24:
		return false
	for i in text.length():
		var c := text.unicode_at(i)
		if not ((c >= 97 and c <= 122) or (c >= 48 and c <= 57) or c == 95):
			return false
	return true
