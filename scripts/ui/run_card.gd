class_name RunCard
extends PanelContainer
## "THE RUN" block of the round-end card (M25 runcard; CONTRACTS "M25", "Run card"). RoundEndOverlay makes one and puts
## it right under the shift report (%ReportCard), above the waiting line and the buttons. Shown only when the run ends
## (GameState.is_run_over(): the final notice paid, PAID IN FULL; or a missed payment, the card that offers START OVER),
## never after an ordinary shift:
##   THE RUN   Shifts worked: 5 · Deposited: $4,210 · Bruised: 3      (the title subtle; Story.get_run_totals_line())
##   Dale carried the deposits. Nobody said so.   Wren ...           (Story.get_run_verdicts(), at most three)
## Both rows are centred HFlowContainers (like the shift report's verdicts): the title sits beside the totals and the
## verdicts share rows while they fit, and they wrap when they do not (long names, big numbers). The round-end card is
## nearly full at PAID IN FULL with four workers, so the block takes as few rows as it can. Everything comes from
## GameState's synced run totals, so the host, every client and a late joiner read the same block. The labels are made
## once (a title, the totals line, Story.RUN_VERDICT_MAX verdicts); refresh() only sets texts.

const TOTALS_FONT_SIZE: int = 18
const VERDICT_FONT_SIZE: int = 17

var _box: VBoxContainer
var _title: Label
var _totals: Label
var _verdicts_box: HFlowContainer
var _verdict_labels: Array[Label] = []
var _verdict_texts: PackedStringArray = []


func _init() -> void:
	name = "RunCard"
	theme_type_variation = &"Card"
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	visible = false
	_box = VBoxContainer.new()
	_box.name = "Box"
	_box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_box.add_theme_constant_override(&"separation", 0)
	add_child(_box)
	var head := _flow("Head", 16)
	_title = _label("Title", 0, head)
	_title.theme_type_variation = &"SubtleLabel"
	_title.text = Story.line("run_title")
	_totals = _label("Totals", TOTALS_FONT_SIZE, head)
	_totals.theme_type_variation = &"HudLabel"
	_verdicts_box = _flow("Verdicts", 24)
	for i in Story.RUN_VERDICT_MAX:
		var verdict := _label("Verdict%d" % (i + 1), VERDICT_FONT_SIZE, _verdicts_box)
		verdict.visible = false
		_verdict_labels.append(verdict)


## Shows the block at the end of a run (with the totals and verdicts as they are now) and hides it otherwise.
func refresh() -> void:
	var shown := GameState.is_run_over()
	visible = shown
	if not shown:
		_verdict_texts = PackedStringArray()
		return
	_totals.text = Story.get_run_totals_line()
	_verdict_texts = Story.get_run_verdicts()
	for i in _verdict_labels.size():
		var has := i < _verdict_texts.size()
		_verdict_labels[i].text = _verdict_texts[i] if has else ""
		_verdict_labels[i].visible = has
	_verdicts_box.visible = not _verdict_texts.is_empty()


## True while the block is shown.
func is_shown() -> bool:
	return visible


## The totals line shown ("" while hidden).
func get_totals_text() -> String:
	return _totals.text if visible else ""


## The verdict lines shown (empty while hidden).
func get_verdict_texts() -> PackedStringArray:
	return _verdict_texts.duplicate() if visible else PackedStringArray()


## The whole block as shown, one line per label ("" while hidden): what every peer must agree on.
func get_block_text() -> String:
	if not visible:
		return ""
	var out := PackedStringArray([_title.text, _totals.text])
	out.append_array(_verdict_texts)
	return "\n".join(out)


## A centred row that wraps when its labels do not fit side by side.
func _flow(node_name: String, h_separation: int) -> HFlowContainer:
	var flow := HFlowContainer.new()
	flow.name = node_name
	flow.mouse_filter = Control.MOUSE_FILTER_IGNORE
	flow.alignment = FlowContainer.ALIGNMENT_CENTER
	flow.add_theme_constant_override(&"h_separation", h_separation)
	flow.add_theme_constant_override(&"v_separation", 0)
	_box.add_child(flow)
	return flow


func _label(node_name: String, font_size: int, parent: Node = null) -> Label:
	var label := Label.new()
	label.name = node_name
	if font_size > 0:
		label.add_theme_font_size_override(&"font_size", font_size)
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER   # the subtle title and the totals share a row
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	(parent if parent != null else _box).add_child(label)
	return label
