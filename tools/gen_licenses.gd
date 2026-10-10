extends SceneTree
## Writes THIRD_PARTY_LICENSES.txt at the project root from the engine's own licence data: Godot's MIT notice, every
## third-party component with its copyright lines and licence (the Open Sans font the theme falls back to among
## them), and the full text of every licence named. tools/export.ps1 puts the file in the shared zip; both licences
## (MIT, OFL-1.1) require their notice to travel with copies. Re-run after an engine upgrade:
##   godot --headless --path . -s res://tools/gen_licenses.gd

const OUT := "res://THIRD_PARTY_LICENSES.txt"


func _initialize() -> void:
	var lines := PackedStringArray()
	var version: Dictionary = Engine.get_version_info()
	lines.append("Grow With Friends is made with Godot Engine %s (https://godotengine.org)." % String(version.get("string", "")))
	lines.append("The game ships the engine and the components it is built with. Their notices follow.")
	lines.append("")
	lines.append("==== Godot Engine ====")
	lines.append("")
	lines.append(Engine.get_license_text())
	lines.append("")
	lines.append("==== Third-party components ====")
	lines.append("")
	for entry: Dictionary in Engine.get_copyright_info():
		lines.append("- %s" % String(entry.get("name", "?")))
		for part: Dictionary in entry.get("parts", []):
			for c: Variant in part.get("copyright", []):
				lines.append("    Copyright %s" % String(c))
			lines.append("    License: %s" % String(part.get("license", "?")))
	lines.append("")
	lines.append("==== Licence texts ====")
	var texts: Dictionary = Engine.get_license_info()
	var names := texts.keys()
	names.sort()
	for name: Variant in names:
		lines.append("")
		lines.append("---- %s ----" % String(name))
		lines.append("")
		lines.append(String(texts[name]))
	var f := FileAccess.open(ProjectSettings.globalize_path(OUT), FileAccess.WRITE)
	if f == null:
		push_error("gen_licenses: could not write %s" % OUT)
		quit(1)
		return
	f.store_string("\n".join(lines) + "\n")
	f.close()
	print("gen_licenses: wrote %s (%d components, %d licence texts)" % [OUT, Engine.get_copyright_info().size(), texts.size()])
	quit(0)
