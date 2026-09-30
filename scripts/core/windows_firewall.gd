extends Node
## Autoload "WindowsFirewall": lets Windows Firewall accept the game's inbound UDP traffic when the player HOSTS
## (M11, lead). Do NOT add a class_name (autoload). Windows only; everywhere else every call returns "skipped".
##
## Transport facts: the game hosts with ENetMultiplayerPeer (UDP only, no TCP anywhere) on the port the menu shows
## (Config.balance.default_port = 7777). Joining needs no inbound rule. LAN discovery (Lan autoload) listens on UDP
## 7778 on the JOINING side and is deliberately not covered here (Windows asks about it on its own the first time).
##
## Flow, run from the main menu's Host button (never at launch, never when joining):
##   Windows?  ->  a rule named "Grow With Friends Multiplayer UDP <port>" exists, enabled, UDP, that port, this
##   program?  ->  host.   Otherwise an elevated helper (one normal UAC prompt) adds or repairs the rule, the rule is
##   re-checked, then the game hosts. A declined prompt or a failure never blocks hosting: the player is told friends
##   may not get in, and no prompt is repeated until they press the menu's retry button.
## Dev runs (the editor binary sets OS.has_feature("editor") even without the editor UI; Engine.is_editor_hint()
## covers tool scripts) skip the check unless `--firewall` is passed; `--no-firewall` skips everywhere; headless
## always skips, so tests never touch netsh with side effects. Exported Windows builds are the primary case: there
## the rule is scoped to the exported .exe (OS.get_executable_path()).
## Elevation: the game never runs as administrator. A small PowerShell helper (text below, written to user:// at
## runtime so nothing has to be packaged) starts netsh through Start-Process -Verb RunAs (the standard UAC dialog)
## and writes one word to a result file. Every part of the command is fixed here (rule name, port, this executable's
## path); nothing from the network, saves, players or files reaches a command line.
## The rule: dir=in action=allow protocol=UDP localport=<port> program=<exe> profile=any enable=yes. Never "any
## port", never a range, never TCP (unused), the firewall itself is never touched.

## Every result (also the skipped ones): {"status": StringName, "message": String, "port": int}.
signal firewall_result(result: Dictionary)

const STATUS_SKIPPED: StringName = &"skipped"    # not Windows, headless, dev run without --firewall, --no-firewall
const STATUS_EXISTS: StringName = &"exists"      # a good rule was already there
const STATUS_CREATED: StringName = &"created"    # the elevated helper added / repaired it and the re-check agrees
const STATUS_DECLINED: StringName = &"declined"  # the UAC prompt was cancelled
const STATUS_FAILED: StringName = &"failed"      # anything else; `message` says what

const GAME_NAME := "Grow With Friends"
const RULE_NAME_FORMAT := GAME_NAME + " Multiplayer UDP %d"
const HELPER_PATH := "user://gwf_firewall_rule.ps1"
const RESULT_PATH := "user://gwf_firewall_result.txt"
## The UAC dialog waits for the user; give up (as "failed") after this long.
const HELPER_TIMEOUT_SEC: float = 180.0
const LOG_PREFIX := "[Firewall] "

const TEXT_DECLINED := "Windows Firewall may block friends from joining: administrator permission was declined. Hosting anyway."
const TEXT_FAILED := "Windows Firewall could not be configured (%s). Friends may not be able to join. Hosting anyway."
const TEXT_CREATED := "Windows Firewall now allows UDP port %d."

## The most recent result (see firewall_result).
var last_result: Dictionary = {}

var _declined_this_session: bool = false
var _busy: bool = false


# ---------------------------------------------------------------------------------------------
# Queries
# ---------------------------------------------------------------------------------------------

func is_windows() -> bool:
	return OS.get_name() == "Windows"


## True when pressing Host should run the check on this machine and build (see the header).
func is_check_enabled() -> bool:
	if not is_windows():
		return false
	if DisplayServer.get_name() == "headless" or Config.has_arg("no-firewall"):
		return false
	if Config.has_arg("firewall"):
		return true
	return not (OS.has_feature("editor") or Engine.is_editor_hint())


## Why the check is skipped here ("" when it runs).
func get_skip_reason() -> String:
	if not is_windows():
		return "not Windows (%s)" % OS.get_name()
	if DisplayServer.get_name() == "headless":
		return "headless"
	if Config.has_arg("no-firewall"):
		return "--no-firewall"
	if not Config.has_arg("firewall") and (OS.has_feature("editor") or Engine.is_editor_hint()):
		return "editor / dev run (pass --firewall to check anyway)"
	return ""


func get_rule_name(port: int) -> String:
	return RULE_NAME_FORMAT % port


## The executable the rule is scoped to: the exported game .exe, or the editor binary in a dev run.
func get_program_path() -> String:
	return OS.get_executable_path().replace("/", "\\")


