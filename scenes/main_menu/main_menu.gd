extends Control
## Main menu: player name, host / join by IP + port, status line (fed by Game.return_to_menu), how-to blurb.
## Remembers the last name / ip / port in user://settings.cfg (section "menu"; other sections are preserved).
##
## Command line (after "--"), consumed once per process via Game.cli_auto_start_used:
##   --host                 host automatically       --join[=IP]  join automatically (default 127.0.0.1)
##   --name=NAME            player name              --port=N     port (default Config.balance.default_port)

const SETTINGS_PATH := "user://settings.cfg"
const SETTINGS_SECTION := "menu"
const DEFAULT_IP := "127.0.0.1"
const MIN_PORT: int = 1024
const MAX_PORT: int = 65535
const FUN_NAMES: Array[String] = ["Sprout", "Clover", "Pip", "Basil", "Poppy", "Fern", "Maple", "Juniper",
	"Radish", "Peanut", "Tulip", "Sage"]

@onready var title_label: Label = %Title
@onready var name_edit: LineEdit = %NameEdit
@onready var ip_edit: LineEdit = %IpEdit
@onready var port_spin: SpinBox = %PortSpin
@onready var host_button: Button = %HostButton
@onready var join_button: Button = %JoinButton
@onready var quit_button: Button = %QuitButton
@onready var status_label: Label = %StatusLabel

var _time: float = 0.0
var _busy: bool = false

func _ready() -> void:
	add_to_group(Game.MENU_GROUP)
	Game.refresh_mouse_mode()
	_apply_fallback_styles()
	name_edit.max_length = Net.MAX_NAME_LENGTH
	port_spin.min_value = MIN_PORT
	port_spin.max_value = MAX_PORT
	port_spin.step = 1
	port_spin.rounded = true
	_load_settings()
	_apply_cli_overrides()
	host_button.pressed.connect(_on_host_pressed)
	join_button.pressed.connect(_on_join_pressed)
	quit_button.pressed.connect(_on_quit_pressed)
	ip_edit.text_submitted.connect(_on_ip_submitted)
	set_status("")
	if not Game.cli_auto_start_used and (Config.has_arg("host") or Config.has_arg("join")):
		Game.cli_auto_start_used = true
		_auto_start()
	else:
		host_button.grab_focus()

func _process(delta: float) -> void:
	_time += delta
	title_label.pivot_offset = title_label.size * 0.5
	title_label.rotation = sin(_time * 1.3) * 0.03
	var s := 1.0 + sin(_time * 2.2) * 0.025
	title_label.scale = Vector2(s, s)

# --- Public (used by Game) ------------------------------------------------------------------------------------

## Shows `text` under the buttons ("" hides it) and re-enables the buttons.
## kind: &"error" (default, used for disconnect/failure messages) | &"info" | &"success".
func set_status(text: String, kind: StringName = &"error") -> void:
	_set_busy(false)
	_show_status(text, kind)

func get_status() -> String:
	return status_label.text if status_label != null else ""

# --- Buttons --------------------------------------------------------------------------------------------------

func _on_host_pressed() -> void:
	_begin_host(true)

func _on_join_pressed() -> void:
	_begin_join(true)

func _on_ip_submitted(_text: String) -> void:
	_begin_join(true)

func _on_quit_pressed() -> void:
	Sfx.play(&"ui_click")
	get_tree().quit()

func _begin_host(remember: bool) -> void:
	if _busy:
		return
	var port := int(port_spin.value)
	if remember:
		_save_settings()
	Sfx.play(&"ui_click")
	Juice.punch_ui(host_button)
	_set_busy(true)
	_show_status("Opening your farm on port %d..." % port, &"info")
	# Deferred: Game frees this menu while starting, never do that inside the button's own signal.
	_do_host.call_deferred(_player_name(), port)

func _begin_join(remember: bool) -> void:
	if _busy:
		return
	var ip := ip_edit.text.strip_edges()
	if ip == "":
		_show_status("Type the host's IP address first.", &"error")
		Sfx.play(&"error")
		return
	var port := int(port_spin.value)
	if remember:
		_save_settings()
	Sfx.play(&"ui_click")
	Juice.punch_ui(join_button)
	_set_busy(true)
	_show_status("Connecting to %s:%d..." % [ip, port], &"info")
	_do_join.call_deferred(ip, port, _player_name())

