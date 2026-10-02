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
  events (the Boss walks the floor and writes up skimmers and loiterers, power cuts with a fuse box, audits, a rat;
  M12: head counts, the water main going off, supply shortages of the strain you planted most),
  three write-ups send a worker to the back room (spectating), a shift report with verdicts. `--no-events` disables
  the events; headless runs need `--events` to enable them.
- Trouble (M12, FRIENDSLOP.md section 7): six strains (Night Shift, Creeper and Floor Brick pay more and have a
  mutation chance), a ready plant can twitch and uproot into a hostile plant that eats growing trays and bites workers
  (a stagger, the item knocked loose; never through a fence); only fire kills it. A tray that starts to turn warns
  every player on screen ("GrowPlot 3 is moving."): six seconds to harvest it or step back.
  A red cabinet on the wall by the fuse box holds one flamethrower: break the glass (E; a cash deposit, and a
  write-up for misuse when nothing is on the floor), hold LMB to
  fire (eight seconds of fuel; burnt crops and co-workers are arson, another write-up); it restocks after ninety
  seconds. Breaking it while a tray is turning is not misuse. The Boss keeps the flamethrower of anyone he sends to the
  back room. Stats: bitten, scorched, burns (the shift report names who).
- The alley and the van (M14): a windowed game starts in a back alley. The shift begins when every worker stands in the
  back of the van (a short count, a fade, and everyone is on the loading dock); the host's Enter leaves without the
  stragglers. Between shifts everyone is back in the alley. Use --no-lobby for the old start on the floor.
- A bigger floor (M14): a grow hall to the east (four more trays, ten in all, and two drying racks) and a loading dock
  to the south with crates for cover. Hang a bundle on a rack for forty-five seconds and it sells cured for 40% more.
  Each strain has a trait: Purple Haze is thirsty, Golden Kush is counted (losing one is a fine), Night Shift grows
  during a power cut, Creeper can leave a seedling behind, Floor Brick is heavy to carry.
- Two more things go wrong on a shift (M14): the tank springs a leak (hold E on it to patch it before it runs dry,
  and do not sprint through the puddle), and a rival crew pulls up outside and shoots the floor up for six seconds
  (get down or get behind a crate; trays in the way lose growth and the Boss bills the floor for the glass).
- No two shifts alike (M15): from the second shift on, the board in the alley posts what is different today before
  anyone gets in the van. One condition a shift, two from shift five: dry air, a twitchy batch, a buyer for one
  strain, seed clearance, inspection week, bad wiring, a short clock, overtime, a slick floor, thin walls, a heat
  wave, a quiet night, an order for cured. Every strain's deposit value also moves up to 15% either way each shift
  (the supply card shows it). Strains open up by shift: Golden Kush at two, Night Shift at three, Floor Brick at four.
- A job a shift (M15): one optional job from the Boss on top of the payment (three cured bundles, no write-ups, burn
  one that walks, patch a leak inside ten seconds). $60 to cash on hand when it is met. It is on the board, under the
  payment bar and in the shift report.
- Your record (M15): shifts worked, best shift, total deposited, jobs done, plants burnt, times bitten, shot and sent
  to the back room, kept in a file on your own PC. The alley board and the pause menu show it; a job title that
  follows your best shift sits under your name for everyone to see.
- Three more things go wrong (M15): a raid (twenty seconds of sirens, then they look in from the roller door, the
  dock passage and the middle of the floor; every bundle in sight is taken and whoever holds one is written up, so
  sell it, get it behind a crate stack or carry it into the grow hall), the sprinklers (every tray filled to the
  top, the whole floor slippery while they run and for ten seconds after), and the collector (a man on the dock
  wants $40: hold E on him to pay out of cash on hand, or he takes the dearest bundle on the floor, and with no
  bundle the plant that is furthest along).
- The alley has a ball, a hoop with a counter, and the board (last shift, next shift, your record).
- The payment due (M15): $350 for the first shift, then it climbs fast ($1,325, $2,535, $4,174, $6,592, $10,429 for
  one worker; 10% more for each extra worker). The sixth shift needs favors and cured bundles. `--no-replay` turns
  the conditions, the market, the unlocks and the jobs off.
- The floor moves (M16): the crates and pallets on the dock, in the main room and in the hall stand differently each
  run (four arrangements). Every run has a four-character code on the alley board. Type a friend's code into the run
  code field under Open the floor, or press THIS WEEK, and the host deals the same run: the same conditions, market,
  jobs, order of events and the same crates in the same places (`--run=<code>` does the same from the command line).
- Issued kit (M16): your record issues hats: a hairnet after the first shift, a paper cap after ten, a yellow hard
  hat for reaching shift three, a traffic cone for three trips to the back room, a bucket for five bites, a welding
  mask for five plants burnt, a bandage for being shot three times. Nothing is bought. Change it at the locker under
  the street lamp in the alley (E); everyone on the floor sees what you wear.
- Twelve jobs now (M16): one bundle each of three strains, lose no plant this shift, and a raid that takes nothing
  join the list. No condition pushes a strain's chance to walk past 50%, a plant that leaves its tray sounds like
  roots and not like a harvest, and an empty flamethrower left on the floor is cleared after 30 seconds.
- To hear the synthesised sounds without launching the game:
  `godot --headless --path . -s res://tools/tests/run_test.gd -- --body=res://tools/tests/sound_demo_body.gd --out=<dir>`
  writes one WAV per sound (`--sounds=a,b,c` or `all`).

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
