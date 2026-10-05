class_name OptionsCard
extends Control
## OPTIONS (M19, settings agent; scenes/ui/options_card.tscn): this machine's settings on one card, opened from the
## main menu (its Options button) and from the pause menu (OPTIONS on the ON BREAK card). Same look as the ON BREAK
## card: a dim, a centred card, the sections on Card panels. Every change goes to the Settings autoload at once (it
## applies and saves); DEFAULTS puts every value back; BACK or Escape closes the card and `closed` hands the keyboard
## back to whoever opened it (the opener hides its own card while this one is up). The key list is read-only.
## Keyboard: the controls form one closed focus loop (Tab / Shift+Tab / up / down); left / right move a slider and walk
## the window-size buttons; nothing outside the card can be reached while it is open (the card also takes the mouse).

## Emitted after the card opened / after it closed (the opener shows its own card again and takes the focus back).
signal opened
signal closed

const TEXT_SENSITIVITY := "%.2fx"
const TEXT_FOV := "%d"
const TEXT_DB := "%+d dB"
const TEXT_WINDOW := "%d x %d"
const TEXT_FORCED_MUTE := "Muted from the command line."
## The key list, read-only: [action (&"" = fixed text), fallback key text, what it does]. Mouse buttons and the
## grouped keys are fixed text; single keys follow the keyboard layout (HUD.action_key_text).
const KEY_ROWS: Array = [
	[&"", "WASD", "move"],
	[&"sprint", "Shift", "sprint"],
	[&"jump", "Space", "jump"],
	[&"crouch", "Ctrl", "crouch"],
	[&"", "E / LMB", "use"],
	[&"drop", "Q", "drop"],
	[&"", "RMB", "throw"],
	[&"shove", "F", "shove"],
	[&"", "MMB", "ping"],
	[&"chat", "T", "chat"],
	[&"push_to_talk", "V", "talk"],
	[&"", "1-4", "gestures"],
	[&"", "Esc", "break"],
	[&"", "Enter", "start shift (host)"],
]
const KEY_FONT_SIZE: int = 16

## Show the card's own dim (the pause menu has one already and turns this off in its scene).
@export var own_dim: bool = true

@onready var dim: Control = %Dim
@onready var card: Control = %Card
@onready var sens_slider: HSlider = %SensSlider
@onready var sens_value: Label = %SensValue
@onready var invert_toggle: CheckButton = %InvertToggle
@onready var fov_slider: HSlider = %FovSlider
@onready var fov_value: Label = %FovValue
@onready var fullscreen_toggle: CheckButton = %FullscreenToggle
@onready var scale_buttons: Array[Button] = [%Scale1, %Scale15, %Scale2]
@onready var window_value: Label = %WindowValue
@onready var vsync_toggle: CheckButton = %VsyncToggle
@onready var guidance_toggle: CheckButton = %GuidanceToggle
@onready var sound_toggle: CheckButton = %SoundToggle
@onready var sound_note: Label = %SoundNote
@onready var master_slider: HSlider = %MasterSlider
@onready var master_value: Label = %MasterValue
@onready var sfx_slider: HSlider = %SfxSlider
@onready var sfx_value: Label = %SfxValue
@onready var voice_slider: HSlider = %VoiceSlider
@onready var voice_value: Label = %VoiceValue
@onready var key_grid: GridContainer = %KeyGrid
@onready var defaults_button: Button = %DefaultsButton
@onready var back_button: Button = %BackButton

## True while sync_from_settings() writes the widgets (their signals must not write back).
var _syncing: bool = false
## Volume slider -> [setting key, value label].
var _volume_rows: Dictionary = {}


func _ready() -> void:
	visible = false
	mouse_filter = Control.MOUSE_FILTER_STOP
	dim.visible = own_dim
	sound_note.text = TEXT_FORCED_MUTE
	_volume_rows ={master_slider: [&"master_db", master_value], sfx_slider: [&"sfx_db", sfx_value],
		voice_slider: [&"voice_db", voice_value]}
	_setup_sliders()
	var group := ButtonGroup.new()
	for b: Button in scale_buttons:
		b.toggle_mode = true
		b.button_group = group
	sens_slider.value_changed.connect(_on_sensitivity_changed)
	invert_toggle.toggled.connect(_on_bool_toggled.bind(&"invert_y"))
	fov_slider.value_changed.connect(_on_fov_changed)
	fullscreen_toggle.toggled.connect(_on_bool_toggled.bind(&"fullscreen"))
	for i in scale_buttons.size():
		scale_buttons[i].toggled.connect(_on_scale_toggled.bind(i))
	vsync_toggle.toggled.connect(_on_bool_toggled.bind(&"vsync"))
	guidance_toggle.toggled.connect(_on_bool_toggled.bind(&"guidance"))
	sound_toggle.toggled.connect(_on_sound_toggled)
	for slider: HSlider in _volume_rows:
		slider.value_changed.connect(_on_volume_changed.bind(slider))
	defaults_button.pressed.connect(_on_defaults_pressed)
	back_button.pressed.connect(_on_back_pressed)
	Settings.changed.connect(_on_setting_changed)
	_build_keys()
	_build_focus_loop()
	sync_from_settings()


