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
- **ENet slots = max_players + 1** so a 5th joiner is told "Server is full" instead of timing out.
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

### M8 Factory retheme, dark undertone, Blender models (done)
Works: 20×15×6 m factory room (cinder-block walls, concrete floor, pendant lamps on chains, flickering fluoros,
black ceiling hole, roller door barred with a wooden beam, fenced grow area, debt board, punch clock, cot, cameras);
every prop, station, item and character is a Blender-authored GLB (tools/blender/models/*.py → art/models/*.glb,
43 models, byte-deterministic builds, toon-converted at runtime by Toonify); the plant has four botanically
referenced cartoon stages plus wilted variants; the Boss scowls behind a barred supply window and barks; workers are
slumped, heavy-lidded and frowning; all copy is shift/payment/debt-toned with no cheer; team-scaled payments.
Placeholder: walls/floor/ceiling shell are still Godot primitives (architecture); Forward+ lighting was tuned by numbers
and GL previews only (no GPU here); sounds are synthesized placeholders never heard by a human.
Test: `tools/test_all.sh` (30 suites). Models: `python3 tools/blender/build.py --test`; previews via the
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
