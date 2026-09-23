class_name Toon
extends RefCounted
## Shared palette + toon material factory (owned by the art agent; rules in STYLE.md).
##
##   mesh.material_override = Toon.lib(&"leaf")                  # a library material (res://art/materials/toon_leaf.tres)
##   mesh.material_override = Toon.material(seed.color)          # runtime tint (per strain / per player), cached + shared
##   mesh.material_override = Toon.material(seed.color, Toon.Finish.GLOW)   # glowing bud
##   mesh.material_overlay  = Toon.outline()                     # cartoon ink outline on round meshes
##   label.modulate = Toon.GOLD
##
## Materials returned by material()/lib()/outline() are SHARED: never modify them in place.
## If you really need a unique one, call Toon.make(...) (uncached) or .duplicate() it.

# --- Palette (keep in sync with the palette table in STYLE.md) ---------------------------------
const TOMATO := Color("ff5a5f")      # red: errors, danger, roofs, red props
const TANGERINE := Color("ff9a3c")   # orange: turn-in bin, warm accents
const SUNSHINE := Color("ffd23f")    # yellow: money, highlights, warnings
const LIME := Color("a8e04a")        # yellow-green: fresh growth, seedlings
const GRASS := Color("4fcb6b")       # green: success, go buttons
const MINT := Color("33d1b0")        # teal: accents, alt cans
const SKY := Color("4da8f7")         # blue: info, default buttons, watering cans
const GRAPE := Color("9a6bff")       # purple: purple strain, fun accents
const BUBBLEGUM := Color("ff7eb6")   # pink: blush, fun accents
const COCOA := Color("a0663a")       # brown: trunks, sacks, crates
const HONEY_WOOD := Color("d8964f")  # wood: planters, counters, furniture
const SOIL := Color("7a4a2a")        # dry soil
const SOIL_WET := Color("4a2c19")    # watered soil
const WATER := Color("45c4ff")       # water (slight glow)
const LEAF := Color("3dbe55")        # plant leaves
const LEAF_DRY := Color("b8b04a")    # thirsty / dry leaves
const BUD := Color("9be15d")         # default buds (glow)
const CREAM := Color("fff4e0")       # warm off-white: labels, aprons, signs
const WHITE := Color("f8f9fa")       # cool white: eyes, clouds, trims
const PEBBLE := Color("b4bcc6")      # gray: neutral props
const STONE := Color("9aa6b5")       # bluish stone: well
const INK := Color("2e2a3d")         # near-black purple: outlines, pupils, text outline
const SAND := Color("f0ddb0")        # floor
const PEACH := Color("ffe3c2")       # walls
const TIN := Color("c3cdd8")         # metal
const SKIN := Color("ffd0b0")        # shopkeeper skin
const GOLD := Color("ffc53d")        # coins, "$", golden things (glossy)

# --- Semantic colors (UI + feedback) ---------------------------------------------------------
const INFO := Color("4da8f7")
const SUCCESS := Color("4fcb6b")
const ERROR := Color("ff5a5f")
const WARNING := Color("ffd23f")
const MONEY := Color("ffd23f")
const TEXT := Color("fffdf7")        # default UI text (always with INK outline)
const TEXT_SUBTLE := Color("d9d2f2")
const UI_PANEL := Color("5b4bc4")    # main panel fill (blueberry)
const UI_PANEL_DARK := Color("3b2f86")
const UI_CARD := Color("7465d8")

## Suggested player colours (menu colour picker / default per join order). Bright, distinct from the
## plant greens and from the error red; all read well with white text + ink outline.
const PLAYER_COLORS: Array[Color] = [
	Color("4da8f7"), Color("ff7eb6"), Color("ffd23f"), Color("9a6bff"),
	Color("ff9a3c"), Color("33d1b0"), Color("ff5a5f"), Color("a8e04a"),
]

## Surface finish presets. See STYLE.md "Material library".
enum Finish {
	SOFT,    ## default: props, characters, stations. Soft two-tone + thin rim.
	MATTE,   ## big surfaces: floor, walls, soil. No highlight, very soft terminator.
	GLOSSY,  ## water, metal, gold, glass: crisper band + visible toon highlight.
	GLOW,    ## SOFT + emission (buds, magic, "ready" things).
	FLAT,    ## unshaded sticker look (eyes, decals, blob shadows, particles).
}

const LIB_DIR := "res://art/materials/"
const OUTLINE_PATH := "res://art/materials/toon_outline.tres"
const OUTLINE_THIN_PATH := "res://art/materials/toon_outline_thin.tres"

static var _cache: Dictionary = {}

## Builds a NEW (uncached) toon material. Used by tools/gen_placeholder_art.gd for the library, so runtime
## materials from material() match the .tres files exactly.
static func make(color: Color, finish: Finish = Finish.SOFT, emission_energy: float = -1.0) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = color
	m.metallic = 0.0
	if finish == Finish.FLAT:
		m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		if color.a < 1.0:
			m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		return m
	m.diffuse_mode = BaseMaterial3D.DIFFUSE_TOON
	m.specular_mode = BaseMaterial3D.SPECULAR_TOON
	m.rim_enabled = true
	match finish:
		Finish.MATTE:
			m.roughness = 0.8
			m.metallic_specular = 0.1
			m.rim = 0.12
			m.rim_tint = 0.7
		Finish.GLOSSY:
			m.roughness = 0.18
			m.metallic_specular = 0.8
			m.rim = 0.35
			m.rim_tint = 0.3
		_: # SOFT, GLOW
			m.roughness = 0.4
			m.metallic_specular = 0.35
			m.rim = 0.3
			m.rim_tint = 0.5
	if finish == Finish.GLOW and emission_energy < 0.0:
		emission_energy = 0.35
	if emission_energy > 0.0:
		m.emission_enabled = true
		m.emission = color
		m.emission_energy_multiplier = emission_energy
	if color.a < 1.0:
		m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	return m

## Cached, shared toon material for an arbitrary color (per strain, per player...). Do not mutate the result.
static func material(color: Color, finish: Finish = Finish.SOFT) -> StandardMaterial3D:
	var key := "%s|%d" % [color.to_html(true), finish]
	var m: StandardMaterial3D = _cache.get(key)
	if m == null:
		m = make(color, finish)
		_cache[key] = m
	return m

## A library material by short name: Toon.lib(&"leaf") == load("res://art/materials/toon_leaf.tres").
## Unknown names warn (no loader error) and return a magenta placeholder so the mistake is obvious.
static func lib(name: StringName) -> Material:
	var path := LIB_DIR + "toon_%s.tres" % name
	var m: Material = load(path) as Material if ResourceLoader.exists(path) else null
	if m == null:
		push_warning("Toon.lib: no material at %s" % path)
		m = material(Color.MAGENTA)
	return m

## Ink outline for GeometryInstance3D.material_overlay (inverted hull: 2.5 cm, thin = 1.2 cm).
## Use on smooth meshes: spheres, capsules, tori, and cylinders whose flat caps are not seen from above.
## Not on boxes, flat caps you look down on, or walls (split normals make the outline tear at corners).
static func outline(thin: bool = false) -> Material:
	return load(OUTLINE_THIN_PATH if thin else OUTLINE_PATH) as Material

## Lighter/darker helpers that keep hue (for hover states, shading tints, strain buds).
static func lighter(c: Color, amount: float = 0.25) -> Color:
	return c.lerp(Color(1, 1, 1, c.a), amount)

static func darker(c: Color, amount: float = 0.25) -> Color:
	return c.lerp(Color(INK.r, INK.g, INK.b, c.a), amount)
