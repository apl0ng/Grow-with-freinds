# STYLE.md: Grow With Friends art & feel guide

Owner: art agent. Everyone building visuals, UI, sound or feedback follows this file. APIs referenced here
are real and tested (`tools/tests/art_test.gd`). If something you need is missing, ask the lead. Do not
edit `art/**` or `scripts/art/**` yourself.

**Look:** chunky "Gamble with Friends"-style cartoon, but the world is a **low-budget factory** where the
players work off a debt to a shady Boss. Chunky rounded toys, soft toon shading with a thin ink outline,
googly-but-tired eyes on anything alive, and clear (never cheerful) feedback on every action. Nothing
realistic, nothing sharp, and **nothing happy**.

## Mood & tone (read first: overrides anything below that conflicts)

**Nobody in this game is happy.** Everyone is sad, tired or grim. The game never glamorises the work, the
money or the Boss. Everything carries a **slight dark undertone** while staying chunky, cartoon and
readable at a glance.

- **Faces:** nobody smiles, ever. `face.tscn` defaults to `&"sad"` (heavy drooping lids, eye bags, frown).
  Use `face.set_mood(&"sad" | &"tired" | &"grim" | &"neutral")`. `set_happy(true)` only reaches
  `&"neutral"`. No blush (`toon_blush` is now a faint grey flush; please remove it from characters), no
  open mouths, no sparkly eyes. Posture slouches (tilt the `Visual` forward 3-5°), sprouts wilt.
- **Palette:** every `Toon` colour and library material is the old candy hue graded by `Toon.grade()`:
  value x0.85, saturation x0.85, then 10% towards cool slate `#6f7787`. Use palette constants as they are.
  Pass colours that come from **data** (SeedDef.color, anything typed in) through `Toon.grade(c)` /
  `Toon.tint(c)`. Keep one hue per part and enough value contrast that props still read. The factory
  palette section (world agent) sits on top of this. **Blender models:** their base colours come from the
  same hex palette and are toon-converted at runtime by `Toonify` (`scripts/art/toonify.gd`, pipeline
  agent). See MODELING.md.
- **Light:** cold and dim. Bluish-grey ambient ~0.45, low cold sun ~0.6, slate background, mild
  desaturation (§3). No glow, no warm "golden hour".
- **Juice stays for readability, toned down.** `Juice.intensity` = 0.7 scales every overshoot, squash,
  pulse and punch. Bursts are smaller and muted, float text rises slowly in muted colours.
  Celebration effects are off (`Juice.allow_celebration = false`; the game never turns it on).
- **Copy tone:** flat and joyless, short and literal. "Quota met." "Shift over." "Debt: $1,240."
  "Out of water." No exclamation marks, no "Awesome!", no "Great job!", no emoji. Round end reads
  as grim relief ("SHIFT OVER" / "QUOTA MISSED"), not victory.

| Discouraged (was) | Use instead |
|---|---|
| `Juice.confetti()` (round win, big sale) | nothing. It is a no-op unless `allow_celebration`. Round win = overlay `pop_in` + `round_win` sound only |
| `Juice.sparkle()` (READY, buy, upgrades) | still callable, but now renders a small grey dust drift. Prefer `Juice.puff(pos, Juice.GLOOM, 4)` or nothing |
| `Juice.burst(pos, bright_color, 16+)` | `burst(pos, color, 8-12)`: colours are muted for you, no pop flash |
| `Juice.float_text(..., "Ready!", ...)` / "!" texts | only numbers that matter: `"+$120"`, `"-$45"`. No "Ready!" |
| `face.set_happy(true)` for a win | `face.set_mood(&"neutral")` (the best it gets), or leave faces `&"tired"` |
| `Sfx.play(&"round_win")` as a jingle | same call: it is now a muffled end-of-shift bell (relief, not joy) |
| `Sfx.play(&"round_start")` as a fanfare | same call: it is now a flat factory buzzer |
| bright gold "$" / sunshine banners | `Toon.GOLD` / `BannerLabel` are already tarnished; do not re-brighten with overrides |

Reference scene: **`res://art/reference/style_kit.tscn`**. Open it in the editor. It contains every object
recipe in this guide at the exact sizes quoted (built by `tools/tests/art_kit.gd`: copy recipes from there).

---

## 0. The 12 rules (read these even if you read nothing else)

1. **Materials only from the library** (`res://art/materials/toon_*.tres`), `Toon.material(Toon.X)` or
   `Toon.tint(data_color)`. Never create a `StandardMaterial3D` by hand, never use the default white material.
2. **Round first.** Sphere > capsule > torus > cylinder (24+ segments) > box. Boxes only for architecture
   (floor, walls, counters).
3. **Oversize everything the player touches:** held items are 0.3-0.5 m, stations are ≥ 1.2 m wide.
4. **Ink outline on round props and characters** (`material_overlay = toon_outline.tres`), never on boxes,
   flat caps seen from above, transparent parts or eyes.
5. **Origin at the base.** Put meshes under a `Visual` Node3D whose origin touches the ground; squash
   and stretch that `Visual`, **never** a physics body, the Interactable root, or a synced node.
6. **Every action has feedback: sound + motion (+ particles for world events).** See the event table in §6.
7. **Feedback must run on every peer:** trigger it from synced setters, `call_local` RPCs or GameState
   signals, never only inside `_server_interact()` (then only the host sees and hears it).
8. **UI uses the theme's type variations** (`theme_type_variation = &"HudLabel"`), never per-node colour or
   font overrides for things the theme already covers.
9. **All text is light with an ink outline** (sticker style). Exceptions: text typed in LineEdits and key caps.
10. **Light budget:** cold sun ≈ 0.6 (low angle), bluish-grey ambient ≈ 0.45 (§3). Much more light washes
    the colours out; much less and props stop reading.
11. **Nothing important is static:** idle bob, blink, pulse or sway on characters, READY plants and signs.
12. **Placeholder-proof:** no image or audio assets are needed. Everything is primitives, theme, synth.

---

## 1. Palette

All colours are constants on the `Toon` class (`scripts/art/toon.gd`, global `class_name Toon`). Values
are **already mood-graded** (`Toon.grade()` of the old candy hue, shown in brackets for reference).

