extends Node
## Autoload "Events": random shift events (PLAN.md M10, events agent). Do NOT add a class_name (autoload).
##
## LEAD STUB: the surface below is the contract (CONTRACTS.md "Events"); the events agent replaces the bodies.
## Server-authoritative: only the host schedules / starts / ends events and broadcasts them (call_local RPCs);
## every peer gets the signals. Story (ui agent) turns the signals into Boss lines; the HUD shows a banner.
## Events run only while GameState.is_playing() and only when are_events_enabled():
##   Config.balance.events_enabled, not `--no-events`, and (a real window or `--events`), so every existing
##   headless suite keeps its deterministic shifts. Tests that want events pass `--events`.

## Every peer: an event began. params: inspection {"seconds"}, power_cut {"max_seconds"}, audit {"raise"}, rat {}.
signal event_started(kind: StringName, params: Dictionary)
## Every peer: the active event is over (timer, fixed, or the shift ended).
signal event_ended(kind: StringName)
## Every peer: the room's mains power changed (power cut started / fuse box reset).
signal power_changed(on: bool)

const EVENT_INSPECTION: StringName = &"inspection"
const EVENT_POWER_CUT: StringName = &"power_cut"
const EVENT_AUDIT: StringName = &"audit"
const EVENT_RAT: StringName = &"rat"

## The running event (&"" when none). Synced.
var active_event: StringName = &""
## False during a power cut. Synced.
var power_on: bool = true

func is_power_on() -> bool:
	return power_on

## True while an event runs (`kind` &"" = any).
func is_event_active(kind: StringName = &"") -> bool:
	return active_event != &"" and (kind == &"" or active_event == kind)

## Seconds until the active event ends on its own (0 when none / open-ended).
func get_event_time_left() -> float:
	return 0.0

## Whether the host schedules random events in this session (see the header).
func are_events_enabled() -> bool:
	if not Config.balance.events_enabled or Config.has_arg("no-events"):
		return false
	return Config.has_arg("events") or DisplayServer.get_name() != "headless"

## SERVER ONLY. Starts `kind` now (false if one is already running / not playing). Tests + the host debug menu.
func server_start_event(_kind: StringName, _params: Dictionary = {}) -> bool:
	return false

## SERVER ONLY. Ends the running event now.
func server_end_event() -> void:
	pass

## Host only (ignored elsewhere): start an event from the UI / debug (validated like a request).
func request_event(_kind: StringName) -> void:
	pass
