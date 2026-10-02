extends Node
## Career (autoload, M15, owner: career agent). Each player's own record, kept in a local file and never synced: shifts
## worked, best shift reached, total deposited, contracts met, plants burnt, times bitten / shot / sent to the back
## room. It is what makes a second session worth starting (FRIENDSLOP.md section 9.3).
##
## This file is the LEAD'S STUB: every method has the agreed signature and does nothing, so other code (the alley
## board, the pause menu, the HUD) can call it before the career branch merges. CONTRACTS.md "M15 / Career" is the
## specification. Do NOT add a class_name (it is an autoload).

## Emitted after any record changed (the end of a shift, a contract met).
signal changed

## One record by key ("shifts", "best_round", "deposited", "contracts", "burns", "bitten", "shot", "backroom", or a
## strain id for that strain's deposits). 0 when unknown.
func get_record(_key: String) -> int:
	return 0

## A few flat lines for the alley board and the pause menu's Record page. Empty before the first shift.
func get_summary_lines() -> Array[String]:
	return []

## A flat job title that follows the best shift reached ("New hire", "Floor hand", ...).
func get_title() -> String:
	return ""
