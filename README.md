# Grow With Friends

A 1–4 player co-op first-person quota game. You and your crew are locked in a low-budget factory, working off a
debt to the Boss: buy seeds at his barred supply window, plant them in the grow trays, haul water from the tank,
harvest, and deposit the product before the shift timer runs out. Make the payment and the number goes up.
Miss it and nobody leaves.

Godot 4.7.2 · GDScript · ENet high-level multiplayer (host/join by IP, server-authoritative) · all models authored
in Blender (bpy) and imported as glTF · chunky cartoon look with a deliberately dark undertone (nobody is happy).

## Run
- Windows: double-click `launch.cmd` (or `.\launch.ps1` in PowerShell). It finds Godot 4.7.2 or offers to download
  it into `tools\godot\`. Options: `-HostGame`, `-Join <ip>`, `-Name <name>`, `-Port`, `-Fast`, `-Players 2..4`
  (several local windows for testing), `-Editor`, `-Fullscreen`.
- Linux / macOS (or Git Bash): `./launch.sh` finds Godot through `$GODOT`, `tools/godot/` or PATH. Options: `--host`,
  `--join <ip[:port]>`, `--name`, `--port`, `--fast`, `--mute`, `--players 2..4`, `--editor`, `--import`, `--fullscreen`.
- Any OS: open the folder in Godot 4.7.x and press Play. Host to play solo; friends join with your IP, or pick your
  floor from "Floors open nearby" when they are on the same network (UDP broadcast on port 7778).
- Two local instances: `godot --path . -- --host --name=Alice` and `godot --path . -- --join=127.0.0.1 --name=Bob`.
- `--fast` makes growth 20× faster and shifts 60 s; `--growth-mult=N`, `--round-sec=N` for finer control. `--mute` (or
  `-Mute` on the launcher) silences the game; the pause menu has a saved Sound toggle. `--auto-start[=sec]` starts the
  shift by itself on the host, `--first-event=<kind>` and `--event-delay=<sec>` steer the first shift event (playtests).
- Controls: WASD move · Shift sprint · Space jump · Ctrl/C crouch · mouse look · E interact · LMB use the held item (hold: the flamethrower) · Q / G drop ·
  RMB / R throw · F shove · MMB / X ping · T chat · V push-to-talk · Enter starts the shift (host) · Esc pause (or
  closes the supply window). Voice, chat and ping settings live in the pause menu.
- Friendslop pass (M10, see FRIENDSLOP.md): proximity voice chat, throwing and shoving, worker collision, random shift
  events (the Boss walks the floor and writes up skimmers and loiterers, power cuts with a fuse box, audits, a rat),
  three write-ups send a worker to the back room (spectating), a shift report with verdicts. `--no-events` disables
  the events; headless runs need `--events` to enable them.
- Trouble (M12, FRIENDSLOP.md section 7): six strains (Night Shift, Creeper and Floor Brick pay more and have a
  mutation chance), a ready plant can twitch and uproot into a hostile plant that eats growing trays and bites workers
  (a stagger, the item knocked loose); only fire kills it. Stats: bitten, scorched, burns.

## Test
- `tools/test_all.sh` — every suite (headless + multi-process ENet + xvfb), about 5 minutes, prints a table. On Windows
  run it from Git Bash with `export GODOT=<path to Godot_v4.7.2-stable_win64_console.exe>` (no setsid needed).
- `tools/check.sh` — loads every script/scene/resource and boots the menu.
- `tools/smoke.sh` — solo loop and a real host+client pair.

## Models
- `python3 tools/blender/build.py [family ...] --test` builds `tools/blender/models/*.py` into `art/models/*.glb`
  and imports them. See MODELING.md for the workflow and STYLE.md for the look.

## Windows Firewall
- When you press Host on Windows, the exported game (or a dev run with `.\launch.ps1 -Firewall`) checks for an
  inbound rule "Grow With Friends Multiplayer UDP 7777" and, if it is missing, asks once for administrator permission
  (the normal Windows prompt) to add just that rule, scoped to the game executable. Declining it never stops hosting: you
  are told friends may not get in, and the menu offers a retry. Nothing else in the firewall is touched. `--no-firewall`
  skips the check. Friends over the internet still need UDP 7777 forwarded on your router (not automated).

## Share a build with friends
- `.\tools\export.ps1` exports `export\GrowWithFriends.exe` (+ a zip) with the "Windows Desktop" preset. It needs the Godot
  4.7.2 export templates once (about 1 GB): the script offers to download them (resumable, so a dropped connection just needs a re-run; `-DownloadTemplates` skips
  the question).
  Friends unzip and run the exe; one hosts, the others join by IP (UDP port 7777 must be reachable).

## Docs
PLAN.md (status, decisions, milestone notes) · CONTRACTS.md (system interfaces) · STYLE.md (art + copy rules) ·
MODELING.md (Blender pipeline).
