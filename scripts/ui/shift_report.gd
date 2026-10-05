class_name ShiftReport
extends VBoxContainer
## The "SHIFT REPORT" block of the round-end card (scenes/ui/shift_report.tscn, instanced by round_end.tscn as
## %Report). A performance review, not a scoreboard (FRIENDSLOP.md §3): a GridContainer with a header row
## (WORKER · DEPOSITED · PLANTED · WATERED · HARVESTED · WRITE-UPS · THROWS/HITS) and one row per worker (every
## registered peer plus every peer with a ledger entry that left, marked "(left)"; name in the worker's colour,
## numbers from GameState.get_stat), then the verdict lines from Story.get_report_verdicts(). Rebuilt by refresh()
## (round_end.gd calls it while the overlay is up: stats_changed / players_changed), digits tabular through the theme.

const TEXT_TITLE := "SHIFT REPORT"
const TEXT_LEFT := "%s (left)"
const TEXT_THROWS_HITS := "%d/%d"
## [header, right-aligned]
const COLUMNS: Array = [
	["WORKER", false], ["DEPOSITED", true], ["PLANTED", true], ["WATERED", true],
	["HARVESTED", true], ["WRITE-UPS", true], ["THROWS/HITS", true],
]
const ROW_FONT_SIZE: int = 16
const VERDICT_FONT_SIZE: int = 18
const NAME_MAX_WIDTH: float = 150.0

var _row_peers: Array[int] = []
var _verdict_texts: PackedStringArray = []

@onready var title_label: Label = %Title
@onready var grid: GridContainer = %Grid
## Verdict lines flow on one row and wrap when the names are long (HFlowContainer).
@onready var verdicts_box: Container = %Verdicts


func _ready() -> void:
	title_label.text = TEXT_TITLE
	grid.columns = COLUMNS.size()
	refresh()


## Rebuilds the table + verdicts from GameState / Net / Story.
func refresh() -> void:
	_clear(grid)
	_clear(verdicts_box)
	_row_peers.clear()
	_verdict_texts = PackedStringArray()
	var fog_column := _spores_has_column()  # M18 spores: a FOGGED column on a shift that fogged somebody
	grid.columns = COLUMNS.size() + (1 if fog_column else 0)  # M18 spores
	for col: Array in COLUMNS:
		grid.add_child(_cell(String(col[0]), bool(col[1]), &"SubtleLabel", 0, Color.WHITE, false))
	if fog_column: grid.add_child(_cell(TEXT_FOGGED, true, &"SubtleLabel", 0, Color.WHITE, false))  # M18 spores
	for peer_id: int in Story.get_report_peers():
		_row_peers.append(peer_id)
		var color: Color = Net.get_player_color(peer_id)
		var worker_name := Net.get_player_name(peer_id)
		if not Net.players.has(peer_id):
			worker_name = TEXT_LEFT % worker_name
		var name_cell := _cell(worker_name, false, &"HudLabel", ROW_FONT_SIZE, color, true)
		name_cell.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
		name_cell.custom_minimum_size.x = NAME_MAX_WIDTH
		grid.add_child(name_cell)
		grid.add_child(_number(HUD.format_money(GameState.get_stat(peer_id, Const.STAT_DEPOSITED))))
		grid.add_child(_number(str(GameState.get_stat(peer_id, Const.STAT_PLANTED))))
		grid.add_child(_number(str(GameState.get_stat(peer_id, Const.STAT_WATERED))))
		grid.add_child(_number(str(GameState.get_stat(peer_id, Const.STAT_HARVESTED))))
		grid.add_child(_number(str(GameState.get_stat(peer_id, Const.STAT_WRITE_UPS))))
		grid.add_child(_number(TEXT_THROWS_HITS % [GameState.get_stat(peer_id, Const.STAT_THROWS),
				GameState.get_stat(peer_id, Const.STAT_HITS)]))
		if fog_column: grid.add_child(_number(str(GameState.get_stat(peer_id, Spores.STAT_FOGGED))))  # M18 spores
	if Story.has_method(&"get_report_verdicts"):
		_verdict_texts = Story.get_report_verdicts()
	for text in _verdict_texts:
		var label := Label.new()
		label.text = text
		label.add_theme_font_size_override(&"font_size", VERDICT_FONT_SIZE)
		label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		label.mouse_filter = Control.MOUSE_FILTER_IGNORE
		verdicts_box.add_child(label)
	verdicts_box.visible = not _verdict_texts.is_empty()
	_career_refresh_job() # M15 career: whether the shift's job was done
	_read_refresh_costs() # M19 readability: what the shift's disruptions cost (under the table)


# --- M15 career: the shift's job on the report ---------------------------------------------------------------------
# One centred line between the table and the verdicts ("JobLine", built on first use): "Job: three cured bundles.
# Done. $60 paid." / "... Failed." / "... Not done." (Contracts.report_text). Hidden without a job.

var _career_job_label: Label


func _career_refresh_job() -> void:
	if _career_job_label == null:
		_career_job_label = Label.new()
		_career_job_label.name = "JobLine"
		_career_job_label.add_theme_font_size_override(&"font_size", VERDICT_FONT_SIZE)
		_career_job_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		_career_job_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		_career_job_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
		add_child(_career_job_label)
		move_child(_career_job_label, verdicts_box.get_index())
		if GameState.has_signal(&"contract_changed"):
			GameState.connect(&"contract_changed", _career_refresh_job)
	var job: Dictionary = GameState.get_contract() if GameState.has_method(&"get_contract") else {}
	var text := Contracts.report_text(job)
	_career_job_label.text = text
	_career_job_label.visible = text != ""


