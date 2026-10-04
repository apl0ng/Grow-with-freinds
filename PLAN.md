# PLAN.md — Grow With Friends

4-player co-op first-person quota farming game. Godot 4.7.2, GDScript, ENet high-level multiplayer,
server-authoritative. Lead: Claude (lead dev / PM). Interfaces live in **CONTRACTS.md**, art rules in **STYLE.md**.

## How to run / test
- Editor: open the folder in Godot 4.7.x. Main scene is the main menu (Host / Join by IP). Solo = just Host.
- Two local instances: `godot --path . -- --host --name=Alice` and `godot --path . -- --join=127.0.0.1 --name=Bob`.
- Fast testing: add `--fast` (growth 20x, 60 s rounds), or `--growth-mult=N`, `--round-sec=N`.
- Controls: WASD move, Shift sprint, Space jump, Ctrl/C crouch, mouse look, E / LMB interact, Q / G drop,
  Enter = host starts the round, Esc = pause menu (or closes the shop).
- Headless validation: `tools/check.sh` (loads every script/scene/resource, boots the menu).
- End-to-end smoke tests: `tools/smoke.sh` (solo loop + real host/client pair over ENet).
- Per-area suites (all headless, all green at integration):
  `godot --headless --path . -s res://tools/tests/<suite>.gd` for `art_test`, `world_test`, `items_test`,
  `farm_test`, `econ_test`, `flow_test`; multi-process: `tools/tests/net_test.sh`, `items_net_test`, `items_e2e_test`,
  `farm_net_test`, `farm_world_test`, `econ_mp_test` (host/client roles), `flow_mp_test`.
- Unified runner: `tools/test_all.sh` runs every suite (about 3 min) and prints a results table; exit 0 means all green.
  `--list` shows the suites, `--only a,b` runs a subset. Env: `QA_BASE_PORT` (default 7900), `TEST_ALL_LOGS`, `GODOT`.
  Standalone QA: `tools/tests/qa_4p.sh` (4-player stress), `tools/tests/qa_mp_robust.sh`, and
  `godot --headless --path . -s res://tools/tests/run_test.gd -- --body=res://tools/tests/qa_{robust,solo}_body.gd --port=N [--fast]`.
  Balance estimate: `... --body=res://tools/tests/qa_balance_sim.gd [--sim-round=2 --sim-money=300 --sim-quota=350]`.
- Models: `python3 tools/blender/build.py [family ...] --test --shots DIR` (see MODELING.md).
- Screenshots without a GPU: `xvfb-run -a godot --path . --rendering-driver opengl3 -s res://tools/tests/net_preview.gd`
  (see also world_preview.gd, art_preview.gd).

## Milestones
| # | Milestone | Status |
|---|---|---|
| 1 | Project skeleton, folders, PLAN/CONTRACTS, balance resource, check tooling, menu stub | DONE (lead) |
| 2 | Networked first-person player, 4-player sync, host/join menu | DONE |
| 3 | Starting room blockout with all four stations | DONE |
| 4 | Interaction + carry systems | DONE |
| 5 | Shop, planting, watering, growth, harvesting, selling | DONE |
| 6 | Quota, timer, round flow, HUD | DONE |
| 7 | QA: multi-instance tests, desync fixes, solo play | DONE (21 suites, 2525 checks green) |

