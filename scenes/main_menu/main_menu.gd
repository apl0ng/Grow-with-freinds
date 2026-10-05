extends Control
## Main menu: player name, host / join by IP + port, status line (fed by Game.return_to_menu), how-to blurb.
## Copy is the factory's (STYLE.md "Mood & tone"): host = "Open the floor", join = "Report for shift",
## quit = "Walk out (you can't)". The title hangs slightly crooked and sways a little; it does not bounce.
## Remembers the last name / ip / port in user://settings.cfg (section "menu"; other sections are preserved). M19: the
## file is the Settings autoload's (Settings.path: `--settings-file=<path>` points both at a test file); a small grey
## version line sits under the title, and Options (beside the quit button) opens the OPTIONS card.
##
## Command line (after "--"), consumed once per process via Game.cli_auto_start_used:
##   --host                 host automatically       --join[=IP]  join automatically (default 127.0.0.1)
##   --name=NAME            player name              --port=N     port (default Config.balance.default_port)

const SETTINGS_PATH := "user://settings.cfg"
const SETTINGS_SECTION := "menu"
const DEFAULT_IP := "127.0.0.1"
const MIN_PORT: int = 1024
const MAX_PORT: int = 65535
## Name placeholders: tired, ordinary names (it is a sweatshop, not a garden party).
const FUN_NAMES: Array[String] = ["Dale", "Marge", "Gus", "Nora", "Lou", "Walt", "Irma", "Hank", "Doris",
	"Earl", "Vern", "Opal"]
## Title sway: a crooked sign on one nail (radians, radians, rad/s).
const TITLE_TILT: float = -0.02
const TITLE_SWAY: float = 0.008
const TITLE_SWAY_SPEED: float = 0.45
const TEXT_HOSTING := "Opening the floor on port %d…"
const TEXT_JOINING := "Reporting for shift at %s…"
const TEXT_NO_IP := "Enter the host's IP first."

@onready var title_label: Label = %Title
@onready var name_edit: LineEdit = %NameEdit
@onready var ip_edit: LineEdit = %IpEdit
@onready var port_spin: SpinBox = %PortSpin
@onready var host_button: Button = %HostButton
@onready var join_button: Button = %JoinButton
@onready var quit_button: Button = %QuitButton
@onready var status_label: Label = %StatusLabel
## M11: floors open on the local network (Lan autoload). Selecting one fills the address; activating joins it.
@onready var lan_caption: Label = %LanCaption
@onready var lan_list: ItemList = %LanList

const TEXT_LAN_CAPTION := "Floors open nearby"
const TEXT_LAN_NONE := "No floors open nearby."
const TEXT_LAN_ITEM := "%s's floor · %d/%d · %s:%d"
## Shown under the list so a host can read their own address out to friends the broadcast does not reach.
const TEXT_MY_ADDRESS := "Your address for friends: %s · port %d"
const TEXT_MY_ADDRESS_NONE := "No network address found."
## Windows Firewall (M11): status texts and the retry button.
const TEXT_FIREWALL_CHECK := "Checking Windows Firewall…"
const TEXT_FIREWALL_OK := "Windows Firewall allows UDP port %d."
const TEXT_FIREWALL_BUTTON := "Allow UDP %d through Windows Firewall"

@onready var firewall_button: Button = %FirewallButton

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
	_run_ready() # M16 variety: the run code row
	_settings_ready() # M19 settings: the version line and the OPTIONS card
	host_button.pressed.connect(_on_host_pressed)
	join_button.pressed.connect(_on_join_pressed)
	quit_button.pressed.connect(_on_quit_pressed)
	ip_edit.text_submitted.connect(_on_ip_submitted)
	lan_list.item_selected.connect(_on_lan_selected)
	lan_list.item_activated.connect(_on_lan_activated)
	firewall_button.pressed.connect(_on_firewall_pressed)
	_refresh_firewall_button()
	Lan.games_changed.connect(_refresh_lan)
	Lan.listen() # a bind error just leaves the list empty (another menu on this PC holds the port)
	port_spin.value_changed.connect(func(_v: float) -> void: _refresh_my_address())
	_refresh_lan()
	set_status("")
	if not Game.cli_auto_start_used and (Config.has_arg("host") or Config.has_arg("join")):
		Game.cli_auto_start_used = true
		_auto_start()
	else:
		host_button.grab_focus()