| Name | Hex | `Toon.` const | Library material | Use |
|---|---|---|---|---|
| Tomato | `#ce6469` (was `#ff5a5f`) | `TOMATO` | toon_red | errors, danger buttons, roofs |
| Tangerine | `#ce8d52` (was `#ff9a3c`) | `TANGERINE` | toon_orange | turn-in bin, warm accents |
| Sunshine | `#ceb254` (was `#ffd23f`) | `SUNSHINE` | toon_yellow | money, quota fill, warnings |
| Gold | `#cea952` (was `#ffc53d`) | `GOLD` | toon_gold | tarnished coins, "$" signs, "+$" float text |
| Lime | `#92b757` (was `#a8e04a`) | `LIME` | toon_lime | seedlings |
| Grass | `#56a76a` (was `#4fcb6b`) | `GRASS` | toon_green | confirm buttons |
| Leaf | `#499d5b` (was `#3dbe55`) | `LEAF` | toon_leaf | plant leaves and bushes |
| Leaf (dry) | `#989353` (was `#b8b04a`) | `LEAF_DRY` | toon_leaf_dry | thirsty leaves, wilted sprout hats |
| Bud | `#8ab864` (was `#9be15d`) | `BUD` | toon_bud (faint glow) | default buds (strains: `Toon.tint(seed.color)`) |
| Mint | `#44ac98` (was `#33d1b0`) | `MINT` | toon_teal | accents, alt watering can |
| Sky | `#5a95ca` (was `#4da8f7`) | `SKY` | toon_blue | info, default buttons, watering cans |
| Water | `#55a9d1` (was `#45c4ff`) | `WATER` | toon_water (faint glow) | water surfaces, droplets |
| Grape | `#8c6fd1` (was `#9a6bff`) | `GRAPE` | toon_purple | purple strain, accents |
| Bubblegum | `#ce7ba1` (was `#ff7eb6`) | `BUBBLEGUM` | toon_pink | accents (never blush) |
| Cocoa | `#866146` (was `#a0663a`) | `COCOA` | toon_brown | rims, beams, sacks, moustaches |
| Honey wood | `#b0865a` (was `#d8964f`) | `HONEY_WOOD` | toon_wood | planters, counters, posts |
| Soil | `#684a37` (was `#7a4a2a`) | `SOIL` | toon_soil | dry soil |
| Soil (wet) | `#443126` (was `#4a2c19`) | `SOIL_WET` | toon_soil_wet | watered soil |
| Cream | `#cec8bc` (was `#fff4e0`) | `CREAM` | toon_cream | dingy labels, aprons, signs |
| White | `#c9cacd` (was `#f8f9fa`) | `WHITE` | toon_white | grubby trims, poles |
| Pebble | `#979da5` (was `#b4bcc6`) | `PEBBLE` | toon_gray | neutral props |
| Stone | `#848d98` (was `#9aa6b5`) | `STONE` | toon_stone | well, rocks |
| Tin | `#a3aab3` (was `#c3cdd8`) | `TIN` | toon_metal | buckets, metal bits |
| Skin | `#ceb09d` (was `#ffd0b0`) | `SKIN` | toon_skin | skin |
| Sand | `#c3b79b` (was `#f0ddb0`) | `SAND` | toon_floor | floor |
| Peach | `#cebda9` (was `#ffe3c2`) | `PEACH` | toon_wall | walls |
| Ink | `#2e2a3d` | `INK` | toon_dark | outlines, pupils, text outline (**never pure black**) |
| Cool slate | `#6f7787` | `COOL_GRAY` | - | what `grade()` nudges every colour towards |

**Semantic colours** (UI + feedback): `Toon.INFO` = Sky, `Toon.SUCCESS` = Grass, `Toon.ERROR` = Tomato,
`Toon.WARNING` = `Toon.MONEY` = Sunshine, `Toon.TEXT` `#ecebe6` (tired off-white, all UI text),
`Toon.TEXT_SUBTLE` `#b4b0c7`, UI panels `Toon.UI_PANEL` `#5d53a3` (faded blueberry), `Toon.UI_PANEL_DARK`
`#413a74`, `Toon.UI_CARD` `#6f66b3`.

**Player colours:** `Toon.PLAYER_COLORS` = Sky `#5a95ca`, Bubblegum `#ce7ba1`, Sunshine `#ceb254`, Grape
`#8c6fd1`, Tangerine `#ce8d52`, Mint `#44ac98`, Tomato `#ce6469`, Lime `#92b757`. Default the Nth joiner to
`PLAYER_COLORS[N]`. **Strain colours** come from `SeedDef.color` (data/balance.tres, un-graded). Use them via
`Toon.tint(seed.color)` (= `Toon.material(Toon.grade(seed.color))`), and `Toon.grade(seed.color)` for particles.

Helpers: `Toon.lighter(c, 0.25)` / `Toon.darker(c, 0.25)` (towards white / towards ink, hue kept). Use
these for hover tints, feet, crimps, name labels (`Toon.lighter(player_color, 0.35)`).

---

## 2. Material library

All are `StandardMaterial3D` with `DIFFUSE_TOON` + `SPECULAR_TOON` + rim (except FLAT ones). **Generated**
by `tools/gen_placeholder_art.gd` from `Toon.make()`. Do not hand-edit; ask the art agent.

