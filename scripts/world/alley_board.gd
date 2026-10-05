class_name AlleyBoard
extends Node3D
## The notice board on the alley wall (M15 alley agent; `Lobby/ReportBoard` in scenes/world/lobby.tscn). FRIENDSLOP
## 9.4, CONTRACTS "The alley": the alley is the room between runs, where the last shift is read and the next one is
## planned. Three columns of Label3D lines on a dark board (`Panel`, a sign_board with no text of its own):
##
##   LAST SHIFT    the last shift as the HOST recorded it when it ended, the same on every peer:
##                 "Shift 3. Paid." / "Shift 3. Missed.", "Deposited $420.", "Due $400.", then the first MAX_VERDICTS
##                 lines of Story.get_report_verdicts() as they stood at that moment. Before the first shift:
##                 "No shift worked yet." A START OVER keeps it (the shift that was missed is what is read).
##   NEXT          "Shift 4 is next.", "Payment due $520." (GameState.round_number / quota while the game waits), then
##                 the lines of GameState.get_shift_briefing() when that method exists (the replay agent's:
##                 conditions, the market, new strains), the job, and last the run's code, "Run 7K2M." (M16
##                 variety; nothing when there is no code). Built on every peer from synced state.
##   YOUR RECORD   this player's own Career.get_title() and Career.get_summary_lines(), read through has_method
##                 guards. LOCAL: every player sees their own. "Nothing on file." while there is none.
##
## Synced state (host -> everyone, reliable, when a shift ends and to a late joiner on Net.peer_registered):
##   report_lines   the LAST SHIFT lines; empty before the first shift.
## The host records only while the lobby is on (Config.lobby_enabled): with it off nothing is sent and nobody sees
## the board anyway. Everything else is local display: refresh() on the sync and on a phase change, and twice a second
## while the board is drawn (the payment follows the head count, the briefing and the record have their own clocks).
## The type shrinks until the longest column fits (never below MIN_FONT_SIZE).

## Every peer: the text on the board changed.
signal changed

const TEXT_NO_SHIFT := "No shift worked yet."
const TEXT_PAID := "Shift %d. Paid."
const TEXT_MISSED := "Shift %d. Missed."
const TEXT_DEPOSITED := "Deposited $%d."
const TEXT_OWED := "Due $%d."
const TEXT_NEXT := "Shift %d is next."
const TEXT_DUE := "Payment due $%d."
const TEXT_NO_RECORD := "Nothing on file."
const TEXT_JOB := "Job: %s. $%d."
const TEXT_RUN := "Run %s."  # M16 variety
const TEXT_FINAL := "Final notice. Pay it and the debt is cleared."  # M17 finale
const HEADS: PackedStringArray = ["LAST SHIFT", "NEXT", "YOUR RECORD"]
## The LAST SHIFT column: this many lines of result and money, then at most this many verdicts.
const HEAD_LINES: int = 3
const MAX_VERDICTS: int = 3
const MAX_BRIEFING: int = 6
const MAX_CAREER: int = 7
const COLUMN_COUNT: int = 3

## Board face in metres (the Panel's board_size), the margin round the text, the gap between two columns.
const BOARD_SIZE := Vector2(4.0, 1.8)
const MARGIN: float = 0.12
const GUTTER: float = 0.12
## Label3D metres per font pixel; type sizes in font pixels (BODY 62 = letters about 7 cm tall: read from 4 m).
const PIXEL_SIZE: float = 0.0016
const HEAD_FONT_SIZE: int = 54
const BODY_FONT_SIZE: int = 62
const MIN_FONT_SIZE: int = 34
const HEAD_HEIGHT: float = 0.16
## The labels float this far in front of the wall (the board's face is at 0.07).
const TEXT_OUT: float = 0.08
const REFRESH_SEC: float = 0.5
const PANEL_PATH := ^"Panel"

## The LAST SHIFT lines as the host recorded them (synced). Empty before the first shift.
var report_lines: PackedStringArray = []
## Where the briefing / the record are read from (tests put a stand-in here). null = GameState / the Career autoload.
var briefing_source: Object = null
var career_source: Object = null

var _heads: Array[Label3D] = []
var _bodies: Array[Label3D] = []
var _shown: PackedStringArray = []
var _accum: float = 0.0


func _ready() -> void:
	_build_labels()
	GameState.round_ended.connect(_on_round_ended)
	GameState.phase_changed.connect(_on_phase_changed)
	GameState.run_changed.connect(refresh)  # M16 variety: the run line follows the code
	Net.peer_registered.connect(_on_peer_registered)
	refresh()


