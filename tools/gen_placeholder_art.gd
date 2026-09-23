extends SceneTree
## Generates the art library at its final paths (art agent). Re-run after changing any value here or in
## scripts/art/toon.gd; the outputs are committed, the game never runs this.
##   godot --headless --path . -s res://tools/gen_placeholder_art.gd
##
## Outputs:
##   res://art/materials/toon_*.tres     toon StandardMaterial3D library (see STYLE.md "Material library")
##   res://art/ui/theme.tres             project UI theme + type variations (see STYLE.md "UI")
##   res://art/env/toon_environment.tres Environment for the room (sky colour, lavender ambient, glow)
##   res://art/env/toon_lighting.tscn    WorldEnvironment + warm Sun, instance it in a level
##   res://art/shaders/toon_example.tres ShaderMaterial using res://art/shaders/toon.gdshader
##   res://art/props/face.tscn           sad googly eyes: heavy lids, eye bags, frown (script ToonFace)
##   res://art/props/vignette.tscn       optional dark full-screen vignette (CanvasLayer -1)
##   res://art/reference/style_kit.tscn  reference diorama of every STYLE.md recipe (open it in the editor)

const ToonLib := preload("res://scripts/art/toon.gd")
const F := ToonLib.Finish

# name -> [color, finish, emission_energy (-1 = finish default)]
# The first 23 names are referenced by other systems: never rename/remove them.
var MATERIALS: Dictionary = {
	"red": [ToonLib.TOMATO, F.SOFT, -1.0],
	"orange": [ToonLib.TANGERINE, F.SOFT, -1.0],
	"yellow": [ToonLib.SUNSHINE, F.SOFT, -1.0],
	"lime": [ToonLib.LIME, F.SOFT, -1.0],
	"green": [ToonLib.GRASS, F.SOFT, -1.0],
	"teal": [ToonLib.MINT, F.SOFT, -1.0],
	"blue": [ToonLib.SKY, F.SOFT, -1.0],
	"purple": [ToonLib.GRAPE, F.SOFT, -1.0],
	"pink": [ToonLib.BUBBLEGUM, F.SOFT, -1.0],
	"brown": [ToonLib.COCOA, F.SOFT, -1.0],
	"wood": [ToonLib.HONEY_WOOD, F.SOFT, -1.0],
	"soil": [ToonLib.SOIL, F.MATTE, -1.0],
	"soil_wet": [ToonLib.SOIL_WET, F.MATTE, -1.0],
	"water": [ToonLib.WATER, F.GLOSSY, 0.08],
	"leaf": [ToonLib.LEAF, F.SOFT, -1.0],
	"bud": [ToonLib.BUD, F.GLOW, 0.12],
	"white": [ToonLib.WHITE, F.SOFT, -1.0],
	"gray": [ToonLib.PEBBLE, F.SOFT, -1.0],
	"dark": [ToonLib.INK, F.SOFT, -1.0],
	"floor": [ToonLib.SAND, F.MATTE, -1.0],
	"wall": [ToonLib.PEACH, F.MATTE, -1.0],
	"metal": [ToonLib.TIN, F.GLOSSY, -1.0],
	"skin": [ToonLib.SKIN, F.SOFT, -1.0],
	# --- additions (art pass 1) ---
	"gold": [ToonLib.GOLD, F.GLOSSY, 0.05],
	"cream": [ToonLib.CREAM, F.SOFT, -1.0],
	"stone": [ToonLib.STONE, F.MATTE, -1.0],
	"leaf_dry": [ToonLib.LEAF_DRY, F.SOFT, -1.0],
	"eye_white": [Color("d6d5d0"), F.FLAT, -1.0],
	"eye_black": [ToonLib.INK, F.FLAT, -1.0],
	# MOOD: nobody blushes. Kept (other scenes reference it) as a faint tired mauve flush.
	"blush": [Color(0.55, 0.45, 0.55, 0.18), F.FLAT, -1.0],
	"sparkle": [ToonLib.grade(Color("fff3b0")), F.FLAT, -1.0],
	# --- mood pass: sad faces ---
	"eyelid": [Color("4a4556"), F.FLAT, -1.0],
	"eyebag": [Color(0.3, 0.26, 0.38, 0.4), F.FLAT, -1.0],
}

var _fail := 0

func _initialize() -> void:
	for d in ["res://art/materials", "res://art/ui", "res://art/env", "res://art/shaders", "res://art/props", "res://art/reference"]:
		DirAccess.make_dir_recursive_absolute(d)
	_gen_materials()
	_gen_theme()
	_gen_environment()
	_gen_shader_example()
	_gen_face()
	_gen_vignette()
	_gen_style_kit()
	print("art generated (%d failures)" % _fail)
	quit(1 if _fail > 0 else 0)

func _save(res: Resource, path: String) -> void:
	var err := ResourceSaver.save(res, path)
	if err != OK:
		_fail += 1
		push_error("save failed for %s: %s" % [path, error_string(err)])