| Path (`res://art/materials/`) | Finish | Intended use |
|---|---|---|
| `toon_red.tres` | soft | roofs, lids, danger props, shopkeeper cap |
| `toon_orange.tres` | soft | turn-in bin, shopkeeper body |
| `toon_yellow.tres` | soft | yellow props, signs |
| `toon_lime.tres` | soft | seedlings, sprout hats |
| `toon_green.tres` | soft | green props (not leaves) |
| `toon_teal.tres` | soft | alt cans, accents |
| `toon_blue.tres` | soft | watering can, blue props |
| `toon_purple.tres` | soft | purple props |
| `toon_pink.tres` | soft | pink props |
| `toon_brown.tres` | soft | planter rims, beams, moustache |
| `toon_wood.tres` | soft | planters, counter, posts |
| `toon_soil.tres` | matte | dry soil |
| `toon_soil_wet.tres` | matte | watered soil (swap when water ≥ 0.3) |
| `toon_water.tres` | glossy + glow 0.08 | well water, droplets |
| `toon_leaf.tres` | soft | leaves, bushes |
| `toon_bud.tres` | glow 0.12 | default bud (strains: `Toon.tint(c, Toon.Finish.GLOW)`) |
| `toon_white.tres` | soft | trims, poles |
| `toon_gray.tres` | soft | neutral props |
| `toon_dark.tres` | soft | ink-coloured solid parts (holes, tyres) |
| `toon_floor.tres` | matte | floor |
| `toon_wall.tres` | matte | walls, ceiling |
| `toon_metal.tres` | glossy | bucket, can rose, hinges |
| `toon_skin.tres` | soft | skin |
| `toon_gold.tres` | glossy + glow 0.05 | tarnished coins, hoops, "$" |
| `toon_cream.tres` | soft | aprons, labels, counter top, packet badge |
| `toon_stone.tres` | matte | well, rocks |
| `toon_leaf_dry.tres` | soft | leaves of a dry plant |
| `toon_eye_white.tres` | flat (unshaded) | eye whites, glints |
| `toon_eye_black.tres` | flat (unshaded) | pupils, drawn-on details |
| `toon_blush.tres` | flat, 18% alpha grey-mauve | **deprecated** (nobody blushes). Kept only because old scenes reference it |
| `toon_sparkle.tres` | flat, muted | small markers (no twinkly stars) |
| `toon_eyelid.tres` | flat, dark `#4a4556`, double-sided | heavy eyelids (face.tscn) |
| `toon_eyebag.tres` | flat, 40% alpha dark mauve | eye bags under tired eyes |
| `toon_glass.tres` | glossy, 38% alpha, double-sided | jars, windows |
| `toon_blob_shadow.tres` | flat, ink 28% alpha | fake contact shadow discs |
| `toon_outline.tres` | overlay | 2.5 cm ink outline (`material_overlay`) |
| `toon_outline_thin.tres` | overlay | 1.2 cm ink outline for small parts |

Finish parameters (in `Toon.make`, mood-toned): **soft** roughness 0.45 / specular 0.25 / rim 0.15 (tint 0.5),
which gives a soft two-tone plus a dull highlight. **matte** 0.8 / 0.08 / rim 0.06 means no highlight. **glossy**
0.22 / 0.55 / rim 0.18. **glow** is soft plus faint emission (0.12). **flat** is unshaded (sticker). Keep roughness < 0.95 on toon
materials: at 1.0 Godot's rim term washes the whole surface out.

**Runtime tints:** `Toon.material(color, finish := Toon.Finish.SOFT)` returns a **cached, shared**
material (one per colour+finish) for palette colours. `Toon.tint(color, finish)` does the same for data
colours after `Toon.grade()`. Never modify what `Toon.material()`/`Toon.lib()`/`load()` return. If you
truly need a unique one, use `Toon.make(color, finish)` (uncached). `Toon.lib(&"leaf")` = the library file.
Optional hand-rolled shader: `res://art/shaders/toon.gdshader` (+ example `toon_example.tres`). Only use it
if you need a hard cel band or coloured rim. The library is the default.

Using them in a hand-written `.tscn`:
```
[ext_resource type="Material" path="res://art/materials/toon_wood.tres" id="3_wood"]
[ext_resource type="Material" path="res://art/materials/toon_outline.tres" id="4_ol"]
[node name="Tub" type="MeshInstance3D" parent="Visual"]
mesh = SubResource("CylinderMesh_tub")
material_override = ExtResource("3_wood")
material_overlay = ExtResource("4_ol")
```

---

## 3. Lighting (world/level agent)

Instance **`res://art/env/toon_lighting.tscn`** in the level (WorldEnvironment + `Sun`) or match these
numbers exactly. The materials are tuned for them.

| Setting | Value |
|---|---|
| Sun (DirectionalLight3D) | energy **0.6**, cold colour `#d4deeb`, **low** rotation (-32°, 40°, 0), shadows on, `shadow_opacity` 0.65, `shadow_blur` 1.5 |
| Environment (`res://art/env/toon_environment.tres`) | background slate `#56606e`, ambient **colour** `#a3adbf` (bluish grey) energy **0.45**, tonemap Linear, glow **off**, adjustments brightness 0.97 / saturation 0.9 / contrast 1.05, no SSAO/SSIL/SDFGI/fog |
| Omni/Spot lights (optional) | dim fluorescent `#dfe8e4` or tired tungsten `#e8d7b8`, energy ≤ 0.35, range 5-7 m, shadows off |
| Vignette (optional) | `res://art/props/vignette.tscn`: CanvasLayer -1, dark cold edges, mouse-transparent. The HUD may instance it |

**Light budget:** cold sun ≈ 0.6 at a low angle plus ambient 0.45 gives lit ≈ 0.9x albedo and shade ≈ 0.35x
with a cool tint: dim and a little grim, props still readable. Much brighter (sun 1.0 + ambient 0.6)
washes everything out; much darker loses the silhouettes. If the room has a ceiling, set the ceiling
mesh's `cast_shadow = off` so the sun still reaches the floor. Glow stays off (it washed the frame out
in testing, and nothing here should glow cheerfully).

---

## 4. Shapes, proportions, scene structure

Scale: 1 unit = 1 m. Room ≈ 16 x 12 m. Everything must read from 6 m away at 1280x720.

**Primitives & detail**
- Spheres: 24 radial / 12 rings for anything ≥ 0.3 m; 12-16 for small bits. Cylinders: 24-28 radial.
  TorusMesh: rings 32, ring_segments 12. Visible faceting reads as "sharp", so avoid it.
- Squashed spheres are the workhorse: leaves `(1.3, 0.4, 0.8)`, blobs `(1, 0.6, 1.3)`, pillows `(1, 1, 0.3)`.
- Containers flare: top radius ≈ 1.15x bottom (tub 0.62 / 0.54, barrel 0.6 / 0.52).
- Add a fat torus rim on the top edge of anything that holds stuff (tubs, wells, jars, bins).
- Break symmetry: rotate repeated parts ±8-25°, vary sizes ±15%.

**Sizes**
- Held items: 0.3-0.5 m longest dimension (≈ 2x real life). Floor items get a blob shadow.
- Stations: ≥ 1.2 m footprint, ≥ 0.4 m tall; interaction collider ≥ the visual bounds.
- Characters: capsule radius : height ≈ 1 : 3.7 (player 0.42 x 1.55). Shopkeeper is rounder: 0.58 x 1.9.
- Eyes: eye-white radius ≈ 0.2 x head radius, pupil ≈ 0.55 x eye (use `art/props/face.tscn`).

**Outline** (`toon_outline` = 2.5 cm, `toon_outline_thin` = 1.2 cm, via `material_overlay`): silhouettes
≥ 0.25 m get the normal one, 0.1-0.25 m the thin one, < 0.1 m none. Never on: boxes, flat cylinder caps seen
from above (lids, discs), transparent materials, eyes, blob shadows, floors, walls (split normals tear).