func _process(delta: float) -> void:
	_accum += delta
	if _accum < REFRESH_SEC:
		return
	_accum = 0.0
	if is_visible_in_tree():
		refresh()


# --- queries (any peer) -----------------------------------------------------------------------------------------

## The last shift as the host recorded it: result, deposited, due, up to three verdicts. Empty before the first shift.
func get_last_shift_lines() -> PackedStringArray:
	return report_lines.duplicate()


## The next shift: its number and payment, then the briefing lines when there is a briefing.
func get_next_lines() -> PackedStringArray:
	var out := PackedStringArray([TEXT_NEXT % GameState.round_number, TEXT_DUE % GameState.quota])
	if GameState.is_final_shift(): out.insert(0, TEXT_FINAL)  # M17 finale: the run's last shift heads the column
	if Story.onboarding_alley_line() != "": out.insert(0, Story.onboarding_alley_line())  # M19 onboarding: a first-timer's first line says what the van is
	var src: Object = briefing_source if briefing_source != null and is_instance_valid(briefing_source) else GameState
	if src.has_method(&"get_shift_briefing"):
		out.append_array(_clean_lines(src.call(&"get_shift_briefing"), MAX_BRIEFING))
	var job := get_job_line()  # M15 lead: the shift's job, posted with the briefing
	if job != "":
		out.append(job)
	var run := get_run_line()  # M16 variety: the run's code closes the column
	if run != "":
		out.append(run)
	return out


## M16 variety: the run's code as the board posts it ("Run 7K2M."): what a friend types into the host panel to be
## dealt the same run. "" when there is none (replay off, or before the host's state arrived).
func get_run_line() -> String:
	var code := GameState.get_run_code()
	return TEXT_RUN % code if code != "" else ""


## The shift's job as the board posts it ("Job: three cured bundles. $60."); "" when there is none (replay off, or
## before the host rolled one).
func get_job_line() -> String:
	var contract := GameState.get_contract()
	var text := String(contract.get("text", "")).strip_edges()
	if text == "":
		return ""
	return TEXT_JOB % [text, int(contract.get("reward", 0))]


## This player's own record: the job title, then the career lines. Empty while there is nothing on file.
func get_career_lines() -> PackedStringArray:
	var src: Object = career_source if career_source != null and is_instance_valid(career_source) else Career
	var out := PackedStringArray()
	if src.has_method(&"get_summary_lines"):
		out = _clean_lines(src.call(&"get_summary_lines"), MAX_CAREER)
	if src.has_method(&"get_title"):
		var title := str(src.call(&"get_title")).strip_edges()
		if title != "" and not (out.size() > 0 and out[0].contains(title)):
			out.insert(0, title if title.ends_with(".") else title + ".")
	return out


## The body of column `index` (0 LAST SHIFT, 1 NEXT, 2 YOUR RECORD) as it should read now.
func get_column_text(index: int) -> String:
	match index:
		0:
			return TEXT_NO_SHIFT if report_lines.is_empty() else "\n".join(report_lines)
		1:
			return "\n".join(get_next_lines())
		2:
			var lines := get_career_lines()
			return TEXT_NO_RECORD if lines.is_empty() else "\n".join(lines)
	return ""


## Everything on the board, top to bottom, column after column (heads included).
func get_board_text() -> String:
	var parts := PackedStringArray()
	for i in COLUMN_COUNT:
		parts.append(HEADS[i] + "\n" + get_column_text(i))
	return "\n\n".join(parts)


## The text a column's label shows right now ("" when the label is missing).
func get_shown_text(index: int) -> String:
	return _bodies[index].text if index >= 0 and index < _bodies.size() else ""


## The type size in use after fitting (font pixels).
func get_font_size() -> int:
	return _bodies[0].font_size if not _bodies.is_empty() else BODY_FONT_SIZE


# --- host -------------------------------------------------------------------------------------------------------

## HOST: writes the last shift on every peer's board. `verdicts` are cut to MAX_VERDICTS.
func server_record_shift(success: bool, round_n: int, deposited: int, due: int, verdicts: PackedStringArray) -> void:
	if not _is_host():
		return
	var lines := PackedStringArray([(TEXT_PAID if success else TEXT_MISSED) % round_n, TEXT_DEPOSITED % deposited, TEXT_OWED % due])
	lines.append_array(_clean_lines(verdicts, MAX_VERDICTS))
	_rpc_report.rpc(lines)