func _do_host(player_name: String, port: int) -> void:
	Game.start_host(player_name, port) # on failure Game calls set_status() on this menu

func _do_join(ip: String, port: int, player_name: String) -> void:
	Game.start_join(ip, port, player_name)

func _auto_start() -> void:
	await get_tree().process_frame # let autoloads and this menu settle for a frame
	if not is_inside_tree() or _busy:
		return
	if Config.has_arg("host"):
		_begin_host(false)
	else:
		_begin_join(false)

# --- Helpers --------------------------------------------------------------------------------------------------

func _player_name() -> String:
	var raw := name_edit.text.strip_edges()
	if raw == "":
		raw = name_edit.placeholder_text
	return Net.sanitize_name(raw)

func _set_busy(busy: bool) -> void:
	_busy = busy
	host_button.disabled = busy
	join_button.disabled = busy
	name_edit.editable = not busy
	ip_edit.editable = not busy
	port_spin.editable = not busy

func _show_status(text: String, kind: StringName) -> void:
	status_label.text = text
	status_label.visible = text != ""
	match kind:
		&"error":
			status_label.theme_type_variation = &"ErrorLabel"
		&"success":
			status_label.theme_type_variation = &"SuccessLabel"
		_:
			status_label.theme_type_variation = &"SubtleLabel"
	if kind == &"error" and text != "" and not _has_variation(&"ErrorLabel"):
		status_label.add_theme_color_override(&"font_color", Color(1.0, 0.35, 0.37))
	else:
		status_label.remove_theme_color_override(&"font_color")

func _load_settings() -> void:
	var cfg := ConfigFile.new()
	var ok := cfg.load(SETTINGS_PATH) == OK
	var saved_name := String(cfg.get_value(SETTINGS_SECTION, "name", "")) if ok else ""
	var saved_ip := String(cfg.get_value(SETTINGS_SECTION, "ip", DEFAULT_IP)) if ok else DEFAULT_IP
	var saved_port := int(cfg.get_value(SETTINGS_SECTION, "port", Config.balance.default_port)) if ok \
		else Config.balance.default_port
	name_edit.placeholder_text = FUN_NAMES[randi() % FUN_NAMES.size()]
	name_edit.text = saved_name
	ip_edit.text = saved_ip if saved_ip != "" else DEFAULT_IP
	port_spin.value = clampi(saved_port, MIN_PORT, MAX_PORT)

func _save_settings() -> void:
	var cfg := ConfigFile.new()
	cfg.load(SETTINGS_PATH) # keep other sections; a missing file is fine
	cfg.set_value(SETTINGS_SECTION, "name", name_edit.text.strip_edges())
	cfg.set_value(SETTINGS_SECTION, "ip", ip_edit.text.strip_edges())
	cfg.set_value(SETTINGS_SECTION, "port", int(port_spin.value))
	var err := cfg.save(SETTINGS_PATH)
	if err != OK:
		push_warning("MainMenu: could not save %s (%s)" % [SETTINGS_PATH, error_string(err)])

func _apply_cli_overrides() -> void:
	if Config.has_arg("name"):
		name_edit.text = String(Config.get_arg("name"))
	if Config.has_arg("port"):
		var p := String(Config.get_arg("port")).to_int()
		if p >= MIN_PORT and p <= MAX_PORT:
			port_spin.value = p
	if Config.has_arg("join"):
		var j: Variant = Config.get_arg("join")
		ip_edit.text = String(j) if j is String and String(j) != "" else DEFAULT_IP

## The art theme provides TitleLabel etc.; if it is missing keep the menu readable anyway.
func _apply_fallback_styles() -> void:
	if not _has_variation(&"TitleLabel"):
		title_label.add_theme_font_size_override(&"font_size", 72)
		title_label.add_theme_constant_override(&"outline_size", 14)
		title_label.add_theme_color_override(&"font_outline_color", Color(0.18, 0.16, 0.24))

func _has_variation(variation: StringName) -> bool:
	var t := theme if theme != null else ThemeDB.get_project_theme()
	return t != null and t.get_type_variation_base(variation) != &""