func _process(delta: float) -> void:
	_time += delta
	title_label.pivot_offset = title_label.size * 0.5
	title_label.rotation = TITLE_TILT + sin(_time * TITLE_SWAY_SPEED) * TITLE_SWAY

func _exit_tree() -> void:
	if Lan.games_changed.is_connected(_refresh_lan):
		Lan.games_changed.disconnect(_refresh_lan)
	Lan.stop_listening()

# --- LAN list ---------------------------------------------------------------------------------------------------

## Rebuilds the "Floors open nearby" list from Lan.get_games() (the caption reads "No floors open nearby." alone
## when there is nothing; the list itself hides).
func _refresh_lan() -> void:
	var games: Array[Dictionary] = Lan.get_games()
	var selected_key := ""
	if lan_list.is_anything_selected():
		var meta: Variant = lan_list.get_item_metadata(lan_list.get_selected_items()[0])
		if meta is Dictionary:
			selected_key = "%s:%d" % [meta.get("ip", ""), int(meta.get("port", 0))]
	lan_list.clear()
	for g in games:
		var idx := lan_list.add_item(TEXT_LAN_ITEM % [g["name"], int(g["players"]), int(g["max"]), g["ip"], int(g["port"])])
		lan_list.set_item_metadata(idx, {"ip": g["ip"], "port": int(g["port"])})
		if "%s:%d" % [g["ip"], int(g["port"])] == selected_key:
			lan_list.select(idx)
	lan_list.visible = not games.is_empty()
	lan_caption.text = TEXT_LAN_CAPTION if not games.is_empty() else TEXT_LAN_NONE
	_refresh_my_address()


## "Your address for friends: 192.168.1.20 · port 7777": the first private IPv4 of this machine (else any IPv4).
func _refresh_my_address() -> void:
	var address_label: Label = get_node_or_null("%AddressLabel")
	if address_label == null:
		return
	var best := ""
	for a in IP.get_local_addresses():
		var s := String(a)
		if not s.is_valid_ip_address() or s.contains(":") or s.begins_with("127.") or s.begins_with("169.254."):
			continue
		var private := s.begins_with("192.168.") or s.begins_with("10.") or (s.begins_with("172.") and int(s.split(".")[1]) >= 16 and int(s.split(".")[1]) <= 31)
		if best == "" or (private and not _is_private_ip(best)):
			best = s
	address_label.text = TEXT_MY_ADDRESS % [best, int(port_spin.value)] if best != "" else TEXT_MY_ADDRESS_NONE


static func _is_private_ip(s: String) -> bool:
	if s.begins_with("192.168.") or s.begins_with("10."):
		return true
	if s.begins_with("172."):
		var second := int(s.split(".")[1])
		return second >= 16 and second <= 31
	return false

func _on_lan_selected(index: int) -> void:
	var meta: Variant = lan_list.get_item_metadata(index)
	if not meta is Dictionary:
		return
	ip_edit.text = String(meta.get("ip", ""))
	var port := int(meta.get("port", 0))
	if port >= MIN_PORT and port <= MAX_PORT:
		port_spin.value = port
	Sfx.play(&"ui_click")

func _on_lan_activated(index: int) -> void:
	_on_lan_selected(index)
	_begin_join(true)

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
	Game.quit_gracefully()  # M17 lead: stops every sound (the click too) and lets the audio thread go first

