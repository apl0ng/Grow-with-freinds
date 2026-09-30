# Handoff — Grow With Friends (for a Claude session running on the user's PC)

## Who you are and what to do first
You are the lead developer on this Godot 4.7.2 project. The user wants the game launched and played on their PC,
and the "friendslop" milestone M10 (FRIENDSLOP.md) is integrated and green as of 2026-09-29.

0. State (2026-09-29, night): M10 integrated, M11 merged: QA sweep (review_m10 + review_m10_mp + qa_m10_4p suites), LAN
   discovery, mute, the Windows export preset, the playtest switches, the Windows Firewall rule (WindowsFirewall
   autoload), the launch.ps1 rewrite and launch.sh. 49 suites in tools/test_all.sh, all green on this PC except the
   skipped X11 mouse suite (last full run 2026-09-29, about 9 minutes). Next candidates: PLAN.md "M11" and "Things the user may ask
   for next".
1. On this PC the repo is cloned at `C:\Users\ap_lo\OneDrive\Desktop\Grow With Freinds` (branch
   `claude/quota-farming-game-lead-hcy18f`; the `C:\Games` path from the cloud session never existed here). `git pull`
   first. Everything through M11 is pushed to origin (the user asked for pushes). Godot 4.7.2 is already extracted at
   `%USERPROFILE%\Downloads\Godot_v4.7.2-stable_win64.exe\` (a folder); the launcher finds it there.
2. Run `.\launch.cmd` (or `.\launch.ps1`) from that folder. It imports resources on the first run, then opens the main
   menu. Tell the user to press Host, then Enter in the room. `.\launch.ps1 -Players 2 -Fast` opens two local windows
   (host + client) for co-op testing; `-Import` forces a re-import after pulling new models.
3. `launch.ps1` was rewritten 2026-09-29 (parameter sets, `-Mute`, `-Firewall`, `-NoDownload`, first-run `--import`);
   `launch.sh` is the Linux / macOS / Git Bash equivalent (`--host`, `--join ip[:port]`, `--players N`, `--mute`).
4. Tests on Windows: Git Bash, `export GODOT="/c/Users/ap_lo/Downloads/Godot_v4.7.2-stable_win64.exe/Godot_v4.7.2-stable_win64_console.exe"`,
   then `tools/test_all.sh` (49 suites, about 9 minutes; the X11 mouse suite is skipped) or `--only a,b`. NEVER run
   Godot without `--headless` from a script (it opens the game on the user's screen). In PowerShell never name a
   function parameter `$args`.
5. Models on this PC: Blender 5.2 through `"/c/Program Files/Blender Foundation/Blender 5.2/blender.exe" --background
   --python tools/blender/build.py -- <family>`; never a full unnamed build (MODELING.md "Windows / Blender 5.2").

## What the game is
1–4 player co-op first-person quota game. The crew is locked in a grim low-budget factory working off a debt to
"the Boss" (the shopkeeper behind a barred supply window). Loop: buy seeds at the supply window → plant in grow
trays → water from the tank → wait through 4 visible growth stages → harvest → deposit at the chute → make the
shift's payment before the timer ends; the payment rises each shift; miss it and everyone starts over.
Tone rules from the user: dark undertone, NOBODY is happy (sad/tired faces, no smiles, no cheer, no "!"), nothing
glamorizes the product. Rendering is chunky cartoon; every model is authored in Blender (bpy scripts →
`art/models/*.glb`), inspired by Kenney CC0 kits but never copied.

## M10 (friendslop pass) in one paragraph
Proximity voice chat (V push-to-talk, back-room channel), throwing (RMB) with hits and chute shots, shoving (F),
worker collision, footsteps; random shift events while playing (the Boss walks the floor with a clipboard and
writes up workers he sees skimming product or loitering, confiscating the product; power cuts fixed by holding E at
the fuse box on the west wall; audits that raise the payment; a rat that eats a growing plant); three write-ups
send a worker to the back room for 30 s (dark overlay, spectator camera, still talking to other back-room workers);
per-worker shift stats and a shift report with verdicts; pings (MMB) and text chat (T). Events are off in headless
runs unless `--events` is passed. Design: FRIENDSLOP.md; contracts: CONTRACTS.md "M10"; tasks: PLAN.md "M10".

## Read these (in order)
PLAN.md (status, decisions, milestone notes) · CONTRACTS.md (system interfaces) · STYLE.md (look + copy tone) ·
MODELING.md (Blender pipeline) · FRIENDSLOP.md (why M10 is shaped the way it is) · CLAUDE.md (rules for agents).

## Architecture in one paragraph
ENet high-level multiplayer, server-authoritative: only the host mutates state; clients send
`@rpc("any_peer", "call_local", "reliable")` requests that the host validates (sender 0 → 1). Autoloads: Const,
Config (balance.tres), Net, Game (scene flow, UI lock, mouse), GameState (money/payment/timer/shifts/favors +
M10 stats/write-ups/back room), Sfx, Juice, Story (Boss lines + debt board + report verdicts), Voice, Events,
Comms. World = Room + Players + Items (MultiplayerSpawner + synchronizers) + HUD. Movement is client-authoritative;
everything else is server-validated. Spawned nodes are never reparented. Held items follow the holder's hand
socket; the local player's held item renders in a view-model layer (render layer 10) so it never clips walls.

## Testing
- `tools/test_all.sh`: 49 suites, all green on this PC after M11 (2026-09-29). Includes multi-process ENet tests, a
  4-player stress test, review regression suites, and the M10 suites (discipline, voice_test/voice_mp, physics/
  physics_mp, ui_m10/ui_m10_mp, events/events_mp).
- `tools/check.sh` loads every resource; `tools/smoke.sh` runs a solo loop and a host+client pair.
- Tests are Node "bodies" launched via `godot --headless --path . -s res://tools/tests/run_test.gd -- --body=...`.

## Known limitations at handoff
- Windows Firewall rule creation (WindowsFirewall autoload): the UAC path was verified on this PC 2026-09-29 with
  `.\launch.ps1 -Firewall -HostGame` (rule "Grow With Friends Multiplayer UDP 7777", UDP 7777 in, all profiles, program = the Godot
  editor exe). The exported exe gets its own repair prompt the first time it hosts (different program path).
- Relay amplification: a rogue peer's voice frames and chat lines are relayed by the server to every peer before game
  code drops them (receiver-side limits only): Godot's relay runs before game code, and `server_relay` stays on because
  the owner-authority movement sync needs it (CONTRACTS, Voice). The export templates (about 1 GB) are not installed
  yet: `tools\export.ps1` asks before downloading.
- Held item receives no world shadows (camera-layer view model).
- The microphone path was never heard by a human here (headless cannot capture); the receive path is tested.
- The booth door's collider is always solid; the Boss has no collision, workers cannot follow him into the booth.
- Fuse-box hold progress is local only; sight checks use the host's copy of remote bodies.
- No host migration; movement trusted to clients.

## Things the user may ask for next (not started)
- A real playtest by ear: voice levels, the sound ladder in sfx.gd (audio agent's risk list in the M10 report).
- Installing the export templates and cutting the first shareable zip (`tools\export.ps1`), a proper font, controller
  support, host migration.