**Blob shadow:** every character and floor item: `CylinderMesh` height 0.01, radius = footprint x 1.15, at
y = 0.006, `toon_blob_shadow`, `cast_shadow = off`.

**3D labels** (names, signs): `Label3D`, `pixel_size` 0.005, `font_size` 48 (names) / 96-160 (signs),
`outline_size` = font_size / 4, `outline_modulate` = `Toon.INK`, billboard enabled.

**Scene structure** (all stations, items, characters):
```
Root (Interactable / CharacterBody3D / StaticBody3D, synced; never scaled)
├─ Visual (Node3D, origin at the ground contact point): Juice targets THIS
│  └─ meshes...
├─ BlobShadow (flat disc, not under Visual so it does not squash)
└─ Body/Shape (colliders, simple boxes/capsules)
```

---

## 5. Juice API (`Juice` autoload, `scripts/art/juice.gd`)

All amounts below are at the mood default `Juice.intensity = 0.7` (1.0 = the original bouncy values).

| Call | What it does | Defaults |
|---|---|---|
| `Juice.pop_in(node, duration := 0.35)` | shows the node, scales 0 to rest with **~+10% overshoot** and a small y-leading stretch (±11%) | UI panels 0.25 s, world 0.3-0.4 s |
| `Juice.bounce(node, strength := 0.2)` | volume-preserving squash, then stretch, then settle, back to rest (strength x intensity) | 0.38 s; 0.12 subtle / 0.2 normal / 0.3 big |
| `Juice.pulse(node)` / `Juice.stop(node)` | looping tired breathe ±5% (y), period 0.9 s / stop + snap to rest | other effects pause it, it resumes |
| `Juice.punch_ui(control)` | scale punch to ~1.2x within 0.04 s, small undershoot, settles to 1 | 0.3 s |
| `Juice.grow_to(node, scale, duration := 0.45)` | animates to a NEW rest scale, small overshoot + ±14% wobble | plant stages |
| `Juice.pop_out(node, duration := 0.2, free_after := false)` | +8% anticipation, collapse, hide (or free) | keeps rest scale for the next pop_in |
| `Juice.shake(node, strength := 1.0)` | damped "nope" wiggle ±7° x strength (Control: rotation, Node3D: yaw) | 0.4 s, runs alongside scale effects |
| `Juice.burst(pos, color, count := 12)` | muted candy burst (0.6 s, 1.8-3.6 m/s, spread 70°, ~80% of count); pop flash only if `allow_celebration` | 8-12 |
| `Juice.float_text(pos, text, color := WHITE)` | billboard text in a muted colour, pops to ~1.18x, rises 0.8 m in 1.4 s, fades from 0.9 s, always on top | `"+$120"`, `Toon.GOLD` |
| `Juice.confetti(pos, count := 40)` | **no-op** unless `allow_celebration` | do not use |
| `Juice.puff(pos, color := Juice.DUST, count := 8)` | grimy dust puff, 0.55 s | plant, drop, landing, "something changed" |
| `Juice.splash(pos, count := 14)` | grey-blue droplets, 0.55 s | water, refill |
| `Juice.sparkle(pos, color, count := 10)` | a few dull grey motes that sink (bright glints only if `allow_celebration`) | prefer `puff(pos, Juice.GLOOM, 4)` |
| `Juice.enabled` | global off switch (pop_in/grow_to still set final state) | |
| `Juice.intensity` / `Juice.allow_celebration` | mood knobs: 0.7 / false. Do not change them in game code | |

Works on Node3D, Control (pivot handled via `pivot_offset_ratio`) and Node2D. Safe if the node is freed
mid-tween. A new scale effect replaces the running one and starts from the node's **rest** scale (no
drift, no stacking). 3D spawns go under `Game.world` (else the current 3D scene, else the root) and free
themselves. Everything is local-only cosmetics.

**Face prop** `res://art/props/face.tscn` (script `ToonFace`): tired googly eyes with heavy dark lids
(hemispheres across the eyes), eye bags, a two-segment frown, **no blush**. Slow blinks every 2.5-5.5 s.
Place on the front (-Z) surface of a head of radius ~0.4 (scale for bigger heads). Calls:
`face.set_mood(&"sad" | &"tired" | &"grim" | &"neutral")` (animated 0.25 s; `default_mood` export, `sad`),
`face.set_happy(true)` = `neutral` at most / `false` = back to `default_mood`, `face.blink()`,
`face.surprise()` (a tired startle: lids lift briefly), `face.look(Vector2)` (+x = character's right;
moods add a downcast gaze). The script finds its parts **by name anywhere below it** (`EyeL`/`EyeR` with
`Pupil` + `Lid` inside, `EyeBagL/R`, `MouthL/R`), null-safe. So it also drives a Blender-modelled face
under a `Visual` child: name the nodes the same and attach `toon_face.gd` (`refresh_parts()` after
swapping models). `show_blush` is a deprecated no-op.
```
[ext_resource type="PackedScene" path="res://art/props/face.tscn" id="5_face"]
[node name="Face" parent="Visual" instance=ExtResource("5_face")]
transform = Transform3D(1, 0, 0, 0, 1, 0, 0, 0, 1, 0, 1.22, -0.4)
```

---

## 6. Feedback per event (animation + sound + particles)

`pos` = the station/item global position; `up` = `Vector3.UP`. "World" effects must run on **every
peer** (rule 7): drive them from the synced state change (e.g. GrowPlot `stage`/`water` setters, item
`holder_id` changes) or have the server call an `@rpc("authority", "call_local", "unreliable")` effect
RPC, or listen to `GameState` signals (`sale_made`, `purchase_made`, `round_started`, `round_ended`) which
fire on every peer. UI feedback runs only on the local client.

