@tool
extends Node3D
## Wall sign / poster / blackboard placeholder (world/level agent). A board (+ optional frame) and a Label3D.
## Origin = board centre on the wall surface, front = +Z. Instances override text / board_size / colours.
## A modeller may replace the meshes under `Visual`; keep the `Text` Label3D (Room.set_debt_board_text uses it).

## Text on the sign. Multi-line is fine. Shrinks to fit the board when `fit_text` is on.
@export_multiline var text: String = "SIGN":
	set(value):
		text = value
		_apply()
## Board size in metres (width, height).
@export var board_size: Vector2 = Vector2(2.0, 1.0):
	set(value):
		board_size = value
		_apply()
## Nominal font size (Label3D pixels at pixel_size 0.005).
@export var font_size: int = 72:
	set(value):
		font_size = maxi(value, 8)
		_apply()
@export var text_color: Color = Color(1.0, 0.99, 0.97):
	set(value):
		text_color = value
		_apply()
@export var outline_color: Color = Color(0.18, 0.165, 0.24):
	set(value):
		outline_color = value
		_apply()
## Outline size in Label3D pixels; -1 = font_size / 4.
@export var outline_size: int = -1:
	set(value):
		outline_size = value
		_apply()
## Shrink the font so the text stays inside the board (with a small margin).
@export var fit_text: bool = true:
	set(value):
		fit_text = value
		_apply()
@export var board_material: Material:
	set(value):
		board_material = value
		_apply()
@export var frame_material: Material:
	set(value):
		frame_material = value
		_apply()
@export var show_frame: bool = true:
	set(value):
		show_frame = value
		_apply()
@export var frame_width: float = 0.08:
	set(value):
		frame_width = value
		_apply()

const _PIXEL_SIZE := 0.005
const _MARGIN := 0.86


func _ready() -> void:
	_apply()


## Font size actually used after fitting the text inside the board.
func get_effective_font_size() -> int:
	var label := get_node_or_null(^"Text") as Label3D
	return label.font_size if label != null else font_size


func _apply() -> void:
	var label := get_node_or_null(^"Text") as Label3D
	if label != null:
		label.text = text
		var size := font_size
		if fit_text and not text.is_empty():
			size = _fitted_size(label)
		label.font_size = size
		label.pixel_size = _PIXEL_SIZE
		label.modulate = text_color
		label.outline_modulate = outline_color
		var ol := outline_size if outline_size >= 0 else int(font_size / 4.0)
		label.outline_size = maxi(1, int(round(float(ol) * float(size) / float(font_size))))
	var board := get_node_or_null(^"Visual/Board") as MeshInstance3D
	if board != null:
		board.scale = Vector3(maxf(board_size.x, 0.05), maxf(board_size.y, 0.05), 1.0)
		if board_material != null:
			board.material_override = board_material
	var frame := get_node_or_null(^"Visual/Frame") as MeshInstance3D
	if frame != null:
		frame.visible = show_frame
		frame.scale = Vector3(board_size.x + 2.0 * frame_width, board_size.y + 2.0 * frame_width, 1.0)
		if frame_material != null:
			frame.material_override = frame_material


func _fitted_size(label: Label3D) -> int:
	var font: Font = label.font if label.font != null else ThemeDB.fallback_font
	if font == null:
		return font_size
	var px := font.get_multiline_string_size(text, HORIZONTAL_ALIGNMENT_CENTER, -1.0, font_size)
	if px.x <= 0.0 or px.y <= 0.0:
		return font_size
	var w := px.x * _PIXEL_SIZE
	var h := px.y * _PIXEL_SIZE
	var k := minf(1.0, minf(board_size.x * _MARGIN / w, board_size.y * _MARGIN / h))
	return maxi(8, int(floor(float(font_size) * k)))