# ------------------------------------------------------------------------------------------ materials
func _gen_materials() -> void:
	for key: String in MATERIALS:
		var spec: Array = MATERIALS[key]
		var m: StandardMaterial3D = ToonLib.make(spec[0], spec[1], spec[2])
		m.resource_name = "toon_" + key
		if key == "eyelid":
			m.cull_mode = BaseMaterial3D.CULL_DISABLED
		_save(m, "res://art/materials/toon_%s.tres" % key)

	# Glass: see-through glossy (product jars, windows). Transparent = no shadow casting, draws after opaques.
	var glass: StandardMaterial3D = ToonLib.make(Color(0.62, 0.72, 0.78, 0.4), F.GLOSSY)
	glass.resource_name = "toon_glass"
	glass.rim = 0.3
	glass.cull_mode = BaseMaterial3D.CULL_DISABLED
	_save(glass, "res://art/materials/toon_glass.tres")

	# Blob shadow: soft dark disc under characters / items (use on a flat CylinderMesh or QuadMesh).
	var blob := StandardMaterial3D.new()
	blob.resource_name = "toon_blob_shadow"
	blob.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	blob.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	blob.albedo_color = Color(ToonLib.INK, 0.32)
	blob.cull_mode = BaseMaterial3D.CULL_DISABLED
	blob.no_depth_test = false
	blob.render_priority = -1
	_save(blob, "res://art/materials/toon_blob_shadow.tres")

	# Outlines for GeometryInstance3D.material_overlay (inverted hull: grow + front-face culling).
	for pair in [["toon_outline", 0.025], ["toon_outline_thin", 0.012]]:
		var o := StandardMaterial3D.new()
		o.resource_name = pair[0]
		o.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		o.albedo_color = ToonLib.INK
		o.cull_mode = BaseMaterial3D.CULL_FRONT
		o.grow = true
		o.grow_amount = pair[1]
		_save(o, "res://art/materials/%s.tres" % pair[0])

# ---------------------------------------------------------------------------------------------- theme
## Mood grade for literal UI colours (see Toon.grade).
func _g(hex: String, amount: float = 1.0) -> Color:
	return ToonLib.grade(Color(hex), amount)

const R_SMALL := 12
const R_MED := 16
const R_LARGE := 24
const LIP := 6

func _flat(bg: Color, radius: int, margins: Vector4 = Vector4(-1, -1, -1, -1)) -> StyleBoxFlat:
	var s := StyleBoxFlat.new()
	s.bg_color = bg
	s.set_corner_radius_all(radius)
	s.corner_detail = 10
	s.anti_aliasing = true
	s.anti_aliasing_size = 1.0
	if margins.x >= 0.0:
		s.content_margin_left = margins.x
		s.content_margin_top = margins.y
		s.content_margin_right = margins.z
		s.content_margin_bottom = margins.w
	return s

## Chunky "pressable" button set: coloured pill with a darker lip at the bottom that squashes when pressed.
func _button_styles(th: Theme, type: StringName, base: Color, lip_color: Color, radius: int, pad_h: int, pad_v: int, lip: int) -> void:
	var normal := _flat(base, radius, Vector4(pad_h, pad_v, pad_h, pad_v + lip))
	normal.border_width_bottom = lip
	normal.border_color = lip_color
	normal.shadow_color = Color(ToonLib.INK, 0.25)
	normal.shadow_size = 4
	normal.shadow_offset = Vector2(0, 3)
	var hover := normal.duplicate() as StyleBoxFlat
	hover.bg_color = ToonLib.lighter(base, 0.18)
	hover.border_color = ToonLib.lighter(lip_color, 0.1)
	var pressed := normal.duplicate() as StyleBoxFlat
	var pressed_lip := 2
	pressed.bg_color = base.darkened(0.08)
	pressed.border_width_bottom = pressed_lip
	# Visually push the whole button down by (lip - pressed_lip) px; content moves with it.
	pressed.expand_margin_top = -float(lip - pressed_lip)
	pressed.content_margin_top = pad_v + (lip - pressed_lip)
	pressed.content_margin_bottom = pad_v + pressed_lip
	pressed.shadow_size = 2
	pressed.shadow_offset = Vector2(0, 1)
	var disabled := normal.duplicate() as StyleBoxFlat
	disabled.bg_color = _g("a39fb8")
	disabled.border_color = _g("7d7894")
	disabled.shadow_color = Color(ToonLib.INK, 0.12)
	var focus := StyleBoxFlat.new()
	focus.draw_center = false
	focus.set_corner_radius_all(radius + 4)
	focus.corner_detail = 10
	focus.set_border_width_all(3)
	focus.border_color = Color(0.85, 0.85, 0.88, 0.6)
	focus.set_expand_margin_all(4)
	th.set_stylebox(&"normal", type, normal)
	th.set_stylebox(&"hover", type, hover)
	th.set_stylebox(&"pressed", type, pressed)
	th.set_stylebox(&"disabled", type, disabled)
	th.set_stylebox(&"focus", type, focus)

func _button_fonts(th: Theme, type: StringName, outline: int) -> void:
	th.set_color(&"font_color", type, ToonLib.TEXT)
	th.set_color(&"font_hover_color", type, Color("f6f5f1"))
	th.set_color(&"font_pressed_color", type, Color("dcdae2"))
	th.set_color(&"font_hover_pressed_color", type, Color("dcdae2"))
	th.set_color(&"font_focus_color", type, Color("f6f5f1"))
	th.set_color(&"font_disabled_color", type, Color("c4c1cc"))
	th.set_color(&"font_outline_color", type, ToonLib.INK)
	th.set_constant(&"outline_size", type, outline)
	th.set_constant(&"h_separation", type, 10)

func _label(th: Theme, type: StringName, size: int, color: Color, outline: int, shadow_y: int, shadow_a: float) -> void:
	if type != &"Label":
		th.set_type_variation(type, &"Label")
	th.set_font_size(&"font_size", type, size)
	th.set_color(&"font_color", type, color)
	th.set_color(&"font_outline_color", type, ToonLib.INK)
	th.set_constant(&"outline_size", type, outline)
	th.set_color(&"font_shadow_color", type, Color(ToonLib.INK, shadow_a))
	th.set_constant(&"shadow_offset_x", type, 0)
	th.set_constant(&"shadow_offset_y", type, shadow_y)
	th.set_constant(&"shadow_outline_size", type, outline)