func _begin_host(remember: bool) -> void:
	if _busy:
		return
	var port := int(port_spin.value)
	if remember:
		_save_settings()
	Sfx.play(&"ui_click")
	Juice.punch_ui(host_button)
	_set_busy(true)
	_show_status(TEXT_HOSTING % port, &"info")
	Config.run_code = get_run_code() # M16 variety: the run the host asks for ("" = a random one)
	# Deferred: Game frees this menu while starting, never do that inside the button's own signal.
	_host_after_firewall.call_deferred(_player_name(), port)

# --- Windows Firewall (M11) -------------------------------------------------------------------------------------

## Host: on Windows (exported builds, or dev runs with --firewall) make sure the inbound UDP rule for the game port
## exists first (one UAC prompt at most; see scripts/core/windows_firewall.gd). A decline or a failure never stops
## hosting: the player is told friends may not get in, here and as a toast once the room is up, and the retry
## button appears under the status line.
func _host_after_firewall(player_name: String, port: int) -> void:
	var fw: Node = WindowsFirewall
	if fw.is_check_enabled():
		_show_status(TEXT_FIREWALL_CHECK, &"info")
		var result: Dictionary = await fw.ensure_multiplayer_firewall_access(port)
		if not is_inside_tree():
			return
		_apply_firewall_result(result, true)
	_do_host(player_name, port)

func _apply_firewall_result(result: Dictionary, hosting_next: bool) -> void:
	var status: StringName = result.get("status", &"")
	var message := String(result.get("message", ""))
	var port := int(result.get("port", 7777))
	match status:
		WindowsFirewall.STATUS_CREATED:
			_show_status(TEXT_FIREWALL_OK % port, &"success")
			if hosting_next:
				Game.world_ready.connect(func(_w: Node) -> void: Game.toast(TEXT_FIREWALL_OK % port, &"info"), CONNECT_ONE_SHOT)
		WindowsFirewall.STATUS_DECLINED, WindowsFirewall.STATUS_FAILED:
			_show_status(message, &"error")
			if hosting_next:
				Game.world_ready.connect(func(_w: Node) -> void: Game.toast(message, &"error"), CONNECT_ONE_SHOT)
	_refresh_firewall_button()

## The retry button shows only when a Windows Firewall request was declined or failed in this session.
func _refresh_firewall_button() -> void:
	var fw: Node = WindowsFirewall
	var last: Dictionary = fw.last_result
	var status: StringName = last.get("status", &"")
	firewall_button.visible = fw.is_check_enabled() and (status == WindowsFirewall.STATUS_DECLINED or status == WindowsFirewall.STATUS_FAILED)
	firewall_button.text = TEXT_FIREWALL_BUTTON % int(port_spin.value)

func _on_firewall_pressed() -> void:
	if _busy:
		return
	Sfx.play(&"ui_click")
	_set_busy(true)
	_show_status(TEXT_FIREWALL_CHECK, &"info")
	var result: Dictionary = await WindowsFirewall.request_again(int(port_spin.value))
	if not is_inside_tree():
		return
	_set_busy(false)
	_apply_firewall_result(result, false)
	if result.get("status", &"") == WindowsFirewall.STATUS_EXISTS:
		_show_status(TEXT_FIREWALL_OK % int(result.get("port", 7777)), &"success")

func _begin_join(remember: bool) -> void:
	if _busy:
		return
	var ip := ip_edit.text.strip_edges()
	if ip == "":
		_show_status(TEXT_NO_IP, &"error")
		Sfx.play(&"error")
		return
	var port := int(port_spin.value)
	if remember:
		_save_settings()
	Sfx.play(&"ui_click")
	Juice.punch_ui(join_button)
	_set_busy(true)
	_show_status(TEXT_JOINING % ("%s:%d" % [ip, port]), &"info")
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
	_run_set_busy(busy) # M16 variety

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
	var ok := cfg.load(_settings_file()) == OK # M19 settings
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
	var path := _settings_file() # M19 settings
	cfg.load(path) # keep other sections; a missing file is fine
	cfg.set_value(SETTINGS_SECTION, "name", name_edit.text.strip_edges())
	cfg.set_value(SETTINGS_SECTION, "ip", ip_edit.text.strip_edges())
	cfg.set_value(SETTINGS_SECTION, "port", int(port_spin.value))
	var err := cfg.save(path)
	if err != OK:
		push_warning("MainMenu: could not save %s (%s)" % [path, error_string(err)])

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


