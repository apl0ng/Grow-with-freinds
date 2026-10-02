extends Node
## Autoload "Config": access to the balance resource plus command-line test overrides.
##
##   Config.balance.starting_money
##   Config.balance.get_seed(&"budget")
##
## Command-line user args (after "--") understood here, mainly for automated tests:
##   --fast          growth 20x faster, rounds 60s (quick manual/automated testing)
##   --round-sec=N   override round length
##   --growth-mult=N multiply growth speed (N=10 -> stages 10x shorter)
##   --mute          no sound at all (Master bus muted; the pause menu Sound toggle is the saved version)

const BALANCE_PATH := "res://data/balance.tres"

var balance: BalanceConfig
## Extra multiplier on growth speed applied on top of upgrades (test override, default 1.0).
var growth_speed_override: float = 1.0
var user_args: Dictionary = {}
## M14: the alley and the van (FRIENDSLOP 8.1). On in a windowed run, off under --headless (the suites spawn workers on
## the floor and start with Enter as before); --lobby forces it on, --no-lobby off.
var lobby_enabled: bool = false
## M15: shift conditions, the market, strain unlocks, contracts (FRIENDSLOP 9). On in a windowed run, off under
## --headless (the suites play a plain, deterministic game); --replay forces it on, --no-replay off.
var replay_enabled: bool = false
## M16: the run code the host asked for (--run=<code>, or typed into the host panel). "" = the host rolls one.
## RunSeed.from_code() turns it into the run's seed (CONTRACTS "M16", Variety).
var run_code: String = ""

func _ready() -> void:
	balance = load(BALANCE_PATH) as BalanceConfig
	if balance == null:
		push_error("Config: could not load %s, using defaults" % BALANCE_PATH)
		balance = BalanceConfig.new()
	# Duplicate so runtime tweaks never write back into the .tres.
	balance = balance.duplicate(true)
	user_args = parse_user_args()
	_load_audio_prefs()
	_apply_overrides()

static func parse_user_args() -> Dictionary:
	var out: Dictionary = {}
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--"):
			var body := a.substr(2)
			var eq := body.find("=")
			if eq >= 0:
				out[body.substr(0, eq)] = body.substr(eq + 1)
			else:
				out[body] = true
	return out

## Master mute: the Sound toggle in the pause menu and `--mute` on the command line (playtests, screenshots).
## The preference is kept in AUDIO_CFG; `--mute` never saves.
const AUDIO_CFG := "user://audio.cfg"

func set_muted(muted: bool, save: bool = true) -> void:
	AudioServer.set_bus_mute(0, muted)
	if save:
		var cfg := ConfigFile.new()
		cfg.load(AUDIO_CFG)
		cfg.set_value("audio", "muted", muted)
		cfg.save(AUDIO_CFG)

func is_muted() -> bool:
	return AudioServer.is_bus_mute(0)

func _load_audio_prefs() -> void:
	var cfg := ConfigFile.new()
	if cfg.load(AUDIO_CFG) == OK and bool(cfg.get_value("audio", "muted", false)):
		AudioServer.set_bus_mute(0, true)

func _apply_overrides() -> void:
	lobby_enabled = DisplayServer.get_name() != "headless"
	if user_args.has("lobby"):
		lobby_enabled = true
	if user_args.has("no-lobby"):
		lobby_enabled = false
	replay_enabled = DisplayServer.get_name() != "headless"
	if user_args.has("replay"):
		replay_enabled = true
	if user_args.has("no-replay"):
		replay_enabled = false
	if user_args.has("run"):
		run_code = str(user_args["run"]).strip_edges()
	if user_args.has("mute"):
		set_muted(true, false)
	if user_args.has("fast"):
		growth_speed_override = 20.0
		balance.round_length_sec = 60.0
	if user_args.has("round-sec"):
		balance.round_length_sec = float(user_args["round-sec"])
	if user_args.has("growth-mult"):
		growth_speed_override = float(user_args["growth-mult"])

func has_arg(name: String) -> bool:
	return user_args.has(name)

func get_arg(name: String, default: Variant = null) -> Variant:
	return user_args.get(name, default)
