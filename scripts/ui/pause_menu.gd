class_name PauseMenu
extends Control
## Pause overlay, "ON BREAK" (scenes/ui/pause_menu.tscn, instanced by the HUD as %PauseMenu).
## Toggled by the "pause" action (Escape). It does NOT pause the tree (multiplayer keeps running: the shift
## clock does not stop, and the copy says so).
## Opens only when nobody else holds the UI lock (e.g. with the shop open, Escape closes the shop
## instead); closing our own menu always works. Holds Game.set_ui_lock(&"pause") while open.
## Keyboard focus stays on its own two buttons (focus neighbours in the scene): the round-end overlay can be open
## underneath, and Tab / arrows must never reach its NEXT SHIFT / START OVER through the pause card.
## M10: a VOICE card (Voice autoload, contract surface only): "Microphone" (Voice.enabled), "Push to talk (V)"
## (Voice.push_to_talk), "Voice volume" slider VOLUME_MIN_DB..VOLUME_MAX_DB, an input meter fed by
## Voice.input_level_changed, "No microphone found." while not Voice.is_mic_available(); values are re-read every time
## the menu opens. M19 settings: the Sound toggle and the voice volume slider are views of the Settings autoload
## (`muted`, `voice_db`); the key list moved to the OPTIONS card (%Options, scenes/ui/options_card.tscn), opened with
## the OPTIONS button between BACK TO WORK and CLOCK OUT; the Controls panel keeps a one-line pointer to it.

## Emitted after the menu closed and released its lock (the HUD hands the keyboard back to the round-end overlay).
signal closed

const LOCK_SOURCE: StringName = &"pause"
const VOLUME_MIN_DB: float = -30.0
const VOLUME_MAX_DB: float = 6.0
const TEXT_VOLUME := "%+d dB"
const TEXT_NO_MIC := "No microphone found."
## M19 settings: the Controls panel's one line (the keys themselves are on the OPTIONS card, incl. 1-4 gestures).
const TEXT_CONTROLS_POINTER := "Keys, mouse, screen and sound: OPTIONS."

var _locked: bool = false
## Frame in which someone else released the UI lock: the same key press must not reopen us.
var _other_unlock_frame: int = -1

@onready var card: Control = %Card
@onready var resume_button: Button = %ResumeButton
@onready var leave_button: Button = %LeaveButton
@onready var host_note: Label = %HostNote
@onready var controls_label: Label = %ControlsLabel
@onready var mic_toggle: CheckButton = %MicToggle
@onready var ptt_toggle: CheckButton = %PttToggle
@onready var sound_toggle: CheckButton = %SoundToggle
@onready var volume_slider: HSlider = %VolumeSlider
@onready var volume_value: Label = %VolumeValue
@onready var input_meter: ProgressBar = %InputMeter
@onready var meter_row: Control = %MeterRow
@onready var no_mic_label: Label = %NoMicLabel

## True while sync_voice_controls() writes the widgets (their signals must not write back into Voice).
var _syncing_voice: bool = false


func _ready() -> void:
	visible = false
	mouse_filter = Control.MOUSE_FILTER_STOP
	resume_button.pressed.connect(_on_resume_pressed)
	leave_button.pressed.connect(_on_leave_pressed)
	Game.ui_lock_changed.connect(_on_ui_lock_changed)
	controls_label.text = TEXT_CONTROLS_POINTER # M19 settings
	# M10 voice settings (Voice contract surface; guarded so a renamed field never breaks the menu).
	volume_slider.min_value = VOLUME_MIN_DB
	volume_slider.max_value = VOLUME_MAX_DB
	no_mic_label.text = TEXT_NO_MIC
	mic_toggle.toggled.connect(_on_mic_toggled)
	ptt_toggle.toggled.connect(_on_ptt_toggled)
	sound_toggle.toggled.connect(_on_sound_toggled)
	volume_slider.value_changed.connect(_on_volume_changed)
	var voice: Node = _voice()
	if voice != null and voice.has_signal(&"input_level_changed"):
		voice.connect(&"input_level_changed", _on_input_level_changed)
	sync_voice_controls()
	_career_ready() # M15 career: the Record card
	_settings_ready() # M19 settings: the OPTIONS button and card


func _exit_tree() -> void:
	_set_locked(false)


func _unhandled_input(event: InputEvent) -> void:
	if not event.is_action_pressed(&"pause") or event.is_echo():
		return
	if options.is_open():
		return # M19 settings: Escape closes the OPTIONS card first (the card handles it)
	if visible:
		close()
		get_viewport().set_input_as_handled()
	elif can_open():
		open()
		get_viewport().set_input_as_handled()
	# else: someone else (shop UI, round-end screen) owns the UI and handles Escape itself.


func is_open() -> bool:
	return visible