# --- M19 settings: the version line and the OPTIONS card ---------------------------------------------------------------
# %Version under the title reads "v" + Game.get_version(). Options (%OptionsButton, beside the quit button and before it
# in the keyboard path) opens %Options, the OPTIONS card (scenes/ui/options_card.tscn, with its own dim): the menu's
# column hides while it is up; Escape or its BACK closes it and the keyboard goes back to Options.

const TEXT_VERSION := "v%s"

@onready var version_label: Label = %Version
@onready var options_button: Button = %OptionsButton
@onready var options: OptionsCard = %Options
@onready var _menu_center: Control = $Center


func _settings_ready() -> void:
	version_label.text = TEXT_VERSION % Game.get_version()
	options_button.pressed.connect(open_options)
	options.closed.connect(_on_options_closed)


## Opens the OPTIONS card over the menu.
func open_options() -> void:
	if options.is_open():
		return
	_menu_center.visible = false
	options.open()


func _on_options_closed() -> void:
	_menu_center.visible = true
	if is_inside_tree():
		options_button.grab_focus.call_deferred()


## The file name / ip / port live in: the Settings autoload's (user://settings.cfg unless --settings-file says).
func _settings_file() -> String:
	var path := String(Settings.get(&"path"))
	return path if path != "" else SETTINGS_PATH

# --- end M19 settings --------------------------------------------------------------------------------------------------


# --- M16 variety: the run code ---------------------------------------------------------------------------------------
# A row under the two big buttons: a field for a run code and THIS WEEK, which fills in the code everyone gets this
# week (FRIENDSLOP 10.1). Hosting hands the field to Config.run_code as a clean code; blank or junk hands over "",
# and the host rolls a random run. The row comes after the buttons in the tree, so the keyboard path it always had
# (Name, IP, Port, Open the floor, Report for shift) is untouched and the new stops come after it. Shown only when
# runs exist (Config.replay_enabled). The code is not kept in settings.cfg: a run is asked for, not a habit.

const TEXT_RUN_OK := "Run %s."
const TEXT_RUN_JUNK := "Not a code. Random run."

@onready var run_row: Control = %RunRow
@onready var run_edit: LineEdit = %RunEdit
@onready var run_hint: Label = %RunHint
@onready var week_button: Button = %WeekButton


## The run code hosting asks for: the field read as a code ("7K2M": case and spaces do not matter), "" when the
## field is blank or is not a code.
func get_run_code() -> String:
	return RunSeed.to_code(RunSeed.from_code(run_edit.text))


func _run_ready() -> void:
	run_row.visible = Config.replay_enabled
	run_edit.text = Config.run_code # `--run=<code>`, or what the last floor was opened with
	run_edit.text_changed.connect(func(_text: String) -> void: _refresh_run_hint())
	run_edit.text_submitted.connect(func(_text: String) -> void: _begin_host(true))
	week_button.pressed.connect(_on_week_pressed)
	_refresh_run_hint()


func _on_week_pressed() -> void:
	if _busy:
		return
	Sfx.play(&"ui_click")
	run_edit.text = RunSeed.to_code(RunSeed.weekly(int(Time.get_unix_time_from_system())))
	_refresh_run_hint()


## Next to the field: nothing while it is blank, "Run 7K2M." for a code, the flat line for anything else.
func _refresh_run_hint() -> void:
	if run_edit.text.strip_edges() == "":
		run_hint.text = ""
	elif get_run_code() != "":
		run_hint.text = TEXT_RUN_OK % get_run_code()
	else:
		run_hint.text = TEXT_RUN_JUNK


func _run_set_busy(busy: bool) -> void:
	run_edit.editable = not busy
	week_button.disabled = busy

# --- end M16 variety -------------------------------------------------------------------------------------------------