func _unhandled_input(event: InputEvent) -> void:
	if not visible or event.is_echo():
		return
	if event.is_action_pressed(&"pause") or event.is_action_pressed(&"ui_cancel"):
		close()
		get_viewport().set_input_as_handled()


# ---------------------------------------------------------------------------------------------
# Public
# ---------------------------------------------------------------------------------------------

func is_open() -> bool:
	return visible


## Shows the card with the current settings; the first control takes the keyboard.
func open() -> void:
	if visible:
		return
	sync_from_settings()
	visible = true
	Sfx.play(&"ui_open")
	if is_inside_tree():
		Juice.pop_in(card)
		get_focus_chain()[0].grab_focus.call_deferred()
	opened.emit()


## Hides the card (Escape, BACK, or the opener closing). `quiet`: no sound (the opener plays its own).
func close(quiet: bool = false) -> void:
	if not visible:
		return
	visible = false
	if not quiet:
		Sfx.play(&"ui_close")
	closed.emit()


## Re-reads every widget from the Settings autoload (on open, after DEFAULTS, when a value changes elsewhere).
func sync_from_settings() -> void:
	_syncing = true
	var base := _sensitivity_base()
	sens_slider.min_value = Settings.SENSITIVITY_MIN / base
	sens_slider.max_value = Settings.SENSITIVITY_MAX / base
	sens_slider.value = float(Settings.get_value(&"mouse_sensitivity", base)) / base
	invert_toggle.button_pressed = bool(Settings.get_value(&"invert_y", false))
	fov_slider.value = float(Settings.get_value(&"fov", 80.0))
	var fullscreen := bool(Settings.get_value(&"fullscreen", false))
	fullscreen_toggle.button_pressed = fullscreen
	var scale := float(Settings.get_value(&"window_scale", 1.0))
	for i in scale_buttons.size():
		scale_buttons[i].button_pressed = is_equal_approx(Settings.WINDOW_SCALES[i], scale)
		scale_buttons[i].disabled = fullscreen
	vsync_toggle.button_pressed = bool(Settings.get_value(&"vsync", true))
	guidance_toggle.button_pressed = bool(Settings.get_value(&"guidance", true))
	var forced: bool = Settings.is_mute_forced()
	sound_toggle.button_pressed = not forced and not bool(Settings.get_value(&"muted", false))
	sound_toggle.disabled = forced
	sound_note.visible = forced
	for slider: HSlider in _volume_rows:
		slider.value = float(Settings.get_value(_volume_rows[slider][0], 0.0))
	_syncing = false
	_refresh_labels()


## The controls in keyboard order (the focus loop, top to bottom, left column first).
func get_focus_chain() -> Array[Control]:
	var out: Array[Control] = [sens_slider, invert_toggle, fov_slider, fullscreen_toggle]
	for b: Button in scale_buttons:
		out.append(b)
	out.append_array([vsync_toggle, guidance_toggle, sound_toggle, master_slider, sfx_slider, voice_slider,
		defaults_button, back_button])
	return out


## The read-only key list as shown, one "KEY what" line per row (tests).
func get_key_texts() -> PackedStringArray:
	var out := PackedStringArray()
	var cells := key_grid.get_children()
	for i in range(0, cells.size() - 1, 2):
		out.append("%s %s" % [(cells[i] as Label).text, (cells[i + 1] as Label).text])
	return out


## What the value labels read: {sensitivity, fov, window, master, sfx, voice} (tests and captures).
func get_value_texts() -> Dictionary:
	return {"sensitivity": sens_value.text, "fov": fov_value.text, "window": window_value.text,
		"master": master_value.text, "sfx": sfx_value.text, "voice": voice_value.text}


# ---------------------------------------------------------------------------------------------
# Widgets -> Settings
# ---------------------------------------------------------------------------------------------

func _on_sensitivity_changed(value: float) -> void:
	_refresh_labels()
	if _syncing:
		return
	Settings.set_value(&"mouse_sensitivity", value * _sensitivity_base())


func _on_fov_changed(value: float) -> void:
	_refresh_labels()
	if _syncing:
		return
	Settings.set_value(&"fov", value)


func _on_volume_changed(value: float, slider: HSlider) -> void:
	_refresh_labels()
	if _syncing:
		return
	Settings.set_value(_volume_rows[slider][0], value)