## False while another overlay holds the UI lock (or released it during this very frame). The back room's own lock
## does not count (M11 review): Escape used to be dead for the whole stay, so a worker could not leave the game.
func can_open() -> bool:
	if visible:
		return false
	if Game.is_ui_locked() and not _only_backroom_locked():
		return false
	return Engine.get_process_frames() != _other_unlock_frame


## True when the back room is the only thing holding the UI lock.
static func _only_backroom_locked() -> bool:
	var sources: Array[StringName] = Game.get_ui_lock_sources()
	return sources.size() == 1 and sources[0] == Const.UI_LOCK_BACKROOM


func open() -> void:
	if visible:
		return
	host_note.visible = GameState.is_local_host()
	sync_voice_controls()
	sync_record() # M15 career
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
	options.close(true) # M19 settings: the OPTIONS card goes with the menu
	_set_locked(false)
	Sfx.play(&"ui_close")
	closed.emit()


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


# --- M10: voice settings --------------------------------------------------------------------------------------------

## Re-reads every voice widget from the Voice autoload (on open; public for tests).
func sync_voice_controls() -> void:
	var voice: Node = _voice()
	_syncing_voice = true
	# M19 settings: Sound is a view of Settings `muted` (`--mute` holds it off and the toggle cannot change that).
	sound_toggle.button_pressed = not Settings.is_mute_forced() and not bool(Settings.get_value(&"muted", false))
	sound_toggle.disabled = Settings.is_mute_forced()
	if voice == null:
		mic_toggle.disabled = true
		ptt_toggle.disabled = true
		volume_slider.editable = false
		meter_row.visible = false
		no_mic_label.visible = true
	else:
		mic_toggle.button_pressed = bool(voice.get(&"enabled"))
		ptt_toggle.button_pressed = bool(voice.get(&"push_to_talk"))
		var db := clampf(float(Settings.get_value(&"voice_db", 0.0)), VOLUME_MIN_DB, VOLUME_MAX_DB) # M19 settings
		volume_slider.value = db
		volume_value.text = TEXT_VOLUME % roundi(db)
		var mic_ok := bool(voice.call(&"is_mic_available")) if voice.has_method(&"is_mic_available") else false
		# One row: the meter with a microphone, the flat note without one (keeps the card short).
		meter_row.visible = mic_ok
		no_mic_label.visible = not mic_ok
		input_meter.value = float(voice.call(&"get_input_level")) if voice.has_method(&"get_input_level") else 0.0
	_syncing_voice = false


func _on_mic_toggled(pressed: bool) -> void:
	if _syncing_voice:
		return
	var voice: Node = _voice()
	if voice != null:
		voice.set(&"enabled", pressed)
	Sfx.play(&"ui_click")


## Sound: the master mute, Settings `muted` (M19; `--mute` on the command line is the unsaved version and wins).
func _on_sound_toggled(pressed: bool) -> void:
	if _syncing_voice:
		return
	Settings.set_value(&"muted", not pressed) # M19 settings (was Config.set_muted)
	if pressed:
		Sfx.play(&"ui_click")


func _on_ptt_toggled(pressed: bool) -> void:
	if _syncing_voice:
		return
	var voice: Node = _voice()
	if voice != null:
		voice.set(&"push_to_talk", pressed)
	Sfx.play(&"ui_click")


func _on_volume_changed(value: float) -> void:
	volume_value.text = TEXT_VOLUME % roundi(value)
	if _syncing_voice:
		return
	Settings.set_value(&"voice_db", value) # M19 settings: it applies the Voice bus (was Voice.output_volume_db)


func _on_input_level_changed(level: float) -> void:
	input_meter.value = clampf(level, 0.0, 1.0)


func _voice() -> Node:
	return Voice


func _set_locked(locked: bool) -> void:
	if locked == _locked:
		return
	_locked = locked
	Game.set_ui_lock(LOCK_SOURCE, locked)


# --- M19 settings: the OPTIONS card ---------------------------------------------------------------------------------
# OPTIONS (%OptionsButton, between BACK TO WORK and CLOCK OUT in the card's closed focus loop) opens %Options, the
# OPTIONS card (scenes/ui/options_card.tscn, without its own dim: ours is under it). While it is up the ON BREAK card
# and the Record card are hidden and the pause lock stays held; Escape or its BACK closes it and the keyboard goes back
# to OPTIONS. Closing the menu closes the card with it.

@onready var options_button: Button = %OptionsButton
@onready var options: OptionsCard = %Options
@onready var _break_center: Control = $Center


func _settings_ready() -> void:
	options_button.pressed.connect(open_options)
	options.closed.connect(_on_options_closed)


## Opens the OPTIONS card over the break (only while the menu is open).
func open_options() -> void:
	if not visible or options.is_open():
		return
	_break_center.visible = false
	record_card.visible = false
	options.open()