| Event | Motion | Sound | Particles / text |
|---|---|---|---|
| **Buy** (shop) | buyer HUD: `punch_ui(money_label)`; packet appears: `pop_in(packet.Visual, 0.3)`; shopkeeper: `bounce(Visual, 0.15)` (no smile) | buyer: `Sfx.play(&"buy")` (2D, dull clink) | none (or `puff(counter_top, Juice.GLOOM, 4)`) |
| **Plant** | `pop_in(seedling, 0.35)`, `bounce(plot.Visual, 0.15)` | `Sfx.play(&"plant", pos)` | `puff(soil_pos, Toon.lighter(Toon.SOIL, 0.3), 8)` |
| **Water** | `bounce(plant, 0.12)`, soil swaps to `toon_soil_wet`, dry leaves back to `toon_leaf` | `Sfx.play(&"water", pos)` | `splash(soil_pos + up * 0.3, 14)` |
| **Stage change** | `grow_to(plant, Vector3.ONE)` or show the next stage node + `pop_in(it, 0.4)` | `Sfx.play(&"grow", pos)` | `puff(soil_pos, Toon.LEAF, 6)` |
| **Ready** | `pulse(buds_node)` until harvested | `Sfx.play(&"ready", pos)` (one low ding) | `puff(plant_top, Juice.GLOOM, 4)` (no sparkles, no "Ready!" text) |
| **Harvest** | `stop(buds)`, `pop_out(plant, 0.2)`, product `pop_in(product.Visual, 0.3)` | `Sfx.play(&"harvest", pos)` | `burst(plant_top, Toon.grade(seed.color), 10)` |
| **Sell** | `bounce(bin.Visual, 0.25)`; HUD `punch_ui(money)` + `punch_ui(quota_bar)` | `Sfx.play(&"sell", pos)` (register clunk) | `float_text(pos + up * 1.4, "+$%d" % v, Toon.GOLD)`, `burst(pos + up, Toon.GOLD, 8)` |
| **Pickup** | `bounce(item.Visual, 0.25)` | `Sfx.play(&"pickup", pos)` | none |
| **Drop / land** | `bounce(item.Visual, 0.3)` | `Sfx.play(&"drop", pos)` | `puff(floor_pos, Juice.DUST, 5)` |
| **Refill (well)** | `bounce(can.Visual, 0.2)`, `bounce(well bucket, 0.2)` | `Sfx.play(&"refill", pos)` | `splash(water_surface, 10)` |
| **Denied / error** | HUD `shake(prompt_panel)` (toast + error sound are automatic in Interactable) | `error` (automatic) | none |
| **Round start** | banner `pop_in(banner, 0.4)` ("SHIFT STARTED"), then `pop_out` after 1.5 s | `Sfx.play(&"round_start")` (flat buzzer) | none |
| **Timer ≤ 10 s** | every whole second `punch_ui(timer_label)`, timer colour `Toon.ERROR` | `tick` each second, `countdown` for 3-2-1 | none |
| **Round win** (grim relief) | overlay `pop_in(panel, 0.45)` ("SHIFT OVER. Quota met."), faces `set_mood(&"neutral")` at most | `Sfx.play(&"round_win")` (muffled end-of-shift bell) | **none** (no confetti) |
| **Round lose** | overlay `pop_in(panel, 0.45)`, then `shake(title, 1.5)`, faces `set_mood(&"grim")` | `Sfx.play(&"round_lose")` | none |
| **UI button** | none (theme press squash) | `ui_click` on `pressed` (`ui_hover` on hover, optional) | none |
| **UI panel open / close** | `pop_in(panel, 0.25)` / `pop_out(panel, 0.15)` | `ui_open` / `ui_close` | none |
| **Toast** | `pop_in(toast, 0.25)`, auto `pop_out(toast, 0.2, true)` after 2.5 s; error toasts also `shake(toast, 0.6)` | none (the caller already played one) | none |

**Idle life (tired, not bouncy):** characters breathe slowly (`Juice.pulse(Visual)` or bob ±0.02 m / 3 s)
and blink slowly via the face. The "$" sign over the bin hangs and bobs ±0.04 m / 2.5 s (no spinning).
READY buds pulse. Plants may sag-sway ±3° / 3 s. Timing curve: quick in, slow settle; never linear.

---

## 7. Sound (`Sfx` autoload, `scripts/art/sfx.gd`)