func _on_bool_toggled(pressed: bool, key: StringName) -> void:
	if _syncing:
		return
	Settings.set_value(key, pressed)
	Sfx.play(&"ui_click")


func _on_sound_toggled(pressed: bool) -> void:
	if _syncing:
		return
	Settings.set_value(&"muted", not pressed)
	if pressed:
		Sfx.play(&"ui_click")


func _on_scale_toggled(pressed: bool, index: int) -> void:
	if _syncing or not pressed:
		return
	Settings.set_value(&"window_scale", Settings.WINDOW_SCALES[index])
	Sfx.play(&"ui_click")


func _on_defaults_pressed() -> void:
	Sfx.play(&"ui_click")
	Settings.reset_to_defaults()
	sync_from_settings()


func _on_back_pressed() -> void:
	close()


## A value changed somewhere else (the ON BREAK card's voice slider, DEFAULTS, the guide): the widgets follow.
func _on_setting_changed(_key: StringName) -> void:
	if visible and not _syncing:
		sync_from_settings()


# ---------------------------------------------------------------------------------------------
# Internals
# ---------------------------------------------------------------------------------------------

func _sensitivity_base() -> float:
	var base := float(Settings.get_default(&"mouse_sensitivity"))
	return base if base > 0.0 else 0.0025


func _setup_sliders() -> void:
	sens_slider.step = 0.05
	fov_slider.min_value = Settings.FOV_MIN
	fov_slider.max_value = Settings.FOV_MAX
	fov_slider.step = 1.0
	for slider: HSlider in _volume_rows:
		slider.min_value = Settings.VOLUME_MIN_DB
		slider.max_value = Settings.VOLUME_MAX_DB
		slider.step = 1.0


func _refresh_labels() -> void:
	sens_value.text = TEXT_SENSITIVITY % sens_slider.value
	fov_value.text = TEXT_FOV % roundi(fov_slider.value)
	for slider: HSlider in _volume_rows:
		(_volume_rows[slider][1] as Label).text = TEXT_DB % roundi(slider.value)
	if fullscreen_toggle.button_pressed:
		window_value.text = ""
	else:
		var size := Settings.window_size_for(float(Settings.get_value(&"window_scale", 1.0)))
		window_value.text = TEXT_WINDOW % [size.x, size.y]


func _build_keys() -> void:
	for child: Node in key_grid.get_children():
		key_grid.remove_child(child)
		child.queue_free()
	for row: Array in KEY_ROWS:
		var key_text: String = row[1]
		if row[0] != &"":
			key_text = HUD.action_key_text(row[0], row[1])
		var key_label := Label.new()
		key_label.text = key_text.to_upper()
		key_label.theme_type_variation = &"HudLabel"
		key_label.add_theme_font_size_override(&"font_size", KEY_FONT_SIZE)
		key_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
		key_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
		key_grid.add_child(key_label)
		var what := Label.new()
		what.text = String(row[2])
		what.theme_type_variation = &"SubtleLabel"
		what.add_theme_font_size_override(&"font_size", KEY_FONT_SIZE)
		what.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		what.mouse_filter = Control.MOUSE_FILTER_IGNORE
		key_grid.add_child(what)


## One closed loop: Tab / down go to the next control, Shift+Tab / up to the previous one (the last wraps to the
## first). Left / right: the window-size buttons walk among themselves, DEFAULTS and BACK swap, sliders take the keys
## themselves, everything else stays put. Nothing outside the card is a neighbour.
func _build_focus_loop() -> void:
	var chain := get_focus_chain()
	var n := chain.size()
	for i in n:
		var c := chain[i]
		c.focus_mode = Control.FOCUS_ALL
		var next := chain[(i + 1) % n]
		var prev := chain[(i - 1 + n) % n]
		c.focus_next = c.get_path_to(next)
		c.focus_previous = c.get_path_to(prev)
		c.focus_neighbor_bottom = c.get_path_to(next)
		c.focus_neighbor_top = c.get_path_to(prev)
		c.focus_neighbor_left = c.get_path_to(c)
		c.focus_neighbor_right = c.get_path_to(c)
	for i in scale_buttons.size():
		var b := scale_buttons[i]
		var m := scale_buttons.size()
		b.focus_neighbor_left = b.get_path_to(scale_buttons[(i - 1 + m) % m])
		b.focus_neighbor_right = b.get_path_to(scale_buttons[(i + 1) % m])
	defaults_button.focus_neighbor_right = defaults_button.get_path_to(back_button)
	defaults_button.focus_neighbor_left = defaults_button.get_path_to(back_button)
	back_button.focus_neighbor_left = back_button.get_path_to(defaults_button)
	back_button.focus_neighbor_right = back_button.get_path_to(defaults_button)
