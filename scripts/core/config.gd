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

const BALANCE_PATH := "res://data/balance.tres"

var balance: BalanceConfig
## Extra multiplier on growth speed applied on top of upgrades (test override, default 1.0).
var growth_speed_override: float = 1.0
var user_args: Dictionary = {}

func _ready() -> void:
	balance = load(BALANCE_PATH) as BalanceConfig
	if balance == null:
		push_error("Config: could not load %s, using defaults" % BALANCE_PATH)
		balance = BalanceConfig.new()
	# Duplicate so runtime tweaks never write back into the .tres.
	balance = balance.duplicate(true)
	user_args = parse_user_args()
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

func _apply_overrides() -> void:
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
