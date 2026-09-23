# MODELING.md: Blender model pipeline

Owner: pipeline agent. Every 3D model in the game is authored as a **Python script driving Blender (bpy
4.2, no GUI)** with the helper library `tools/blender/gwf.py`. The script exports a `.glb` into
`res://art/models/`, and Godot imports it with fixed settings. At runtime the model **toon-shades itself**
(`scripts/art/toonify.gd`). Read **STYLE.md** first for mood, palette, sizes and outlines. This file is
the *how*.

Files: `tools/blender/gwf.py` (library) · `tools/blender/build.py` (CLI) · `tools/blender/models/*.py`
(one script per model family) · `tools/blender/gwf_post_import.gd` (import hook) · `art/models/*.glb`
+ `.glb.import` + `manifest.json` (generated, never hand-edited) · `scripts/art/toonify.gd` (class
`Toonify`) · `tools/tests/models_test.gd` (headless suite) · `tools/tests/models_preview.gd` (renders).
Worked examples: `tools/blender/models/oil_drum.py`, `tools/blender/models/pendant_lamp.py` (a family).

---

## 0. Recipe (copy-paste)

```bash
# 1. Write tools/blender/models/<family>.py (template below). One file per model or per family.
# 2. Build, import, render in-game shots and run the model tests (~15 s):
python3 tools/blender/build.py <family> --test --shots /tmp/shots/<family>
# 3. LOOK at /tmp/shots/<family>/<model>_sheet_1.png (close-up) and <model>_eye.png (player's view at
#    fov 80, eye height 1.6 m). Fix, re-run. The table must say ok, and models_test must report 0 failures.
# 4. Hook the model into its scene (section 5), then check the scene:
tools/check_files.sh res://scenes/world/props/<scene>.tscn
```

```python
"""crate: a cheap slatted crate, dented (room decor). Floor mount, 0.9 m cube, goes in
scenes/world/props/crate.tscn."""
from gwf import *


def build():
    wood, metal = lib("wood"), lib("metal_dark")
    body = subdivide(box((0.9, 0.9, 0.9), bevel=0.04, mat=wood, name="body"), 5)  # stands on z = 0
    dent(body, (0.25, -0.45, 0.6), radius=0.25, depth=0.05)            # the front is -Y
    bands = [box((0.94, 0.94, 0.08), pos=(0, 0, z), bevel=0.02, mat=metal, name="band") for z in (0.12, 0.7)]
    crate = join([body] + bands, "crate")                            # one mesh, one surface per material
    export(crate, "crate", kind="prop", mount="floor")               # -> art/models/crate.glb
```

Build **only your own scripts** (`build.py <family>`). Running `build.py` without names builds every
model, including other people's work in progress.

---

## 1. How it works

1. `build.py <family>` imports bpy and gwf, then calls `reset()` and your `build()`. Each `export()` applies
   the modifiers, sorts the mesh into a canonical order, checks it (size, origin, materials, budget),
   and writes `art/models/<name>.glb` **only if the bytes changed**. Builds are deterministic: re-running
   gives byte-identical files, so there's no reimport and no git churn.
2. build.py merges fixed import settings into each `<name>.glb.import`: root type Node3D, **root script
   = `toonify.gd`**, `gwf_post_import.gd`, no LODs, no tangents, shadow meshes on, animation off, name
   suffixes off. It then updates `art/models/manifest.json` (kind, Godot front, mount, tris, size,
   materials, script) and runs **one** `godot --headless --path . --import`. The import is serialised by a
   lock, so several modelers can build at once.
3. In Godot the imported scene's root is a `Toonify` node. When you instance it, its `_ready()` converts
   every material into a toon material (same recipe as the library: `Toon.make`). It uses the real
   library `.tres` for `toon_*` materials, recolours `TINT*` materials with its `tint`, and can add a
   size-aware ink outline. Nothing needs to be called for plain props.
4. `models_test.gd` checks every model headless. `models_preview.gd` renders them in the game's toon
   lighting under xvfb.

In the **editor** the models show their base colours with default (PBR) shading; toon shading appears at
runtime (Toonify is not a `@tool` script, on purpose: it would bake overrides into saved scenes).

