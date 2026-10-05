extends Node
## Settings (autoload, M19, owner: settings agent). The player's own preferences in user://settings.cfg: controls,
## video, audio, the onboarding guidance. Never synced.
##
## This file is the LEAD'S STUB: every method has the agreed signature and returns the default, so the onboarding
## and readability agents can call it before the settings branch merges. CONTRACTS.md "M19" / "Settings" is the
## specification. Do NOT add a class_name (it is an autoload).

## Emitted after a value changed (`key` is its name, e.g. &"fov").
signal changed(key: StringName)

const DEFAULTS := {
	&"mouse_sensitivity": 0.0025,
	&"invert_y": false,
	&"fov": 75.0,
	&"master_db": 0.0,
	&"sfx_db": 0.0,
	&"voice_db": 0.0,
	&"fullscreen": false,
	&"window_scale": 1.0,
	&"vsync": true,
	&"guidance": true,
}


## The value for `key` (`default` when the key is unknown).
func get_value(key: StringName, default: Variant = null) -> Variant:
	return DEFAULTS.get(key, default)


## Sets `key` and saves (the stub keeps nothing).
func set_value(key: StringName, _value: Variant) -> void:
	changed.emit(key)


## Every value back to its default.
func reset_to_defaults() -> void:
	pass
