extends SceneTree
## Generates placeholder toon materials + UI theme at their final paths (the art agent restyles them in place).
##   godot --headless --path . -s res://tools/gen_placeholder_art.gd

const MATERIALS := {
	"red": Color("ff5d5d"), "orange": Color("ff9f43"), "yellow": Color("ffd43b"), "lime": Color("a9e34b"),
	"green": Color("51cf66"), "teal": Color("38d9a9"), "blue": Color("4dabf7"), "purple": Color("9775fa"),
	"pink": Color("f783ac"), "brown": Color("a97142"), "wood": Color("c98b4a"), "soil": Color("7a4b2a"),
	"soil_wet": Color("4e2f1a"), "water": Color("4fc3f7"), "leaf": Color("3fbf5a"), "bud": Color("8fd14f"),
	"white": Color("f8f9fa"), "gray": Color("adb5bd"), "dark": Color("343a40"), "floor": Color("e9d8a6"),
	"wall": Color("ffe8cc"), "metal": Color("c0c8d0"), "skin": Color("ffd5b8"),
}

func _initialize() -> void:
	DirAccess.make_dir_recursive_absolute("res://art/materials")
	DirAccess.make_dir_recursive_absolute("res://art/ui")
	for key in MATERIALS:
		var m := StandardMaterial3D.new()
		m.albedo_color = MATERIALS[key]
		m.roughness = 1.0
		m.metallic = 0.0
		m.diffuse_mode = BaseMaterial3D.DIFFUSE_TOON
		m.specular_mode = BaseMaterial3D.SPECULAR_TOON
		m.rim_enabled = true
		m.rim = 0.6
		m.rim_tint = 0.3
		var err := ResourceSaver.save(m, "res://art/materials/toon_%s.tres" % key)
		if err != OK:
			push_error("save failed for %s: %s" % [key, error_string(err)])
	var theme := Theme.new()
	theme.default_font_size = 20
	ResourceSaver.save(theme, "res://art/ui/theme.tres")
	print("placeholder art generated")
	quit(0)
