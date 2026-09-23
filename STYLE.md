# STYLE.md: Grow With Friends art & feel guide

Owner: art agent. Everyone building visuals, UI, sound or feedback follows this file. APIs referenced here
are real and tested (`tools/tests/art_test.gd`). If something you need is missing, ask the lead. Do not
edit `art/**` or `scripts/art/**` yourself.

**Look:** "Gamble with Friends"-style party cartoon. Chunky rounded toys, candy-bright colours, soft toon
shading with a thin ink outline, googly eyes on anything alive, and *juicy* feedback on every action (pop,
squash, burst, ding). Nothing realistic, nothing sharp, nothing grey and sad.

Reference scene: **`res://art/reference/style_kit.tscn`**. Open it in the editor. It contains every object
recipe in this guide at the exact sizes quoted (built by `tools/tests/art_kit.gd`: copy recipes from there).

---

## 0. The 12 rules (read these even if you read nothing else)

1. **Materials only from the library** (`res://art/materials/toon_*.tres`) or `Toon.material(color)`. Never
   create a `StandardMaterial3D` by hand, never use the default white material.
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
10. **Light budget:** sun ≈ 0.5, ambient ≈ 0.65. More light than that blows the candy colours out to white (§3).
11. **Nothing important is static:** idle bob, blink, pulse or sway on characters, READY plants and signs.
12. **Placeholder-proof:** no image or audio assets are needed. Everything is primitives, theme, synth.

---

## 1. Palette

All colours are constants on the `Toon` class (`scripts/art/toon.gd`, global `class_name Toon`).

| Name | Hex | `Toon.` const | Library material | Use |
|---|---|---|---|---|
| Tomato | `#ff5a5f` | `TOMATO` | toon_red | errors, danger buttons, roofs, lids |
| Tangerine | `#ff9a3c` | `TANGERINE` | toon_orange | turn-in bin, shopkeeper, warm accents |
| Sunshine | `#ffd23f` | `SUNSHINE` | toon_yellow | money, quota fill, highlights, warnings |
| Gold | `#ffc53d` | `GOLD` | toon_gold | coins, "$" signs, hoops, "+$" float text |
| Lime | `#a8e04a` | `LIME` | toon_lime | seedlings, sprout hats, fresh growth |
| Grass | `#4fcb6b` | `GRASS` | toon_green | success, go/confirm buttons |
| Leaf | `#3dbe55` | `LEAF` | toon_leaf | plant leaves and bushes |
| Leaf (dry) | `#b8b04a` | `LEAF_DRY` | toon_leaf_dry | thirsty plant leaves |
| Bud | `#9be15d` | `BUD` | toon_bud (glows) | default buds (strains use their own colour) |
| Mint | `#33d1b0` | `MINT` | toon_teal | accents, alt watering can |
| Sky | `#4da8f7` | `SKY` | toon_blue | info, default buttons, watering cans |
| Water | `#45c4ff` | `WATER` | toon_water (glows) | water surfaces, droplets |
| Grape | `#9a6bff` | `GRAPE` | toon_purple | purple strain, fun accents |
| Bubblegum | `#ff7eb6` | `BUBBLEGUM` | toon_pink | blush, fun accents |
| Cocoa | `#a0663a` | `COCOA` | toon_brown | rims, beams, sacks, moustaches |
| Honey wood | `#d8964f` | `HONEY_WOOD` | toon_wood | planters, counters, posts, furniture |
| Soil | `#7a4a2a` | `SOIL` | toon_soil | dry soil |
| Soil (wet) | `#4a2c19` | `SOIL_WET` | toon_soil_wet | watered soil |
| Cream | `#fff4e0` | `CREAM` | toon_cream | labels, aprons, signs, bands |
| White | `#f8f9fa` | `WHITE` | toon_white | trims, poles, clouds |
| Pebble | `#b4bcc6` | `PEBBLE` | toon_gray | neutral props |
| Stone | `#9aa6b5` | `STONE` | toon_stone | well, rocks |
| Tin | `#c3cdd8` | `TIN` | toon_metal | buckets, can rose, metal bits |
| Skin | `#ffd0b0` | `SKIN` | toon_skin | hands/faces if you ever need skin |
| Sand | `#f0ddb0` | `SAND` | toon_floor | floor |
| Peach | `#ffe3c2` | `PEACH` | toon_wall | walls |
| Ink | `#2e2a3d` | `INK` | toon_dark | outlines, pupils, text outline (**never pure black**) |

