# PLAN.md — Grow With Friends

4-player co-op first-person quota farming game. Godot 4.7.2, GDScript, ENet high-level multiplayer,
server-authoritative. Lead: Claude (lead dev / PM). Interfaces live in **CONTRACTS.md**, art rules in **STYLE.md**.

## How to run / test
- Editor: open the folder in Godot 4.7.x. Main scene is the main menu (Host / Join by IP).
- Two local instances: `godot --path . -- --host --name=Alice` and `godot --path . -- --join=127.0.0.1 --name=Bob`.
- Fast testing: add `--fast` (growth 20x, 60 s rounds).
- Headless validation: `tools/check.sh` (loads every script/scene/resource, boots the menu).
- Automated multiplayer smoke test: `tools/test_multiplayer.sh` (QA milestone).

## Milestones
| # | Milestone | Status |
|---|---|---|
| 1 | Project skeleton, folders, PLAN/CONTRACTS, balance resource, check tooling, menu stub | DONE (lead) |
| 2 | Networked first-person player, 4-player sync, host/join menu | in progress |
| 3 | Starting room blockout with all four stations | in progress |
| 4 | Interaction + carry systems | in progress |
| 5 | Shop, planting, watering, growth, harvesting, selling | in progress |
| 6 | Quota, timer, round flow, HUD | in progress |
| 7 | QA: multi-instance tests, desync fixes, solo play | todo |

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
| 2.1 | Net autoload: host/join/leave, player registry sync, disconnect handling | B | todo |
| 2.2 | Game autoload: menu↔world flow, ui lock, toasts, local player tracking | B | todo |
| 2.3 | Main menu: name, host, join by IP, port, error message, CLI auto host/join | B | todo |
| 2.4 | Player: FP controller (walk/sprint/jump/crouch/mouse look), sync, capsule + name label | B | todo |
| 2.5 | World: player spawner (spawn_function), spawn points, despawn on leave | B | todo |
| 3.1 | Room blockout: walls/floor/ceiling with collision, lights, props, station placement | C | todo |
| 3.2 | Shopkeeper NPC visual (bubbly, idle animation) | C | todo |
| 4.1 | Interactor: raycast, prompt signal, interact/drop input | F | todo |
| 4.2 | Item base + ItemManager (spawn/despawn/give/drop/release) via MultiplayerSpawner | F | todo |
| 4.3 | Item scenes: watering can, seed packet, product (synced props, visuals) | F | todo |
| 5.1 | GrowPlot: plant/water/harvest interactions, growth tick, stage visuals + puff animation | D | todo |
| 5.2 | Well: refill can, spawn starting cans | D | todo |
| 5.3 | ShopCounter + ShopUI: seeds tab, upgrades tab, server-validated purchases | E | todo |
| 5.4 | TurnInStation: sell product, float text, quota progress | E | todo |
| 6.1 | GameState: phases, money, quota, timer, rounds, upgrades, full-state sync | G | todo |
| 6.2 | HUD: quota/money/timer/round, prompt, held item, toasts, players | G | todo |
| 6.3 | Round-end overlay + pause menu | G | todo |
| A.1 | STYLE.md + toon material library + UI theme | A | todo |
| A.2 | Sfx autoload (procedural placeholder sounds) + Juice autoload (pop/bounce/burst/float text) | A | todo |
| 7.1 | Headless smoke tests (solo + host/client loop), fix desyncs | H | todo |

## Decisions
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

## Milestone notes
### M1 (done)
Works: project loads headless, balance resource generated from `tools/gen_balance.gd`, check tooling.
Placeholder: menu, HUD, stations, player are stubs that define the contracts. Test: `tools/check.sh`.
