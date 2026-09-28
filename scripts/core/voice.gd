extends Node
## Autoload "Voice": proximity voice chat (PLAN.md M10, voice agent). Do NOT add a class_name (autoload).
##
## LEAD STUB: the surface below is the contract (CONTRACTS.md "Voice"); the voice agent replaces the bodies.
## Other systems only use this API (HUD: speaking marks; pause menu: settings; nothing else).
##   - Capture: AudioStreamMicrophone on a muted "Mic" bus with an AudioEffectCapture (needs
##     audio/driver/enable_input in project.godot). Frames: 20 ms, 16 kHz mono, mu-law 8-bit.
##   - Transport: @rpc("any_peer", "unreliable") frames relayed by the server; rate + size limited.
##   - Playback: one AudioStreamPlayer3D (AudioStreamGenerator) per remote peer at that player's head.
##   - Back room (GameState.is_in_backroom): back-room workers hear each other at full volume (2D) and the floor
##     faintly; the floor never hears the back room.

## Every peer: `peer_id` started / stopped being heard (remote) or transmitting (local).
signal speaking_changed(peer_id: int, speaking: bool)
## Local mic level 0..1 for a meter (emitted at most ~20 times per second while capturing).
signal input_level_changed(level: float)

## Master switch for capturing the local microphone (settings).
var enabled: bool = true
## true = hold `push_to_talk` to transmit; false = open mic with an energy gate.
var push_to_talk: bool = true
## Volume of every remote voice (dB, applied to the Voice bus).
var output_volume_db: float = 0.0
## Multiplier on the captured signal before encoding.
var input_gain: float = 1.0
## True while the local microphone is being sent.
var transmitting: bool = false

## True while `peer_id` is heard on this peer (or, for the local id, while transmitting).
func is_speaking(_peer_id: int) -> bool:
	return false

func is_transmitting() -> bool:
	return transmitting

## Last measured local input level 0..1.
func get_input_level() -> float:
	return 0.0

## True when a microphone could be opened on this machine (false headless / no input device).
func is_mic_available() -> bool:
	return false

## Peers currently heard, sorted.
func get_speaking_peers() -> Array[int]:
	return []