**Semantic colours** (UI + feedback): `Toon.INFO` = Sky, `Toon.SUCCESS` = Grass, `Toon.ERROR` = Tomato,
`Toon.WARNING` = `Toon.MONEY` = Sunshine, `Toon.TEXT` `#fffdf7` (all UI text), `Toon.TEXT_SUBTLE` `#d9d2f2`,
UI panels `Toon.UI_PANEL` `#5b4bc4` (blueberry), `Toon.UI_PANEL_DARK` `#3b2f86`, `Toon.UI_CARD` `#7465d8`.

**Player colours:** `Toon.PLAYER_COLORS` = Sky `#4da8f7`, Bubblegum `#ff7eb6`, Sunshine `#ffd23f`, Grape
`#9a6bff`, Tangerine `#ff9a3c`, Mint `#33d1b0`, Tomato `#ff5a5f`, Lime `#a8e04a`. Default the Nth joiner to
`PLAYER_COLORS[N]`. **Strain colours** come from `SeedDef.color` (data/balance.tres). Use them via
`Toon.material(seed.color)`.

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
| `toon_water.tres` | glossy + glow 0.25 | well water, droplets |
| `toon_leaf.tres` | soft | leaves, bushes |
| `toon_bud.tres` | glow 0.35 | default bud (strains: `Toon.material(c, Toon.Finish.GLOW)`) |
| `toon_white.tres` | soft | trims, poles |
| `toon_gray.tres` | soft | neutral props |
| `toon_dark.tres` | soft | ink-coloured solid parts (holes, tyres) |
| `toon_floor.tres` | matte | floor |
| `toon_wall.tres` | matte | walls, ceiling |
| `toon_metal.tres` | glossy | bucket, can rose, hinges |
| `toon_skin.tres` | soft | skin |
| `toon_gold.tres` | glossy + glow 0.15 | coins, hoops, "$", trophies |
| `toon_cream.tres` | soft | aprons, labels, counter top, packet badge |
| `toon_stone.tres` | matte | well, rocks |
| `toon_leaf_dry.tres` | soft | leaves of a dry plant |
| `toon_eye_white.tres` | flat (unshaded) | eye whites, glints |
| `toon_eye_black.tres` | flat (unshaded) | pupils, drawn-on details |
| `toon_blush.tres` | flat, 55% alpha | cheeks |
| `toon_sparkle.tres` | flat | stars/glints/"ready" markers |
| `toon_glass.tres` | glossy, 38% alpha, double-sided | jars, windows |
| `toon_blob_shadow.tres` | flat, ink 28% alpha | fake contact shadow discs |
| `toon_outline.tres` | overlay | 2.5 cm ink outline (`material_overlay`) |
| `toon_outline_thin.tres` | overlay | 1.2 cm ink outline for small parts |

Finish parameters (in `Toon.make`): **soft** roughness 0.4 / specular 0.35 / rim 0.3 (tint 0.5), which gives a
soft two-tone plus a toy-like highlight. **matte** 0.8 / 0.1 / rim 0.12 means no highlight. **glossy** 0.18 / 0.8 / rim 0.35
gives a crisp highlight. **glow** is soft plus emission. **flat** is unshaded (sticker). Keep roughness < 0.95 on toon
materials: at 1.0 Godot's rim term washes the whole surface out.

**Runtime tints:** `Toon.material(color, finish := Toon.Finish.SOFT)` returns a **cached, shared**
material (one per colour+finish). Never modify what `Toon.material()`/`Toon.lib()`/`load()` return. If you
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
| Sun (DirectionalLight3D) | energy **0.5**, colour `#fff1d6`, rotation (-55°, 35°, 0), shadows on, `shadow_opacity` 0.55, `shadow_blur` 1.5 |
| Environment (`res://art/env/toon_environment.tres`) | background colour `#8fd3ff`, ambient **colour** `#d6cfff` (lavender) energy **0.65**, tonemap Linear, glow **off**, adjustments saturation 1.08 / contrast 1.02, no SSAO/SSIL/SDFGI/fog |
| Omni/Spot lights (optional) | warm `#ffe7c4`, energy ≤ 0.4, range 6-8 m, shadows off |

