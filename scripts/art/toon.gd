class_name Toon
extends RefCounted
## Shared palette + toon material factory (owned by the art agent; rules in STYLE.md).
##
##   mesh.material_override = Toon.lib(&"leaf")                  # a library material (res://art/materials/toon_leaf.tres)
##   mesh.material_override = Toon.tint(seed.color)              # data colour, graded to the mood, cached + shared
##   mesh.material_override = Toon.tint(seed.color, Toon.Finish.GLOW)       # (faintly) glowing bud
##   mesh.material_override = Toon.material(Toon.SKY)             # palette colour (already graded)
##   mesh.material_overlay  = Toon.outline()                     # cartoon ink outline on round meshes
##   label.modulate = Toon.GOLD
##
## Materials returned by material()/lib()/outline() are SHARED: never modify them in place.
## If you really need a unique one, call Toon.make(...) (uncached) or .duplicate() it.

# --- Palette (keep in sync with the palette table in STYLE.md) ---------------------------------
# MOOD: every colour is the original candy hue passed through grade() (value x0.85, saturation x0.85,
# 10% cool slate mixed in): a slight dark undertone that stays chunky and readable. Nobody is happy here.
const COOL_GRAY := Color("6f7787")   # the slate every colour is nudged towards
const TOMATO := Color("ce6469")      # red: errors, danger, roofs, red props
const TANGERINE := Color("ce8d52")   # orange: turn-in bin, warm accents
const SUNSHINE := Color("ceb254")    # yellow: money, highlights, warnings
const LIME := Color("92b757")        # yellow-green: seedlings
const GRASS := Color("56a76a")       # green: confirm buttons
const MINT := Color("44ac98")        # teal: accents, alt cans
const SKY := Color("5a95ca")         # blue: info, default buttons, watering cans
const GRAPE := Color("8c6fd1")       # purple: purple strain, accents
const BUBBLEGUM := Color("ce7ba1")   # pink: accents (no blush anywhere)
const COCOA := Color("866146")       # brown: rims, beams, sacks
const HONEY_WOOD := Color("b0865a")  # wood: planters, counters, furniture
const SOIL := Color("684a37")        # dry soil
const SOIL_WET := Color("443126")    # watered soil
const WATER := Color("55a9d1")       # water (faint glow)
const LEAF := Color("499d5b")        # plant leaves
const LEAF_DRY := Color("989353")    # thirsty / dry leaves
const BUD := Color("8ab864")         # default buds (faint glow)
const CREAM := Color("cec8bc")       # dingy off-white: labels, aprons, signs
const WHITE := Color("c9cacd")       # grubby white: trims, poles
const PEBBLE := Color("979da5")      # gray: neutral props
const STONE := Color("848d98")       # bluish stone: well
const INK := Color("2e2a3d")         # near-black purple: outlines, pupils, text outline
const SAND := Color("c3b79b")        # floor
const PEACH := Color("cebda9")       # walls
const TIN := Color("a3aab3")         # metal
const SKIN := Color("ceb09d")        # skin
const GOLD := Color("cea952")        # coins, "$", tarnished gold

# --- Semantic colors (UI + feedback) ---------------------------------------------------------
const INFO := Color("5a95ca")
const SUCCESS := Color("56a76a")
const ERROR := Color("ce6469")
const WARNING := Color("ceb254")
const MONEY := Color("ceb254")
const TEXT := Color("ecebe6")        # default UI text (always with INK outline): tired off-white
const TEXT_SUBTLE := Color("b4b0c7")
const UI_PANEL := Color("5d53a3")    # main panel fill (faded blueberry)
const UI_PANEL_DARK := Color("413a74")
const UI_CARD := Color("6f66b3")

## Suggested player colours (menu colour picker / default per join order). Muted like everything else,
## still distinct from the plant greens and from the error red; all read with light text + ink outline.
const PLAYER_COLORS: Array[Color] = [
	Color("5a95ca"), Color("ce7ba1"), Color("ceb254"), Color("8c6fd1"),
	Color("ce8d52"), Color("44ac98"), Color("ce6469"), Color("92b757"),
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
			m.metallic_specular = 0.08
			m.rim = 0.06
			m.rim_tint = 0.7
		Finish.GLOSSY:
			m.roughness = 0.22
			m.metallic_specular = 0.55
			m.rim = 0.18
			m.rim_tint = 0.4
		_: # SOFT, GLOW
			m.roughness = 0.45
			m.metallic_specular = 0.25
			m.rim = 0.15
			m.rim_tint = 0.5
	if finish == Finish.GLOW and emission_energy < 0.0:
		emission_energy = 0.12
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

## The mood grade: value x0.85, saturation x0.85, then 10% towards COOL_GRAY (alpha kept). The palette
## constants above are already graded; use this on colours that come from DATA (SeedDef.color, anything
## a designer typed in) before showing them, or call tint() which does it for you.
static func grade(c: Color, amount: float = 1.0) -> Color:
	var g := Color.from_hsv(c.h, c.s * lerpf(1.0, 0.85, amount), c.v * lerpf(1.0, 0.85, amount), c.a)
	return g.lerp(Color(COOL_GRAY, c.a), 0.1 * amount)

## Cached toon material for a DATA colour (strain, player pick...): grade(color) then material().
static func tint(color: Color, finish: Finish = Finish.SOFT) -> StandardMaterial3D:
	return material(grade(color), finish)

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