func _panel(bg: Color, radius: int, pad: Vector4, border: int, border_color: Color, shadow: int, shadow_y: int, shadow_a: float) -> StyleBoxFlat:
	var s := _flat(bg, radius, pad)
	if border > 0:
		s.set_border_width_all(border)
		s.border_color = border_color
	if shadow > 0:
		s.shadow_color = Color(ToonLib.INK, shadow_a)
		s.shadow_size = shadow
		s.shadow_offset = Vector2(0, shadow_y)
	return s

func _gen_theme() -> void:
	var th := Theme.new()
	th.resource_name = "grow_with_friends_theme"
	var body_font := FontVariation.new()   # base_font unset = engine default font (Open Sans SemiBold)
	body_font.resource_name = "body_bold"
	body_font.variation_embolden = 0.45
	var chunky_font := FontVariation.new()
	chunky_font.resource_name = "chunky"
	chunky_font.variation_embolden = 0.9
	chunky_font.spacing_glyph = 1
	th.default_font = body_font
	th.default_font_size = 20

	# --- Labels -----------------------------------------------------------------------------------
	_label(th, &"Label", 20, ToonLib.TEXT, 6, 2, 0.35)
	th.set_constant(&"line_spacing", &"Label", 2)
	_label(th, &"TitleLabel", 48, ToonLib.TEXT, 14, 5, 0.45)
	th.set_font(&"font", &"TitleLabel", chunky_font)
	_label(th, &"BannerLabel", 72, ToonLib.SUNSHINE, 18, 7, 0.5)
	th.set_font(&"font", &"BannerLabel", chunky_font)
	_label(th, &"HeaderLabel", 32, ToonLib.TEXT, 10, 4, 0.4)
	th.set_font(&"font", &"HeaderLabel", chunky_font)
	_label(th, &"HudLabel", 24, ToonLib.TEXT, 8, 3, 0.5)
	th.set_font(&"font", &"HudLabel", chunky_font)
	_label(th, &"MoneyLabel", 32, ToonLib.MONEY, 10, 4, 0.5)
	th.set_font(&"font", &"MoneyLabel", chunky_font)
	_label(th, &"TimerLabel", 32, ToonLib.TEXT, 10, 4, 0.5)
	th.set_font(&"font", &"TimerLabel", chunky_font)
	_label(th, &"SubtleLabel", 16, ToonLib.TEXT_SUBTLE, 4, 1, 0.25)
	_label(th, &"ErrorLabel", 20, _g("ff8a8d", 0.6), 6, 2, 0.35)
	_label(th, &"SuccessLabel", 20, _g("7fe396", 0.6), 6, 2, 0.35)

	th.set_color(&"font_color", &"TooltipLabel", ToonLib.TEXT)
	th.set_color(&"font_outline_color", &"TooltipLabel", ToonLib.INK)
	th.set_constant(&"outline_size", &"TooltipLabel", 4)
	th.set_font_size(&"font_size", &"TooltipLabel", 16)
	th.set_stylebox(&"panel", &"TooltipPanel", _panel(Color(ToonLib.INK, 0.94), R_SMALL, Vector4(12, 8, 12, 8), 2, Color(1, 1, 1, 0.25), 4, 2, 0.3))

	th.set_color(&"default_color", &"RichTextLabel", ToonLib.TEXT)
	th.set_color(&"font_outline_color", &"RichTextLabel", ToonLib.INK)
	th.set_constant(&"outline_size", &"RichTextLabel", 5)
	th.set_color(&"font_shadow_color", &"RichTextLabel", Color(ToonLib.INK, 0.3))
	th.set_constant(&"shadow_offset_y", &"RichTextLabel", 2)
	th.set_constant(&"shadow_offset_x", &"RichTextLabel", 0)
	th.set_constant(&"shadow_outline_size", &"RichTextLabel", 5)

	# --- Buttons ----------------------------------------------------------------------------------
	_button_styles(th, &"Button", ToonLib.SKY, _g("2f7fd0"), R_MED, 20, 8, LIP)
	_button_fonts(th, &"Button", 6)
	th.set_type_variation(&"BigButton", &"Button")
	_button_styles(th, &"BigButton", ToonLib.GRASS, _g("2e9e4a"), 22, 36, 12, 8)
	_button_fonts(th, &"BigButton", 10)
	th.set_font_size(&"font_size", &"BigButton", 30)
	th.set_font(&"font", &"BigButton", chunky_font)
	th.set_type_variation(&"DangerButton", &"Button")
	_button_styles(th, &"DangerButton", ToonLib.TOMATO, _g("c93a3f"), R_MED, 20, 8, LIP)
	_button_fonts(th, &"DangerButton", 6)
	th.set_type_variation(&"GoldButton", &"Button")
	_button_styles(th, &"GoldButton", _g("ffc233"), _g("d18a12"), R_MED, 20, 8, LIP)
	_button_fonts(th, &"GoldButton", 6)
	th.set_type_variation(&"SmallButton", &"Button")
	_button_styles(th, &"SmallButton", ToonLib.SKY, _g("2f7fd0"), R_SMALL, 12, 4, 4)
	_button_fonts(th, &"SmallButton", 5)
	th.set_font_size(&"font_size", &"SmallButton", 16)

	# CheckBox / CheckButton extend Button: give them their own (mostly empty) styles so they don't
	# inherit the blue pill.
	var check_icons := _gen_check_icons()
	for t: StringName in [&"CheckBox", &"CheckButton"]:
		var empty := StyleBoxEmpty.new()
		empty.content_margin_left = 4
		empty.content_margin_right = 4
		empty.content_margin_top = 4
		empty.content_margin_bottom = 4
		var hover_bg := _flat(Color(1, 1, 1, 0.1), R_SMALL, Vector4(4, 4, 4, 4))
		var focus := StyleBoxFlat.new()
		focus.draw_center = false
		focus.set_corner_radius_all(R_SMALL)
		focus.set_border_width_all(2)
		focus.border_color = Color(1, 1, 1, 0.6)
		for s: StringName in [&"normal", &"pressed", &"disabled"]:
			th.set_stylebox(s, t, empty)
		th.set_stylebox(&"hover", t, hover_bg)
		th.set_stylebox(&"hover_pressed", t, hover_bg)
		th.set_stylebox(&"focus", t, focus)
		_button_fonts(th, t, 5)
		th.set_constant(&"h_separation", t, 10)
	for icon_name: String in check_icons:
		th.set_icon(icon_name, &"CheckBox", check_icons[icon_name])
	var switch_icons := _gen_switch_icons()
	for icon_name: String in switch_icons:
		th.set_icon(icon_name, &"CheckButton", switch_icons[icon_name])

	th.set_stylebox(&"normal", &"LinkButton", StyleBoxEmpty.new())

	# --- Panels -----------------------------------------------------------------------------------
	var panel := _panel(ToonLib.UI_PANEL, R_LARGE, Vector4(24, 20, 24, 20), 4, _g("8a7cf0"), 14, 8, 0.35)
	th.set_stylebox(&"panel", &"PanelContainer", panel)
	th.set_stylebox(&"panel", &"Panel", panel)
	th.set_type_variation(&"Card", &"PanelContainer")
	th.set_stylebox(&"panel", &"Card", _panel(ToonLib.UI_CARD, 18, Vector4(16, 14, 16, 14), 3, _g("a095f5"), 6, 4, 0.3))
	th.set_type_variation(&"HudPanel", &"PanelContainer")
	th.set_stylebox(&"panel", &"HudPanel", _panel(Color(ToonLib.INK, 0.62), 18, Vector4(16, 8, 16, 8), 0, Color.TRANSPARENT, 0, 0, 0.0))
	th.set_type_variation(&"Toast", &"PanelContainer")
	th.set_stylebox(&"panel", &"Toast", _panel(ToonLib.INFO, 22, Vector4(22, 10, 22, 12), 3, Color(0.82, 0.82, 0.86, 0.7), 8, 5, 0.4))
	th.set_type_variation(&"ToastError", &"PanelContainer")
	th.set_stylebox(&"panel", &"ToastError", _panel(ToonLib.ERROR, 22, Vector4(22, 10, 22, 12), 3, Color(0.82, 0.82, 0.86, 0.7), 8, 5, 0.4))
	th.set_type_variation(&"ToastSuccess", &"PanelContainer")
	th.set_stylebox(&"panel", &"ToastSuccess", _panel(ToonLib.SUCCESS, 22, Vector4(22, 10, 22, 12), 3, Color(0.82, 0.82, 0.86, 0.7), 8, 5, 0.4))
	th.set_type_variation(&"OverlayPanel", &"Panel")   # full-screen dim behind modal panels
	th.set_stylebox(&"panel", &"OverlayPanel", _flat(Color(ToonLib.INK, 0.6), 0))
	th.set_type_variation(&"CrosshairDot", &"Panel")   # 10x10 Panel in the screen centre
	th.set_stylebox(&"panel", &"CrosshairDot", _panel(Color(0.9, 0.9, 0.9, 0.9), 6, Vector4(0, 0, 0, 0), 2, Color(ToonLib.INK, 0.85), 0, 0, 0.0))
	th.set_type_variation(&"KeyCap", &"PanelContainer")   # "[E]" key hint in prompts
	var key := _panel(ToonLib.CREAM, 8, Vector4(9, 1, 9, 4), 2, ToonLib.INK, 0, 0, 0.0)
	key.border_width_bottom = 5
	th.set_stylebox(&"panel", &"KeyCap", key)
	th.set_type_variation(&"KeyCapLabel", &"Label")
	th.set_font_size(&"font_size", &"KeyCapLabel", 20)
	th.set_font(&"font", &"KeyCapLabel", chunky_font)
	th.set_color(&"font_color", &"KeyCapLabel", ToonLib.INK)
	th.set_constant(&"outline_size", &"KeyCapLabel", 0)
	th.set_color(&"font_shadow_color", &"KeyCapLabel", Color(0, 0, 0, 0))

	# --- LineEdit ---------------------------------------------------------------------------------
	var le := _panel(ToonLib.CREAM, R_SMALL, Vector4(14, 8, 14, 8), 3, _g("c8bfe8"), 0, 0, 0.0)
	var le_focus := StyleBoxFlat.new()
	le_focus.draw_center = false
	le_focus.set_corner_radius_all(R_SMALL + 3)
	le_focus.corner_detail = 10
	le_focus.set_border_width_all(3)
	le_focus.border_color = ToonLib.SUNSHINE
	le_focus.set_expand_margin_all(2)
	var le_ro := _panel(_g("d9d4e8"), R_SMALL, Vector4(14, 8, 14, 8), 3, _g("b3abd1"), 0, 0, 0.0)
	th.set_stylebox(&"normal", &"LineEdit", le)
	th.set_stylebox(&"focus", &"LineEdit", le_focus)
	th.set_stylebox(&"read_only", &"LineEdit", le_ro)
	th.set_color(&"font_color", &"LineEdit", ToonLib.INK)
	th.set_color(&"font_selected_color", &"LineEdit", ToonLib.INK)
	th.set_color(&"font_uneditable_color", &"LineEdit", Color(ToonLib.INK, 0.6))
	th.set_color(&"font_placeholder_color", &"LineEdit", Color(ToonLib.INK, 0.4))
	th.set_color(&"caret_color", &"LineEdit", ToonLib.INK)
	th.set_color(&"selection_color", &"LineEdit", Color(ToonLib.SKY, 0.45))
	th.set_color(&"clear_button_color", &"LineEdit", Color(ToonLib.INK, 0.6))
	th.set_color(&"clear_button_color_pressed", &"LineEdit", ToonLib.SKY)
	th.set_constant(&"outline_size", &"LineEdit", 0)
	th.set_constant(&"caret_width", &"LineEdit", 2)

	# --- ProgressBar + QuotaBar ---------------------------------------------------------------------
	var pb_bg := _panel(Color(ToonLib.INK, 0.55), R_SMALL, Vector4(0, 0, 0, 0), 3, Color(0.82, 0.82, 0.86, 0.7), 0, 0, 0.0)
	var pb_fill := _flat(ToonLib.GRASS, R_SMALL - 3, Vector4(0, 0, 0, 0))
	pb_fill.set_expand_margin_all(-3)   # sit inside the white border
	pb_fill.border_width_bottom = 3
	pb_fill.border_color = _g("2e9e4a")
	th.set_stylebox(&"background", &"ProgressBar", pb_bg)
	th.set_stylebox(&"fill", &"ProgressBar", pb_fill)
	th.set_color(&"font_color", &"ProgressBar", ToonLib.TEXT)
	th.set_color(&"font_outline_color", &"ProgressBar", ToonLib.INK)
	th.set_constant(&"outline_size", &"ProgressBar", 5)
	th.set_font_size(&"font_size", &"ProgressBar", 16)
	th.set_type_variation(&"QuotaBar", &"ProgressBar")
	var q_bg := _panel(Color(ToonLib.INK, 0.65), 18, Vector4(0, 0, 0, 0), 4, Color("c9c8cf"), 8, 4, 0.35)
	var q_fill := _flat(ToonLib.SUNSHINE, 14, Vector4(0, 0, 0, 0))
	q_fill.set_expand_margin_all(-4)
	q_fill.border_width_bottom = 5
	q_fill.border_color = _g("e0a100")
	th.set_stylebox(&"background", &"QuotaBar", q_bg)
	th.set_stylebox(&"fill", &"QuotaBar", q_fill)
	th.set_font_size(&"font_size", &"QuotaBar", 22)
	th.set_font(&"font", &"QuotaBar", chunky_font)
	th.set_constant(&"outline_size", &"QuotaBar", 8)

	# --- Tabs -------------------------------------------------------------------------------------
	var tab_sel := _flat(ToonLib.UI_PANEL, 14, Vector4(20, 10, 20, 10))
	tab_sel.corner_radius_bottom_left = 0
	tab_sel.corner_radius_bottom_right = 0
	tab_sel.border_width_top = 4
	tab_sel.border_width_left = 4
	tab_sel.border_width_right = 4
	tab_sel.border_color = _g("8a7cf0")
	var tab_un := _flat(ToonLib.UI_PANEL_DARK, 14, Vector4(18, 8, 18, 8))
	tab_un.corner_radius_bottom_left = 0
	tab_un.corner_radius_bottom_right = 0
	tab_un.expand_margin_top = -4
	var tab_hov := tab_un.duplicate() as StyleBoxFlat
	tab_hov.bg_color = ToonLib.lighter(ToonLib.UI_PANEL_DARK, 0.15)
	var tab_dis := tab_un.duplicate() as StyleBoxFlat
	tab_dis.bg_color = Color(ToonLib.UI_PANEL_DARK, 0.5)
	var tab_focus := StyleBoxFlat.new()
	tab_focus.draw_center = false
	tab_focus.set_border_width_all(2)
	tab_focus.border_color = Color(1, 1, 1, 0.6)
	tab_focus.set_corner_radius_all(12)
	var tab_panel := panel.duplicate() as StyleBoxFlat
	tab_panel.corner_radius_top_left = 0
	for t: StringName in [&"TabContainer", &"TabBar"]:
		th.set_stylebox(&"tab_selected", t, tab_sel)
		th.set_stylebox(&"tab_unselected", t, tab_un)
		th.set_stylebox(&"tab_hovered", t, tab_hov)
		th.set_stylebox(&"tab_disabled", t, tab_dis)
		th.set_stylebox(&"tab_focus", t, tab_focus)
		th.set_color(&"font_selected_color", t, ToonLib.TEXT)
		th.set_color(&"font_hovered_color", t, ToonLib.TEXT)
		th.set_color(&"font_unselected_color", t, ToonLib.TEXT_SUBTLE)
		th.set_color(&"font_disabled_color", t, Color(ToonLib.TEXT_SUBTLE, 0.5))
		th.set_color(&"font_outline_color", t, ToonLib.INK)
		th.set_constant(&"outline_size", t, 6)
		th.set_font_size(&"font_size", t, 22)
	th.set_stylebox(&"panel", &"TabContainer", tab_panel)
	th.set_stylebox(&"tabbar_background", &"TabContainer", StyleBoxEmpty.new())
	th.set_constant(&"side_margin", &"TabContainer", 0)

	# --- Popups / menus ---------------------------------------------------------------------------
	th.set_stylebox(&"panel", &"PopupMenu", _panel(ToonLib.UI_PANEL_DARK, 14, Vector4(8, 8, 8, 8), 3, _g("8a7cf0"), 8, 4, 0.35))
	th.set_stylebox(&"hover", &"PopupMenu", _flat(ToonLib.SKY, 10, Vector4(8, 4, 8, 4)))
	th.set_color(&"font_color", &"PopupMenu", ToonLib.TEXT)
	th.set_color(&"font_hover_color", &"PopupMenu", Color.WHITE)
	th.set_color(&"font_disabled_color", &"PopupMenu", Color(ToonLib.TEXT_SUBTLE, 0.5))
	th.set_color(&"font_outline_color", &"PopupMenu", ToonLib.INK)
	th.set_constant(&"outline_size", &"PopupMenu", 4)
	th.set_constant(&"v_separation", &"PopupMenu", 8)
	th.set_stylebox(&"panel", &"PopupPanel", _panel(ToonLib.UI_PANEL_DARK, 14, Vector4(8, 8, 8, 8), 3, _g("8a7cf0"), 0, 0, 0.0))

	# --- Scrollbars / slider ----------------------------------------------------------------------
	for t: StringName in [&"VScrollBar", &"HScrollBar"]:
		th.set_stylebox(&"scroll", t, _flat(Color(ToonLib.INK, 0.3), 8, Vector4(3, 3, 3, 3)))
		th.set_stylebox(&"scroll_focus", t, _flat(Color(ToonLib.INK, 0.3), 8, Vector4(3, 3, 3, 3)))
		th.set_stylebox(&"grabber", t, _flat(Color(0.85, 0.85, 0.88, 0.55), 8, Vector4(6, 6, 6, 6)))
		th.set_stylebox(&"grabber_highlight", t, _flat(Color(0.85, 0.85, 0.88, 0.8), 8, Vector4(6, 6, 6, 6)))
		th.set_stylebox(&"grabber_pressed", t, _flat(ToonLib.SUNSHINE, 8, Vector4(6, 6, 6, 6)))
	for t: StringName in [&"HSlider", &"VSlider"]:
		th.set_stylebox(&"slider", t, _flat(Color(ToonLib.INK, 0.45), 6, Vector4(4, 4, 4, 4)))
		th.set_stylebox(&"grabber_area", t, _flat(ToonLib.SKY, 6, Vector4(4, 4, 4, 4)))
		th.set_stylebox(&"grabber_area_highlight", t, _flat(ToonLib.lighter(ToonLib.SKY, 0.2), 6, Vector4(4, 4, 4, 4)))
		th.set_icon(&"grabber", t, _slider_grabber(Color.WHITE, 1.0))
		th.set_icon(&"grabber_highlight", t, _slider_grabber(ToonLib.SUNSHINE, 1.0))
		th.set_icon(&"grabber_disabled", t, _slider_grabber(Color.WHITE, 0.5))

	# --- Containers: airy default spacing ---------------------------------------------------------
	th.set_constant(&"separation", &"BoxContainer", 10)
	th.set_constant(&"separation", &"VBoxContainer", 10)
	th.set_constant(&"separation", &"HBoxContainer", 10)
	th.set_constant(&"h_separation", &"GridContainer", 10)
	th.set_constant(&"v_separation", &"GridContainer", 10)
	th.set_constant(&"separation", &"HFlowContainer", 10)
	th.set_constant(&"separation", &"VFlowContainer", 10)

	_save(th, "res://art/ui/theme.tres")