**Light budget:** direct light on any surface ≈ 0.5-0.6 plus ambient 0.65 gives lit ≈ 1.1x albedo and shade
≈ 0.6x albedo with a lavender tint (the cartoon look). Sun 1.0 + ambient 0.6 (the current room stub)
renders sand, yellow and pink as **white**. If the room has a ceiling, set the ceiling mesh's
`cast_shadow = off` so the sun still reaches the floor. Glow is off because it washed the whole frame out
in testing. Emission alone makes buds and water pop.

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

| Call | What it does | Defaults |
|---|---|---|
| `Juice.pop_in(node, duration := 0.35)` | shows the node, scales 0 to rest with **+18% overshoot** and a y-leading stretch (±16%) | UI panels 0.25 s, world 0.3-0.4 s |
| `Juice.bounce(node, strength := 0.2)` | volume-preserving squash, then stretch, then settle, back to rest | 0.38 s; 0.12 subtle / 0.2 normal / 0.3 big |
| `Juice.pulse(node)` / `Juice.stop(node)` | looping breathe ±7% (y), ±5% (xz), period 0.9 s / stop + snap to rest | other effects pause it, it resumes |
| `Juice.punch_ui(control)` | scale punch: snaps to ~1.3x within 0.04 s, ~6% undershoot, settles to 1 | 0.3 s |
| `Juice.grow_to(node, scale, duration := 0.45)` | animates to a NEW rest scale, overshoot + ±20% wobble | plant stages |
| `Juice.pop_out(node, duration := 0.2, free_after := false)` | +12% anticipation, collapse, hide (or free) | keeps rest scale for the next pop_in |
| `Juice.shake(node, strength := 1.0)` | damped "nope" wiggle ±7° x strength (Control: rotation, Node3D: yaw) | 0.4 s, runs alongside scale effects |
| `Juice.burst(pos, color, count := 12)` | candy burst (0.65 s, 2.4-4.6 m/s, spread 75°) + 0.18 s pop flash | 12-16 |
| `Juice.float_text(pos, text, color := WHITE)` | billboard text, pops to 1.25x, rises 1.1 m in 1.2 s, fades from 0.8 s, always on top | `"+$120"`, `Toon.GOLD` |
| `Juice.confetti(pos, count := 40)` | 6-colour tumbling chips, 1.8 s | round win, big sale |
| `Juice.puff(pos, color := Juice.DUST, count := 8)` | soft dust puff, 0.55 s | plant, drop, landing |
| `Juice.splash(pos, count := 14)` | water droplets, 0.55 s | water, refill |
| `Juice.sparkle(pos, color := SUNSHINE, count := 10)` | flat glints drifting up, 1 s | READY, buy, upgrades |
| `Juice.enabled` | global off switch (pop_in/grow_to still set final state) | |

Works on Node3D, Control (pivot handled via `pivot_offset_ratio`) and Node2D. Safe if the node is freed
mid-tween. A new scale effect replaces the running one and starts from the node's **rest** scale (no
drift, no stacking). 3D spawns go under `Game.world` (else the current 3D scene, else the root) and free
themselves. Everything is local-only cosmetics.

