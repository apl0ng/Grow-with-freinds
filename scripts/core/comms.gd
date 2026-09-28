extends Node
## Autoload "Comms": pings and text chat (PLAN.md M10, ui agent). Do NOT add a class_name (autoload).
##
## LEAD STUB: the surface below is the contract (CONTRACTS.md "Comms"); the ui agent replaces the bodies.
## Both are peer-to-peer cosmetics relayed by the server (@rpc("any_peer", "call_local", ...)): a ping is a
## world position everyone marks for a few seconds; chat is a short sanitized line. Rate limited per sender on
## every receiver (PING_MIN_GAP_SEC / CHAT_MIN_GAP_SEC); oversized or garbage payloads are dropped silently.

## Every peer: `peer_id` pinged `position` (world space).
signal ping_received(peer_id: int, position: Vector3)
## Every peer: `peer_id` said `text` (already sanitized, at most CHAT_MAX_CHARS).
signal chat_received(peer_id: int, text: String)

const CHAT_MAX_CHARS: int = 120
const PING_MIN_GAP_SEC: float = 0.8
const CHAT_MIN_GAP_SEC: float = 0.5
## Pings further than this from the sender's player are refused (garbage / cheating).
const PING_MAX_RANGE: float = 40.0

## Local player: mark `world_position` for everyone (bound to the "ping" action; the HUD picks the point).
func ping(_world_position: Vector3) -> void:
	pass

## Local player: send a chat line (the HUD's chat box calls this).
func say(_text: String) -> void:
	pass

## Strips control / invisible characters, collapses whitespace and clamps to CHAT_MAX_CHARS ("" if nothing left).
static func sanitize_chat(text: String) -> String:
	var clean := ""
	for i in mini(text.length(), CHAT_MAX_CHARS * 4):
		var code := text.unicode_at(i)
		if code == 0x20 or code == 0x09 or code == 0x0A or code == 0x0D or code == 0xA0:
			clean += " "
		elif code >= 0x20 and not (code >= 0x7F and code <= 0x9F) and not (code >= 0x200B and code <= 0x200F) \
				and not (code >= 0x2028 and code <= 0x202E) and not (code >= 0x2060 and code <= 0x206F) \
				and code != 0xFEFF:
			clean += String.chr(code)
	while clean.contains("  "):
		clean = clean.replace("  ", " ")
	return clean.strip_edges().left(CHAT_MAX_CHARS)
