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

### Windows / Blender 5.2 (this PC; the cloud sessions use the Linux bpy 4.2 module)

There is no `python` with bpy here: Blender 5.2.2 LTS is installed as an application and build.py runs
**inside** it. From Git Bash in the repo root:

```bash
export GODOT="/c/Users/ap_lo/Downloads/Godot_v4.7.2-stable_win64.exe/Godot_v4.7.2-stable_win64_console.exe"
export BLENDER="/c/Program Files/Blender Foundation/Blender 5.2/blender.exe"     # optional: it is the default
"$BLENDER" --background --python tools/blender/build.py -- fuse_box rat --test   # our args go after "--"
"$GODOT" --headless --path . --import                                             # after every build, before tests
```

`python tools/blender/build.py ...` (any Python without bpy, or with `--blender` / `BLENDER` set) re-runs
itself under blender.exe with the same arguments and forwards the exit code, so both spellings work; the
Blender start-up costs ~5 s per run, so batch your families. Inside Blender, build.py reads its own
arguments after `--` (Blender's own come first) and still leaves through `os._exit`. Compatibility
guards (gwf.py, both versions build the same meshes): `Material.use_nodes` only when the node tree is
missing (deprecated in 5.x), `blend_method` / `surface_render_method` by `hasattr`, glTF exporter options
filtered against this Blender's operator (`_gltf_args`), the preview view transform in a try. build.py:
`fcntl` is optional (a `msvcrt` byte-range lock on Windows), `--shots` without `xvfb-run` opens a small
real Godot window at 1500,900 for a few seconds (no virtual display here: keep it rare).

**Do not rebuild shipped models on another Blender version.** The 5.2 exporter writes the same vertices,
triangles and materials as 4.2 (checked on oil_drum, security_camera, watering_can: same tris, size and
accessor counts) but a different `generator` string, so every re-exported `.glb` is "changed" and a full
`build.py` run would churn the whole of art/models. Build only your own families; verify compatibility with
`--out DIR` (the .glb files go to DIR, no manifest / .import / Godot pass) and compare the table with
manifest.json. If a run did rewrite others: `git checkout -- art/models/<name>.glb art/models/<name>.glb.import`.
Godot's `--import` also rewrites every `.glb.import` with LF line endings on this CRLF checkout (pure
line-ending churn): `git checkout -- art/models/*.glb.import` before committing.

**Visual check without xvfb:** `--preview --preview-dir DIR` renders a Cycles turntable strip per model
(4 views, background, no window) in ~0.2 s each; open the PNGs (the Read tool shows them). It is not the
in-game look (no toon shading, no outline) but shapes, proportions, colour blocks and the front direction
read fine. For the real look use `--shots DIR` once at the end (a small window flashes) or
`tools/tests/models_preview.gd` with `--position 1500,900 --resolution 640x360` on the console exe.

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

**M10 friendslop props** (modeling agent; built on Windows / Blender 5.2, scenes by the events agent)