func _on_round_ended(success: bool, round_n: int) -> void:
	if not _is_host() or not Config.lobby_enabled:
		return
	var verdicts := PackedStringArray()
	if Story.has_method(&"get_report_verdicts"):
		verdicts = Story.get_report_verdicts()
	server_record_shift(success, round_n, GameState.round_sales, GameState.quota, verdicts)


func _is_host() -> bool:
	return Net.is_host and is_inside_tree() and multiplayer.has_multiplayer_peer() and multiplayer.is_server()


## HOST: a late joiner gets the last shift (reliable, after its world exists: clients build it before joining).
func _on_peer_registered(peer_id: int) -> void:
	if not _is_host() or report_lines.is_empty():
		return
	if peer_id == multiplayer.get_unique_id() or peer_id not in multiplayer.get_peers():
		return
	_rpc_report.rpc_id(peer_id, report_lines)


# --- every peer -------------------------------------------------------------------------------------------------

## Host -> every peer (the host through call_local): the LAST SHIFT lines.
@rpc("authority", "call_local", "reliable")
func _rpc_report(lines: PackedStringArray) -> void:
	report_lines = _clean_lines(lines, HEAD_LINES + MAX_VERDICTS)
	refresh()


func _on_phase_changed(_phase: int) -> void:
	refresh()


## Rebuilds the three columns and fits the type. Cheap when nothing changed.
func refresh() -> void:
	var texts := PackedStringArray()
	for i in COLUMN_COUNT:
		texts.append(get_column_text(i))
	if texts == _shown:
		return
	_shown = texts
	var size := _fit_font_size(texts)
	for i in mini(COLUMN_COUNT, _bodies.size()):
		_bodies[i].font_size = size
		_bodies[i].outline_size = maxi(4, int(size / 7.0))
		_bodies[i].text = texts[i]
	changed.emit()


## The largest type size (BODY_FONT_SIZE down to MIN_FONT_SIZE) at which every column fits its height.
func _fit_font_size(texts: PackedStringArray) -> int:
	var font: Font = ThemeDB.fallback_font
	if font == null:
		return BODY_FONT_SIZE
	var width_px := _column_width() / PIXEL_SIZE
	var room := BOARD_SIZE.y - 2.0 * MARGIN - HEAD_HEIGHT
	var size := BODY_FONT_SIZE
	while size > MIN_FONT_SIZE:
		var tallest := 0.0
		for t in texts:
			tallest = maxf(tallest, font.get_multiline_string_size(t, HORIZONTAL_ALIGNMENT_LEFT, width_px, size).y * PIXEL_SIZE)
		if tallest <= room:
			break
		size -= 2
	return size


func _column_width() -> float:
	return (BOARD_SIZE.x - 2.0 * MARGIN - GUTTER * float(COLUMN_COUNT - 1)) / float(COLUMN_COUNT)


## Plain, trimmed, non-empty lines out of whatever a source returned (at most `limit`).
static func _clean_lines(raw: Variant, limit: int) -> PackedStringArray:
	var out := PackedStringArray()
	if not (raw is Array or raw is PackedStringArray):
		return out
	for entry: Variant in raw:
		var text := str(entry).strip_edges().replace("\n", " ")
		if text != "":
			out.append(text.left(160))
		if out.size() >= limit:
			break
	return out


## Six labels in front of the panel: a head and a body per column, top-left anchored (Label3D: LEFT + TOP put the
## node's origin on the block's top-left corner).
func _build_labels() -> void:
	var col_w := _column_width()
	var top := BOARD_SIZE.y * 0.5 - MARGIN
	for i in COLUMN_COUNT:
		var x := -BOARD_SIZE.x * 0.5 + MARGIN + (col_w + GUTTER) * float(i)
		var head := _make_label("Head%d" % i, col_w, HEAD_FONT_SIZE, Toon.GOLD)
		head.position = Vector3(x, top, TEXT_OUT)
		head.text = HEADS[i]
		add_child(head)
		_heads.append(head)
		var body := _make_label("Body%d" % i, col_w, BODY_FONT_SIZE, Toon.TEXT)
		body.position = Vector3(x, top - HEAD_HEIGHT, TEXT_OUT)
		add_child(body)
		_bodies.append(body)


func _make_label(label_name: String, width: float, font_size: int, color: Color) -> Label3D:
	var label := Label3D.new()
	label.name = label_name
	label.pixel_size = PIXEL_SIZE
	label.font_size = font_size
	label.outline_size = maxi(4, int(font_size / 7.0))
	label.modulate = color
	label.outline_modulate = Toon.INK
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT
	label.vertical_alignment = VERTICAL_ALIGNMENT_TOP
	label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	label.width = width / PIXEL_SIZE
	label.double_sided = false
	label.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	return label