---

## 2. Conventions

| Topic | Rule |
|---|---|
| Units / up | 1 Blender unit = 1 m. Blender Z is up (Godot Y). |
| **Front** | **Always model the front facing Blender -Y** (what Blender's *Front* view shows; +X is to your right as you look at it). gwf helpers agree: `arc_panel`/`band` angle 0 and `extrude_profile` all point at -Y. |
| **Kind → Godot facing** | `export(kind=...)`: `prop`, `station`, `part` → front lands on **Godot +Z**, like every station and room prop ("front = +Z faces the room centre / out of the wall"). `character`, `item` → front on **Godot -Z** (face.tscn, `look_at`, the hand socket and camera all look down -Z). The 180° turn is baked into vertices and node *positions*: node rotations stay identity. |
| **Origin / mount** | The origin is the contact point. `mount="floor"`: footprint centred on the origin, lowest point z = 0. `"ceiling"`: mount point at the origin, everything below z = 0. `"wall"`: back on the plane y = 0, body towards the front (-y); in Godot the back is on z = 0 and the body is in +Z. `"free"`: no check (rare). Wall-standing floor things (roller door, fence) use `floor` with their back at y = 0. |
| Names | Model / file names `snake_case` (`oil_drum`, `plant_ready_dry`). One script per model **family** (`plant_stages.py` exports 8 GLBs). Node names that Godot code addresses are `PascalCase` exactly as the scene script expects (`Torso`, `HeadPivot`, `Bulb`, `MinuteHand`). Blender needs unique names, so `Hand__L` / `Hand__R` import as `Hand` (the post-import script strips from `__`). |
| Budgets (tris) | `prop` 3000 · `station` 5000 · `character` 8000 · `item` 1500 · `part` 3000 (`export(..., budget=N)` overrides). Over budget = WARN in the table. Aim for 1–2.5k on props: round shapes need their segments (24+ radial on anything ≥ 0.3 m). |
| Size | The largest dimension must be 0.05–6 m (export refuses otherwise). Anything longer (pipes, cable trays, the grow-light bar) is built as **repeatable segments** (2–3 m) and tiled in the scene. |
| Materials | Flat colours only: no textures, no UVs. **Prefer `lib("<name>")`**: a Blender material named `toon_<name>` with the library colour, which Toonify swaps for `res://art/materials/toon_<name>.tres` at runtime, so art-agent retunes reach every model without a rebuild. Custom colours: `material("name", "#hex", finish)` with finish `soft` (props, default) · `matte` (concrete, fabric, rubber, soil) · `glossy` (enamel, metal, glass, wet) · `glow` (faint emission 0.12; `emission=` to change) · `flat` (unshaded sticker: eyes, LEDs, bulbs, screens). Hexes come from the STYLE.md palette (`pal("INK")` reads `Toon` constants) and the factory palette (STYLE §12). 3–7 materials per prop. |
| **TINT** | `tint_material("TINT_paint", shade=1.0)`: painted neutral grey `#d9d9d9` in Blender. At runtime it becomes `tint × shade` (`shade` 0.7 = a darker shade of the same tint, for stripes and undersides). Use it for strain colour (buds, seed packets, product), player colour (bean body) and paint variety (drums, crates, lockers). Without a tint it stays neutral grey. |
| Vertex colours | Not used (skip). Colour-block with materials, `paint()` and `band()`. |
| Style (STYLE.md) | Chunky, rounded, oversized, readable at 6 m. **Nobody is happy**: dents (`dent`), crooked hangs 4–8°, slouches, sagging cords, rust creeping up from the floor, drips, chipped paint, wilting. Round first (lathe/cyl/sphere/torus); boxes get fat bevels. Break symmetry a little (`jitter` 5–10 mm, ±8° rotations). Bright colours only for gameplay signals (strain colour, money, caution). |

---

## 3. gwf cheat sheet (`from gwf import *`)

Builders return a mesh object at `pos` (m), `rot` (degrees XYZ). **Anchors:** `box`, `plank`, `cyl`,
`cone`, `capsule`, `lathe` stand on `pos` (pos = centre of the bottom); `sphere`/`torus` are centred.
`mat=` takes a material or a library name string (`mat="rust"`).

| Call | Use |
|---|---|
| `box((x, y, z), pos, rot, bevel=0.02)` | beveled box (bevel = radius; segments auto by size) |
| `plank(length, width=0.14, thickness=0.035, ...)` | boards (pallets, beams, shelves), small bevel, wood |
| `cyl(r, depth, verts=24, ..., bevel=0.015, radius_top=None)` / `cone(...)` | drums, posts, bolts (`verts=6` = hex nut) |
| `sphere(r, pos, scale=(1, 1, 1))` | squashed spheres: leaves, blobs, pillows, bulbs |
| `capsule(r, height, ...)` | beans, rails, rolled crimps (height = total, like Godot) |
| `torus(major, minor, ...)` | rims, hoops, handles, collars |
| `lathe([(r, z), ...], verts=24, closed=False)` | revolved profiles: drums with ribs, jars, pots, shades (`closed=True` = shell with thickness) |
| `pipe(points, r, bend=None)` / `sag_points(a, b, sag)` | pipes, cords, cables, handles, frames (rounded corners) |
| `extrude_profile([(u, v), ...], depth, pos)` | flat shapes drawn as you see them from the front, extruded towards -Y: signs, brackets, arrows, stencils |
| `arc_panel(r, height, angle)` / `band(r_or_fn, z0, z1, top=fn)` | labels and patches on round bodies / rings with wavy edges (rust, paint stripes, water lines) |
| `empty("Name", pos)` | pivot / socket / marker node (exports as a Node3D) |
| `bevel(obj, width)` · `subdiv(obj, 2)` · `mirror(obj, "X")` · `array(obj, n, offset)` | live modifiers (applied at join/export; mirror/array run before bevel) |
| `boolean_cut(obj, cutter)` | carve now (before the bevel, so cut edges get rounded too) |
| `dent(obj, point, radius, depth)` · `jitter(obj, 0.008)` · `taper(obj, 0.85)` · `move_verts(obj, fn)` | tired, cheap, hand-made deformation (on the base mesh, before bevel) |
| `subdivide(obj, cuts=4)` | give boxes/panels vertices to dent, jitter or taper (bevels still only round real edges) |
| `paint(obj, mat, lambda c, n: ...)` | colour-block faces by centre/normal: two-tone splits, the inside of a shade |
| `set_smooth(obj, angle=35)` | smooth shading with edges sharper than `angle` kept hard (applied after modifiers) |
| `join(objs, "Name", origin=(x, y, z))` | apply everything and merge into ONE mesh (one surface per material). `origin` = pivot for animated parts |
| `set_parent(child, parent)` · `set_origin(obj, point)` · `set_origin_to_floor(obj)` · `apply_transform(obj)` · `duplicate(obj, pos, rot)` | hierarchy, pivots |
| `lib("rust")` · `material("name", "#hex", "matte")` · `tint_material("TINT_x", shade)` · `pal("INK")` · `srgb("#hex")` | materials (hex is sRGB; gwf converts to Blender's linear) |
| `report(objs)` | prints tris, size (Godot W×H×D), z range, materials |
| `export(objs, "name", kind="prop", mount="floor", budget=None)` | write `art/models/<name>.glb` (+ checks); `objs` may be several top-level nodes |
| `reset()` | empty scene: **call it at the start of each model** in a family script |

---

## 4. Commands

| Command | What |
|---|---|
| `python3 tools/blender/build.py <family> [<family> ...]` | build the given scripts (file stems), import, print the table. Exit 0 = all ok |
| `python3 tools/blender/build.py` | every script (also warns about orphan `.glb`s no script produces) |
| `... --test` | then run `godot --headless --path . -s res://tools/tests/models_test.gd` (all models) |
| `... --shots DIR` | then render the built models in-game (xvfb): `DIR/<first>_sheet_1.png` + `DIR/<first>_eye.png` |
| `... --preview [--preview-dir DIR]` | also a Blender Cycles turntable strip per model (4 views, 256 px, 12 spp: ~0.5–1.5 s per model plus ~5 s Cycles warm-up once per run; default `$TMPDIR/gwf_previews`). Quick shape check, but not the in-game look |
| `... --no-import` / `--verbose` / `--list` | Blender side only / show exporter + Godot output / list scripts |
| `godot --headless --path . -s res://tools/tests/models_test.gd` | the model suite alone (~0.4 s) |
| `xvfb-run -a -s "-screen 0 1280x720x24" godot --path . --rendering-driver opengl3 --rendering-method gl_compatibility -s res://tools/tests/models_preview.gd -- --out=DIR --models=a,b --layout=sheet,eye,lineup [--tint=#hex] [--variants=3 --tints=#a,#b,#c] [--outline] [--ref=/abs/x.glb] [--dir=/abs/pack]` | renders on demand. `--ref`/`--dir` load any external glb at runtime without importing it (reference packs) |

Timings (this machine): Blender ~0.3–0.6 s per model, Godot import ~6 s, tests ~0.4 s, shots ~4 s.
Full `build.py --test --shots` for 3 models: ~12 s.

Table columns: `glb changed/same` (was the file rewritten), `status` ok / WARN (over budget, off-centre
footprint) / FAIL (not exported: bad size, origin not on the contact point, faces without material,
default Blender material, import failed, script crashed; the reason is in the notes).

---

## 5. Hooking a model into a Godot scene (without breaking contracts)

Contracts first: never rename or remove nodes other code uses (`Visual`, colliders, `%Unique` nodes,
`Label3D`s, lights, `CanSpots`, `ShopkeeperAnchor`...). Never scale physics bodies or synced roots.
Colliders stay simple shapes in the scene; the model is visual only. Blob shadows stay flat Godot discs
outside `Visual`. Lights stay Godot lights.

**A. Mesh swap (static props, stations).** Keep the `Visual` Node3D (Juice squashes it). Delete the
primitive MeshInstances under it that the model replaces, and instance the model under it:
```
[ext_resource type="PackedScene" path="res://art/models/oil_drum.glb" id="3_drum"]
[node name="Visual" type="Node3D" parent="."]
[node name="Model" parent="Visual" instance=ExtResource("3_drum")]
tint = Color(0.31, 0.43, 0.56, 1)     ; optional: TINT parts (Toonify export on the model root)
outline_width = 0.025                 ; optional: ink outline hull
```
Stations/props need no rotation (the model's front is +Z). Characters and items need none either (front -Z).

**B. Rigged models (parts code animates).** When the scene script addresses parts by path
(`Visual/Torso/HeadPivot`, `Visual/Pan/Tilt/Led`, `Visual/MinuteHand`), export those parts as a node
hierarchy with the same names, and instance the model **as** `Visual`, so every path stays valid:
```
[node name="Visual" parent="." instance=ExtResource("4_boss")]
[node name="Face" parent="Visual/Torso/HeadPivot" instance=ExtResource("5_face")]   ; scene-only extras
```
Rules for rigged parts:
- **pivot = object origin** (`join(parts, "ArmLeft", origin=shoulder)`);
- **rest rotation = identity** (scripts set absolute rotations: the Boss sets `HeadPivot.rotation.y`, taps
  `Fingers.rotation.x` back to 0 and bobs `Torso.position.y` back to 0, so `Torso`'s origin is at the floor);
- repeated names get a `__suffix` (`Hand__L`, `Hand__R` import as `Hand`);
- `empty()` for pure pivots/sockets.

**C. From code.**
- Recolour live: `($Visual/Model as Toonify).tint = Toon.grade(seed.color)`. Pass data colours through
  `Toon.grade`; palette constants as they are.
- On any subtree: `Toonify.toonify($Visual, -1.0, tint)`, `Toonify.outline($Visual, 0.025)`. Both are
  idempotent and cheap; converted materials are shared per (source, tint).
- Swapping a part's material yourself: set `material_override` (Toonify leaves those alone).

**D. Outline.** `outline_width = 0.025` builds an inverted hull with welded normals (no tearing on hard
edges, unlike `material_overlay` on imported meshes). Each connected part is sized on its own, per STYLE
rule 4: parts ≥ 0.25 m get the full width, 0.1–0.25 m 48 %, < 0.1 m none. Transparent and unshaded
surfaces are skipped. Use it on characters, held items and stations; room decor is optional. The hull is
an internal child named `ToonOutline` with the meta `toonify_outline`: `get_children()` skips it,
`find_children()` does not.

---

## 6. Review checklist (before you hand a model over)

- [ ] `build.py <family> --test` says **ok** for every model and `models_test: ... 0 failures`.
- [ ] You looked at the `--shots` sheet **and** eye view: readable at 6 m, chunky, no faceting on round
      parts, nothing sharp, silhouette tells what it is.
- [ ] Front faces the right way (label/face/spout towards the camera in the shots), origin on the
      contact point, size matches the scene's collider (section 8).
- [ ] Materials: library first, flat colours, 3–7 per prop, bright only for signals, `TINT` where the
      colour comes from data. No `Material`/`Material.001`.
- [ ] Mood: at least one sign of wear or sadness (dent, rust, crooked, droop). Nothing smiles.
- [ ] Tris within budget; tiny details only if they read (bolts ≥ 3 cm, labels ≥ 10 cm).
- [ ] Rigged: node names/paths exactly as the scene script expects, pivots at joints, rest rotation 0.
- [ ] Scene hooked per section 5, contracts untouched, `tools/check_files.sh <scene>` OK; the scene's own
      tests still pass (e.g. `world_test`, `farm_test`).

---

## 7. Reference notes (Kenney CC0 starter kits: style reference only, never copied)

Rendered contact sheets of all 40 reference models (platformer, FPS and city-builder kits) in our toon
lighting. The numbers were measured on the files.

**What makes the Kenney style read**
1. **Very low polycount, all in the silhouette.** 20–834 tris per model (median ~190); a whole character
   is 550 tris; a small building 450–830. Detail comes from stacked shapes and colour blocks, not from
   mesh density.
2. **Chunky chamfers.** Edges are cut at ~5–10 % of the part's smallest dimension (≈ 5 cm on a 0.5 m
   platform lip, ≈ 15 cm on the 1 m "cloud" cube) with 1–2 segments. The chamfer is smooth-shaded and the
   big faces stay flat (50–80 % of faces smooth). Every edge catches a highlight, which is what makes it
   read as a toy.
3. **Colour blocking.** One palette texture. Each part picks one swatch: 2–4 main colours per model, a
   neutral blue-grey "metal" trim and a near-black accent. The swatches carry a gentle vertical gradient
   (lighter tops, darker bottoms): a baked top light.
4. **Proportions.** Stacked primitives with **overhangs and bases**: roofs and lips 5–10 % wider than the
   body, plinths wider than what stands on them, which grounds and frames everything. Details (bolts, hex
   nuts, hinges, window frames, coin rings) are small extruded blocks at 10–15 % scale, few, at
   corners and edges.
5. **The character** is 6 rigid parts (one head-torso block, two arm blocks, two leg blocks, an antenna),
   no skinning, each part pivoting at its joint. It has a two-tone split (white top, purple bottom) and an
   **inset face panel** (a flat screen with two eye dashes and a mouth), all geometry plus swatches.
6. Organic things (grass, rocks, trees) are deliberately faceted crystals; hard-surface is bevel-smooth.
   Everything faces +Z with the origin at the base centre, on 1 m (city) or 2/3/5 m (platform) grids.

**How ours differs**
- **Rounder and chunkier.** 24–32-segment cylinders and tori, lathe profiles with ribs, bellies and
  flares, fat rolled rims (STYLE: round first). A prop costs 1–3k tris instead of 200–800, because toon
  shading and the ink outline need smooth curvature (faceting reads as "sharp"). Keep Kenney's lesson
  anyway: the silhouette does the work, and small details stay few and big.
- **Sadder.** Dents, crooked hangs, slouches, sagging cords, wilted leaves, uneven wear. Nothing
  pristine, nothing cute-happy, no smiles.
- **Darker undertone.** Graded Toon palette plus the factory palette (rust, metal_dark, olive, concrete).
  Caution yellow and data colours (strains, money) are the only bright accents, and value contrast stays
  high enough to read.
- **Factory materials as colour blocks** instead of gradient swatches: rust bands creeping up from the
  floor (`band` with a wavy top), rust drips (`arc_panel`), painted stripes in a darker `TINT` shade,
  hazard labels (cream plate + caution diamond + ink "!"), metal_dark bolts and rims. Use explicit value
  steps (darker bases and stripes) where Kenney uses gradients.
- **Faces:** characters get `face.tscn` (tired eyes, frown) on the head's -Z side, never a smiley panel.
- **Kept from Kenney:** rigid-part characters (pivots at joints, no skinning), overhangs and bases, a
  neutral metal trim colour, few big details, everything facing one way with the origin at the base.

The contact sheets live outside the repo (the pipeline agent's scratchpad, `refpacks/sheets/`). To make
new ones from any pack: `models_preview.gd -- --models=none --dir=/abs/pack/models --layout=sheet`.

---

## 8. Model list (targets taken from the current scenes)

W × H × D in Godot metres (x × y × z); "collider" is the scene's collision shape the model must fill.
All paths are relative to `scenes/`. ✅ = shipped (in `art/models/manifest.json`; sizes there are the real ones), ⏳ = pending.

**Characters** (`kind="character"`, front → Godot -Z, floor)

| Model | Size | Scene | Notes |
|---|---|---|---|
| ⏳ `player` (character modeler, in progress) | 0.85 × 1.6 × 0.8 (collider capsule r 0.4 h 1.8) | `player/player.tscn` (replaces `Visual/BodyMesh`) | Bean (STYLE §9: capsule r 0.42 h 1.55), slouched 4°, body = `TINT` (player colour), feet `TINT` shade 0.75, wilted sprout (`leaf_dry`). Leave the front of the head clear for `face.tscn` at (0, 1.22, -0.4); keep `Face`, `%NameLabel`, sockets |
| ⏳ `boss` (character modeler, in progress) | 1.2 × 2.1 × 1.4 | `world/shopkeeper_npc.tscn`, instanced **as** `Visual` | Rigged: `Torso` (origin at the floor) / `HeadPivot` / `EyeLeft`,`EyeR` / `LidLeft`,`LidR`; `Torso/ArmLeft/Hand__L/Cash/TopBill`; `Torso/ArmRight/Hand__R/Fingers/...`; `FootLeft`, `FootRight`. Round, heavy, scowling, fedora (`metal_dark`), cash stack (olive). The shop anchor already turns him to face the room |

**Stations** (`kind="station"`, front → Godot +Z towards the room, floor)

| Model | Size | Scene | Notes |
|---|---|---|---|
| ✅ `shop_cage` | ≈ 3.4 × 3.2 × 1.95 (counter collider 3.4 × 1.04 × 1.2; the Boss stands at z -0.9) | `stations/shop_counter.tscn` | The Boss's barred pay window / cage: counter, bars, a slot tray, a "PAY HERE" plate. Keep `ShopkeeperAnchor` and what `shop_counter.gd` addresses (`Visual/Jars`, `Visual/Badges`, `PriceTag` today; check the script first, the economy agent may change them) |
| ✅ `deposit_chute` | 1.6 × ≤ 2.6 × 1.4 (collider 1.6 × 1.08 × 1.4) | `stations/turn_in_station.tscn` | Rusty hopper mouth on a box, chute into the wall, "NO REFUNDS" plate. The script spins `Visual/Sign/Coin` and uses `SoldLabel`: keep them (or export a `Sign/Coin` node and instance the model as `Visual`) |
| ✅ `water_tank` + `water_tank_bucket` (part) | ≈ 2.8 × 2.7 × 2.2 (collider: ring r 1.0 h 0.76, posts ±0.98 × 2.05, roof 2.6 × 0.5 × 1.6) | `stations/well.tscn` | Replaces the well: a dented tank with a tap and drip tray (fits the colliders or ask the farming agent to update them). `well.gd` uses `%Water`, `%Bucket`, `%CanSpots`: they stay Godot nodes |
| ✅ `grow_tray` | 1.5 × 0.5 × 1.5 (collider 1.46 × 0.52 × 1.46) | `stations/grow_plot.tscn` | Planter tray + rim on a plinth, soil top at y ≈ 0.4 (the plant origin). The model is the tray only: `grow_plot.gd` recolours `%SoilBed`/`%SoilMound` (dry/wet) and moves `%FillPivot`/`%Fill`, `%Tag`/`%Card`, so those stay Godot nodes (`%unique` names can't live inside a glb) |
| ⏳ `plant_seedling` / `_vegetative` / `_flowering` / `_ready` + `*_dry` (dedicated pass, PLAN 8.7) | 0.3 × 0.24 × 0.3 / 0.6 × 0.58 × 0.6 / 0.75 × 0.8 × 0.75 / 0.85 × 1.05 × 0.85 (`PlantVisual.STAGE_HEIGHTS`) | `stations/plant_visual.tscn` stage nodes | `kind="part"`, origin at the soil top. One family script `plant_stages.py`. Nodes `Leaves` (`lib("leaf")`, dry: `lib("leaf_dry")` + droop 8–15°) and `Buds` (`tint_material("TINT_bud", finish="glow")`). The farming agent maps them onto the stage nodes; buds pulse. PLAN 8.7 is a later dedicated pass with real cannabis morphology (cotyledons, fan leaves with 5–7 serrated fingers: `extrude_profile` + `move_verts` for the fold; dense colas with sugar leaves), still chunky |

**Held items** (`kind="item"`, front → Godot -Z, floor, budget 1500)

| Model | Size | Scene | Notes |
|---|---|---|---|
| ✅ `watering_can` | ≈ 0.5 nose-to-handle × 0.42 H (collider cyl r 0.19 h 0.42) | `items/watering_can.tscn` | Dented tin can, the spout pointing to the front. Keep `Visual/WaterTop` (level) and the gauge |
| ✅ `seed_packet` | 0.3 × 0.36 × 0.12 (collider box) | `items/seed_packet.tscn` | Crumpled paper packet, `TINT` = strain colour, crimped top. Keep `Visual/Packet/NameLabel`, `Icon/Bud` |
| ✅ `product_bundle` | ≈ 0.4 × 0.35 × 0.4 (collider sphere r 0.2 at y 0.15) | `items/product.tscn` | A twine-tied brick or bag of product, `TINT` buds poking out. `Visual/Cluster` |

**Room props** (`kind="prop"`, `scenes/world/props/`, front → Godot +Z)

| Model | Size / mount | Scene | Notes |
|---|---|---|---|
| ✅ `oil_drum` | 0.70 × 0.94 × 0.71, floor (collider cyl r 0.33 h 0.92) | `oil_drum.tscn` | `TINT` paint (faded blue `#4f6d8f` / olive `#6f7a4f` / red `#8f4a3f`), stripe shade 0.7 |
| ✅ `pendant_lamp` / `pendant_lamp_short` | 0.94 × 2.94 × 0.94 / 0.62 × 0.92 × 0.61, ceiling | `pendant_lamp.tscn` | Nodes `Lamp` + `Bulb` (flat, flicker/hide it). The SpotLight stays in the scene at y ≈ -2.86 |
| ✅ `pallet` | 1.2 × 0.15 × 1.0, floor | `pallet.tscn` | `plank`s + blocks, one board cracked/missing |
| ✅ `crate` | 0.9 × 0.9 × 0.9, floor | `crate.tscn` | Slatted, banded, dented; `TINT` stencil optional |
| ✅ `fence_panel`, `fence_gate`, `fence_gate_leaf` (part) | 2.5 × 2.2 × 0.1, floor (back on y = 0) | `fence_panel.tscn` | Frame `pipe`s + chain-link (`chainlink`): a diamond lattice of thin boxes via `array`, ≤ 2.5k tris, or keep the MultiMesh wires and model only the frame. Sagging, one torn corner |
| ✅ `cot` | 1.92 × 0.65 × 0.92, floor | `cot.tscn` | Steel frame, thin stained mattress, flat pillow, rumpled blanket |
| ✅ `security_camera` | 0.26 × 0.4 × 0.73, wall | `security_camera.tscn` | Rigged: `Bracket`, `Pan` / `Tilt` / `Led` (flat red; the script toggles it) |
| ✅ `punch_clock` | ≈ 0.5 × 1.9 × 0.3, wall | `punch_clock.tscn` | Box, clock face, card slot, card rack. The "CLOCK IN" Label3D stays in the scene |
| ✅ `sign_board` (the debt board) | 2.16 × 1.16 × 0.06, wall | `sign_board.tscn` | `sign_board.gd` scales `Visual/Board` and `Visual/Frame` to `board_size`: model them as **1 × 1 m** meshes named `Board` and `Frame` (small bevels, they stretch); the `Text` Label3D stays |
| ✅ `wall_clock` | 0.92 × 0.92 × 0.13, wall | `wall_clock.tscn` | Rigged: `HourHand`, `MinuteHand`, `SecondHand` pivoting at the centre, pointing at 12 at rest; cracked glass |
| ✅ `sad_plant` | 0.5 × 0.6 × 0.4, floor | `sad_plant.tscn` | Chipped pot, drooping stem, one fallen leaf |
| ✅ `roller_door` (beam, chain, padlock as nodes) | 4.8 × 4.3 × 0.64, floor (back on y = 0) | `roller_door.tscn` | Slatted shutter, rails, top drum, rust drip; the wooden beam bar + chain + padlock as separate nodes (`Beam`, `Chain`, `PadlockBody`, `PadlockShackle`) |
| ✅ `barred_window` | 1.8 × 1.9 × 0.23, wall | `barred_window.tscn` | Frame, bars, sill, rust streak; keep the Sky/Moon/Stars meshes in the scene |
| ✅ `fluoro_light` / `fluoro_light_broken` | 1.5 × 1.9 × 0.34, ceiling | `fluoro_light.tscn` | Housing on two chains; tubes as node `Tubes` (`lib("neon_green")`; the flicker script toggles it) |
| ✅ `grow_light_bar` | 3.7 m segment, ceiling | `grow_light.tscn` (7.4 m = 2 segments) | Housing + glowing strip + cables |
| ✅ `pipe_straight_2m`, `pipe_straight_1m`, `pipe_elbow`, `pipe_valve`, `pipe_hanger`, `leaky_pipe` (flanges are built into the straights) | Ø 0.2, modules | room ceiling/walls, `leaky_pipe.tscn` (6 m = segments) | `metal_dark` + rust, flanges with bolts. Keep the leaky pipe's `Puddle`/`Drop` in the scene |
| ✅ `cable_tray_2m` | 2 × 0.1 × 0.3, ceiling | room | Sagging cables (`sag_points`) |
| Caution stripes, posters, decals | – | room | Stay flat Godot meshes / `sign_board` (not worth modelling) |

---

## 9. Gotchas

- Run scripts through `build.py` only: it sets up `sys.path`, resets the scene and handles the next point.
  bpy 4.2 **segfaults at interpreter exit after any glTF export** (after the files are written); build.py
  exits with `os._exit`, so its exit code is reliable. Your own ad-hoc bpy scripts should do the same.
- A family script must `reset()` at the start of every model, or names collide (`Lamp.001`).
- `export()` refuses models whose origin isn't on the declared contact point, or that are < 5 cm or
  > 6 m. `jitter`/`dent` can push vertices below the floor: jitter before placing, or lift by the amount.
- Blender Base Color is linear. gwf converts your sRGB hex (`srgb()`), so the game shows exactly the
  hex (before toon lighting). Don't set `Base Color` by hand.
- Don't hand-edit `art/models/*` (generated) or `.glb.import` (build.py rewrites them). If you delete a
  model script, delete its `.glb` + `.glb.import` too (the full build warns about orphans).
- Some bmesh ops order their output differently every run; `export()` canonicalises vertex, face and loop
  order, so identical scripts give identical files. If `glb` says `changed` on a re-run without edits,
  something in your script is nondeterministic (e.g. `random` without a seed).
- The editor shows models with default shading; the toon look is runtime-only (section 1). The shots and
  the game are the truth.
- `find_children("*", "MeshInstance3D")` also finds Toonify's `ToonOutline` hulls (meta `toonify_outline`).