| Model | Size / mount | Scene | Notes |
|---|---|---|---|
| ✅ `fuse_box` | 0.51 × 0.85 × 0.32, wall (origin = the cabinet's bottom centre on the wall; place the node ~1.1 m up) | `stations/fuse_box.tscn`, instanced **as** `Visual` | Rigged: `Cabinet` (static) + `Lever` (pivot on its axle at (0.175, 0.34, 0.225), pointing up at rest; `Lever.rotation.x = deg_to_rad(130)` = tripped: down and out of the wall). Door ajar + crooked, "FUSES" caution plate, red grip, rust drips onto the wall |
| ✅ `backroom_door` | 1.10 × 2.20 × 0.17, wall, feet on the floor | room `Decor/BackRoomDoor`, instanced **as** `Visual` | Rigged: `Frame` + `Backing` (a void-black slab in the opening; hide it for a see-through doorway) static, `Door` (pivot on the hinge edge at (-0.46, 0, 0.07); `Door.rotation.y = deg_to_rad(80)` swings the leaf through the wall plane, away from the viewer). Wired window, "STAFF ONLY", kick plate askew, "NO BREAKS" tag, boot dents |
| ✅ `clipboard` | 0.25 × 0.36 × 0.07, floor (item, front -Z: the sheets face -Z), budget 1500 | the Boss's `Visual/Torso/ArmRight/Hand` during inspections | One mesh, no rig. Standing upright on its bottom edge; in a palm-down hand rotate it -90° about X (sheets up) |
| ✅ `rat` | 0.13 × 0.07 × 0.35 (nose at -Z), floor, budget 2000 | `world/props/rat.tscn`, instanced **as** `Visual` | Rigged: `Body` (static, one unioned part so it gets the thin outline) + `Tail` (pivot at the rump (0, 0.046, 0.06), rest identity; `Tail.rotation.y` swishes). Thin, head hanging, heavy lids, bald patches, tail dragging |

**M17 mayhem3** (mayhem3 agent; built on Windows / Blender 5.2; `tools/blender/models/wall_phone.py`)

| Model | Size / mount | Scene | Notes |
|---|---|---|---|
| ✅ `wall_phone` | 0.34 × 0.59 × 0.11, wall (origin = the bottom centre of the housing on the wall; the node hangs 1.15 m up, so the earpiece sits at ~1.55 m), 2992 tris (budget 3000) | `world/props/wall_phone.tscn`, instanced **as** `Visual` (collider: box 0.32 × 0.48 × 0.13 on the interactable layer); room `Decor/WallPhone` | Rigged: `Body` (static: the yellowed housing with its hood, the keypad, the speaker slots, the crack, the taped note above it, grease on the wall, the coiled cord) + `Handset` (pivot on the hook at (-0.105, 0.40, 0.06), rest identity, hanging straight down; `wall_phone.gd` rattles `Handset.rotation.z` ±4° while it rings and lifts it off the hook when the call is taken). Custom `phone_plastic` (beige gone yellow), `phone_grease`, `phone_tape` |

**M14 lobby** (lobby agent; built on Windows / Blender 5.2)

| Model | Size / mount | Scene | Notes |
|---|---|---|---|
| ✅ `van` | 2.48 × 2.52 × 5.73 (doors open), floor, budget 7000. **Origin: on the ground under the centre of the rear axle. Front of the model = the REAR of the van** (the open doors face Godot +Z, the nose points at -Z) | `world/van.tscn` (the alley's van: `Model` + colliders + the cargo volume); as plain decor instance `art/models/van.glb` and give it your own box collider | Rigged: `Body` (static) + `DoorLeft` / `DoorRight` (pivots on the hinges at (∓0.93, 0.47, 0.78); **rest = open**, swung out 105°; `DoorLeft.rotation.y = deg_to_rad(105)` and `DoorRight.rotation.y = deg_to_rad(-105)` shut them). From the origin: rear sill z = +0.75, bulkhead z = -2.05, cargo floor y = 0.45, cargo ceiling y = 2.42, bay 1.8 wide (x ±0.9), bumper step z 0.75..1.07 at y 0.25, nose z = -4.07, body sides x ±1.0 (wheels ±1.14), open door tips x ±1.16, z +1.65. `TINT_paint` + `TINT_stripe` (give the root a `tint`: off-white `Color(0.79, 0.78, 0.74)` in the alley). Primer patch, rust, a dead headlight and tail light, a lost hubcap, "FLORIST" with letters scraped off |

**M15 alley** (alley agent; built on Windows / Blender 5.2; one family script, `tools/blender/models/alley.py`)

| Model | Size / mount | Scene | Notes |
|---|---|---|---|
| ✅ `ball` | 0.24 × 0.17 × 0.24, floor (item, front -Z), 528 tris | `items/ball.tscn`, instanced **as** `Visual` (collider: sphere r 0.15 at y 0.1) | One mesh, no rig. A half-flat rubber ball resting on the flat it sagged into: `orange` rubber, two `dark` seams (painted faces), a `cream` patch over a puncture, a caved-in shoulder |
| ✅ `alley_hoop` | 0.99 × 0.75 × 0.83, wall (origin = the centre of the board on the wall), 2564 tris | `world/lobby.tscn` `Hoop/Model` | One mesh, no rig, no collider. A scrap of ply 3° off level with a painted square half worn off, a steel flat, a rusted ring off a barrel: its centre 0.47 m out of the wall at the origin's height, radius 0.34 m (`AlleyHoop.RING_OUT` / `RING_RADIUS` mirror `RING_OUT` / `RING_R` in the script), drooping to the front, a little oval; three ends of a net |

**M16 hats** (hats agent; built on Windows / Blender 5.2; one family script, `tools/blender/models/hats.py`, plus a change to `player.py`)

The worker's stock hard hat is no longer part of `Body`: `player.glb` carries it as its own mesh `Hat` and an empty
`HatSocket` on the hat's seat (the one node in the pipeline with a rest rotation: it leans as the hat leans; in Godot
`Transform3D(Basis((0.98484, 0.13917, 0.10351), (-0.12689, 0.98499, -0.11706), (-0.11825, 0.10215, 0.98772)), (-0.01, 1.5311, -0.0895))`,
printed by the build and mirrored in `Player.HAT_SOCKET_FALLBACK`). Same triangles and size as before (6266, 0.93 × 1.87 × 0.91).
An issued hat is ONE mesh authored **in that socket's space**: origin on the seat, +Z up the hat's own axis, front -Y
(`kind="item"` so the front lands on Godot -Z like the worker, `mount="free"`, budget 2500). `scripts/player/player.gd`
hides `Visual/Model/Hat` and instances the issued hat (`Hats.make`, outline 0.025) under `Visual/Model/HatSocket`.
What a hat must cover: under the stock hat the head is tucked 3.5 cm inside the dome and the body's ink hull follows
it, so every hat encloses the stock dome less 1 cm (`check_cover` in hats.py casts 312 rays out of that surface and
prints how many get through: all must be met) and is at least 0.322 m in radius at the seat.

| Model | Size / mount | Scene | Notes |
|---|---|---|---|
| ✅ `hat_hairnet` | 0.70 × 0.35 × 0.71, socket, 998 tris | on a worker's `HatSocket` (issued: one shift worked) | A disposable bouffant cap in washed-out blue (custom `hairnet`), slumped to the back, an elastic rim with its gather, two stains |
| ✅ `hat_paper_cap` | 0.65 × 0.40 × 0.65, socket, 780 tris | same (ten shifts) | A tall folded paper cap (`cream`), a faded `blue` stripe, the fold sagging and one end sat on, a cross of tape, grease |
| ✅ `hat_hard_hat` | 0.74 × 0.35 × 0.81, socket, 1530 tris | same (best shift 3) | The stock hat's profile at 0.97 instead of 0.88 ("this one fits") in `caution` yellow, no sprout; a dead torch (`metal_dark`, grey lens) taped to the front, tape once round the dome |
| ✅ `hat_cone` | 0.80 × 0.59 × 0.80, socket, 1114 tris | same (back room three times) | A traffic cone (`orange`), a `cream` collar, the tip bent over, a dent, a tyre mark, the base turned 9° with one corner driven over |
| ✅ `hat_bucket` | 0.75 × 0.53 × 0.76, socket, 2398 tris | same (bitten five times) | A tin bucket upside down (`metal`), two ribs, rust creeping up from the rim, a bite out of the rim with five tooth marks, a dent, the wire handle hanging down behind |
| ✅ `hat_welding_mask` | 0.70 × 0.38 × 0.83, socket, 1710 tris | same (five plants burnt) | A leather cap (`brown`), a headband with a strap over the top and two knobs, the mask swung up on them over the forehead (built hanging in front of the face, then turned -66°): a grey shield, a framed dark window, soot |
| ✅ `hat_bandage` | 0.65 × 0.49 × 0.69, socket, 1322 tris | same (shot three times) | A head wrapped in gauze (`cream` + an older shade), three turns over the top, one old stain gone the colour of `rust`, a knot and two loose ends at the back |
| ✅ `hat_eyeshade` (M17 finale) | 0.80 × 0.34 × 0.82, socket, 1962 tris | same (one debt cleared: Career `cleared` 1) | A bookkeeper's eyeshade: a crescent of dull green celluloid (custom `celluloid`) tipped down over the eyes, warped, its left front corner bent down, a `dark` binding, on a `dark` elastic band; under it a thin comb-over (the liner every hat needs, the stock dome plus 1.2 cm like the welding mask's cap: custom `hair`) with five grey strands lying flat across the top in parallel (`comb_strand`, not through the pole like `strap`); a chewed `caution` pencil stub with a `pink` eraser pushed through the band over the right ear |
| ✅ `locker` | 0.87 × 1.88 × 0.57, floor (origin under the centre of the footprint; stand it 0.3 m off a wall), 2704 tris | `world/locker.tscn`, instanced **as** `Visual` (collider: box 0.88 × 1.88 × 0.54) | Rigged: `Body` (static: the shell, the shut left-hand door with its padlock, the dark inside) + `Door` (the right-hand door, pivot on its hinge edge at (0.41, 0, 0.258), rest = shut; `Door.rotation.y = deg_to_rad(6)` hangs it ajar, + swings it out). `TINT_paint` + `TINT_trim` (the alley's is faded blue `Color(0.31, 0.43, 0.56)`), rust along the foot, a dent in the side and the top, tape where the names were |

To look at a hat on the worker without a window: build both into one scratch model (`player.py`'s parts, the hat's
`make_*()` parts joined and placed with `hat.matrix_world = player.hat_matrix()`) with `--out DIR --preview`.

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

### Architecture (shipped)
`wall_panel`, `wall_panel_b`, `wall_panel_window`, `wall_panel_door`, `wall_panel_door_b` (5.08 × 6 m cinder-block
sections, half-block seams), `floor_slab`, `floor_slab_b`, `floor_slab_drain` (5 × 5 m), `ceiling_panel`,
`ceiling_panel_b`, `ceiling_panel_hole` (corrugated deck), `ceiling_beam` (5 m I-beam), `hole_rim`. Built by
`tools/blender/models/{wall_panel,floor_slab,ceiling_panel,ceiling_beam,hole_rim}.py` (shared helper `_arch.py`),
placed in room.tscn as `segment_run.gd` MultiMesh runs; `tools/tests/models_arch_test.gd` proves the tiling.

M14 (level agent), `tools/blender/models/wall_opening.py` (it imports `wall_panel.py`'s `Wall` class): `wall_panel_doorway`,
`wall_panel_doorway_b` (a 2.0 x 2.5 m walk-through doorway 1.25 m left / right of the panel centre), `wall_panel_pass`,
`wall_panel_pass_b` (half of the 4.2 x 3.75 m dock passage on the panel's left / right edge), `wall_panel_door_c` (the
roller door's opening, dark back, centred in one panel). Walk-through openings have no back face: two panels stand back
to back, 0.6 m apart (2 x the 0.3 m reveal), so each variant serves both faces of its wall. The room's shell is now
36 wall panels, 27 floor slabs and 27 deck panels (main room 20 x 15, grow hall 12 x 15, loading dock 15 x 7.5; the
5 m modules of the hall's long walls and the dock's side walls end outside, behind the wall they meet).
