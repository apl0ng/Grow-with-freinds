# Handoff — Grow With Friends (for a Claude session running on the user's PC)

## Who you are and what to do first
You are taking over as lead developer on this Godot 4.7.2 project from a cloud session that could not reach the
user's computer. The user wants the game launched and played on their PC.

1. The repo is cloned at `C:\Games\Grow-with-freinds` (branch `claude/quota-farming-game-lead-hcy18f`, everything
   is pushed; `git pull` first).
2. Run `.\launch.cmd` (or `.\launch.ps1`) from that folder. It finds Godot 4.7.2 or asks to download it into
   `tools\godot\`, then opens the game at the main menu. Tell the user to press Host, then Enter in the room.
   `.\launch.ps1 -Players 2 -Fast` opens two local windows (host + client) for co-op testing.
3. `launch.ps1` was written blind (no PowerShell in the cloud container). If it errors, fix it in place: it must
   locate a Godot 4.7.x exe (GODOT env var, tools\godot\, PATH, common folders), download
   `https://github.com/godotengine/godot-builds/releases/download/4.7.2-stable/Godot_v4.7.2-stable_win64.exe.zip`
   when missing, and run `godot --path <repo> -- --host|--join=IP --name=... [--fast]`.
4. If the game itself misbehaves on real hardware, note that the cloud session only ever previewed the Forward+
   renderer on software Vulkan and GL Compatibility; sounds were never heard by a human. Those are the most likely
   places for surprises.

## What the game is
1–4 player co-op first-person quota game. The crew is locked in a grim low-budget factory working off a debt to
"the Boss" (the shopkeeper behind a barred supply window). Loop: buy seeds at the supply window → plant in grow
trays → water from the tank → wait through 4 visible growth stages → harvest → deposit at the chute → make the
shift's payment before the timer ends; the payment rises each shift; miss it and everyone starts over.
Tone rules from the user: dark undertone, NOBODY is happy (sad/tired faces, no smiles, no cheer, no "!"), nothing
glamorizes the product. Rendering is chunky cartoon; every model is authored in Blender (bpy scripts →
`art/models/*.glb`), inspired by Kenney CC0 kits but never copied.

## Read these (in order)
PLAN.md (status, decisions, milestone notes M1–M9) · CONTRACTS.md (system interfaces) · STYLE.md (look + copy
tone) · MODELING.md (Blender pipeline) · CLAUDE.md (rules for agents).

## Architecture in one paragraph
ENet high-level multiplayer, server-authoritative: only the host mutates state; clients send
`@rpc("any_peer", "call_local", "reliable")` requests that the host validates (sender 0 → 1). Autoloads: Const,
Config (balance.tres), Net, Game (scene flow, UI lock, mouse), GameState (money/payment/timer/shifts/favors),
Sfx, Juice, Story (Boss barks + debt board). World = Room + Players + Items (MultiplayerSpawner + synchronizers)
+ HUD. Movement is client-authoritative; everything else is server-validated. Spawned nodes are never
reparented. Held items follow the holder's hand socket; the local player's held item renders in a view-model
layer (render layer 10) so it never clips walls.

## Testing
- `tools/test_all.sh` (bash; on Windows use Git Bash or WSL, or run suites individually): 35 suites, 5928 checks,
  all green at handoff. Includes multi-process ENet tests, a 4-player stress test, review regression suites.
- `tools/check.sh` loads every resource; `tools/smoke.sh` runs a solo loop and a host+client pair.
- Tests are Node "bodies" launched via `godot --headless --path . -s res://tools/tests/run_test.gd -- --body=...`
  because a `-s` SceneTree script cannot see autoloads at compile time.
- Models: `python3 tools/blender/build.py [family] --test` (needs the `bpy` 4.2 Python module).

## Known limitations at handoff
- Held item receives no world shadows (camera-layer view model).
- Forward+ only previewed on software Vulkan; audio never heard.
- No host migration; movement trusted to clients.
- Wilting is a 0.4 s crossfade between two models (no blend shapes).

## Things the user may ask for next (not started)
- Real playtest feedback on balance (starting cash 150, shift-1 payment 350, +20 % per extra worker).
- Audio pass by ear; a proper font; export presets (Windows build) — none exist yet.
- More rooms/stations, host migration, controller support.
