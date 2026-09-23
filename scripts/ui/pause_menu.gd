class_name PauseMenu
extends Control
## Pause overlay (scenes/ui/pause_menu.tscn, instanced by the HUD as %PauseMenu).
## Toggled by the "pause" action (Escape). It does NOT pause the tree (multiplayer keeps running).
## Opens only when nobody else holds the UI lock (e.g. with the shop open, Escape closes the shop
## instead); closing our own menu always works. Holds Game.set_ui_lock(&"pause") while open.

const LOCK_SOURCE: StringName = &"pause"
## Controls hint rows: [label, action, fallback key text].
const CONTROL_HINTS: Array = [
	["Move", &"move_forward", "WASD"],
	["Interact", &"interact", "E"],
	["Drop", &"drop", "Q"],
	["Jump", &"jump", "Space"],
	["Sprint", &"sprint", "Shift"],
	["Crouch", &"crouch", "Ctrl"],
]

var _locked: bool = false
## Frame in which someone else released the UI lock: the same key press must not reopen us.
var _other_unlock_frame: int = -1

@onready var card: Control = %Card
@onready var resume_button: Button = %ResumeButton
@onready var leave_button: Button = %LeaveButton
@onready var host_note: Label = %HostNote
@onready var controls_label: Label = %ControlsLabel


func _ready() -> void:
	visible = false
	mouse_filter = Control.MOUSE_FILTER_STOP
	resume_button.pressed.connect(_on_resume_pressed)
	leave_button.pressed.connect(_on_leave_pressed)
	Game.ui_lock_changed.connect(_on_ui_lock_changed)
	controls_label.text = _build_controls_text()


func _exit_tree() -> void:
	_set_locked(false)


func _unhandled_input(event: InputEvent) -> void:
	if not event.is_action_pressed(&"pause") or event.is_echo():
		return
	if visible:
		close()
		get_viewport().set_input_as_handled()
	elif can_open():
		open()
		get_viewport().set_input_as_handled()
	# else: someone else (shop UI, round-end screen) owns the UI and handles Escape itself.


func is_open() -> bool:
	return visible


## False while another overlay holds the UI lock (or released it during this very frame).
func can_open() -> bool:
	if visible:
		return false
	if Game.is_ui_locked():
		return false
	return Engine.get_process_frames() != _other_unlock_frame


func open() -> void:
	if visible:
		return
	host_note.visible = GameState.is_local_host()
	visible = true
	_set_locked(true)
	Sfx.play(&"ui_open")
	if is_inside_tree():
		Juice.pop_in(card)
		resume_button.grab_focus.call_deferred()


func close() -> void:
	if not visible:
		return
	visible = false
	_set_locked(false)
	Sfx.play(&"ui_close")


func toggle() -> void:
	if visible:
		close()
	elif can_open():
		open()


func _on_resume_pressed() -> void:
	Sfx.play(&"ui_click")
	close()


func _on_leave_pressed() -> void:
	Sfx.play(&"ui_click")
	close()
	Game.return_to_menu()


func _on_ui_lock_changed(locked: bool) -> void:
	if not locked and not _locked:
		_other_unlock_frame = Engine.get_process_frames()


func _set_locked(locked: bool) -> void:
	if locked == _locked:
		return
	_locked = locked
	Game.set_ui_lock(LOCK_SOURCE, locked)


static func _build_controls_text() -> String:
	var parts: PackedStringArray = []
	for row: Array in CONTROL_HINTS:
		var key_text: String = row[2]
		if row[1] != &"move_forward":
			key_text = HUD.action_key_text(row[1], row[2])
		parts.append("%s: %s" % [row[0], key_text])
	return "   ".join(parts)
