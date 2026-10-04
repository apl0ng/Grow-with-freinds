# Agent rules for a milestone wave (read all of this before you start)

Written for M18 (2026-10-04); the lead copies it per wave and changes the milestone, the agent names, the base
commit and the base ports. Everything else holds for every wave.

You are one of four agents (radio, spores, emotes, economy2) building milestone M18 of "Grow With Friends": Godot
4.7.2, GDScript, a co-op first-person quota game, server-authoritative ENet, models built by Blender scripts. You
work alone in your own git worktree; the lead merges your branch.

## Worktree
- Create it (Git Bash; works from any checkout of this repo):
  `git worktree add "/c/Users/ap_lo/OneDrive/Desktop/Grow With Freinds/.claude/worktrees/<agent>18" -b m18/<agent> 691e542`
- Work ONLY inside that directory, by absolute paths. Never edit the main checkout
  (`C:\Users\ap_lo\OneDrive\Desktop\Grow With Freinds`: the user launches the game from it) or any other worktree.
  Commit on your branch. Do NOT push, do NOT merge.
- Read in your worktree: CLAUDE.md, CONTRACTS.md section "M18" (your part of it is your specification) and the
  "as delivered" notes of M15, M16 and M17, FRIENDSLOP.md section 12, STYLE.md (copy tone: flat, grim, nobody is
  happy, no exclamation marks, no cheer).

## Godot
- `export GODOT="/c/Users/ap_lo/Downloads/Godot_v4.7.2-stable_win64.exe/Godot_v4.7.2-stable_win64_console.exe"`
- A new worktree has no `.godot` cache: run `timeout 500 "$GODOT" --headless --path . --import` once first, and again
  after you add a model or a `class_name`.
- ALWAYS `--headless` and ALWAYS wrapped in `timeout <sec>`. A Godot run without --headless opens a game window on
  the user's screen: forbidden for agents.
- `--import` rewrites existing `art/models/*.glb.import` with LF. Before every commit run
  `git ls-files -m -- 'art/models/*.glb.import' icon.svg.import | xargs -r git checkout --`
  (NEW sidecars of your own new files are committed).
- There is no python on PATH.

## Blender (only if you make a model)
- `"/c/Program Files/Blender Foundation/Blender 5.2/blender.exe" --background --python tools/blender/build.py -- <family>`
  builds one family from `tools/blender/models/<family>.py`. NEVER a full unnamed build. Read MODELING.md; look at
  a recent family (tools/blender/models/hand_truck.py, wall_phone.py, hats.py) and the models suites
  (`models_test`, `models_item_test`, `models_props_test`) for what a new model must satisfy (manifest entry,
  triangle budget, palette materials). Chunky, worn, dented, taped; nothing shiny or cute.

## Tests
- `tools/check_files.sh res://path`, `tools/check.sh`,
  `QA_BASE_PORT=<your base> TEST_ALL_LOGS=/tmp/<agent>18_logs tools/test_all.sh --only a,b,c`.
- Base ports: radio 9100, spores 9200, emotes 9300, economy2 9400.
- Suites are Node "bodies" run via `tools/tests/run_test.gd -- --body=res://tools/tests/<name>.gd`. Good shapes to
  copy: tools/tests/cart_body.gd (solo host + a fake worker), cart_mp.sh + cart_mp_body.gd (host + client + late
  joiner as separate processes), mayhem3_body.gd (events through the host's tick steps). Any unannounced ERROR line
  fails a suite. A suite ends through smoke_base.finish() (it releases audio and waits before quitting).
- Do NOT edit tools/test_all.sh: put the lines to add in your report (one `run_suite` line per suite, the
  ALL_SUITES names, the port offsets).
- Any run with `--replay` also passes `--run=B5VP` (cover layout 0, a fixed card) and
  `--career-file=user://<agent>_test_<port>.cfg`. The user's real record `user://career.cfg` EXISTS: never read,
  write or delete it.

## Editing on this CRLF checkout
- Safest: `perl tools/dev/splice.pl <file> <old block file> <new block file>` (exact block replace, `<T>` = a tab,
  CRLF kept) and `perl tools/dev/insert_after.pl <file> <anchor text> <block file>`; write block files with quoted
  heredocs. The Edit tool also works.
- Pitfalls seen here: `$1` inside a perl replacement held in a variable lands literally; `$500` interpolates even
  inside `\Q..\E`; Bash heredocs containing backticks fail in this tool (write such text with the Write tool); `%`
  in a GDScript format string must be `%%`; a perl `-pi` regex anchored with `$` misses on CRLF lines.

## Ownership
- Lead-only files, never edit: project.godot, CONTRACTS.md, PLAN.md, README.md, HANDOFF.md, FRIENDSLOP.md,
  tools/test_all.sh, scripts/core/const.gd, scripts/core/balance_config.gd, scripts/core/config.gd, and the tables
  (SOUNDS / SETTINGS / LOOPING) of scripts/art/sfx.gd. What the lead prepared for M18 is listed in CONTRACTS "M18",
  "Prep already in place". Sound recipes go in a block of your own in the recipe function of sfx.gd (procedural
  like the neighbours, no DC offset: there is a `_dc_block` helper; art_test checks every sound).
- In shared files edit only inside a region `# --- M18 <agent> ---` that you add, plus one-line hooks tagged
  `# M18 <agent>`. Put your region where the other agents are unlikely to insert (not all at the very end of a
  file if you can avoid it).
- Codebase rules: never reparent spawned nodes (players, items). Server-authoritative: only the host mutates
  state; clients send `@rpc("any_peer", "call_local", "reliable")` requests validated on the server (sender 0 ->
  1). Effects run on every peer from synced setters or cosmetic RPCs. Player movement is owner-authoritative.
- The cover layouts (`Room.COVER_LAYOUTS`, four, picked by the run code) move the dock / main room / hall crates:
  anything you place must be clear in all four (`Room.is_in_cover`, `Room.get_cover_footprints`) and off the routes.
- Never kill processes you did not start. If a tool call is denied, do not work around it: say so in the report.

## Report (your final message; it is all the lead will see)
Branch and commit ids; what shipped (exact signatures); deviations from the contract and why; every file changed,
with hooks outside your regions listed; test pins you changed on purpose; the exact run lines and results; the
lines for tools/test_all.sh; what you never saw rendered or heard, with node paths and camera positions / look-at
points (or the calls that force each state) for the lead's capture pass; one or two README sentences; decisions the
lead should review. State plainly anything that failed or was skipped.
