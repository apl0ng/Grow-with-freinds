class_name Contracts
extends RefCounted
## M15 career: the catalog of jobs (FRIENDSLOP 9.3, CONTRACTS.md "Career"). One optional job per shift, rolled by the
## host (GameState's "M15 career" region does the rolling, the counting and the paying; this file is data and pure
## functions, static, no state).
##
## A job as it travels (GameState.contract, a plain Dictionary so it goes over the wire as it is):
##   id        String    the catalog id ("cured", "strain", ...)
##   text      String    the flat copy with its numbers filled in ("three cured bundles"); the HUD prefixes "Job: "
##   goal      int       what `progress` has to reach (1 for a yes / no job, dollars for "cash")
##   progress  int       counted on the host
##   reward    int       Config.balance.contract_reward at the time of the roll
##   done      bool      met and paid (once)
##   failed    bool      it can no longer be met this shift (a write-up, somebody shot, the leak ran out, time)
##   round     int       the shift it belongs to
##   strain    String    "strain" only: the strain to deposit
##
## The catalog (id: what, how it is counted, when it is judged, what it needs):
##   cured    "three cured bundles"                     cured deposits (any worker)          on the spot
##   strain   "three bundles of Purple Haze"            deposits of that strain              on the spot
##   hall     "harvest three trays in the grow hall"    harvests of GrowPlot7..10            on the spot
##   early    "make the payment with a minute on the clock"   deposits cover the payment with 60 s left   on the spot
##   clean    "no write-ups this shift"                 fails on the first write-up          when the shift ends, paid
##   cash     "end the shift with more than $360 on hand"     cash on hand                   when the shift ends, paid
##   burn     "burn one that walks"                     Hostiles.hostile_died with a worker  on the spot   needs a hostile plant
##   leak     "patch a leak inside ten seconds"         Events.leak_resolved(patched) in time on the spot  needs a leak
##   driveby  "nobody knocked down in a drive-by"       a drive-by ends with nobody shot     when it ends  needs a drive-by
## Goals of the counted jobs grow with the team: base + one per extra worker.
##
## Jobs that need something the shift may never bring ("burn", "leak", "driveby") are only offered when it can happen
## at all (events on in this session; a strain on sale that can turn hostile); "clean" is only offered with events on
## as well (without inspections it could not be lost). When half the shift has gone
## without it the host swaps the job for one that needs nothing (fallback_id: "clean" while nobody has been written
## up, else "cash"), so the reward is never out of reach because of the dice.

const JUDGE_SPOT: StringName = &"spot"
const JUDGE_END: StringName = &"end"
const NEED_NONE: StringName = &""
const NEED_HOSTILE: StringName = &"hostile"
const NEED_LEAK: StringName = &"leak"
const NEED_DRIVEBY: StringName = &"driveby"

const ID_CURED: StringName = &"cured"
const ID_STRAIN: StringName = &"strain"
const ID_HALL: StringName = &"hall"
const ID_EARLY: StringName = &"early"
const ID_CLEAN: StringName = &"clean"
const ID_CASH: StringName = &"cash"
const ID_BURN: StringName = &"burn"
const ID_LEAK: StringName = &"leak"
const ID_DRIVEBY: StringName = &"driveby"

## "leak": the patch has to be on within this many seconds of the leak starting.
const LEAK_SECONDS: float = 10.0
## "early": the deposits have to cover the payment with this many seconds left.
const EARLY_SECONDS: float = 60.0
## "cash": the target is the cash on hand at the roll plus this fraction of what is still owed (at least CASH_MIN_GAIN),
## rounded up to CASH_ROUND dollars.
const CASH_QUOTA_FRACTION: float = 0.6
const CASH_MIN_GAIN: int = 30
const CASH_ROUND: int = 10
## A job that needs something is swapped once this fraction of the shift has gone without it.
const SWAP_AT_FRACTION: float = 0.5
## Longest text a peer accepts for a job (the host's catalog never comes near it).
const TEXT_MAX: int = 96
## The grow hall's index in Room.get_play_areas().
const HALL_AREA_INDEX: int = 1

