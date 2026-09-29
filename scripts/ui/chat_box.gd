class_name ChatBox
extends VBoxContainer
## Text chat (scenes/ui/chat.tscn, instanced by the HUD as %Chat, bottom-left above the held-item panel).
##   log    at most MAX_LINES lines "<name in the worker's colour>: text" (one RichTextLabel each), every line fades
##          LINE_LIFETIME_SEC after it arrived (Comms.chat_received, also our own line through call_local)
##   input  a LineEdit opened by the "chat" action (the HUD calls open()): Enter sends Comms.say(text) and closes,
##          Escape closes and drops the text.
## While the line is open it holds Game.set_ui_lock(LOCK_SOURCE): the mouse is free, the player stands still and
## Voice does not transmit (the voice agent checks the &"chat" lock). Closing releases the lock (the mouse is
## captured again). Escape is consumed in the LineEdit's gui_input (GUI input runs before _unhandled_input), so the
## same press never reaches the pause menu; the pause menu also ignores a press in the frame another lock was released.
## Copy is flat (STYLE.md): the placeholder says what the keys do, nothing more.

## The line opened (took the lock) / closed (released it).
signal opened
signal closed

const LOCK_SOURCE: StringName = &"chat"
const MAX_LINES: int = 6
const LINE_LIFETIME_SEC: float = 8.0
const LINE_FADE_SEC: float = 0.6
const LINE_FONT_SIZE: int = 20
const TEXT_PLACEHOLDER := "Enter sends. Esc drops it."
const TEXT_LINE_FORMAT := "[color=%s]%s[/color]: %s"

var _locked: bool = false

@onready var log_box: VBoxContainer = %Log
@onready var line_edit: LineEdit = %Input


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	log_box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	line_edit.visible = false
	line_edit.max_length = Comms.CHAT_MAX_CHARS
	line_edit.placeholder_text = TEXT_PLACEHOLDER
	line_edit.context_menu_enabled = false
	line_edit.text_submitted.connect(_on_submitted)
	line_edit.gui_input.connect(_on_line_gui_input)
	line_edit.focus_exited.connect(_on_focus_exited)
	Comms.chat_received.connect(_on_chat_received)


func _exit_tree() -> void:
	_set_locked(false)


## True while the input line is open (and the &"chat" lock is held).
func is_open() -> bool:
	return line_edit.visible


## Opens the input line and takes the lock (no-op if already open or off the tree).
func open() -> void:
	if is_open() or not is_inside_tree():
		return
	line_edit.text = ""
	line_edit.visible = true
	_set_locked(true)
	line_edit.grab_focus()
	Sfx.play(&"ui_open")
	opened.emit()


## Closes the input line (the typed text is dropped) and releases the lock.
func close() -> void:
	if not is_open():
		return
	line_edit.visible = false # hiding a focused control releases its focus
	line_edit.text = ""
	_set_locked(false)
	Sfx.play(&"ui_close")
	closed.emit()


func toggle() -> void:
	if is_open():
		close()
	else:
		open()


## Number of lines in the log right now (tests).
func get_line_count() -> int:
	var n := 0
	for child in log_box.get_children():
		if not child.is_queued_for_deletion():
			n += 1
	return n


## Text (bbcode) of the newest line, "" when the log is empty (tests).
func get_last_line_text() -> String:
	var last: RichTextLabel = null
	for child in log_box.get_children():
		if not child.is_queued_for_deletion():
			last = child as RichTextLabel
	return last.text if last != null else ""


## Adds "<name>: text" to the log in the worker's colour; the oldest line goes when there are more than MAX_LINES.
func add_line(peer_id: int, text: String) -> void:
	var color: Color = Net.get_player_color(peer_id)
	var label := RichTextLabel.new()
	label.bbcode_enabled = true
	label.fit_content = true
	label.scroll_active = false
	label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	label.focus_mode = Control.FOCUS_NONE
	label.add_theme_font_size_override(&"normal_font_size", LINE_FONT_SIZE)
	if has_theme_font(&"font", &"HudLabel"):
		label.add_theme_font_override(&"normal_font", get_theme_font(&"font", &"HudLabel"))
	label.text = TEXT_LINE_FORMAT % [color.to_html(false), escape_bbcode(Net.get_player_name(peer_id)), escape_bbcode(text)]
	log_box.add_child(label)
	while get_line_count() > MAX_LINES:
		var oldest: Node = null
		for child in log_box.get_children():
			if not child.is_queued_for_deletion():
				oldest = child
				break
		if oldest == null:
			break
		log_box.remove_child(oldest)
		oldest.queue_free()
	if is_inside_tree():
		var tween := label.create_tween()
		tween.tween_interval(LINE_LIFETIME_SEC)
		tween.tween_property(label, "modulate:a", 0.0, LINE_FADE_SEC)
		tween.tween_callback(label.queue_free)


## Text typed by workers must never open a bbcode tag (one pass, so the escapes themselves are not re-escaped).
static func escape_bbcode(text: String) -> String:
	var out := ""
	for i in text.length():
		var ch := text[i]
		if ch == "[":
			out += "[lb]"
		elif ch == "]":
			out += "[rb]"
		else:
			out += ch
	return out


func _on_chat_received(peer_id: int, text: String) -> void:
	add_line(peer_id, text)
	Sfx.play(&"chat")


func _on_submitted(text: String) -> void:
	Comms.say(text)
	close()


func _on_line_gui_input(event: InputEvent) -> void:
	if not is_open() or not event.is_pressed() or event.is_echo():
		return
	var key := event as InputEventKey
	var escape := key != null and (key.keycode == KEY_ESCAPE or key.physical_keycode == KEY_ESCAPE)
	if escape or event.is_action_pressed(&"ui_cancel"):
		get_viewport().set_input_as_handled()
		close()


## Focus went elsewhere (a click on another control, the pause menu taking the keyboard): the line closes.
func _on_focus_exited() -> void:
	if is_open():
		close()


func _set_locked(locked: bool) -> void:
	if locked == _locked:
		return
	_locked = locked
	if locked:
		Game.set_ui_lock(LOCK_SOURCE, true)
	elif Game.is_ui_locked_by(LOCK_SOURCE):
		Game.set_ui_lock(LOCK_SOURCE, false)