## Rounded check box / radio / switch / slider icons as SVG DPITextures (text in the .tres, re-rasterised
## crisply at any UI scale; no image assets).
func _svg(src: String) -> DPITexture:
	var t := DPITexture.new()
	t.set_source(src)
	return t

func _hex(c: Color) -> String:
	return "#" + c.to_html(false)

func _gen_check_icons() -> Dictionary:
	var ink := _hex(ToonLib.INK)
	var cream := _hex(ToonLib.CREAM)
	var grass := _hex(ToonLib.GRASS)
	var head := '<svg xmlns="http://www.w3.org/2000/svg" width="28" height="28" viewBox="0 0 28 28">'
	var box := '<rect x="2" y="2" width="24" height="24" rx="7" fill="%s" stroke="' + ink + '" stroke-width="3"/>'
	var check := '<path d="M7.5 14.5 L12 19 L20.5 9" fill="none" stroke="#ffffff" stroke-width="4" stroke-linecap="round" stroke-linejoin="round"/>'
	var circle := '<circle cx="14" cy="14" r="12" fill="%s" stroke="' + ink + '" stroke-width="3"/>'
	var dot := '<circle cx="14" cy="14" r="5.5" fill="#ffffff"/>'
	var box_un := _svg(head + box % cream + '</svg>')
	var box_on := _svg(head + box % grass + check + '</svg>')
	var box_un_d := _svg(head.replace('>', ' opacity="0.5">') + box % cream + '</svg>')
	var box_on_d := _svg(head.replace('>', ' opacity="0.5">') + box % grass + check + '</svg>')
	var rad_un := _svg(head + circle % cream + '</svg>')
	var rad_on := _svg(head + circle % grass + dot + '</svg>')
	var rad_un_d := _svg(head.replace('>', ' opacity="0.5">') + circle % cream + '</svg>')
	var rad_on_d := _svg(head.replace('>', ' opacity="0.5">') + circle % grass + dot + '</svg>')
	return {
		"unchecked": box_un, "unchecked_disabled": box_un_d, "checked": box_on, "checked_disabled": box_on_d,
		"radio_unchecked": rad_un, "radio_unchecked_disabled": rad_un_d, "radio_checked": rad_on,
		"radio_checked_disabled": rad_on_d,
	}