## id, text (format), base goal, extra goal per worker beyond the first, judge, need, weight in the roll.
const CATALOG: Array[Dictionary] = [
	{"id": ID_CURED, "text": "%s cured bundles", "base": 3, "per_extra": 1, "judge": JUDGE_SPOT, "need": NEED_NONE, "weight": 3},
	{"id": ID_STRAIN, "text": "%s bundles of %s", "base": 3, "per_extra": 1, "judge": JUDGE_SPOT, "need": NEED_NONE, "weight": 3},
	{"id": ID_HALL, "text": "harvest %s trays in the grow hall", "base": 3, "per_extra": 1, "judge": JUDGE_SPOT, "need": NEED_NONE, "weight": 3},
	{"id": ID_EARLY, "text": "make the payment with a minute on the clock", "base": 1, "per_extra": 0, "judge": JUDGE_SPOT, "need": NEED_NONE, "weight": 2},
	{"id": ID_CLEAN, "text": "no write-ups this shift", "base": 1, "per_extra": 0, "judge": JUDGE_END, "need": NEED_NONE, "weight": 3},
	{"id": ID_CASH, "text": "end the shift with more than %s on hand", "base": 1, "per_extra": 0, "judge": JUDGE_END, "need": NEED_NONE, "weight": 3},
	{"id": ID_BURN, "text": "burn one that walks", "base": 1, "per_extra": 0, "judge": JUDGE_SPOT, "need": NEED_HOSTILE, "weight": 2},
	{"id": ID_LEAK, "text": "patch a leak inside ten seconds", "base": 1, "per_extra": 0, "judge": JUDGE_SPOT, "need": NEED_LEAK, "weight": 2},
	{"id": ID_DRIVEBY, "text": "nobody knocked down in a drive-by", "base": 1, "per_extra": 0, "judge": JUDGE_SPOT, "need": NEED_DRIVEBY, "weight": 2},
]

const NUMBER_WORDS: PackedStringArray = ["no", "one", "two", "three", "four", "five", "six", "seven", "eight", "nine", "ten",
		"eleven", "twelve"]

## HUD / report copy ("%s" = the job's text). Flat: no cheer.
const TEXT_HUD := "Job: %s"
const TEXT_HUD_COUNT := "Job: %s %d / %d"
const TEXT_HUD_PAID := " · paid"
const TEXT_HUD_FAILED := " · failed"
const TEXT_REPORT_DONE := "Job: %s. Done. %s paid."
const TEXT_REPORT_FAILED := "Job: %s. Failed."
const TEXT_REPORT_OPEN := "Job: %s. Not done."


## Every catalog id, in catalog order.
static func ids() -> Array[StringName]:
	var out: Array[StringName] = []
	for def: Dictionary in CATALOG:
		out.append(def["id"])
	return out


## The catalog entry of `id` ({} when unknown).
static func get_def(id: StringName) -> Dictionary:
	for def: Dictionary in CATALOG:
		if def["id"] == id:
			return def
	return {}


static func has(id: StringName) -> bool:
	return not get_def(id).is_empty()


## &"spot" (paid the moment it is met) or &"end" (judged when the shift ends); &"" when unknown.
static func get_judge(id: StringName) -> StringName:
	return get_def(id).get("judge", &"")


## What the job needs before it can be met at all: &"" (nothing), &"hostile", &"leak", &"driveby".
static func get_need(id: StringName) -> StringName:
	return get_def(id).get("need", NEED_NONE)


## "three" for 3, "14" beyond twelve.
static func number_words(n: int) -> String:
	if n >= 0 and n < NUMBER_WORDS.size():
		return NUMBER_WORDS[n]
	return str(n)


## The goal of a counted job for a team of `team` workers.
static func goal_for(id: StringName, team: int) -> int:
	var def := get_def(id)
	if def.is_empty():
		return 1
	return maxi(int(def["base"]) + int(def["per_extra"]) * maxi(team - 1, 0), 1)


## "cash": the target for `money` on hand and `owed` still to deposit.
static func cash_goal(money: int, owed: int) -> int:
	var gain := maxi(int(round(float(maxi(owed, 0)) * CASH_QUOTA_FRACTION)), CASH_MIN_GAIN)
	var raw := maxi(money, 0) + gain
	@warning_ignore("integer_division")
	return ((raw + CASH_ROUND - 1) / CASH_ROUND) * CASH_ROUND


## A fresh job. `ctx`: {"team": int, "round": int, "money": int, "owed": int, "reward": int, "strain": StringName
## (for "strain"; &"" = Budget Bud or the first seed)}. {} for an unknown id.
static func build(id: StringName, ctx: Dictionary) -> Dictionary:
	var def := get_def(id)
	if def.is_empty():
		return {}
	var team := int(ctx.get("team", 1))
	var goal := goal_for(id, team)
	var text := String(def["text"])
	var out := {
		"id": String(id), "text": text, "goal": goal, "progress": 0, "reward": maxi(int(ctx.get("reward", 0)), 0),
		"done": false, "failed": false, "round": int(ctx.get("round", 1)),
	}
	match id:
		ID_CURED, ID_HALL:
			out["text"] = text % number_words(goal)
		ID_STRAIN:
			var strain := StringName(str(ctx.get("strain", "")))
			var seed_def: SeedDef = Config.balance.get_seed(strain) if strain != &"" else null
			if seed_def == null and not Config.balance.seeds.is_empty():
				seed_def = Config.balance.seeds[0]
			out["strain"] = String(seed_def.id) if seed_def != null else ""
			out["text"] = text % [number_words(goal), seed_def.display_name if seed_def != null else "anything"]
		ID_CASH:
			goal = cash_goal(int(ctx.get("money", 0)), int(ctx.get("owed", 0)))
			out["goal"] = goal
			out["text"] = text % format_money(goal)
	return out


