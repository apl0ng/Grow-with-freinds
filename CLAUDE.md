# Grow With Friends — notes for coding agents

Read PLAN.md (status + decisions), CONTRACTS.md (interfaces), STYLE.md (look + copy tone), MODELING.md (models).

- Engine: Godot 4.7.2 (`godot` must be on PATH for the tools; a headless Linux build works). No editor is needed:
  scenes are hand-written text `.tscn` files; models are built by `python3 tools/blender/build.py` (bpy 4.2 module).
- Validate before finishing: `tools/check.sh`, then `tools/test_all.sh` (must be fully green; it also fails on any
  unannounced ERROR line). Per-file: `tools/check_files.sh res://path`.
- A `-s` SceneTree script cannot reference autoloads at compile time: write tests as Node "bodies" launched via
  `tools/tests/run_test.gd -- --body=res://tools/tests/<name>.gd`.
- Server-authoritative: only the host mutates state; clients send `@rpc("any_peer", "call_local", "reliable")`
  requests validated on the server (sender 0 → 1). Use `Net.is_host` for authority at `_ready` time.
- Never reparent spawned nodes (players, items). Effects run on every peer from synced setters or cosmetic RPCs.
- Copy tone: shift / payment due / cash on hand / workers / supply window / favors / deposit. No exclamation marks,
  no cheer, nobody smiles. Colors from `Toon.*` palette; data colors through `Toon.grade`.
- `.godot/` and `__pycache__/` are ignored; `.uid` and `.import` sidecars are committed.
