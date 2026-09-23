extends SceneTree
## Generates the FACTORY palette additions to the toon material library (world/level agent).
## Same recipe as tools/gen_placeholder_art.gd: every material comes from Toon.make(), so finishes match the
## rest of the library exactly. Re-run after changing a value here; the outputs are committed:
##   godot --headless --path . -s res://tools/gen_factory_art.gd && godot --headless --path . --import
## See STYLE.md "Factory palette".

const ToonLib := preload("res://scripts/art/toon.gd")
const F := ToonLib.Finish

## name -> [colour, finish, emission_energy (-1 = finish default)]
const MATERIALS: Dictionary = {
	"concrete": [Color("9a978c"), F.MATTE, -1.0],        # floor slab, cinder blocks
	"concrete_dark": [Color("64625b"), F.MATTE, -1.0],   # stains, cracks, mortar joints, grime
	"rust": [Color("a3572e"), F.MATTE, -1.0],            # rust streaks, rusty drums/shutter/chute
	"caution": [Color("f0c02e"), F.SOFT, -1.0],          # caution stripes, hazard paint
	"metal_dark": [Color("4e585e"), F.GLOSSY, -1.0],     # steel frames, bars, pipes, housings
	"olive": [Color("7c8665"), F.MATTE, -1.0],           # painted walls, lockers, army-surplus stuff
	"chainlink": [Color("a9b2b8"), F.SOFT, -1.0],        # galvanised fence wire and posts
	"neon_green": [Color("b5ff7a"), F.GLOW, 1.1],        # fluorescent tubes, neon signs (self-lit)
}


func _initialize() -> void:
	var fails := 0
	DirAccess.make_dir_recursive_absolute("res://art/materials")
	for key: String in MATERIALS:
		var spec: Array = MATERIALS[key]
		var m: StandardMaterial3D = ToonLib.make(spec[0], spec[1], spec[2])
		m.resource_name = "toon_" + key
		var path := "res://art/materials/toon_%s.tres" % key
		var err := ResourceSaver.save(m, path)
		if err != OK:
			fails += 1
			push_error("save failed for %s: %s" % [path, error_string(err)])
	print("factory art generated: %d materials, %d failures" % [MATERIALS.size(), fails])
	quit(1 if fails > 0 else 0)