func _gen_switch_icons() -> Dictionary:
	var ink := _hex(ToonLib.INK)
	var out := {}
	for on in [false, true]:
		for mirrored in [false, true]:
			for disabled in [false, true]:
				var knob_right: bool = on != mirrored
				var track := _hex(ToonLib.GRASS) if on else "#8d86ad"
				var cx := 34 if knob_right else 16
				var src := '<svg xmlns="http://www.w3.org/2000/svg" width="50" height="30" viewBox="0 0 50 30"%s>' % (' opacity="0.5"' if disabled else "")
				src += '<rect x="2" y="2" width="46" height="26" rx="13" fill="%s" stroke="%s" stroke-width="3"/>' % [track, ink]
				src += '<circle cx="%d" cy="15" r="9" fill="#ffffff" stroke="%s" stroke-width="2.5"/></svg>' % [cx, ink]
				var key := ("checked" if on else "unchecked") + ("_disabled" if disabled else "") + ("_mirrored" if mirrored else "")
				out[key] = _svg(src)
	return out

func _slider_grabber(color: Color, alpha: float) -> DPITexture:
	return _svg('<svg xmlns="http://www.w3.org/2000/svg" width="26" height="26" viewBox="0 0 26 26" opacity="%s"><circle cx="13" cy="13" r="10.5" fill="%s" stroke="%s" stroke-width="3"/></svg>' % [str(alpha), _hex(color), _hex(ToonLib.INK)])

