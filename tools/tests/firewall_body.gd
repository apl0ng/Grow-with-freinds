extends "res://tools/tests/smoke_base.gd"
## M11 lead suite: the Windows Firewall helper (no elevation, no rule changes: headless always skips the real flow;
## the pure parsers are exercised with canned netsh output, and on Windows a read-only netsh query runs).
##   godot --headless --path . -s res://tools/tests/run_test.gd -- --body=res://tools/tests/firewall_body.gd --port=7853

const SAMPLE_GOOD := """
Rule Name:                            Grow With Friends Multiplayer UDP 7777
----------------------------------------------------------------------
Enabled:                              Yes
Direction:                            In
Profiles:                             Domain,Private,Public
Grouping:
LocalIP:                              Any
RemoteIP:                             Any
Protocol:                             UDP
LocalPort:                            7777
RemotePort:                           Any
Edge traversal:                       No
Program:                              C:\\Games\\GrowWithFriends.exe
InterfaceTypes:                       Any
Security:                             NotRequired
Rule source:                          Local Setting
Action:                               Allow
Ok.
"""

const SAMPLE_LOCALIZED := """
Regelname:                            Grow With Friends Multiplayer UDP 7777
----------------------------------------------------------------------
Aktiviert:                            Ja
Richtung:                             Eingehend
Protokoll:                            UDP
Lokaler Port:                         7777
Aktion:                               Zulassen
OK.
"""


func _run() -> void:
	_label = "firewall"
	await get_tree().process_frame
	var fw: Node = WindowsFirewall
	var results: Array = []
	fw.firewall_result.connect(func(r: Dictionary) -> void: results.append(r))

	step("skip rules")
	check(fw.get_rule_name(7777) == "Grow With Friends Multiplayer UDP 7777", "rule name")
	check(not fw.is_check_enabled(), "headless: the check is disabled")
	check(fw.get_skip_reason() != "", "headless: a skip reason is given (%s)" % fw.get_skip_reason())
	var r: Dictionary = await fw.ensure_multiplayer_firewall_access(7777)
	check(r["status"] == fw.STATUS_SKIPPED, "ensure() skips headless (%s)" % r.get("message", ""))
	check(results.size() == 1 and results[0]["status"] == fw.STATUS_SKIPPED, "firewall_result emitted once")
	check(fw.last_result == r, "last_result kept")
	check(not fw.is_busy(), "not busy after a skip")

	step("parser: a healthy rule")
	var exe := "C:\\Games\\GrowWithFriends.exe"
	var p: Dictionary = fw.parse_rule_output(SAMPLE_GOOD, 7777, exe)
	check(p["exists"] and p["healthy"], "good rule is healthy (%s)" % p["details"])
	p = fw.parse_rule_output(SAMPLE_GOOD, 7777, "c:/games/growwithfriends.exe")
	check(p["healthy"], "program compared case- and slash-insensitively")
	p = fw.parse_rule_output(SAMPLE_GOOD, 7777, "")
	check(p["healthy"], "no program to compare: still healthy")

	step("parser: unusable rules")
	p = fw.parse_rule_output(SAMPLE_GOOD.replace("Enabled:                              Yes", "Enabled:                              No"), 7777, exe)
	check(p["exists"] and not p["healthy"] and String(p["details"]).contains("disabled"), "disabled rule is not healthy")
	p = fw.parse_rule_output(SAMPLE_GOOD.replace("LocalPort:                            7777", "LocalPort:                            7778"), 7777, exe)
	check(not p["healthy"] and String(p["details"]).contains("port"), "wrong port is not healthy")
	p = fw.parse_rule_output(SAMPLE_GOOD.replace("Protocol:                             UDP", "Protocol:                             TCP"), 7777, exe)
	check(not p["healthy"] and String(p["details"]).contains("protocol"), "TCP rule is not healthy")
	p = fw.parse_rule_output(SAMPLE_GOOD.replace("Action:                               Allow", "Action:                               Block"), 7777, exe)
	check(not p["healthy"] and String(p["details"]).contains("action"), "block rule is not healthy")
	p = fw.parse_rule_output(SAMPLE_GOOD, 7777, "C:\\Other\\Old.exe")
	check(not p["healthy"] and String(p["details"]).contains("program"), "another program's rule is not healthy (repair)")
	p = fw.parse_rule_output(SAMPLE_GOOD.replace("Program:                              C:\\Games\\GrowWithFriends.exe", "Program:                              Any"), 7777, exe)
	check(p["healthy"], "a rule for any program is accepted")
	p = fw.parse_rule_output(SAMPLE_LOCALIZED, 7777, exe)
	check(p["exists"] and p["healthy"] and String(p["details"]).contains("assumed"), "localized labels: assumed usable, never a prompt loop")

	step("result words")
	check(fw.classify_result_text("created\r\n") == "created", "created")
	check(fw.classify_result_text(" declined ") == "declined", "declined")
	check(fw.classify_result_text("") == "failed: no result from the helper", "empty -> failed")
	check(fw.classify_result_text("failed: netsh exit code 1") == "failed: netsh exit code 1", "failed passthrough")
	check(fw.classify_result_text("garbage") == "failed: garbage", "unknown -> failed")

	step("helper script")
	var script: String = fw.build_helper_script()
	check(script.contains("-Verb RunAs") and script.contains("protocol=UDP") and script.contains("localport=$Port") and script.contains("dir=in action=allow"), "helper: one UAC prompt, inbound allow UDP on the port")
	check(not script.contains("localport=any") and not script.contains("-") == false, "helper never opens any port")
	check(script.contains("canceled by the user") and script.contains("declined"), "helper reports a declined prompt")
	check(not script.to_lower().contains("set currentprofile state off") and not script.to_lower().contains("firewall set"), "helper never touches the firewall state")

	step("read-only query on this machine")
	if fw.is_windows():
		var chk: Dictionary = fw.check_rule(7777)
		check(chk.has("exists") and chk.has("healthy") and chk.has("details"), "check_rule returns the fields (%s)" % chk.get("details", ""))
		check(fw.get_program_path().contains("\\"), "program path is a Windows path (%s)" % fw.get_program_path())
	else:
		var chk2: Dictionary = fw.check_rule(7777)
		check(not chk2["exists"], "non-Windows: check_rule says no rule")
	finish()
