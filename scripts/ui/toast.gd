class_name HudToast
extends PanelContainer
## One toast pill in the HUD toast stack (scenes/ui/toast.tscn). Created by HUD.show_toast():
## pops in, stays for LIFETIME_SEC, fades out and frees itself. The same message arriving again
## while it is still up bumps it ("Hands full x2") instead of stacking a duplicate.

const LIFETIME_SEC: float = 2.8
const FADE_SEC: float = 0.35

var text: String = ""
var kind: StringName = &"info"
var repeat_count: int = 1
var _life_tween: Tween
var _dismissing: bool = false

@onready var label: Label = %Label


static func variation_for_kind(toast_kind: StringName) -> StringName:
	match toast_kind:
		&"error":
			return &"ToastError"
		&"success":
			return &"ToastSuccess"
		_:
			return &"Toast"


## Call before adding to the tree (or any time after).
func setup(toast_text: String, toast_kind: StringName) -> void:
	text = toast_text
	kind = toast_kind
	theme_type_variation = variation_for_kind(toast_kind)
	if is_node_ready():
		_refresh_text()


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	_refresh_text()
	_restart_life()
	Juice.pop_in(self)


## The same message again: count it and restart the timer.
func bump() -> void:
	if _dismissing:
		return
	repeat_count += 1
	_refresh_text()
	_restart_life()
	Juice.bounce(self)


func is_dismissing() -> bool:
	return _dismissing


## Fade out quickly and free (used when the stack is full).
func dismiss() -> void:
	if _dismissing:
		return
	_dismissing = true
	if _life_tween != null:
		_life_tween.kill()
	if not is_inside_tree():
		queue_free()
		return
	_life_tween = create_tween()
	_life_tween.tween_property(self, "modulate:a", 0.0, FADE_SEC * 0.5)
	_life_tween.tween_callback(queue_free)


func _refresh_text() -> void:
	if label == null:
		return
	label.text = text if repeat_count <= 1 else "%s  x%d" % [text, repeat_count]


func _restart_life() -> void:
	if _life_tween != null:
		_life_tween.kill()
	modulate.a = 1.0
	if not is_inside_tree():
		return
	_life_tween = create_tween()
	_life_tween.tween_interval(LIFETIME_SEC)
	_life_tween.tween_property(self, "modulate:a", 0.0, FADE_SEC)
	_life_tween.tween_callback(queue_free)