`Sfx.play(name: StringName, position := Vector3.INF)`: **no position = 2D** (UI, round jingles, the local
player's private feedback); **with position = 3D** (world events everyone nearby should hear).
All sounds are synthesised at startup (worker thread, no audio files): 16-bit mono 22.05 kHz
`AudioStreamWAV`s. 8 x 2D + 16 x 3D voices (oldest voice is stolen), 0-12% random pitch (none on
jingles/ticks), a 40 ms
per-sound retrigger guard, own `SFX` bus (added at runtime). Unknown names warn once and are ignored.

| Name | Sound | Use |
|---|---|---|
| `buy` | dull coin clink (money leaves) | purchase |
| `plant` | soft thump + pop | seed planted |
| `water` | bubbly splash | plot watered |
| `harvest` | snip-snip + rising pop | harvest |
| `sell` | old register drawer clunk + one tired ding | product sold |
| `pickup` | quick rising pop | item picked up |
| `drop` | low thud | item dropped / lands |
| `error` | short "uh-uh" buzz | denied action (automatic) |
| `grow` | small low bloop | stage change |
| `round_win` | "shift over": clunk + muffled two-tone bell going down (relief, not joy) | quota met |
| `round_lose` | sad trombone "wah-wah-wah-waaah" | time's up |
| `tick` | click | last 10 s of the timer |
| `ui_click` / `ui_open` / `ui_close` | tock / rising blip / falling blip | UI |
| extras: `ready` (one low break-room ding), `refill` (glugs), `ui_hover` (tiny tick), `coin` (dull coin), `pop` (generic pop), `whoosh`, `countdown` (3-2-1 beep), `round_start` (flat factory shift buzzer) | | |

Naming: lowercase snake_case; `ui_*` for interface, `round_*` for round flow, plain verbs for gameplay.
A new sound = a recipe in `Sfx._synth()` + a row in `Sfx.SETTINGS` + an entry in `Sfx.SOUNDS` (ask the
art agent). Other API: `play_at(name, node3d)`, `has_sound`, `get_stream` (for your own looping
player), `get_sound_names`, `stop_all`, `volume_db` (SFX bus), `enabled`.
Headless tests that play sounds: `Sfx.stop_all()` and let ~5 frames pass before `quit()`. Otherwise
quitting mid-sound prints a harmless "ObjectDB instances leaked" warning.

---

## 8. UI

The project theme is **`res://art/ui/theme.tres`** (already set in project.godot). Do not assign
another theme and do not override colours/fonts/styles per node when a variation exists. Set a
variation in code with `label.theme_type_variation = &"HudLabel"` or in a `.tscn` with
`theme_type_variation = &"HudLabel"`.

**Fonts:** engine default font, emboldened (body +0.45, "chunky" +0.9 for titles/HUD). Sizes: 16 subtle,
**20 body/buttons (default)**, 22 tabs/quota, 24 HUD, 30 big buttons, 32 header/money/timer, 48 title, 72
banner. All text is tired off-white `#ecebe6` with an **ink outline** (6 px at 20 px, 8-18 px on bigger
text) plus a soft drop shadow. Digits are tabular, so timers don't jitter. The whole theme is mood-graded
(faded panels, dull buttons, grey borders), so do not re-brighten it with overrides.

**Shapes:** radii 8 key caps · 12 inputs/small buttons/bars/tooltips · 16 buttons · 18 cards/HUD panels ·
22 toasts/big button · 24 panels. Panel border 4 px `#8a7cf0`, card border 3 px, toast border 3 px white.
Buttons are candy pills with a darker 6 px bottom lip (8 px BigButton, 4 px SmallButton) that squashes to
2 px and shifts the label down when pressed. Shadows: panels 14 px ink 35% (offset y 8), cards 6 px,
toasts 8 px, buttons 4 px.

**Spacing:** 8 px grid. The theme sets Box/Grid/Flow container separation = **10**. Screen-edge margin 16
(HUD) / 24 (menus). Panels already pad 24 x 20, cards 16 x 14. Buttons min height 44 (BigButton 64:
set `custom_minimum_size`).

**Colours:** info = Sky, error = Tomato, success = Grass, money/warning = Sunshine (all graded, §1). Panels
are faded blueberry `#5d53a3` (dark `#413a74`, card `#6f66b3`); HUD panels are ink at 62% alpha.

### Type variations (exact names)

| Variation | Base | Look | Use for |
|---|---|---|---|
| *(plain)* `Label` | - | 20 px, light + ink outline 6 | body text anywhere |
| `TitleLabel` | Label | 48 px chunky, outline 14 | menu/overlay titles |
| `BannerLabel` | Label | 72 px chunky **sunshine**, outline 18 | "ROUND COMPLETE!" (override colour to `Toon.ERROR` for "TIME'S UP!") |
| `HeaderLabel` | Label | 32 px chunky, outline 10 | section headers, card titles |
| `HudLabel` | Label | 24 px chunky, outline 8 + shadow | every HUD text, text inside toasts / HudPanels |
| `MoneyLabel` | Label | 32 px chunky **sunshine** | wallet, prices |
| `TimerLabel` | Label | 32 px chunky | round timer (`Toon.ERROR` override when ≤ 10 s) |
| `SubtleLabel` | Label | 16 px lavender, outline 4 | hints, descriptions, secondary info |
| `ErrorLabel` / `SuccessLabel` | Label | 20 px pink-red / mint-green | inline form errors / confirmations |
| `KeyCapLabel` | Label | 20 px chunky **ink**, no outline | the letter inside a `KeyCap` |
| *(plain)* `Button` | - | sky-blue candy pill, 20 px | default buttons |
| `BigButton` | Button | green, 30 px, radius 22, 8 px lip | primary CTA: Host, Start round, Next round, Resume |
| `DangerButton` | Button | tomato | Leave, Quit, Retry-from-scratch |
| `GoldButton` | Button | gold | Buy / money actions |
| `SmallButton` | Button | sky, 16 px, radius 12 | compact rows, +/- |
| *(plain)* `PanelContainer` / `Panel` | - | blueberry panel, radius 24, border 4, shadow | menus, shop window, overlays |
| `Card` | PanelContainer | lighter card, radius 18, border 3 | shop items, list entries |
| `HudPanel` | PanelContainer | ink 55%, radius 18, pad 16 x 8, no border | HUD boxes over the 3D view |
| `Toast` / `ToastError` / `ToastSuccess` | PanelContainer | sky / tomato / grass pill, white border | `Game.toast` kinds `&"info"` / `&"error"` / `&"success"` |
| `KeyCap` | PanelContainer | cream key with ink border + lip | "[E]" hints in prompts |
| `OverlayPanel` | Panel | full-screen ink 60% | dim behind modal overlays (round end, pause) |
| `CrosshairDot` | Panel | 10 x 10 white dot, ink border | crosshair (size it 10 x 10, centre it) |
| *(plain)* `ProgressBar` | - | ink track, white border, green fill | generic progress |
| `QuotaBar` | ProgressBar | chunky white-bordered pill, **sunshine** fill, 22 px text | quota progress (`show_percentage = false`, put a centred `HudLabel` "$248 / $400" on top) |

Also styled: `LineEdit` (cream field, ink text, sunshine focus ring), `CheckBox` (rounded check / radio),
`CheckButton` (candy switch), `TabContainer`/`TabBar` (selected tab merges into the panel), `PopupMenu`/
`OptionButton`, tooltips, scrollbars, sliders, `RichTextLabel` (light + outline).
Any `Panel`/`PanelContainer` draws the big panel. Use plain `Control`/containers for invisible grouping.

### Layout recipes (1280 x 720 reference, stretch mode canvas_items)
- **HUD:** top-centre `QuotaBar` 480 x 44 at y 16 with a centred `HudLabel`; `HudLabel` "Round 3"
  below it. Top-left `HudPanel` with `MoneyLabel`. Top-right `HudPanel` with `TimerLabel`. Screen centre
  `CrosshairDot`. Prompt at 62% height, centred: `HudPanel` holding HBox[`KeyCap`("E"), `HudLabel`("Water
  plant")]; denied: `HudLabel` + reason in `ErrorLabel`, panel at 70% alpha. Toasts stack top-centre under
  the quota bar (max 3, newest on top). Held item bottom-right `HudPanel` (`HudLabel` "Watering can 3/4").
  Player list left-middle `HudPanel`, one row per player: 14 px colour dot + `HudLabel` name.
- **Round end / pause:** full-rect `OverlayPanel`, centred `PanelContainer` ≥ 520 wide: `BannerLabel`
  (or `TitleLabel` for pause), `HeaderLabel` stats, buttons: `BigButton` primary, `Button` secondary,
  `DangerButton` leave.
- **Shop:** `PanelContainer` ~760 x 480 with `TitleLabel` "Shop" + `MoneyLabel`, `TabContainer` (Seeds,
  Upgrades), rows of `Card`s: 64 px colour swatch / icon, `HeaderLabel` name, `MoneyLabel` price,
  `SubtleLabel` description, `GoldButton` "Buy" (disabled when unaffordable).
- **Main menu:** sky gradient or 3D backdrop, centred `PanelContainer` 440 wide: `TitleLabel` "Grow With
  Friends", `LineEdit` name, colour row (8 round buttons, `Toon.PLAYER_COLORS`), `BigButton` "Host",
  HBox[`LineEdit` IP, `Button` "Join"], `ErrorLabel` for connection errors, `SubtleLabel` hints.

---

## 9. Per-object guidance

(All recipes exist in `tools/tests/art_kit.gd` and in `res://art/reference/style_kit.tscn`.)

- **Player (bean):** `Visual` (tilted -4° on X: a slouch) holds a `CapsuleMesh` r 0.42 h 1.55 at y 0.84 with
  `Toon.material(player_color)` (a `Toon.PLAYER_COLORS` entry, or `Toon.tint(picked)` for free picks)
  + outline; two feet: spheres r 0.14 scaled (1, 0.6, 1.35) at (±0.17, 0.08, -0.06) in
  `Toon.material(player_color.darkened(0.3))`; `face.tscn` at (0, 1.22, -0.4) (sad); **wilted** sprout hat:
  stem cylinder r 0.022-0.028 h 0.16 (toon_leaf) bent -18° + two `toon_leaf_dry` leaf spheres r 0.09 scaled
  (1.4, 0.4, 0.8) drooping (-35° / +40°); blob shadow r 0.48. `%NameLabel`: Label3D at y 2.1, 48 px, `Toon.lighter(player_color, 0.35)`, ink
  outline 12. Local player hides `Visual` + label. Juice: `bounce(Visual, 0.15)` on landing, face
  `surprise()` on a sale/harvest by that player.
- **Shopkeeper:** 1.3x bean: capsule r 0.58 h 1.9 `toon_orange`, cream apron (sphere r 0.5 scaled
  (0.95, 1.05, 0.5) on the front), `face.tscn` scaled 1.3 at (0, 1.45, -0.55), brown capsule moustache
  (r 0.05, h 0.26, tilted), red squashed-sphere flat cap (r 0.38, y-scale 0.55) + brim, no pompom, face
  `default_mood = &"grim"`. Stands behind the counter facing the room. Idle `Juice.pulse(Visual)` (slow
  breathing); on purchase `bounce(Visual, 0.15)`.
- **Shop counter:** box counter 2.4 x 1.0 x 0.8 `toon_wood` + cream top 2.6 x 0.12 x 1.0; candy awning of
  6 alternating red/cream slats (0.44 wide, tilted -15°) on white poles at 2.55 m; "SHOP" Label3D 96 px
  sunshine at ~2.95 m.
- **Grow plot:** round tub (CylinderMesh top 0.62 / bottom 0.54, h 0.42, `toon_wood`, outline) + rim torus
  (0.56-0.70, y-scale 1.4, `toon_brown`) + soil dome (sphere r 0.57 scaled (1, 0.16, 1) at y 0.4,
  `toon_soil` / `toon_soil_wet`); blob shadow r 0.72. Plant origin at the soil top (y 0.46).
  Stages (height above soil): **EMPTY** bare dome · **SEEDLING** 0.22 m: lime stem + 2 leaf blobs
  r 0.08 · **VEGETATIVE** 0.55 m: leaf stem + 4 leaf blobs r 0.13 around + top blob r 0.16 ·
  **FLOWERING** 0.8 m: 3 stacked bush spheres (r 0.26/0.22/0.17) + 5 small buds r 0.065 in
  `Toon.tint(seed.color)` · **READY** 1.0 m: same bush x1.2 + 7 big buds r 0.1 + crown bud r 0.12 in
  `Toon.tint(seed.color, Toon.Finish.GLOW)` (faint glow), pulsing. **Dry** (water < dry_threshold): leaves swap
  to `toon_leaf_dry`, plant tilts 8°, and a water-drop marker (sphere r 0.07 `toon_water` + thin outline)
  bobs 0.3 m above the plant with `Juice.pulse`.
- **Well:** stone drum (CylinderMesh 0.75/0.8, h 0.62, `toon_stone`), water disc r 0.64 at y 0.63
  (`toon_water`), fat stone rim torus (0.6-0.88, y-scale 1.4) at 0.68, two wood posts (r 0.07, h 1.7) at
  x ±0.78, brown beam, red PrismMesh roof 2.1 x 0.7 x 1.4 at y 2.25, cream rope + metal bucket. Can spots
  sit on the floor beside it.
- **Turn-in bin:** tangerine barrel (CylinderMesh 0.6/0.52, h 0.95, outline) with two gold hoops (torus
  0.55-0.64) and an ink "hole" disc on top; floating "$" Label3D 160 px `Toon.GOLD` (outline 36) at 1.55 m
  that hangs and bobs slowly (no spin). Sale: `bounce(Visual, 0.25)` + small muted gold burst + "+$N" float text.
- **Watering can:** body cylinder r 0.17-0.19 h 0.26 `toon_blue` + lid dome (sphere r 0.17 y-scale 0.35) +
  spout (cylinder r 0.03-0.045, h 0.34, tilted -55° forward along -Z) + metal rose + torus handle
  (0.09-0.13) on the back. ~0.5 m nose to handle. Optional: while watering, tilt the held can -35° on X
  for 0.3 s. Empty can (0 charges): lid swaps to `toon_gray`.
- **Seed packet:** flat puffy stadium: CapsuleMesh r 0.17 h 0.46 scaled (1, 1, 0.3) in
  `Toon.tint(seed.color)` + outline; rolled crimp on top (capsule r 0.035 h 0.3, horizontal, colour
  darkened 0.2); cream badge disc (r 0.1) on the front with a tiny two-leaf sprout.
- **Product:** open glass jar (CylinderMesh 0.15/0.14 h 0.2 `toon_glass` + glass lip torus) stuffed with
  6 faintly glowing buds (r 0.075-0.085, `Toon.tint(seed.color, GLOW)`) that spill over the top; cream label
  band near the base. `amount` 2+ → add a second jar or scale the Visual 1.2x.
- **Room:** sand matte floor, peach matte walls with a honey-wood skirting (0.3 m), sky-blue background.
  Keep the floor clear and flat; props hug the walls. Big readable landmarks: well (left), shop (back),
  bin (front), plots (right).
- **HUD:** see §8 layout recipes. Punch numbers on change, pop panels in, never let text sit directly
  on the 3D view without an outline (`HudLabel`) or a `HudPanel`.

---

## 10. Do / Don't

| Do | Don't |
|---|---|
| Use `toon_*.tres` / `Toon.material()` | `StandardMaterial3D.new()` in scenes, default grey materials, PBR metal/rough looks |
| Round, chunky, flared shapes; squashed spheres | thin sticks, sharp boxes as props, realistic proportions |
| Oversize props (2x) and give floor items a blob shadow | tiny details players can't read at 6 m |
| Ink `#2e2a3d` for outlines, pupils, text outline | pure black `#000000` anywhere |
| Mood-graded palette from §1, one hue per part, enough value contrast to read | fully saturated candy colours; also pure mud where props stop reading |
| Sad / tired / grim faces, slouches, wilted sprouts, flat copy | smiles, blush, confetti, sparkles, "!" and "Great job" text, cheerful jingles |
| Juice the `Visual` child; feedback on every peer | scaling physics bodies / synced roots; FX only in `_server_interact` |
| Theme variations for all UI | per-node `add_theme_color_override` for things a variation covers |
| Light text + ink outline everywhere | dark text on the 3D view, unoutlined small text |
| Short, snappy anims (0.2-0.45 s) with overshoot | long linear tweens, anims > 0.6 s for routine actions |
| Sound on every action (`Sfx.play`) | silent interactions, sound files / music (not needed yet) |
| Cold sun 0.6 + bluish-grey ambient 0.45 | warm/golden light, sun 1.0+, glow on, SSAO, heavy fog, pitch-dark rooms |

---

## 11. Tools, tests, regeneration

- **Test (headless, exit 0 = pass, 389 checks, ~1 s; ~12 s without `--fixed-fps`):**
  `godot --headless --path . --fixed-fps 60 -s res://tools/tests/art_test.gd`
  (loads every material/theme/env/prop, checks all type variations resolve, exercises every `Toon`,
  `Juice` and `Sfx` call incl. freed-node safety and self-freeing particles).
- **Screenshots** (needs Xvfb; Compatibility renderer, sun shadows off to show true colours):
  `xvfb-run -a -s "-screen 0 1280x720x24" godot --path . --rendering-driver opengl3 --rendering-method gl_compatibility --resolution 1280x720 --fixed-fps 60 -s res://tools/tests/art_preview.gd -- --out=/tmp/art_preview --shot=materials,ui,kit,juice`
- **Regenerate** materials, theme, env, face, style kit after changing `scripts/art/toon.gd` or the
  generator: `godot --headless --path . -s res://tools/gen_placeholder_art.gd`, then
  `godot --headless --path . --import`. Generated files are not hand-edited.

**Files:** `scripts/art/{sfx,juice,toon,toon_face}.gd` · `art/materials/toon_*.tres` · `art/ui/theme.tres` ·
`art/env/toon_environment.tres`, `art/env/toon_lighting.tscn` · `art/props/face.tscn`, `art/props/vignette.tscn` ·
`art/shaders/toon.gdshader`, `art/shaders/toon_example.tres` · `art/reference/style_kit.tscn` ·
`tools/gen_placeholder_art.gd` · `tools/tests/art_{test,preview,kit}.gd`.

---

## 12. Factory palette & mood (world/level agent)

The starting room is a **low-budget factory** ("cute-dystopia sweatshop"): the players are stuck here working
off a debt to a shady Boss. The rendering rules above still apply (primitives or modelled GLBs, toon
materials, ink outlines on round parts, oversized readable props), but the setting, palette and mood change:
**nobody is happy**. No smiles, no blush, no candy party colours in factory scenes. Bright hues are reserved
for gameplay signals only (strain colours, money, warnings).

| Material (`res://art/materials/`) | Hex | Finish | Use |
|---|---|---|---|
| `toon_concrete.tres` | `#9a978c` | matte | floor slab, cinder-block walls |
| `toon_concrete_dark.tres` | `#64625b` | matte | stains, mortar joints, grime, ceiling, drip trays |
| `toon_olive.tres` | `#7c8665` | matte | painted wall band, booth partitions, cash, army-surplus stuff |
| `toon_metal_dark.tres` | `#4e585e` | glossy | steel frames, bars, beams, pipes, housings, fedora |
| `toon_rust.tres` | `#a3572e` | matte | rust drips, rusty drums / shutter / deposit box |
| `toon_caution.tres` | `#f0c02e` | soft | caution stripes, hazard paint, warning signs |
| `toon_chainlink.tres` | `#a9b2b8` | soft | fence wire and posts |
| `toon_neon_green.tres` | `#b5ff7a` | glow 1.1 | fluorescent tubes, neon text |
| `toon_void.tres` | `#040405` | flat | holes / voids only (the one exception to "never pure black") |

Generated by `tools/gen_factory_art.gd` from `Toon.make()` (same finishes as §2); do not hand-edit. Regenerate:
`godot --headless --path . -s res://tools/gen_factory_art.gd && godot --headless --path . --import`.

**Factory lighting** (the room; replaces §3 there): Environment ambient colour `#9fb3b0` (cold green-grey)
energy **0.52**, background `#0c0e12`, tonemap Linear, glow **off**, saturation 0.86 / contrast 1.06. A weak
cold Sun (`#cfdcff`, **0.22**, soft shadows) for grounding; the room is lit by **drop-down pendant lamps**
(SpotLight3D warm `#ffd29a`, energy 2.4, range 5.2, angle 44°) that pool light on the floor at the stations,
fluorescent fixtures (Omni `#d6ffe0`, 1.1, range 7.5; one flickers), a warm Omni over the grow area (`#ffc47a`,
1.9) and a faint cold spot under the ceiling hole. Max 8 local lights, none with shadows. The ceiling stays
dim (nothing lights it directly); **every station must sit inside a pool** so it stays readable.

**Props**: placeholders live in `scenes/world/props/`. Meshes go under a `Visual` child so a modelled GLB can be
dropped in without touching placement; origin at the floor (wall-mounted props: the mount point on the wall
surface, front = +Z; ceiling props: the ceiling mount). Scripts find parts with `get_node_or_null`.
Signs/posters/blackboards: `props/sign_board.tscn` (`@tool`; `text`, `board_size`, colours; text shrinks to fit).

**Copy**: terse and grim, stencil or chalk: light text + ink outline on dark boards, or ink text on caution
yellow ("PAY UP", "NO BREAKS", "WORK HARDER", "DAYS WITHOUT INCIDENT: 0", "DEPOSIT PRODUCT / NO REFUNDS").
The Boss (`ShopkeeperNPC`) scowls, drums his fingers, beckons curtly and barks flat lines ("Tick tock.").