## The ids the host may roll from. `ctx`: {"events": bool (random events run in this session), "can_mutate": bool (a
## strain on sale can turn hostile), "early_ok": bool (the shift is long enough for "early" to mean anything; default
## true)}.
static func pool(ctx: Dictionary) -> Array[StringName]:
	var out: Array[StringName] = []
	for def: Dictionary in CATALOG:
		if def["id"] == ID_EARLY and not bool(ctx.get("early_ok", true)):
			continue
		if def["id"] == ID_CLEAN and not bool(ctx.get("events", false)):
			continue # nobody is written up on a floor the Boss never walks: it would be free money
		match def["need"]:
			NEED_LEAK, NEED_DRIVEBY:
				if not bool(ctx.get("events", false)):
					continue
			NEED_HOSTILE:
				if not bool(ctx.get("can_mutate", false)):
					continue
		out.append(def["id"])
	return out


## A weighted pick from pool(ctx) that is never `previous` (the last shift's job) when anything else is on offer.
static func roll(ctx: Dictionary, rng: RandomNumberGenerator, previous: StringName = &"") -> StringName:
	var candidates := pool(ctx)
	if candidates.size() > 1:
		candidates.erase(previous)
	if candidates.is_empty():
		return &""
	var total := 0
	for id in candidates:
		total += int(get_def(id)["weight"])
	var pick := rng.randi_range(1, maxi(total, 1))
	for id in candidates:
		pick -= int(get_def(id)["weight"])
		if pick <= 0:
			return id
	return candidates[0]


## The job that replaces one whose event never came: "clean" while nobody has been written up, else "cash".
static func fallback_id(any_write_up: bool) -> StringName:
	return ID_CASH if any_write_up else ID_CLEAN


## True for a job that counts up to a goal above one (the HUD then shows "1 / 3").
static func is_counted(contract: Dictionary) -> bool:
	var id := StringName(str(contract.get("id", "")))
	return int(contract.get("goal", 1)) > 1 and id != ID_CASH


## The HUD line ("" without a job): "Job: three cured bundles 1 / 3", " · paid" / " · failed" once it is settled.
static func hud_text(contract: Dictionary) -> String:
	if contract.is_empty() or String(contract.get("text", "")) == "":
		return ""
	var out: String
	if is_counted(contract):
		out = TEXT_HUD_COUNT % [String(contract["text"]), int(contract.get("progress", 0)), int(contract.get("goal", 1))]
	else:
		out = TEXT_HUD % String(contract["text"])
	if bool(contract.get("done", false)):
		out += TEXT_HUD_PAID
	elif bool(contract.get("failed", false)):
		out += TEXT_HUD_FAILED
	return out


## The shift report's line ("" without a job).
static func report_text(contract: Dictionary) -> String:
	if contract.is_empty() or String(contract.get("text", "")) == "":
		return ""
	var text := String(contract["text"])
	if bool(contract.get("done", false)):
		return TEXT_REPORT_DONE % [text, format_money(int(contract.get("reward", 0)))]
	if bool(contract.get("failed", false)):
		return TEXT_REPORT_FAILED % text
	return TEXT_REPORT_OPEN % text


## What arrived over the wire as a job, with every field typed and clamped ({} for anything that is not one).
static func parse(raw: Variant) -> Dictionary:
	if not raw is Dictionary or (raw as Dictionary).is_empty():
		return {}
	var d: Dictionary = raw
	var id := str(d.get("id", "")).left(24)
	var text := str(d.get("text", "")).left(TEXT_MAX).replace("\n", " ")
	if id == "" or text == "":
		return {}
	var goal := maxi(int(d.get("goal", 1)), 1)
	var out := {
		"id": id, "text": text, "goal": goal, "progress": clampi(int(d.get("progress", 0)), 0, goal),
		"reward": maxi(int(d.get("reward", 0)), 0), "done": bool(d.get("done", false)), "failed": bool(d.get("failed", false)),
		"round": maxi(int(d.get("round", 1)), 1),
	}
	if d.has("strain"):
		out["strain"] = str(d["strain"]).left(24)
	return out


## "$1,234" (the same format as HUD.format_money; kept here so this file loads no UI script).
static func format_money(amount: int) -> String:
	var digits := str(absi(amount))
	var grouped := ""
	var count := 0
	for i in range(digits.length() - 1, -1, -1):
		grouped = digits[i] + grouped
		count += 1
		if count % 3 == 0 and i > 0:
			grouped = "," + grouped
	return ("-$" if amount < 0 else "$") + grouped