## The job line as shown ("" while hidden).
func get_job_text() -> String:
	return _career_job_label.text if _career_job_label != null and _career_job_label.visible else ""

# --- end M15 career ------------------------------------------------------------------------------------------------


# --- M19 readability: what the shift's disruptions cost ---------------------------------------------------------------
# A short block right under the table ("CostLines", built on first use): a small "WHAT IT COST" title and at most three
# lines from Story.get_shift_cost_lines() (Events' ledger, synced by the host like the verdicts' stats), the dearest
# first: "The raid took two bundles. $360.", "The collector took $40.", "The rat ate into a tray of Purple Haze.".
# Hidden on a shift nothing cost anything. It follows Events.shift_costs_changed, so a cost booked as the shift ended
# (a sale on a light scale, the last unpaid call) still lands on the card.

const TEXT_COST_TITLE := "WHAT IT COST"
const COST_TITLE_FONT_SIZE: int = 14
const COST_FONT_SIZE: int = 17

var _read_box: VBoxContainer
var _read_title: Label
var _read_texts: PackedStringArray = []


func _read_refresh_costs() -> void:
	if _read_box == null:
		_read_box = VBoxContainer.new()
		_read_box.name = "CostLines"
		_read_box.mouse_filter = Control.MOUSE_FILTER_IGNORE
		_read_box.add_theme_constant_override(&"separation", 0)
		_read_title = Label.new()
		_read_title.name = "CostTitle"
		_read_title.text = TEXT_COST_TITLE
		_read_title.theme_type_variation = &"SubtleLabel"
		_read_title.add_theme_font_size_override(&"font_size", COST_TITLE_FONT_SIZE)
		_read_title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		_read_title.mouse_filter = Control.MOUSE_FILTER_IGNORE
		_read_box.add_child(_read_title)
		add_child(_read_box)
		move_child(_read_box, grid.get_index() + 1)
		if Events.has_signal(&"shift_costs_changed"):
			Events.connect(&"shift_costs_changed", _read_refresh_costs)
	for child: Node in _read_box.get_children():
		if child != _read_title:
			_read_box.remove_child(child)
			child.queue_free()
	_read_texts = Story.get_shift_cost_lines() if Story.has_method(&"get_shift_cost_lines") else PackedStringArray()
	for text in _read_texts:
		var label := Label.new()
		label.text = text
		label.add_theme_font_size_override(&"font_size", COST_FONT_SIZE)
		label.add_theme_color_override(&"font_color", Toon.WARNING)
		label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		label.mouse_filter = Control.MOUSE_FILTER_IGNORE
		_read_box.add_child(label)
	_read_box.visible = not _read_texts.is_empty()


## The "what it cost" lines shown (tests); empty while the block is hidden.
func get_cost_texts() -> PackedStringArray:
	return _read_texts.duplicate() if _read_box != null and _read_box.visible else PackedStringArray()

# --- end M19 readability -----------------------------------------------------------------------------------------------


# --- M18 spores: the FOGGED column ------------------------------------------------------------------------------------
# After THROWS/HITS, only on a shift where somebody breathed Black Damp's spores (GameState stat Spores.STAT_FOGGED, the
# times each worker was fogged); every other shift keeps the seven columns it always had.

const TEXT_FOGGED := "FOGGED"


## True when the table shows the FOGGED column right now.
func has_fogged_column() -> bool:
	return grid != null and grid.columns > COLUMNS.size()


func _spores_has_column() -> bool:
	for peer_id: int in Story.get_report_peers():
		if GameState.get_stat(peer_id, Spores.STAT_FOGGED) > 0:
			return true
	return false

# --- end M18 spores ----------------------------------------------------------------------------------------------------


## Peer ids shown, in row order (tests).
func get_row_peers() -> Array[int]:
	return _row_peers.duplicate()


## The verdict lines shown (tests).
func get_verdict_texts() -> PackedStringArray:
	return _verdict_texts.duplicate()


## Text of one cell: `row` 0 = header, `column` 0..6 (7 = FOGGED when shown) (tests). "" when out of range.
func get_cell_text(row: int, column: int) -> String:
	var index := row * grid.columns + column  # M18 spores: the grid's own width (COLUMNS, plus FOGGED when shown)
	if index < 0 or index >= grid.get_child_count():
		return ""
	var label := grid.get_child(index) as Label
	return label.text if label != null else ""


func _number(text: String) -> Label:
	return _cell(text, true, &"HudLabel", ROW_FONT_SIZE, Color.WHITE, false)


func _cell(text: String, right: bool, variation: StringName, font_size: int, color: Color, colored: bool) -> Label:
	var label := Label.new()
	label.text = text
	label.theme_type_variation = variation
	if font_size > 0:
		label.add_theme_font_size_override(&"font_size", font_size)
	if colored:
		label.add_theme_color_override(&"font_color", color)
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT if right else HORIZONTAL_ALIGNMENT_LEFT
	label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	label.size_flags_horizontal = Control.SIZE_EXPAND_FILL if right else Control.SIZE_FILL
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return label


static func _clear(container: Node) -> void:
	for child: Node in container.get_children():
		container.remove_child(child)
		child.queue_free()