# -------------------------------------------------------------------------------------- environment
func _gen_environment() -> void:
	var env := Environment.new()
	env.resource_name = "toon_environment"   # mood pass: colder, dimmer, slightly desaturated
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color("56606e")       # overcast slate, not a sunny sky
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color("a3adbf")    # cold bluish-gray fill: shade goes cool and a bit grim
	# Light budget (see STYLE.md): cold sun 0.6 at a low angle + ambient 0.45 -> lit ~0.9x albedo, shade ~0.35x.
	env.ambient_light_energy = 0.45
	env.reflected_light_source = Environment.REFLECTION_SOURCE_DISABLED
	env.tonemap_mode = Environment.TONE_MAPPER_LINEAR
	env.tonemap_exposure = 1.0
	# Glow stays OFF: under the Compatibility renderer every glow blend mode washed the whole frame out in
	# testing, and nothing in this world should glow cheerfully anyway.
	env.glow_enabled = false
	env.adjustment_enabled = true
	env.adjustment_brightness = 0.97
	env.adjustment_saturation = 0.9
	env.adjustment_contrast = 1.05
	_save(env, "res://art/env/toon_environment.tres")

	var root := Node3D.new()
	root.name = "ToonLighting"
	var we := WorldEnvironment.new()
	we.name = "WorldEnvironment"
	we.environment = load("res://art/env/toon_environment.tres")
	root.add_child(we)
	we.owner = root
	var sun := DirectionalLight3D.new()
	sun.name = "Sun"
	sun.light_color = Color("d4deeb")   # cold, tired daylight through dirty windows
	sun.light_energy = 0.6
	sun.shadow_enabled = true
	sun.shadow_opacity = 0.65
	sun.shadow_blur = 1.5
	sun.directional_shadow_max_distance = 40.0
	sun.rotation_degrees = Vector3(-32, 40, 0)   # low sun: long, dreary shadows
	root.add_child(sun)
	sun.owner = root
	var ps := PackedScene.new()
	var err := ps.pack(root)
	if err != OK:
		_fail += 1
		push_error("pack toon_lighting failed: %s" % error_string(err))
	else:
		_save(ps, "res://art/env/toon_lighting.tscn")
	root.free()