**Face prop** `res://art/props/face.tscn` (script `ToonFace`): googly eyes + blush that blink every
2.2-5 s by themselves. Place on the front (-Z) surface of a head of radius ~0.4 (scale for bigger heads).
Calls: `face.blink()`, `face.surprise()` (eyes pop wide), `face.look(Vector2)` (+x = character's right),
`face.set_happy(true/false)` (^ ^ squint), `face.show_blush = false`.
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
| **Buy** (shop) | buyer HUD: `punch_ui(money_label)`; packet appears: `pop_in(packet.Visual, 0.3)`; shopkeeper: `bounce(Visual, 0.2)` + `face.surprise()` | buyer: `Sfx.play(&"buy")` (2D) | `sparkle(counter_top, Toon.SUNSHINE, 8)` |
| **Plant** | `pop_in(seedling, 0.35)`, `bounce(plot.Visual, 0.15)` | `Sfx.play(&"plant", pos)` | `puff(soil_pos, Toon.lighter(Toon.SOIL, 0.3), 8)` |
| **Water** | `bounce(plant, 0.12)`, soil swaps to `toon_soil_wet`, dry leaves back to `toon_leaf` | `Sfx.play(&"water", pos)` | `splash(soil_pos + up * 0.3, 14)` |
| **Stage change** | `grow_to(plant, Vector3.ONE)` or show the next stage node + `pop_in(it, 0.4)` | `Sfx.play(&"grow", pos)` | `puff(soil_pos, Toon.LEAF, 6)` |
| **Ready** | `pulse(buds_node)` until harvested | `Sfx.play(&"ready", pos)` | `sparkle(plant_top, Toon.SUNSHINE)` |
| **Harvest** | `stop(buds)`, `pop_out(plant, 0.2)`, product `pop_in(product.Visual, 0.3)` | `Sfx.play(&"harvest", pos)` | `burst(plant_top, seed.color, 16)` |
| **Sell** | `bounce(bin.Visual, 0.3)`; HUD `punch_ui(money)` + `punch_ui(quota_bar)` | `Sfx.play(&"sell", pos)` | `float_text(pos + up * 1.4, "+$%d" % v, Toon.GOLD)`, `burst(pos + up, Toon.GOLD, 14)` |
| **Pickup** | `bounce(item.Visual, 0.25)` | `Sfx.play(&"pickup", pos)` | none |
| **Drop / land** | `bounce(item.Visual, 0.3)` | `Sfx.play(&"drop", pos)` | `puff(floor_pos, Juice.DUST, 5)` |
| **Refill (well)** | `bounce(can.Visual, 0.2)`, `bounce(well bucket, 0.2)` | `Sfx.play(&"refill", pos)` | `splash(water_surface, 10)` |
| **Denied / error** | HUD `shake(prompt_panel)` (toast + error sound are automatic in Interactable) | `error` (automatic) | none |
| **Round start** | banner `pop_in(banner, 0.4)`, then `pop_out` after 1.5 s | `Sfx.play(&"round_start")` | none |
| **Timer ≤ 10 s** | every whole second `punch_ui(timer_label)`, timer colour `Toon.ERROR` | `tick` each second, `countdown` for 3-2-1 | none |
| **Round win** | overlay `pop_in(panel, 0.45)`, faces `set_happy(true)` | `Sfx.play(&"round_win")` | `confetti(cam.global_position - cam.global_basis.z * 2.5 - up * 0.6)` |
| **Round lose** | overlay `pop_in(panel, 0.45)`, then `shake(title, 1.5)` | `Sfx.play(&"round_lose")` | none |
| **UI button** | none (theme press squash) | `ui_click` on `pressed` (`ui_hover` on hover, optional) | none |
| **UI panel open / close** | `pop_in(panel, 0.25)` / `pop_out(panel, 0.15)` | `ui_open` / `ui_close` | none |
| **Toast** | `pop_in(toast, 0.25)`, auto `pop_out(toast, 0.2, true)` after 2.5 s; error toasts also `shake(toast, 0.6)` | none (the caller already played one) | none |

**Idle life:** shopkeeper `Visual` bobs ±0.03 m every 2.2 s (or just `Juice.pulse(Visual)`), blinks via the
face. The "$" sign over the bin bobs ±0.08 m / 1.6 s and spins 60°/s. READY buds pulse. Plants may sway
±3° / 2.5 s. Timing curve: fast in (≤ 0.12 s to peak), slow settle; never linear.

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
| `buy` | coin chime (B5 then E6) | purchase |
| `plant` | soft thump + pop | seed planted |
| `water` | bubbly splash | plot watered |
| `harvest` | snip-snip + rising pop | harvest |
| `sell` | ka-ching register bell | product sold |
| `pickup` | quick rising pop | item picked up |
| `drop` | low thud | item dropped / lands |
| `error` | short "uh-uh" buzz | denied action (automatic) |
| `grow` | rising bloop | stage change |
| `round_win` | C-E-G then C chord jingle | quota met |
| `round_lose` | sad trombone "wah-wah-wah-waaah" | time's up |
| `tick` | click | last 10 s of the timer |
| `ui_click` / `ui_open` / `ui_close` | tock / rising blip / falling blip | UI |
| extras: `ready` (sparkle arpeggio), `refill` (glugs), `ui_hover` (tiny tick), `coin` (small coin), `pop` (generic pop), `whoosh`, `countdown` (3-2-1 beep), `round_start` (2-note fanfare) | | |

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
banner. All text is `#fffdf7` with an **ink outline** (6 px at 20 px, 8-18 px on bigger text) plus a soft
drop shadow. Digits are tabular, so timers don't jitter.

**Shapes:** radii 8 key caps · 12 inputs/small buttons/bars/tooltips · 16 buttons · 18 cards/HUD panels ·
22 toasts/big button · 24 panels. Panel border 4 px `#8a7cf0`, card border 3 px, toast border 3 px white.
Buttons are candy pills with a darker 6 px bottom lip (8 px BigButton, 4 px SmallButton) that squashes to
2 px and shifts the label down when pressed. Shadows: panels 14 px ink 35% (offset y 8), cards 6 px,
toasts 8 px, buttons 4 px.

**Spacing:** 8 px grid. The theme sets Box/Grid/Flow container separation = **10**. Screen-edge margin 16
(HUD) / 24 (menus). Panels already pad 24 x 20, cards 16 x 14. Buttons min height 44 (BigButton 64:
set `custom_minimum_size`).

**Colours:** info = Sky, error = Tomato, success = Grass, money/warning = Sunshine. Panels are blueberry
`#5b4bc4` (dark `#3b2f86`, card `#7465d8`); HUD panels are ink at 55% alpha.

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

- **Player (bean):** `Visual` holds a `CapsuleMesh` r 0.42 h 1.55 at y 0.84 with `Toon.material(player_color)`
  + outline; two feet: spheres r 0.14 scaled (1, 0.6, 1.35) at (±0.17, 0.08, -0.06) in
  `Toon.material(player_color.darkened(0.25))`; `face.tscn` at (0, 1.22, -0.4); sprout hat: stem cylinder
  r 0.022-0.028 h 0.16 (toon_leaf) at y 1.66 + two lime leaf spheres r 0.09 scaled (1.4, 0.4, 0.8) tilted
  ±25°; blob shadow r 0.48. `%NameLabel`: Label3D at y 2.1, 48 px, `Toon.lighter(player_color, 0.35)`, ink
  outline 12. Local player hides `Visual` + label. Juice: `bounce(Visual, 0.15)` on landing, face
  `surprise()` on a sale/harvest by that player.
- **Shopkeeper:** 1.3x bean: capsule r 0.58 h 1.9 `toon_orange`, cream apron (sphere r 0.5 scaled
  (0.95, 1.05, 0.5) on the front), `face.tscn` scaled 1.3 at (0, 1.45, -0.55), brown capsule moustache
  (r 0.05, h 0.26, tilted), red squashed-sphere cap (r 0.38, y-scale 0.55) + brim + cream pompom. Stands
  behind the counter facing the room. Idle `Juice.pulse(Visual)` (breathing); on purchase `bounce(Visual,
  0.2)` + `face.surprise()`.
- **Shop counter:** box counter 2.4 x 1.0 x 0.8 `toon_wood` + cream top 2.6 x 0.12 x 1.0; candy awning of
  6 alternating red/cream slats (0.44 wide, tilted -15°) on white poles at 2.55 m; "SHOP" Label3D 96 px
  sunshine at ~2.95 m.
- **Grow plot:** round tub (CylinderMesh top 0.62 / bottom 0.54, h 0.42, `toon_wood`, outline) + rim torus
  (0.56-0.70, y-scale 1.4, `toon_brown`) + soil dome (sphere r 0.57 scaled (1, 0.16, 1) at y 0.4,
  `toon_soil` / `toon_soil_wet`); blob shadow r 0.72. Plant origin at the soil top (y 0.46).
  Stages (height above soil): **EMPTY** bare dome · **SEEDLING** 0.22 m: lime stem + 2 leaf blobs
  r 0.08 · **VEGETATIVE** 0.55 m: leaf stem + 4 leaf blobs r 0.13 around + top blob r 0.16 ·
  **FLOWERING** 0.8 m: 3 stacked bush spheres (r 0.26/0.22/0.17) + 5 small buds r 0.065 in
  `Toon.material(seed.color)` · **READY** 1.0 m: same bush x1.2 + 7 big buds r 0.1 + crown bud r 0.12 in
  `Toon.material(seed.color, Toon.Finish.GLOW)`, pulsing. **Dry** (water < dry_threshold): leaves swap
  to `toon_leaf_dry`, plant tilts 8°, and a water-drop marker (sphere r 0.07 `toon_water` + thin outline)
  bobs 0.3 m above the plant with `Juice.pulse`.
- **Well:** stone drum (CylinderMesh 0.75/0.8, h 0.62, `toon_stone`), water disc r 0.64 at y 0.63
  (`toon_water`), fat stone rim torus (0.6-0.88, y-scale 1.4) at 0.68, two wood posts (r 0.07, h 1.7) at
  x ±0.78, brown beam, red PrismMesh roof 2.1 x 0.7 x 1.4 at y 2.25, cream rope + metal bucket. Can spots
  sit on the floor beside it.
- **Turn-in bin:** tangerine barrel (CylinderMesh 0.6/0.52, h 0.95, outline) with two gold hoops (torus
  0.55-0.64) and an ink "hole" disc on top; floating "$" Label3D 160 px `Toon.GOLD` (outline 36) at 1.55 m
  that bobs + spins. Sale: `bounce(Visual, 0.3)` + gold burst + "+$N" float text.
- **Watering can:** body cylinder r 0.17-0.19 h 0.26 `toon_blue` + lid dome (sphere r 0.17 y-scale 0.35) +
  spout (cylinder r 0.03-0.045, h 0.34, tilted -55° forward along -Z) + metal rose + torus handle
  (0.09-0.13) on the back. ~0.5 m nose to handle. Optional: while watering, tilt the held can -35° on X
  for 0.3 s. Empty can (0 charges): lid swaps to `toon_gray`.
- **Seed packet:** flat puffy stadium: CapsuleMesh r 0.17 h 0.46 scaled (1, 1, 0.3) in
  `Toon.material(seed.color)` + outline; rolled crimp on top (capsule r 0.035 h 0.3, horizontal, colour
  darkened 0.2); cream badge disc (r 0.1) on the front with a tiny two-leaf sprout.
- **Product:** open glass jar (CylinderMesh 0.15/0.14 h 0.2 `toon_glass` + glass lip torus) stuffed with
  6 glowing buds (r 0.075-0.085, `Toon.material(seed.color, GLOW)`) that spill over the top; cream label
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
| Candy palette from §1, one hue per part | muddy, desaturated or grey-brown colour schemes |
| Juice the `Visual` child; feedback on every peer | scaling physics bodies / synced roots; FX only in `_server_interact` |
| Theme variations for all UI | per-node `add_theme_color_override` for things a variation covers |
| Light text + ink outline everywhere | dark text on the 3D view, unoutlined small text |
| Short, snappy anims (0.2-0.45 s) with overshoot | long linear tweens, anims > 0.6 s for routine actions |
| Sound on every action (`Sfx.play`) | silent interactions, sound files / music (not needed yet) |
| Sun 0.5 + ambient 0.65 | sun 1.0+, glow on, SSAO, heavy fog, dark rooms |

---

## 11. Tools, tests, regeneration

- **Test (headless, exit 0 = pass, 333 checks, ~1 s; ~9 s without `--fixed-fps`):**
  `godot --headless --path . --fixed-fps 60 -s res://tools/tests/art_test.gd`
  (loads every material/theme/env/prop, checks all type variations resolve, exercises every `Toon`,
  `Juice` and `Sfx` call incl. freed-node safety and self-freeing particles).
- **Screenshots** (needs Xvfb; Compatibility renderer, sun shadows off to show true colours):
  `xvfb-run -a -s "-screen 0 1280x720x24" godot --path . --rendering-driver opengl3 --rendering-method gl_compatibility --resolution 1280x720 --fixed-fps 60 -s res://tools/tests/art_preview.gd -- --out=/tmp/art_preview --shot=materials,ui,kit,juice`
- **Regenerate** materials, theme, env, face, style kit after changing `scripts/art/toon.gd` or the
  generator: `godot --headless --path . -s res://tools/gen_placeholder_art.gd`, then
  `godot --headless --path . --import`. Generated files are not hand-edited.

**Files:** `scripts/art/{sfx,juice,toon,toon_face}.gd` · `art/materials/toon_*.tres` · `art/ui/theme.tres` ·
`art/env/toon_environment.tres`, `art/env/toon_lighting.tscn` · `art/props/face.tscn` ·
`art/shaders/toon.gdshader`, `art/shaders/toon_example.tres` · `art/reference/style_kit.tscn` ·
`tools/gen_placeholder_art.gd` · `tools/tests/art_{test,preview,kit}.gd`.
