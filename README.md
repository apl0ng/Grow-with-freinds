# Grow With Friends

A 1–4 player co-op first-person quota game. You and your crew are locked in a low-budget factory, working off a
debt to the Boss: buy seeds at his barred supply window, plant them in the grow trays, haul water from the tank,
harvest, and deposit the product before the shift timer runs out. Make the payment and the number goes up.
Miss it and nobody leaves.

Godot 4.7.2 · GDScript · ENet high-level multiplayer (host/join by IP, server-authoritative) · all models authored
in Blender (bpy) and imported as glTF · chunky cartoon look with a deliberately dark undertone (nobody is happy).

## Run
- Open the folder in Godot 4.7.x and press Play. Host to play solo; friends join with your IP.
- Two local instances: `godot --path . -- --host --name=Alice` and `godot --path . -- --join=127.0.0.1 --name=Bob`.
- `--fast` makes growth 20× faster and shifts 60 s; `--growth-mult=N`, `--round-sec=N` for finer control.
- Controls: WASD move · Shift sprint · Space jump · Ctrl/C crouch · mouse look · E / LMB interact · Q / G drop ·
  Enter starts the shift (host) · Esc pause (or closes the supply window).

## Test
- `tools/test_all.sh` — every suite (headless + multi-process ENet + xvfb), about 3–4 minutes, prints a table.
- `tools/check.sh` — loads every script/scene/resource and boots the menu.
- `tools/smoke.sh` — solo loop and a real host+client pair.

## Models
- `python3 tools/blender/build.py [family ...] --test` builds `tools/blender/models/*.py` into `art/models/*.glb`
  and imports them. See MODELING.md for the workflow and STYLE.md for the look.

## Docs
PLAN.md (status, decisions, milestone notes) · CONTRACTS.md (system interfaces) · STYLE.md (art + copy rules) ·
MODELING.md (Blender pipeline).
