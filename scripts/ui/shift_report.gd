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
	for col: Array in COLUMNS:
		grid.add_child(_cell(String(col[0]), bool(col[1]), &"SubtleLabel", 0, Color.WHITE, false))
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


## Peer ids shown, in row order (tests).
func get_row_peers() -> Array[int]:
	return _row_peers.duplicate()


## The verdict lines shown (tests).
func get_verdict_texts() -> PackedStringArray:
	return _verdict_texts.duplicate()


## Text of one cell: `row` 0 = header, `column` 0..6 (tests). "" when out of range.
func get_cell_text(row: int, column: int) -> String:
	var index := row * COLUMNS.size() + column
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