## True while a helper (UAC prompt) is in flight.
func is_busy() -> bool:
	return _busy


## Read-only: asks netsh about the rule. {"exists": bool, "healthy": bool, "details": String, "raw": String}.
## Existence comes from netsh's exit code (locale independent); health is parsed from the English labels and is
## assumed when the labels are not recognisable (a localized Windows), so the player is never prompted in a loop.
func check_rule(port: int) -> Dictionary:
	if not is_windows():
		return {"exists": false, "healthy": false, "details": "not Windows", "raw": ""}
	var out: Array = []
	var rc := OS.execute("netsh", ["advfirewall", "firewall", "show", "rule", "name=%s" % get_rule_name(port), "verbose"], out, true)
	var raw := "\n".join(PackedStringArray(out))
	if rc != 0:
		return {"exists": false, "healthy": false, "details": "no rule (netsh exit %d)" % rc, "raw": raw}
	var parsed := parse_rule_output(raw, port, get_program_path())
	parsed["raw"] = raw
	return parsed


# ---------------------------------------------------------------------------------------------
# The check itself
# ---------------------------------------------------------------------------------------------

## Makes sure the inbound UDP rule for `port` exists (one UAC prompt at most, none after a decline unless `force`).
## Coroutine: `var r: Dictionary = await WindowsFirewall.ensure_multiplayer_firewall_access(port)`.
func ensure_multiplayer_firewall_access(port: int = 7777, force: bool = false) -> Dictionary:
	if not is_windows():
		return _finish(STATUS_SKIPPED, "not Windows", port, false)
	_log("Windows detected.")
	var skip := get_skip_reason()
	if skip != "":
		return _finish(STATUS_SKIPPED, skip, port, false)
	if _busy:
		return _finish(STATUS_FAILED, "a firewall request is already running", port, true)
	_log("Checking multiplayer firewall rule...")
	var chk := check_rule(port)
	if bool(chk.get("healthy", false)):
		_log("Firewall rule already exists.")
		return _finish(STATUS_EXISTS, String(chk.get("details", "")), port, true)
	if _declined_this_session and not force:
		return _finish(STATUS_DECLINED, TEXT_DECLINED, port, true)
	var repair := bool(chk.get("exists", false))
	if repair:
		_log("Firewall rule exists but is not usable (%s); repairing." % String(chk.get("details", "")))
	_log("Requesting administrator permission to add firewall rule.")
	var word := await _run_helper(port, repair)
	var status := STATUS_FAILED
	var message := word
	if word == "created":
		var again := check_rule(port)
		if bool(again.get("healthy", false)):
			_log("Firewall rule created successfully for UDP port %d." % port)
			status = STATUS_CREATED
			message = TEXT_CREATED % port
		else:
			message = "the rule was reported created but the re-check does not see it (%s)" % String(again.get("details", ""))
			_log("Failed to configure Windows Firewall: %s" % message)
	elif word == "declined":
		_log("User declined administrator permission.")
		_declined_this_session = true
		status = STATUS_DECLINED
		message = TEXT_DECLINED
	else:
		var reason := word.trim_prefix("failed:").strip_edges()
		_log("Failed to configure Windows Firewall: %s" % reason)
		message = TEXT_FAILED % reason
	return _finish(status, message, port, true)


## The menu's retry: forgets a decline and asks again.
func request_again(port: int = 7777) -> Dictionary:
	_declined_this_session = false
	return await ensure_multiplayer_firewall_access(port, true)


# ---------------------------------------------------------------------------------------------
# Pure helpers (tests)
# ---------------------------------------------------------------------------------------------

## Parses `netsh advfirewall firewall show rule name=... verbose` output for one rule.
## English labels are read when present; when none of them is recognisable the rule is assumed usable.
static func parse_rule_output(text: String, port: int, program: String) -> Dictionary:
	var fields: Dictionary = {}
	for line in text.split("\n"):
		var idx := line.find(":")
		if idx <= 0:
			continue
		var key := line.left(idx).strip_edges().to_lower()
		var value := line.substr(idx + 1).strip_edges()
		if key != "" and not fields.has(key):
			fields[key] = value
	var known := fields.has("enabled") or fields.has("protocol") or fields.has("localport") or fields.has("action")
	if not known:
		return {"exists": true, "healthy": true, "details": "rule present (labels not recognised: assumed usable)"}
	var problems: PackedStringArray = []
	if fields.has("enabled") and String(fields["enabled"]).to_lower() != "yes":
		problems.append("disabled")
	if fields.has("direction") and String(fields["direction"]).to_lower() != "in":
		problems.append("not inbound")
	if fields.has("protocol") and String(fields["protocol"]).to_upper() != "UDP":
		problems.append("protocol %s" % fields["protocol"])
	if fields.has("localport") and String(fields["localport"]).strip_edges() != str(port):
		problems.append("port %s" % fields["localport"])
	if fields.has("action") and String(fields["action"]).to_lower() != "allow":
		problems.append("action %s" % fields["action"])
	if fields.has("program") and program != "":
		var p := String(fields["program"]).replace("/", "\\").to_lower()
		var mine := program.replace("/", "\\").to_lower()
		if p != "any" and p != mine:
			problems.append("program %s" % fields["program"])
	if problems.is_empty():
		return {"exists": true, "healthy": true, "details": "enabled, UDP %d, allow, this program" % port}
	return {"exists": true, "healthy": false, "details": ", ".join(problems)}