func _on_options_closed() -> void:
	_break_center.visible = true
	sync_record()
	sync_voice_controls()
	if visible and is_inside_tree():
		options_button.grab_focus.call_deferred()

# --- end M19 settings -----------------------------------------------------------------------------------------------


# --- M15 career: the Record card ------------------------------------------------------------------------------------
# A second card (%Record in pause_menu.tscn, a child of the overlay itself, not of the centre container) to the right
# of the ON BREAK card and level with its middle: "RECORD", the player's job title (Career.get_title()) and the lines of
# Career.get_summary_lines(), or "Nothing on file." before the first shift. Shown with replay on (Config.replay_enabled);
# the ON BREAK card keeps its place and size either way. Re-read every time the menu opens and when the record
# changes. It takes no mouse and no focus.

const TEXT_RECORD_EMPTY := "Nothing on file."
## Gap between the ON BREAK card and the Record card.
const RECORD_GAP: float = 16.0
const RECORD_FONT_SIZE: int = 16

@onready var record_card: Control = %Record
@onready var record_job: Label = %RecordJob
@onready var record_lines: VBoxContainer = %RecordLines


func _career_ready() -> void:
	var career: Node = Career
	if career != null and career.has_signal(&"changed"):
		career.connect(&"changed", sync_record)
	card.resized.connect(_career_place_record)
	record_card.resized.connect(_career_place_record)
	sync_record()


## Re-reads the Record card from the Career autoload (on open and when the record changes; public for tests).
func sync_record() -> void:
	var career: Node = Career
	record_card.visible = Config.replay_enabled and career != null and career.has_method(&"get_summary_lines")
	if not record_card.visible:
		return
	record_job.text = String(career.call(&"get_title")) if career.has_method(&"get_title") else ""
	record_job.visible = record_job.text != ""
	record_job.custom_minimum_size.x = _record_line_width()  # M19 lead: it wraps too
	for child: Node in record_lines.get_children():
		record_lines.remove_child(child)
		child.queue_free()
	var texts: Array = career.call(&"get_summary_lines")
	if texts.is_empty():
		texts = [TEXT_RECORD_EMPTY]
	for text: Variant in texts:
		var label := Label.new()
		label.text = String(text)
		label.theme_type_variation = &"SubtleLabel"
		label.add_theme_font_size_override(&"font_size", RECORD_FONT_SIZE)
		label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART # the card keeps its width: a long line wraps
		label.custom_minimum_size = Vector2(_record_line_width(), 0.0)  # M19 lead: a wrapping label needs a width
		label.mouse_filter = Control.MOUSE_FILTER_IGNORE
		record_lines.add_child(label)
	_hats_sync_record(career) # M16 hats
	_career_place_record.call_deferred()


## M19 lead: the width a Record line wraps at (the card's own width less its panel margins). A wrapping Label with no
## width of its own was measured before the card had one after M19's pause menu changes: every line wrapped a letter
## at a time and the card grew to 2500 px.
func _record_line_width() -> float:
	var panel := record_card.get_theme_stylebox(&"panel")
	var margins := panel.get_minimum_size().x if panel != null else 0.0
	return maxf(record_card.custom_minimum_size.x - margins, 120.0)


## What the Record card shows, top to bottom: the job title, then the lines ([] while it is hidden; tests).
func get_record_texts() -> PackedStringArray:
	var out := PackedStringArray()
	if not record_card.visible:
		return out
	out.append(record_job.text)
	for child: Node in record_lines.get_children():
		if child is Label and not child.is_queued_for_deletion():
			out.append((child as Label).text)
	return out


## Right of the ON BREAK card, level with its middle (both cards live in the overlay's own full-rect space).
func _career_place_record() -> void:
	if record_card == null or not record_card.visible or not is_inside_tree():
		return
	record_card.reset_size()
	var x := card.position.x + card.size.x + RECORD_GAP
	var y := card.position.y + (card.size.y - record_card.size.y) * 0.5
	record_card.position = Vector2(x, maxf(y, 0.0))

# --- end M15 career ------------------------------------------------------------------------------------------------


# --- M16 hats: one more line on the Record card ----------------------------------------------------------------------
# "Issued: 3 of 7" (Hats.record_text) under the record's lines: %RecordIssued in pause_menu.tscn, a label of its own
# below %RecordLines, so get_record_texts() (the title and the record's own lines) is what it was. Hidden while the
# record has issued nothing (before the first shift).

@onready var record_issued: Label = %RecordIssued


func _hats_sync_record(career: Node) -> void:
	record_issued.visible = not Hats.issued_for(career).is_empty()
	record_issued.text = Hats.record_text(career)


## The Record card's issued line ("" while the card or the line is hidden; tests).
func get_record_issued_text() -> String:
	return record_issued.text if record_card.visible and record_issued.visible else ""

# --- end M16 hats ---------------------------------------------------------------------------------------------------