func _gen_shader_example() -> void:
	var sh := load("res://art/shaders/toon.gdshader") as Shader
	if sh == null:
		print("(no res://art/shaders/toon.gdshader yet, skipping shader example)")
		return
	var sm := ShaderMaterial.new()
	sm.resource_name = "toon_shader_example"
	sm.shader = sh
	# Set every uniform explicitly: headless has no shader compiler, so unset ones would serialise as null.
	var params := {
		&"albedo": ToonLib.GRAPE, &"band_softness": 0.06, &"band_offset": -0.1, &"rim_color": Color("c9c3d6"),
		&"rim_width": 0.28, &"rim_strength": 0.45, &"specular_size": 0.06, &"specular_strength": 0.4,
		&"emission_color": Color(0, 0, 0, 1),
	}
	for k: StringName in params:
		sm.set_shader_parameter(k, params[k])
	_save(sm, "res://art/shaders/toon_example.tres")

# ----------------------------------------------------------------------------------------------- face
func _mesh_node(parent: Node3D, owner_node: Node, name: String, mesh: Mesh, mat_name: String, pos: Vector3, scl: Vector3, rot_deg: Vector3 = Vector3.ZERO) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	mi.name = name
	mi.mesh = mesh
	mi.material_override = load("res://art/materials/toon_%s.tres" % mat_name)
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	mi.position = pos
	mi.scale = scl
	mi.rotation_degrees = rot_deg
	parent.add_child(mi)
	mi.owner = owner_node
	return mi

func _sphere_mesh(r: float, segs: int = 16) -> SphereMesh:
	var m := SphereMesh.new()
	m.radius = r
	m.height = r * 2.0
	m.radial_segments = segs
	m.rings = segs / 2
	return m