## The one-word result file -> a status word: "created" | "declined" | "failed: <reason>".
static func classify_result_text(text: String) -> String:
	var t := text.strip_edges()
	if t == "created" or t == "declined":
		return t
	if t == "":
		return "failed: no result from the helper"
	return t if t.begins_with("failed:") else "failed: " + t


## The PowerShell helper (Windows PowerShell 5.1 and 7). It runs UNELEVATED; only the netsh line inside runs elevated,
## through the standard UAC prompt. Parameters come from this autoload alone.
static func build_helper_script() -> String:
	return """param([string]$RuleName, [int]$Port, [string]$Program, [string]$ResultFile, [int]$Repair = 0)
$ErrorActionPreference = 'Stop'
function Out-Result([string]$Text) { Set-Content -LiteralPath $ResultFile -Value $Text -Encoding ASCII }
try {
    if ($Port -lt 1024 -or $Port -gt 65535) { Out-Result 'failed: bad port'; exit 0 }
    $add = "netsh advfirewall firewall add rule name=`"$RuleName`" dir=in action=allow protocol=UDP localport=$Port enable=yes profile=any"
    if ($Program) { $add += " program=`"$Program`"" }
    $line = $add
    if ($Repair -eq 1) { $line = "netsh advfirewall firewall delete rule name=`"$RuleName`" & " + $add }
    # One UAC prompt: an elevated, hidden cmd.exe runs the netsh line(s); the exit code is the add rule's.
    $p = Start-Process -FilePath 'cmd.exe' -ArgumentList "/d /c $line" -Verb RunAs -Wait -PassThru -WindowStyle Hidden
    if ($p.ExitCode -eq 0) { Out-Result 'created' } else { Out-Result "failed: netsh exit code $($p.ExitCode)" }
} catch {
    $m = $_.Exception.Message
    if ($m -match 'canceled by the user' -or $m -match '1223') { Out-Result 'declined' } else { Out-Result ('failed: ' + $m) }
}
"""


# ---------------------------------------------------------------------------------------------
# Internals
# ---------------------------------------------------------------------------------------------

## Writes the helper, runs it without blocking the game, waits for the result file (the UAC prompt sits in between).
func _run_helper(port: int, repair: bool) -> String:
	_busy = true
	var helper := ProjectSettings.globalize_path(HELPER_PATH)
	var result_file := ProjectSettings.globalize_path(RESULT_PATH)
	var f := FileAccess.open(HELPER_PATH, FileAccess.WRITE)
	if f == null:
		_busy = false
		return "failed: cannot write the helper script (%s)" % error_string(FileAccess.get_open_error())
	f.store_string(build_helper_script())
	f.close()
	if FileAccess.file_exists(RESULT_PATH):
		DirAccess.remove_absolute(result_file)
	var args := PackedStringArray([
		"-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-WindowStyle", "Hidden", "-File", helper,
		"-RuleName", get_rule_name(port), "-Port", str(port), "-Program", get_program_path(),
		"-ResultFile", result_file, "-Repair", "1" if repair else "0",
	])
	var pid := OS.create_process("powershell.exe", args, false)
	if pid <= 0:
		_busy = false
		return "failed: could not start powershell.exe"
	var waited := 0.0
	while OS.is_process_running(pid) and waited < HELPER_TIMEOUT_SEC:
		await get_tree().create_timer(0.2).timeout
		waited += 0.2
	if OS.is_process_running(pid):
		OS.kill(pid)
		_busy = false
		return "failed: the permission prompt timed out"
	var word := "failed: no result from the helper"
	if FileAccess.file_exists(RESULT_PATH):
		word = classify_result_text(FileAccess.get_file_as_string(RESULT_PATH))
		DirAccess.remove_absolute(result_file)
	_busy = false
	return word


func _finish(status: StringName, message: String, port: int, loud: bool) -> Dictionary:
	last_result = {"status": status, "message": message, "port": port}
	if loud or status != STATUS_SKIPPED:
		pass
	if status == STATUS_SKIPPED:
		_log("Check skipped: %s." % message)
	firewall_result.emit(last_result)
	return last_result


func _log(text: String) -> void:
	print(LOG_PREFIX + text)