## Team & ownership (wave 1 runs in parallel; nobody edits files they don't own)
| Agent | Scope | Owns |
|---|---|---|
| **A art/style** | STYLE.md, toon material library, UI theme, Sfx + Juice autoloads | STYLE.md, art/**, scripts/art/** |
| **B net/player** | Net + Game autoloads, main menu (host/join/name/CLI args), Player controller + sync, World player spawning | scripts/core/net.gd, scripts/core/game.gd, scenes/main_menu/**, scenes/player/**, scripts/player/**, scenes/world/world.{tscn,gd} |
| **C world/level** | Room blockout (geometry, lights, props, station placement, spawn points), shopkeeper NPC visual | scenes/world/room.{tscn,gd}, scenes/world/shopkeeper_npc.{tscn,gd}, scenes/world/props/** |
| **D farming** | GrowPlot (stages, water, growth tick, visuals), Well (refill, starting cans) | scripts/stations/grow_plot.gd, scripts/stations/well.gd, scenes/stations/grow_plot.tscn, scenes/stations/well.tscn, scenes/stations/plant_visual*.{tscn,gd} |
| **E economy** | ShopCounter + ShopUI (seeds + upgrades, server-validated), TurnInStation (selling) | scripts/stations/shop_counter.gd, scripts/stations/turn_in_station.gd, scenes/stations/shop_counter.tscn, scenes/stations/turn_in_station.tscn, scenes/ui/shop_ui.{tscn,gd} |
| **F interaction/carry** | Interactor, Item base + ItemManager + 3 item scenes, pickup/drop, held-item visuals | scripts/interaction/interactor.gd, scripts/items/**, scenes/items/** |
| **G game flow/UI** | GameState autoload (money/quota/timer/rounds/upgrades sync), HUD, round-end overlay, pause menu | scripts/core/game_state.gd, scripts/ui/**, scenes/ui/hud.tscn, scenes/ui/round_end*.tscn, scenes/ui/pause_menu*.tscn |
| **H QA** (wave 2) | Headless multi-instance smoke tests, desync hunting, solo play check | tools/tests/**, tools/test_multiplayer.sh |
| **lead** | project.godot, CONTRACTS.md, PLAN.md, README.md, scripts/core/{const,config,balance_config,seed_def,upgrade_def}.gd, scripts/interaction/interactable.gd, data/**, tools/check* | integration, review, conflict fixes |

## Task list
| ID | Task | Owner | Status |
|---|---|---|---|
| 1.1 | Folder structure, project.godot (autoloads, input map, layers) | lead | done |
| 1.2 | BalanceConfig / SeedDef / UpgradeDef + data/balance.tres | lead | done |
| 1.3 | Interactable base class + stubs for every contract | lead | done |
| 1.4 | tools/check.sh headless validation | lead | done |
| 2.1 | Net autoload: host/join/leave, player registry sync, disconnect handling | B | done |
| 2.2 | Game autoload: menu↔world flow, ui lock, toasts, local player tracking | B | done |
| 2.3 | Main menu: name, host, join by IP, port, error message, CLI auto host/join | B | done |
| 2.4 | Player: FP controller (walk/sprint/jump/crouch/mouse look), sync, capsule + name label | B | done |
| 2.5 | World: player spawner (spawn_function), spawn points, despawn on leave | B | done |
| 3.1 | Room blockout: walls/floor/ceiling with collision, lights, props, station placement | C | done |
| 3.2 | Shopkeeper NPC visual (bubbly, idle animation) | C | done |
| 4.1 | Interactor: raycast, prompt signal, interact/drop input | F | done |
| 4.2 | Item base + ItemManager (spawn/despawn/give/drop/release) via MultiplayerSpawner | F | done |
| 4.3 | Item scenes: watering can, seed packet, product (synced props, visuals) | F | done |
| 5.1 | GrowPlot: plant/water/harvest interactions, growth tick, stage visuals + puff animation | D | done |
| 5.2 | Well: refill can, spawn starting cans | D | done |
| 5.3 | ShopCounter + ShopUI: seeds tab, upgrades tab, server-validated purchases | E | done |
| 5.4 | TurnInStation: sell product, float text, quota progress | E | done |
| 6.1 | GameState: phases, money, quota, timer, rounds, upgrades, full-state sync | G | done |
| 6.2 | HUD: quota/money/timer/round, prompt, held item, toasts, players | G | done |
| 6.3 | Round-end overlay + pause menu | G | done |
| A.1 | STYLE.md + toon material library + UI theme | A | done |
| A.2 | Sfx autoload (procedural placeholder sounds) + Juice autoload (pop/bounce/burst/float text) | A | done |
| 7.1 | Lead smoke tests (solo + host/client loop) | lead | done |
| 7.2 | Unified runner, 4-player stress test, robustness sweep, bug fixes (3 found/fixed) | H | done |
| 7.3 | Room lighting cool-down per art measurements | C | done |
| 8.1 | Factory retheme: room, props, Boss NPC, station visuals, factory palette | C | done |
| 8.2 | Narrative/text pass: HUD, menu, shop UI, overlays, Story autoload (Boss barks, debt board), team quota scaling (+ test updates) | writer | done |
| 8.3 | Dark undertone: material library re-tune, colder environment, sad ToonFace, mood rules in STYLE.md | A | in progress |
| 8.4 | Sad player faces / slumped idle on the player body | folded into 8.6a | — |
| 8.5 | Blender pipeline: tools/blender (gwf.py, build.py), Toonify, MODELING.md, reference contact sheets, models_test | pipeline | done |
| 8.6a | Modeling: player body (sad) + Boss | M1 | done |
| 8.6b | Modeling: shop cage counter, deposit chute, water tank, grow tray | M2 | done |
| 8.6c | Modeling: watering can, seed packet, product bundle | M3 | done |
| 8.6d | Modeling: roller door + beam, barred window, fence + gate, cable tray, pipes, grow-light bar, fluoro | M4 | done (room swaps being applied by C) |
| 8.6e | Modeling: pallet, crate, cot, camera, punch clock, debt board, clock, sad plant, signs, leaky pipe, hook up drum + lamps | M5 | done |
| 8.6 | Modeling wave (Blender): characters, stations, items + plant stages, room props | modelers | todo (after 8.5) |
| 9.1 | Adversarial code review + fixes: core/net/player/flow | R1 | done (3 host-hardening bugs fixed; slot fix by lead) |
| 9.2 | Adversarial code review + fixes: items/interaction/stations | R2 | done (favor double-buy race fixed) |
| 9.3 | Adversarial code review + fixes: UI/HUD/overlays/Story | R3 | done (6 focus/layout bugs fixed; START SHIFT is now an Enter hint since the mouse is captured while waiting) |
| 9.4 | Architecture models (Blender): cinder-block wall panels, floor slabs, ceiling beams/panels, hole rim | A2 | done |
| 9.5 | Farming polish: graded tag color, drop BudTop workaround, wilt crossfade, ready-plant hitbox verified | D2 | done |
| 9.6 | First-person view-model layer for held items (no wall clipping) + NaN-pose hardening | V | done |
| 9.7 | README refresh, CLAUDE.md for future sessions | lead | done |
| 8.7 | **Plant deep-dive (user request, back of queue):** take extra time on the plant model across seedling, vegetative, flowering ("fruitation") and ready stages; reference real cannabis morphology (cotyledons + first serrated leaflets, fan leaves with 5–7 serrated fingers on nodes, apical dominance, pistils/bud sites forming, dense colas with sugar leaves when ready, drooping when dry) but keep the output chunky/cartoon like the rest of the game | plant modeler | done |

## Decisions
- **Theme (user direction, after M6): the starting room is a LOW-BUDGET FACTORY.** The crew is here against their
  will, working off a debt to a shady "Boss" (the shopkeeper). Rendering stays chunky/cartoon (STYLE.md), but the
  setting, palette and all copy (HUD, menu, shop, overlays, NPC barks) shift to grim-but-charming sweatshop tone:
  rounds are "shifts", the quota is the "payment due", the shop is the Boss's supply window, the turn-in is a
  deposit chute. Retheme runs as: (1) visual pass on room/props/NPC/station visuals, (2) narrative/text pass after QA.
- **User direction (after retheme start): slight dark undertone everywhere; NOBODY is happy** (sad/tired faces, no
  smiles, no celebration effects) so the game never glamorizes anything; room bigger (~20×15×6 m), pendant lights
  dropping from a tall dim ceiling, a black hole in the ceiling you cannot see through, door barred with a skinny beam.
- **User direction: all models authored in Blender, inspired by asset packs (never copied), imported into Godot.**
  Blender is available as the bpy 4.2 Python module (no GUI), so models are built by bpy scripts under
  tools/blender/models/*.py and exported to art/models/*.glb; Kenney CC0 starter kits (from GitHub) are style reference
  only. Godot instances the .glb under each scene's `Visual` node and `Toonify.toonify()` converts materials to the
  toon look at runtime. Primitive-mesh visuals are placeholders until each model lands.
- **User request (queued last): the plant gets a dedicated modeling pass** with real-world cannabis growth stages as
  reference, cartoon output. Runs after the general modeling wave so it can take its time.
- **Quota = sales this round**, not wallet balance. Spending on seeds never lowers quota progress. Wallet carries over.
- **Round ends immediately when the quota is met** (`end_round_on_quota_met = true`, tweakable). Missing it at 0:00 = game over (host can Retry → full reset).
- **Plants persist across rounds**; growth and water drain only tick while a round is PLAYING (no free growth on the end screen).
- **Drop-in joining**: players join straight into the world. Host starts the round (Enter / HUD button) when everyone is in.
- **Movement is client-authoritative**, all gameplay actions are server-validated RPCs (Interactable base handles the plumbing + distance check).
- **Items are world nodes** under World/Items (MultiplayerSpawner + spawn_function). Holding = `holder_id` synced; the item copies the holder's hand-socket transform each frame. Never reparented. Dropping is allowed anywhere (hand-offs between players).
- **Watering cans** are persistent items (2 spawn at the well); seed packets are created by purchases; product is created by harvesting and destroyed by selling.
- **Upgrades** (fertilizer, bigger cans, sweet talk) are included as team-wide levels because they are cheap to add once the shop exists; values in balance.tres.
- Renderer: Forward+. Primitive meshes + `StandardMaterial3D` toon diffuse/specular + rim (no custom shader required).
- Godot 4.4+ `.uid` sidecar files are committed. `.godot/` is not.
- **Items sync `rest_position`/`rest_rotation`, not `position`**: a held item follows the holder's hand locally on every
  peer, so nothing streams while carrying. Server-side position writes on floor items still replicate (copied next frame).
- **Selling only while PLAYING** (`TurnInStation.sell_only_while_playing`), so sales between rounds are never lost.
- **ShopCounter overrides `interact()` locally** (opening a menu is not a server action); purchases are RPCs.
- **ENet slots = max_players + 3**: a 5th joiner is told "Server is full" instead of timing out, and two spare slots
  absorb half-finished connections that hold a slot for up to 30 s (found by the core review).
- **Effects run on every peer** from synced-property setters or cosmetic `call_local` RPCs, never from server-only code.
- **`-s` test scripts use a launcher + body split** (tools/tests/run_test.gd + a Node script) because a SceneTree
  script run with `-s` compiles before autoloads exist.

## Milestone notes
### M1 (done)
Works: project loads headless, balance resource generated from `tools/gen_balance.gd`, check tooling.
Placeholder: menu, HUD, stations, player are stubs that define the contracts. Test: `tools/check.sh`.

### M2 Networked player + menu (done)
Works: main menu (name / IP / port, remembers settings, CLI auto host/join), host + join by IP, 1–4 players with
unique names and palette colours, first-person controller (walk/sprint/jump/crouch/mouse look), ~30 Hz position sync
with smoothing, late joiners see everyone, clean handling of host leaving / client crash / full server / bad IP.
Placeholder: bean-shaped capsule bodies with eyes; no host migration; client-authoritative movement (no anti-cheat).
Test: `tools/tests/net_test.sh` (6 scenarios, 14 processes) and `tools/smoke.sh mp`.

### M3 Room blockout (done)
Works: closed 16×12×4 m room with collision, warm lighting, rug, windows, shelves, lamps, grow lights, pipes,
crates; shop (north), 6 plots (east, 2×3), well (west), turn-in (south); 4 spawn points; bubbly shopkeeper NPC that
idles, blinks, looks at players, waves and cheers. Placeholder: all primitive meshes; lighting tuned for the GL preview.
Test: `godot --headless --path . -s res://tools/tests/world_test.gd` (183 checks incl. reachability flood fill).

### M4 Interaction + carry (done)
Works: look-at + E prompts (enabled / greyed reason), one held item, pickup / drop (Q) with wall-safe drop spots,
watering can / seed packet / product world items spawned by the server, synced holders, late-join correct state.
Placeholder: held items can clip into walls in first person (needs a view-model layer later).
Test: `items_test` (111), `items_net_test` (45, one process, real ENet), `items_e2e_test` (27, two processes).

### M5 Shop / plant / water / grow / harvest / sell (done)
Works: shop UI (seeds + upgrades tabs, wallet, disabled states), server-validated purchases straight into your hands,
plots with 4 visible stages that pop in and pulse when ready, water gauge + DRY indicator, growth pauses when dry,
well refills cans (2 spawn at start), harvest into hands, selling adds to quota with float text / burst / sound,
team favors (Cheap Fertilizer, Dented Cans, Better Cut). Test: `farm_test` (99), `farm_net_test`, `farm_world_test`,
`econ_test` (116), `econ_mp_test`, and `tools/smoke.sh solo` (51 checks through the real RPC path).

### M9 Review wave, architecture models, polish (done)
Works: three adversarial reviews fixed 10 demonstrated bugs with regression suites (favor double-buy race across
workers/slow links; host freeze from a 300k-char name; invisible-character names; NaN-distance interaction bypass;
pause/round-end focus trap; Space/Enter pressing overlay buttons at shift end; client keyboard path; Escape cancels
connecting; worker list under the banner; oversized shift banner) plus spare ENet slots for half-finished handshakes
and NaN-pose hardening. Walls, floor, ceiling, beams and the hole rim are now Blender models (segment_run MultiMesh
runs, seams proven by models_arch_test). Farming: graded strain colour everywhere, no dummy nodes, 0.4 s wilt
crossfade, ready hitbox raycast-verified. First-person view-model layer: held items never clip walls (verified in GL
and Forward+ via software Vulkan). Test: `tools/test_all.sh` (35 suites).

### M8 Factory retheme, dark undertone, Blender models (done)
Works: 20×15×6 m factory room (cinder-block walls, concrete floor, pendant lamps on chains, flickering fluoros,
black ceiling hole, roller door barred with a wooden beam, fenced grow area, debt board, punch clock, cot, cameras);
every prop, station, item and character is a Blender-authored GLB (tools/blender/models/*.py → art/models/*.glb,
43 models, byte-deterministic builds, toon-converted at runtime by Toonify); the plant has four botanically
referenced cartoon stages plus wilted variants; the Boss scowls behind a barred supply window and barks; workers are
slumped, heavy-lidded and frowning; all copy is shift/payment/debt-toned with no cheer; team-scaled payments.
Placeholder: walls/floor/ceiling shell are still Godot primitives (architecture); Forward+ lighting was tuned by numbers
and GL previews only (no GPU here); sounds are synthesized placeholders never heard by a human.
Test: `tools/test_all.sh` (28 suites, 4783 checks). Models: `python3 tools/blender/build.py --test`; previews via the
`tools/tests/models_*_preview.gd` scripts under xvfb.

### M7 QA (done)
Works: `tools/test_all.sh` = 21 suites / 2525 checks green in ~3 min; 4-player stress test (same-frame pickup races,
plant/water/harvest by different players, late joiner mid-round, disconnect while holding, retry with clients,
next round, leave + rejoin), robustness sweep (garbage RPCs, double presses, drops near walls, full server, host
leaving, overlays vs return-to-menu), solo full round through real inputs, X11 mouse-mode check. Bugs fixed: items
dropped inside colliders, holder's double-press error toast, same-frame multi-disconnect ERROR lines.
Balance after QA sim: starting money 150, round-1 payment 350 (+150/shift, ×1.5), +20% per extra worker.

### M6 Quota / timer / rounds / HUD (done)
Works: WAITING → PLAYING (host presses Enter) → ROUND_SUCCESS (quota met, immediately) / ROUND_FAILED (timer) →
next round with scaled quota or RETRY (full reset, plants/items cleared) / main menu; HUD with round, timer (red +
ticks under 30 s), quota bar, wallet, player list, prompt, held item, toasts; round-end overlay; pause menu.
Test: `flow_test` (145), `flow_mp_test` (two processes).

## M10 Friendslop pass (in progress, 2026-09-28)
Why and what: **FRIENDSLOP.md**. Interfaces: CONTRACTS.md "M10". Lead prep landed first (stats / write-ups /
back room in GameState, stub autoloads Voice / Events / Comms, input actions, balance knobs, placeholder sounds,
test_all.sh runs under Git Bash without setsid); the wave runs in parallel git worktrees, one branch per agent,
merged by the lead.

| Agent | Scope | Owns (nobody else edits these) |
|---|---|---|
| **voice** | proximity voice chat, push-to-talk, back-room channel, speaking signals | scripts/core/voice.gd, tools/tests/voice_* |
| **physics** | throw (arc, hits, chute shots), shove, worker collision, footsteps, stagger | scripts/player/**, scenes/player/**, scripts/interaction/**, scripts/items/**, scenes/items/**, scripts/stations/turn_in_station.gd, tools/tests/physics_* |
| **events** | Events autoload, inspection (Boss walks + sight), power cut + FuseBox station, audit, rat (stretch), room hooks | scripts/core/events.gd, scenes/world/shopkeeper_npc.*, scenes/world/room.*, scenes/world/props/rat.*, scenes/stations/fuse_box.tscn, scripts/stations/fuse_box.gd, scripts/stations/grow_plot.gd, tools/tests/events_* |
| **ui** | HUD marks + event banner, back-room overlay + spectator, shift report, ping + chat (Comms), Boss lines, pause-menu voice settings | scripts/ui/**, scenes/ui/**, scripts/core/comms.gd, scripts/core/story.gd, tools/tests/ui_m10_* |
| **audio** | new sound recipes, loops (keys, hum), event alarms, levels | scripts/art/sfx.gd, tools/tests/art_test.gd |
| **modeling** | Blender 5.2 on Windows for the pipeline; fuse_box, clipboard, rat, backroom_door models | tools/blender/**, art/models/{fuse_box,clipboard,rat,backroom_door}.*, art/models/manifest.json, MODELING.md, tools/tests/models_props_test.gd |
| **lead** | GameState, Const, BalanceConfig, project.godot, CONTRACTS/PLAN/FRIENDSLOP, test_all.sh, integration (model swaps, suite registration), QA | everything else |

| ID | Task | Owner | Status |
|---|---|---|---|
| 10.0 | Design (FRIENDSLOP.md), contracts, GameState stats / write-ups / back room / audits + discipline test, stubs, inputs, knobs, sounds, Windows test runner | lead | done |
| 10.1 | Voice autoload: capture, mu-law codec, relay, 3D playback, back-room channel, tests | voice | done |
| 10.2 | Throw + hits + chute shots, shove, player collision, footsteps, stagger, tests | physics | done |
| 10.3 | Events: scheduler, inspection walk + sight checks, power cut + fuse box, audit, rat, room hooks, tests | events | done |
| 10.4 | HUD marks / banner, back-room overlay + spectator camera, shift report, Comms (ping, chat), Story lines, pause voice settings, tests | ui | done |
| 10.5 | Sounds: steps, keys loop, breaker, hum, door, alarms, write-up; loop API; art_test rows | audio | done |
| 10.6 | Models: fuse_box, clipboard, rat, backroom_door; build.py on Windows / Blender 5.2 | modeling | done |
| 10.7 | Integration: merge, model swaps into scenes, register suites, full test_all green, playtest with 2 windows | lead | done (all six branches merged; model swaps; full suite green on Windows) |
| 10.8 | QA sweep: 4-player cases for throws / shoves / inspection / back room; regression fixes | qa | todo |

Decisions:
- **Events are off in headless sessions unless `--events` is passed** (and always off with `--no-events`), so every
  existing suite keeps deterministic shifts; event tests opt in.
- **Back room uses the shift timer** (`backroom[peer]` = time_left at release): no extra timer sync, released at
  shift end. Only while PLAYING.
- **Story owns all new copy** (inspection lines, write-ups, events, report verdicts); Events only emits signals.
- **Worktrees:** agents work in `.claude/worktrees/<agent>` on branch `m10/<agent>` from the lead prep commit and
  commit there; the lead merges. Shared files (project.godot, CONTRACTS, PLAN, test_all.sh, sound names) are lead-only.

## M11 QA sweep + shipping (in progress, 2026-09-29)
| ID | Task | Owner | Status |
|---|---|---|---|
| 11.1 | Adversarial review of every M10 request path (hostile inputs, back-room cheating, griefing limits, churn during events, copy tone) + regression suite review_m10 | review | done (6 bugs fixed: back-room server rule, shop/Escape in the back room, stranded items, stagger immunity, shove LOS) |
| 11.2 | Four-player stress of M10 (same-frame throws, chute shots, shove chains, inspection with churn, back room, power cut, voice/chat floods, retry, a full shift with the scheduler on) qa_m10_4p | qa | done (506 checks; 2 bugs fixed: back-room slots, workers as moving platforms) |
| 11.3 | Shareable Windows build: export_presets.cfg ("Windows Desktop", embedded PCK) + tools/export.ps1 (installs the Windows export templates on request, exports, zips) | lead | done (templates not downloaded yet: the user's call, ~1 GB) |
| 11.4 | `--mute` / `-Mute` / saved Sound toggle; playtest switches `--auto-start`, `--first-event`, `--event-delay` | lead | done |
| 11.5 | LAN discovery: Lan autoload (UDP beacon on 7778 while hosting) + "Floors open nearby" in the menu; lan suite | lead | done |
| 11.6 | Windows Firewall permission for hosting: WindowsFirewall autoload (read-only netsh check, one UAC prompt through a PowerShell helper, retry button, `--firewall` / `--no-firewall`); firewall suite | lead | done (UAC path verified on the user's PC 2026-09-29: rule created, hosting started) |
| 11.7 | Launchers: launch.ps1 rewrite (parameter sets, `-Mute`, `-NoDownload`, ASCII output), Linux / macOS `launch.sh`, `.gitattributes` keeping `*.sh` LF | lead | done |
| 11.8 | Graceful test shutdown (Voice.shutdown + Sfx.stop_all before quit) against the exit-139 crash after PASS; full run 2026-09-29: 49 suites, about 7,900 checks, no crash | lead | done (watch for a recurrence) |
| 11.9 | Late joiner's rat resumes from the seconds left instead of rerunning from the gap; events_mp waits for both reliable packets (power / event) before asserting | lead | done |

## M12 Strains, the hostile plant, the emergency flamethrower, more disruptions (merged 2026-10-01)
Asked for by the user on 2026-10-01: "ways to disrupt the gameplay loop, more strains, a chance to grow an angry plant
that attacks players and eats the plants, a break-in-case-of-emergency flamethrower". Contracts: CONTRACTS.md "M12".
Rationale: FRIENDSLOP.md section 7.
| ID | Task | Owner | Status |
|---|---|---|---|
| 12.0 | Prep: Const stats / write-ups, BalanceConfig M12 groups, SeedDef.mutation_chance, `use_item` on LMB, Hostiles autoload stub, World/Hostiles, GrowPlot.server_scorch stub, Sfx names | lead | done |
| 12.1 | Three strains (Night Shift, Creeper, Floor Brick) with mutation chances, blurbs, counter/HUD fit; models hostile_plant / emergency_cabinet / flamethrower; strains suite | strains | done (314 checks) |
| 12.2 | Hostile plant: mutation roll + twitch on READY plants, Hostiles autoload (server behaviour, 10 Hz sync, late-join replay), HostilePlant node, eat / chase / bite / burn / die, Story lines; hostile + hostile_mp suites | hostile | done (100 + 37 checks) |
| 12.3 | Emergency cabinet (deposit, restock, misuse write-up) + flamethrower item (use_item, fuel, cone: burns hostiles, scorches crops, ignites workers, arson write-ups); flame + flame_mp suites | flame | done (104 + 47 checks) |
| 12.4 | Events: head count, water main off, supply shortage; weights; Well pressure, ShopCounter shortage; Story lines; disrupt + disrupt_mp suites | disrupt | done (114 + 59 checks) |
| 12.5 | Integration: merge, hook the models, test_all registration + ports, README controls (LMB = use item), CONTRACTS "M12 as delivered", a four-player playtest | lead | pending |

## M13 Hardening M12: review, four-player QA, visual pass (merged 2026-10-02)
| ID | Task | Owner | Status |
|---|---|---|---|
| 13.1 | Adversarial review of every M12 request path and state transition (fire RPC, cabinet, shortage / pressure refusals, authority-only RPCs, late joins, shift end, back room, griefing limits, copy, numbers) + review_m12 suites (+63 / +64) | review | done (16 fixes; 184 + 57 checks) |
| 13.2 | Four-process stress of M12 (mutation under load, the chase, fire, events on top, churn) qa_m12_4p (+65) | qa | done (652 checks; 2 fixes) |
| 13.3 | Visual pass on the real renderer (tools/tests/m12_shots_body.gd): flame plume, on-screen notices for a moving tray and a plant coming out, first-person flamethrower pose checked, banners checked | lead | done |
| 13.4 | Hostile plant 2x (user request), tray warning line, fire-kills-plant covered in the flame suite, real recipes for flame / ignite / glass_break / scorch | lead | done |
| 13.5 | Merge 13.1 and 13.2, register the suites, full run, re-export | lead | done (59 suites, 9891 checks green; export re-cut) |
| 13.6 | Lead follow-ups from the review: the Boss keeps the flamethrower of a back-room worker, MIN_EAT_SEC, Night Shift 210, report verdicts for burns / scorched / bitten, "No pressure.", the supply window footer hint | lead | done |
Known UI gap: the supply window shows one and a half rows of the six strain cards at 720 lines (it scrolls; arrows and the
wheel reach the second row). A compact card would fit both rows; not done yet.

## M14 The lobby and the van, a bigger floor, mayhem, strain traits (merged 2026-10-02)
Asked for by the user on 2026-10-02 (brainstorm + build): FRIENDSLOP.md section 8, CONTRACTS.md "M14".
| ID | Task | Owner | Status |
|---|---|---|---|
| 14.0 | Prep: Config.lobby_enabled, Const stats and group, BalanceConfig groups (Lobby, Mayhem, Loop), SeedDef traits, Room stubs (arrival, gunfire lanes, play areas), Sfx names | lead | done |
| 14.1 | The alley, the van, pile-in start with a countdown, fade and teleport to the dock, back to the alley between shifts, van model; lobby + lobby_mp suites | lobby | done (168 + 214 checks) |
| 14.2 | Grow hall (four more trays) and loading dock through new openings, play areas, arrivals, gunfire lanes, the plant crossing rooms; level suite | level | done (240 checks; world_test 302) |
| 14.3 | Events: the tank leak (patch it, puddle, slips) and the drive-by (lanes, cover, crouch, tray damage, the fine); mayhem + mayhem_mp suites | mayhem | done (210 + 87 checks) |
| 14.4 | Strain traits (thirsty, counted, grows in the dark, spreads, heavy) on the six strains, drying racks with cured bundles; loop + loop_mp suites | loop | done (238 + 66 checks) |
| 14.5 | Footsteps: one per human stride, three variants, crouch quieter, a landing thud | lead | done |
| 14.6 | Integration: merges, racks moved into the hall, van model on the dock, test_all registration, README, a visual pass, full run, export | lead | done (66 suites, 11959 checks green; export re-cut) |

## M15 Replayability: conditions and a market, contracts and a career, three more events, the economy, the alley (done, 2026-10-02)
Asked for by the user on 2026-10-02 ("keep going", then "refine gameplay, I want good replayability"):
FRIENDSLOP.md section 9, CONTRACTS.md "M15".
| ID | Task | Owner | Status |
|---|---|---|---|
| 15.0 | Prep: Config.replay_enabled, Const (raid write-up, ball, contracts stat), BalanceConfig groups (Mayhem 2, Replay), SeedDef.unlock_round, Sfx names, Career autoload stub | lead | done |
| 15.1 | Events: the raid, the sprinklers, the collector; weights for twelve kinds; mayhem2 + mayhem2_mp suites | mayhem2 | done (240 + 95 checks) |
| 15.2 | A model of a shift (econ_sim), the payment due / cure time / Purple Haze / Golden Kush retuned from it; economy suite | economy | done (122 checks; the lead put shift 1 back to $350: 350, x1.82 + 688, and the market swing to 0.15) |
| 15.3 | The alley: a ball, a hoop with a counter, the board (last shift, briefing, career); alley + alley_mp suites | alley | done (183 + 75 checks) |
| 15.4 | Shift conditions (ten or more), the market, strains unlocking by shift, event gaps shrinking; replay + replay_mp suites | replay | done (thirteen conditions; 293 + 81 checks, 52 with --no-replay) |
| 15.5 | Contracts (eight or more), the career file, job titles, the Record page; career + career_mp suites | career | done (nine jobs; 207 + 91 checks) |
| 15.6 | Integration: merges, test_all registration, captures in the real renderer (the job on the alley board, the banner under the payment column, raid lights retuned), README, full run, export | lead | done (76 suites, 13525 checks green; export re-cut) |

## M16 The floor moves, issued kit, more jobs (done, 2026-10-02)
The user said "proceed" after M15 (2026-10-02); the lead chose this scope from FRIENDSLOP 9.5: FRIENDSLOP.md
section 10, CONTRACTS.md "M16".
| ID | Task | Owner | Status |
|---|---|---|---|
| 16.0 | Prep: Config.run_code, BalanceConfig group M16 (mutation cap, empty flamethrower timer), Sfx names (uproot, locker) | lead | done |
| 16.1 | A run code that seeds the card, cover layouts picked per run, the menu field, the board line; variety + variety_mp suites | variety | done (four layouts, dice seeded per shift; 244 + 73 checks) |
| 16.2 | Hats issued from the record, the locker in the alley, hat sync, six models; hats + hats_mp suites | hats | done (seven hats, the stock hard hat split out of the worker model; 230 + 74 checks; the lead raised the change limit to 160) |
| 16.3 | Three more jobs, the mutation cap, the uproot sound, empty flamethrowers cleared, the sound audition tool; polish suite | polish | done (twelve jobs; 167 checks) |
| 16.4 | Integration: merges, test_all registration, captures in the real renderer (hats, locker, four layouts, the menu row), README, full run, export | lead | done (81 suites, 14622 checks; the full run failed two old timing races, mayhem_mp and qa_m12_4p, fixed in the tests and rerun green; export re-cut) |

## M17 A run has an end, a hand truck, two more events (done, 2026-10-04)
The user said "keep going" after M16 (2026-10-02); the lead chose this scope from FRIENDSLOP 10.4: FRIENDSLOP.md
section 11, CONTRACTS.md "M17".
| ID | Task | Owner | Status |
|---|---|---|---|
| 17.0 | Prep: Const.ITEM_HAND_TRUCK, BalanceConfig group M17, Sfx names (phone, scale, truck, paid in full) | lead | done |
| 17.1 | The final notice (a run's last shift by team size), its half-time look, PAID IN FULL, the cleared record and its hat; finale + finale_mp suites | finale | done (105 + 63 checks; the first agent stopped on the Fable usage limit, an Opus agent finished) |
| 17.2 | The hand truck: heavy carry, four bundles, deposit all at the chute, the raid takes its load; cart + cart_mp suites | cart | done (159 + 81 checks) |
| 17.3 | Events: the scale that reads light, the phone; weights for fourteen kinds; mayhem3 + mayhem3_mp suites | mayhem3 | done (194 + 69 checks; the lead capped retries of a told kind) |
| 17.4 | Integration: merges, test_all registration, captures in the real renderer, README, full run, export; the exit crash found and fixed (Game.quit_gracefully, quit suite) | lead | done (88 suites, 15470 checks green; export re-cut) |

## M18 Radios, spores, gestures, a fairer payment for full crews (in progress, 2026-10-04)
The user asked for "more" after M17 (2026-10-04); the lead chose this scope: FRIENDSLOP.md section 12, CONTRACTS.md
"M18".
| ID | Task | Owner | Status |
|---|---|---|---|
| 18.0 | Prep: Const.ITEM_RADIO, input actions emote_1..4, BalanceConfig group M18 and quota_team_growth, Sfx names | lead | done |
| 18.1 | Walkie-talkies: radio voice to every other radio, the shelf, clicks and static; radio + radio_mp suites | radio | in progress |
| 18.2 | Black Damp (seventh strain): spore clouds, fogged workers (screen, hearing, coughing); spores + spores_mp suites | spores | in progress |
| 18.3 | Gestures: point, half-wave, shrug, slump; emotes + emotes_mp suites | emotes | in progress |
| 18.4 | The payment for full crews grows by shift (quota_team_growth) against the final notice; economy suite | economy2 | in progress |
| 18.5 | Integration: merges, test_all registration, captures in the real renderer, README, full run, export | lead | pending |