## Face for a head of radius ~0.4 looking along -Z. MOOD: sad by default. Each eye is a Node3D pivot
## (blink = scale.y) holding a flattened white, an ink pupil (+ tiny glint) and a heavy dark EYELID: a
## hemisphere whose cut edge sits across the eye (ToonFace moves/tilts it per mood). Eye bags under the
## eyes, a two-segment mouth (frown / flat line). No blush.
func _gen_face() -> void:
	var face := Node3D.new()
	face.name = "Face"
	face.set_script(load("res://scripts/art/toon_face.gd"))
	var white := _sphere_mesh(0.085)
	var pupil := _sphere_mesh(0.047)
	var glint := _sphere_mesh(0.011, 8)
	var lid := SphereMesh.new()
	lid.radius = 0.085
	lid.height = 0.085
	lid.is_hemisphere = true
	lid.radial_segments = 16
	lid.rings = 6
	var bag := _sphere_mesh(0.05, 12)
	var mouth_seg := CapsuleMesh.new()
	mouth_seg.radius = 0.014
	mouth_seg.height = 0.075
	mouth_seg.radial_segments = 8
	mouth_seg.rings = 2
	for side in [-1.0, 1.0]:
		var eye := Node3D.new()
		eye.name = "EyeL" if side < 0.0 else "EyeR"
		eye.position = Vector3(0.12 * side, 0.03, 0.0)
		eye.rotation_degrees = Vector3(0, -10.0 * side, 0)
		face.add_child(eye)
		eye.owner = face
		_mesh_node(eye, face, "White", white, "eye_white", Vector3.ZERO, Vector3(1.0, 1.22, 0.55))
		var p := _mesh_node(eye, face, "Pupil", pupil, "eye_black", Vector3(0.006 * side, -0.02, -0.03), Vector3(1.0, 1.12, 0.5))
		_mesh_node(p, face, "Glint", glint, "eye_white", Vector3(0.014, 0.02, -0.02), Vector3(1.0, 1.0, 0.6))
		# Lid: sad default (cut edge ~at the eye centre, outer corner drooping). ToonFace re-poses it.
		_mesh_node(eye, face, "Lid", lid, "eyelid", Vector3(0, 0.01, 0), Vector3(1.14, 1.6, 0.7), Vector3(0, 0, -16.0 * side))
		_mesh_node(face, face, "EyeBagL" if side < 0.0 else "EyeBagR", bag, "eyebag", Vector3(0.12 * side, -0.075, 0.006), Vector3(1.25, 0.42, 0.3))
	var mouth := Node3D.new()
	mouth.name = "Mouth"
	mouth.position = Vector3(0, -0.14, -0.026)   # proud of the surface: capsule bodies bulge ~2 cm there
	face.add_child(mouth)
	mouth.owner = face
	for side in [-1.0, 1.0]:
		_mesh_node(mouth, face, "MouthL" if side < 0.0 else "MouthR", mouth_seg, "eye_black", Vector3(0.03 * side, -0.012, 0), Vector3.ONE, Vector3(0, 0, 90.0 - 22.0 * side))
	var ps := PackedScene.new()
	var err := ps.pack(face)
	if err != OK:
		_fail += 1
		push_error("pack face failed: %s" % error_string(err))
	else:
		_save(ps, "res://art/props/face.tscn")
	face.free()

# --------------------------------------------------------------------------------------------- vignette
## Optional full-screen vignette (dark, slightly cold edges). CanvasLayer -1: above the 3D view, below any
## HUD/menu on layer >= 0. Ignores the mouse. The HUD may instance it; it has no gameplay.
func _gen_vignette() -> void:
	var layer := CanvasLayer.new()
	layer.name = "Vignette"
	layer.layer = -1
	var rect := TextureRect.new()
	rect.name = "Shade"
	rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
	rect.set_anchors_preset(Control.PRESET_FULL_RECT)
	rect.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	rect.stretch_mode = TextureRect.STRETCH_SCALE
	var g := Gradient.new()
	g.offsets = PackedFloat32Array([0.0, 0.5, 0.78, 1.0])
	g.colors = PackedColorArray([Color(0.1, 0.1, 0.15, 0.0), Color(0.1, 0.1, 0.15, 0.0), Color(0.1, 0.1, 0.15, 0.28), Color(0.07, 0.07, 0.11, 0.62)])
	var gt := GradientTexture2D.new()
	gt.gradient = g
	gt.width = 256
	gt.height = 256
	gt.fill = GradientTexture2D.FILL_RADIAL
	gt.fill_from = Vector2(0.5, 0.5)
	gt.fill_to = Vector2(1.0, 1.0)
	rect.texture = gt
	layer.add_child(rect)
	rect.owner = layer
	var ps := PackedScene.new()
	var err := ps.pack(layer)
	if err != OK:
		_fail += 1
		push_error("pack vignette failed: %s" % error_string(err))
	else:
		_save(ps, "res://art/props/vignette.tscn")
	layer.free()

# ------------------------------------------------------------------------------------------ style kit
## Packs the reference diorama from tools/tests/art_kit.gd (built from the files generated above).
func _gen_style_kit() -> void:
	var kit_script := load("res://tools/tests/art_kit.gd")
	if kit_script == null:
		return
	var kit: Node3D = kit_script.build_diorama()
	kit_script.aim_camera(kit, 0)
	_own(kit, kit)
	var ps := PackedScene.new()
	var err := ps.pack(kit)
	if err != OK:
		_fail += 1
		push_error("pack style_kit failed: %s" % error_string(err))
	else:
		_save(ps, "res://art/reference/style_kit.tscn")
	kit.free()

## Sets owner on every node so pack() keeps it; instanced sub-scenes keep their own internals.
func _own(node: Node, owner_node: Node) -> void:
	for c in node.get_children():
		c.owner = owner_node
		if c.scene_file_path == "":
			_own(c, owner_node)
