# CONTRACTS.md — interfaces between systems

Every system is owned by exactly one agent (see PLAN.md). Other agents only call the APIs below.
If you need something that is not here, ask the lead; do not edit files you don't own.

Engine: **Godot 4.7.2, GDScript**. Headless binary: `godot` (on PATH). Validate with `tools/check.sh`.
Server-authoritative: **all state mutation happens on the host (peer 1)**. Clients only send requests.

## Autoloads (project.godot, in this order)
| Name | Script | Owner |
|---|---|---|
| `Const` | scripts/core/const.gd | lead (constants: layers, groups, item types, effect keys) |
| `Config` | scripts/core/config.gd | lead (`Config.balance: BalanceConfig`, CLI test overrides) |
| `Net` | scripts/core/net.gd | net/player agent |
| `Game` | scripts/core/game.gd | net/player agent |
| `GameState` | scripts/core/game_state.gd | game-flow/UI agent |
| `Sfx` | scripts/art/sfx.gd | art agent |
| `Juice` | scripts/art/juice.gd | art agent |

Autoload scripts must NOT declare `class_name`.

## Collision layers (Const.LAYER_*)
1 world (static geometry) · 2 player bodies · 3 interactable (stations) · 4 item (carryables).
Player body: layer 2, mask 1. Station colliders: layer 1|3 (=5), mask 0. Item colliders: layer 4, mask 0 (0 while held).
Interaction ray mask: 1|3|4 so walls block the ray. Ray length `Config.balance.interact_distance`.

## Net (autoload)
```gdscript
signal players_changed                      # players dict changed (any peer)
signal connection_failed(reason: String)    # client only
signal server_disconnected                  # client only
signal peer_registered(peer_id: int)        # SERVER: peer sent name/color, players[peer_id] now exists
signal peer_left(peer_id: int)              # SERVER (and clients after sync): peer gone
var players: Dictionary                     # peer_id -> {"name": String, "color": Color}  (synced)
var is_host: bool                           # true only on the host; valid immediately after host()
var local_name: String
var local_color: Color
func host(port: int = Config.balance.default_port) -> Error
func join(ip: String, port: int = Config.balance.default_port) -> Error
func leave() -> void
func is_online() -> bool
func get_player_name(peer_id: int) -> String
func get_player_color(peer_id: int) -> Color
signal peer_joined(peer_id); signal peer_rejected(reason)     # additions
const PALETTE; func get_peer_ids() -> Array[int]; func sanitize_name(n) -> String
```
Server slots = max_players + 3: one so a 5th joiner gets "Server is full" instead of a timeout, two more because
half-finished connections (cancelled/crashed mid-handshake) hold a slot for 5–30 s without the engine reporting them. Unregistered peers are dropped
after 10 s; join attempts time out after 12 s. Names are made unique ("Bob 2"). Colors by join order:
bubblegum #FF7EB6, sky #4DA8F7, sunshine #FFD23F, mint #33D1B0.
Use `Net.is_host` for "am I the authority" in `_ready`-time code (before a client is connected,
`multiplayer.is_server()` is misleadingly true). Inside RPC handlers `multiplayer.is_server()` is fine.

## Game (autoload) — scene flow
```gdscript
signal world_ready(world: World)              # every peer: World is in the tree and _ready ran
signal local_player_spawned(player: Player)   # every peer: my own Player node exists
signal toast_requested(text: String, kind: StringName)   # kind: &"info" | &"error" | &"success"
signal ui_lock_changed(locked: bool)
var world: World                              # null in the menu
var local_player: Player
func start_host(player_name: String, port: int) -> Error
func start_join(ip: String, port: int, player_name: String) -> Error
func return_to_menu(message: String = "") -> void   # any peer; disconnects and shows the menu (with message)
func get_player(peer_id: int) -> Player
func get_local_peer_id() -> int
func toast(text: String, kind: StringName = &"info") -> void
func set_ui_lock(source: StringName, locked: bool) -> void  # shop UI, pause menu, round-end screen
func is_ui_locked() -> bool                                  # player ignores input + frees mouse while locked
func is_ui_locked_by(source: StringName) -> bool; func refresh_mouse_mode() -> void
```
`world_ready` / `local_player_spawned` are emitted deferred (end of frame) once the node is in the tree and `_ready` ran.
`return_to_menu()` is deferred: Net.leave → GameState.reset_local → clear UI locks → remove Players → free World → menu.
Game owns the mouse mode (captured only with a world and no UI lock).
Order of operations: **host**: `Net.host()` → world instantiated → `world.server_spawn_player(1)`.
**client**: world instantiated **first** → `Net.join()` → on `connected_to_server` the client registers
name/color → server spawns its Player and sends full GameState. (World-before-connect guarantees the client's
MultiplayerSpawners exist when spawn packets arrive.)

## World (scenes/world/world.tscn + world.gd, owner: net/player agent)
```
World (Node3D, class World)
├─ Room            (instance room.tscn, owner: world/level agent)
├─ Players         (Node3D) - Player nodes named by peer id ("1", "23456")
├─ PlayerSpawner   (MultiplayerSpawner, spawn_path ../Players, spawn_function set by world.gd)
├─ Items           (Node3D + item_manager.gd, class ItemManager, owner: interaction/carry agent)
├─ ItemSpawner     (MultiplayerSpawner, spawn_path ../Items, spawn_function set by item_manager.gd)
└─ HUD             (instance hud.tscn, owner: game-flow/UI agent)
```
```gdscript
var room: Room; var players_root: Node3D; var items: ItemManager
func get_player(peer_id) -> Player; func get_players() -> Array[Player]
func server_spawn_player(peer_id: int) -> Player     # uses room.get_spawn_transform(i)
func server_despawn_player(peer_id: int) -> void
func server_reset_player_positions() -> void          # addition; also an OverviewCamera node exists for screenshots
```
Spawned nodes (players, items) are **never reparented** (the spawner would despawn them on clients).

## Room (scenes/world/room.tscn, owner: world/level agent)
Must keep: `$Spawns/Spawn1..4` (Marker3D), `$Stations/ShopCounter`, `$Stations/Well`, `$Stations/TurnInStation`,
`$Stations/GrowPlot1..6` (instances of the station scenes — only their transforms are set here).
`func get_spawn_points() -> Array[Marker3D]`, `func get_spawn_transform(index: int) -> Transform3D`,
`get_station(name)`, `get_stations()`, `get_bounds() -> AABB`, `get_station_access_point(name)`.
Layout: interior x -8..8, z -6..6, ceiling 4 m. Shop (0,-3.7) faces +Z; Well (-5.6,0) faces +X; TurnIn (0,4.5) faces -Z;
plots at x 3.5/6.0, z -2.5/0/2.5 facing -X; spawns near the centre facing the shop.

## Player (scenes/player/player.tscn + scripts/player/player.gd, class Player, owner: net/player agent)
Node name == peer id. `_enter_tree` sets multiplayer authority to peer id (recursive). Movement is
client-authoritative (owner syncs position/rotation), everything else is server-authoritative.
```gdscript
var peer_id: int; var display_name: String; var player_color: Color
func is_local() -> bool
func get_item_socket() -> Node3D      # %HandSocket (under camera) if local, else %BodyHandSocket
func get_held_item() -> Item          # via Game.world.items.get_held_by(peer_id)
func get_interactor() -> Interactor
@onready var camera: Camera3D = %Camera
```
Required unique-named children: `%Camera`, `%HandSocket`, `%BodyHandSocket`, `%Interactor` (script
scripts/interaction/interactor.gd), `%NameLabel` (Label3D). Local player hides its own body + label.
Player input is ignored (and the mouse is released) while `Game.is_ui_locked()`.
Additions: `spawn_index`, `place_at(xf)`, `server_teleport(pos)` (the ONLY way the server may move a client's player:
plain position writes on the server are overwritten by the owner's sync), `respawn()`, `apply_look_input()`,
`get_look_direction()`. Sync: owner writes `net_position/net_yaw/net_pitch` each physics tick, `$Sync` sends them
unreliably ~30 Hz (always, so late joiners get them); remote peers smooth toward them (snap if > 3 m or on first packet).
**First-person view model:** render layer 10 (`Player.VIEW_MODEL_LAYER`, named "viewmodel" in project.godot) is
excluded from %Camera's cull mask. The local player builds, at runtime, a CanvasLayer(-1) → transparent SubViewport
(same World3D) → Camera (layer 10 only, copies %Camera each frame after the item snaps to its socket) → full-screen
TextureRect. While the local player holds an item, `Item` moves its visual nodes to layer 10 (`is_in_view_model()`,
`refresh_view_model()`, original layers kept in `META_WORLD_LAYERS`) and restores them on drop/hand-off/despawn. The
pass renders only while an item is held. Lights get the layer bit added by the local player. Player API:
`view_model_enabled`, `uses_view_model()`, `is_view_model_active()`, `get_view_model_viewport()/camera()`,
`add/remove_view_model_user()`, `sync_view_model()`, `refresh_view_model_environment()`. Limitation: the held item
receives no world shadows (camera-layer approach).
**NaN rule:** synced `net_position/net_yaw/net_pitch` that are not finite are ignored (last valid pose kept, pitch
clamped ±89°); ItemManager never feeds non-finite positions into drops/releases (falls back below the holder, else the
first spawn point); the Interactable distance check is written `not (d <= max)` so NaN cannot pass.
**Everything under a Player (Interactor included) has that peer's authority**: `@rpc("authority")` there can only be
called by the owner; server→owner calls need `any_peer` + a sender check.

## Interactable (scripts/interaction/interactable.gd, LEAD-OWNED base class; read it)
Subclasses override `get_prompt(player) -> String`, `can_interact(player) -> bool`,
`get_denied_reason(player) -> String`, and `_server_interact(player)` (server only).
Never override `interact()` / the RPCs. Denials show a toast + error sound automatically.
Physical setup: a StaticBody3D/Area3D child on layer 3 (stations) or 4 (items); the Interactor walks up from
the hit collider to the nearest `Interactable` ancestor.

## Interactor (%Interactor on the player, owner: interaction/carry agent)
```gdscript
signal prompt_changed(text: String, enabled: bool)   # "" = hide. HUD listens on Game.local_player.get_interactor()
signal target_changed(target: Interactable)
var current_target: Interactable
func try_interact() -> void; func try_drop() -> void   # bound to "interact" (E / LMB) and "drop" (Q / G)
```
Handles its own input in `_unhandled_input` for the local player only, respecting `Game.is_ui_locked()`.

## Items (owner: interaction/carry agent)
`Item extends Interactable` (scripts/items/item.gd). Scenes: scenes/items/{watering_can,seed_packet,product}.tscn
with scripts `WateringCan`, `SeedPacket`, `Product` (all `extends Item`).
```gdscript
# Item
@export var item_type: StringName          # Const.ITEM_WATERING_CAN / ITEM_SEED_PACKET / ITEM_PRODUCT
var holder_id: int                         # 0 = on the floor; synced, server authority
func get_display_name() -> String; func is_held() -> bool; func get_holder() -> Player
# WateringCan: var charges: int (synced); func get_capacity() -> int  (= GameState.get_can_capacity())
# SeedPacket:  var strain_id: StringName (synced); func get_seed() -> SeedDef
# Product:     var strain_id: StringName, var amount: int (synced); func get_seed() -> SeedDef
```
Held items follow `holder.get_item_socket()` every frame (copy global transform × per-item hold pose), collision disabled.
Interacting with a floor item = pick up (only with empty hands). Drop key drops ~0.8 m in front of the player on the floor.
**Sync detail:** items sync `rest_position` / `rest_rotation` (not `position`), so a held item that follows a hand does not
stream deltas. Server code may still just write `item.global_position` on a floor item; ItemManager copies it into the rest
values next frame. Extra Item API: signals `holder_changed`, `props_changed`; `get_status_text()`, `get_label_text()`
(HUD uses it: "Watering Can (3/4)"), `get_visual()`, `get_collider()`, `apply_props()/get_props()`, `server_set_rest()`;
WateringCan `is_empty()/is_full()`; SeedPacket/Product `get_strain_name()`.
```gdscript
# ItemManager (World/Items)
func server_spawn_item(item_type: StringName, props := {}, position := Vector3.ZERO, holder_id := 0) -> Item
#   props: watering_can {"charges": int}   seed_packet {"strain_id": StringName}   product {"strain_id": StringName, "amount": int}
func server_despawn_item(item: Item) -> void
func server_give_item(item: Item, peer_id: int) -> bool
func server_drop_item(item: Item, position: Vector3) -> void
func server_release_holder(peer_id: int) -> void      # called by Net on disconnect
func get_held_by(peer_id: int) -> Item
func get_items() -> Array[Item]
func request_drop() -> void                            # any peer (local): drop what I hold (RPC to server)
func server_despawn_all() -> void; func get_items_of_type(type) -> Array[Item]
signal item_added(item); signal item_removed(item); signal holder_changed(item, old_holder, new_holder)
```
On `GameState.game_reset` the host despawns all seed packets and products (cans are re-homed by the Well).
QA rules: an item's holder re-requesting pickup is a silent no-op; drops never land inside geometry or on a station
(the spot is walked back toward the player, feet as the last resort); Net's disconnect cleanup (incl. `peer_left`)
runs at the end of the frame. `BalanceConfig.quota_for_round(n, player_count)` scales the quota by team size.
Initial world spawns (e.g. the well's starting cans) must wait for `Game.world_ready` and check `Net.is_host`
(ItemManager._ready runs after Room._ready, so do not spawn from a station's `_ready`).

## GameState (autoload, owner: game-flow/UI agent)
```gdscript
enum Phase { MENU, WAITING, PLAYING, ROUND_SUCCESS, ROUND_FAILED }
signal money_changed(money: int)
signal sales_changed(round_sales: int, quota: int)
signal time_changed(time_left: float)
signal phase_changed(phase: int)
signal round_started(round_number: int)
signal round_ended(success: bool, round_number: int)
signal sale_made(amount: int, seller_peer: int)
signal purchase_made(cost: int, buyer_peer: int, what: String)
signal upgrade_level_changed(upgrade_id: StringName, level: int)
var phase: int; var money: int; var round_number: int; var quota: int; var round_sales: int
var time_left: float; var upgrades: Dictionary   # upgrade_id -> level
func is_playing() -> bool                         # phase == PLAYING (growth/drain tick only then)
# SERVER ONLY mutators (assert multiplayer.is_server()); all broadcast to clients:
func server_try_spend(amount: int, buyer_peer: int, what: String) -> bool
func server_add_sale(amount: int, seller_peer: int) -> void      # money += amount; round_sales += amount
func server_add_money(amount: int) -> void
func server_buy_upgrade(upgrade_id: StringName, buyer_peer: int) -> bool
func server_start_round() -> void                 # WAITING/ROUND_SUCCESS -> PLAYING (next round, new quota, timer reset)
func server_reset_game() -> void                  # -> WAITING, round 1, starting money, upgrades cleared
func server_send_full_state(peer_id: int) -> void # called by Net when a peer registers
# host-only requests from UI (validated server side): 
func request_start_round() -> void; func request_next_round() -> void; func request_retry() -> void
# effect helpers (any peer):
func get_effect_total(effect_key: StringName) -> float
func get_growth_speed_multiplier() -> float   # (1 + growth_speed effect) * Config.growth_speed_override
func get_can_capacity() -> int                # Config.balance.can_capacity + can_capacity effect
func get_sale_multiplier() -> float           # 1 + sale_bonus effect
func get_water_drain_multiplier() -> float    # 1 / (1 + water_retention effect)
func get_upgrade_level(upgrade_id: StringName) -> int
# additions:
signal game_reset                                  # every peer, after a RETRY reset is applied (not on the first reset)
func reset_local() -> void                         # any peer: back to MENU defaults (Game calls it on return_to_menu)
func get_time_string() -> String                   # "mm:ss"
func get_phase_name() -> String; func is_local_host() -> bool; func is_round_over() -> bool
func get_quota_progress() -> float; func get_upgrade_next_cost(upgrade_id) -> int
```
Sync: every server_* mutation broadcasts the full (tiny) state dict with a reliable call_local RPC; the timer is sent
every 0.5 s unreliable_ordered with a round serial; clients tick locally and never end rounds themselves.
Quota rule: `round_sales` (money earned from sales this round) must reach `quota` before `time_left` hits 0.
Spending does not reduce quota progress. Money carries over between rounds. Plants persist between rounds.
Round ends immediately on quota met if `Config.balance.end_round_on_quota_met`.

## Stations
**GrowPlot** (`scripts/stations/grow_plot.gd`, scenes/stations/grow_plot.tscn, owner: farming agent)
synced: `stage: Stage`, `strain_id`, `water: float 0..1`, `stage_progress: float 0..1`.
Interactions: seed packet + empty plot → plant · watering can (charges>0) + plant → water · READY + empty hands → harvest
(spawns product in hands: `{"strain_id", "amount": seed.yield_amount}`). Growth ticks on the server only while
`GameState.is_playing()` and `water >= dry_threshold`.
GrowPlot additions: `tick(delta)`, `server_plant(strain_id) -> bool`, `server_water(charges_worth := 1.0) -> bool`,
`server_harvest(player) -> bool`, `server_reset()`, `is_growing()`, `needs_water()`, `get_growth_fraction()`,
`get_status_text()`, `get_stage_duration()`, `get_seed()`, `get_strain_name()`; static helpers `is_server_peer(node)`,
`item_is(item, type)`, `get_can_charges/get_can_capacity/get_packet_strain/get_held_item_of`. Sync: `Sync` node,
`replication_interval 0.1`; stage/strain ON_CHANGE (reliable), water/progress ALWAYS (unreliable). Plots clear on
`GameState.game_reset`. `PlantVisual` (scenes/stations/plant_visual.tscn) renders the 4 stages + dry state.
**Well** (`well.gd`): refills a held watering can to `get_capacity()`; spawns `starting_watering_cans` at `$CanSpots/*`
on `Game.world_ready` (host only, once); on `game_reset` re-homes/refills every can two frames later. API:
`server_fill_can`, `server_spawn_starting_cans`, `server_reset_cans`, `get_can_spots`, `get_can_spot_position`.
**ShopCounter** (`shop_counter.gd`, owner: economy agent): overrides `interact()` WITHOUT calling super (opening a menu
is purely local); `open_shop_for(player)`, `get_shop_ui()`, `UI_LOCK_SOURCE = &"shop"`. Buy requests:
`request_buy_seed(id)` / `request_buy_upgrade(id, seen_level := -1)` (client) → `_rpc_request_buy_*` → server
`server_buy_seed(peer, id)` / `server_buy_upgrade(peer, id, seen_level := -1)` returning `{"ok", "reason", "message"}`;
a favor request carries the level the card was priced at and is refused with "Price changed. Look again." if the
team level moved on (prevents double-buys across workers or slow links); validation order: player exists, range, def exists,
hands empty, `GameState.server_try_spend`, spawn packet in the buyer's hands (refund if the spawn fails).
**TurnInStation** (`turn_in_station.gd`, owner: economy agent): sells a held Product:
`value = int(round(amount * seed.sale_value_per_unit * GameState.get_sale_multiplier()))` → `GameState.server_add_sale`.
Selling only works while PLAYING (`sell_only_while_playing` export) so between-round sales are not lost.
**ShopkeeperNPC** (`scenes/world/shopkeeper_npc.tscn`, world agent): visual only; `wave()`, `cheer()`; looks at the nearest player.

## HUD (scenes/ui/hud.tscn, owner: game-flow/UI agent)
Shows quota progress (round_sales / quota), wallet, timer, round number, phase banner, held item, prompt, toasts,
player list. Round-end overlay (success/fail; host: Next round / Retry / Menu, clients: waiting / Leave).
Pause menu on `pause` action (Resume / Leave to menu). All overlays use `Game.set_ui_lock`.
Classes: `HUD` (`show_toast`, `set_prompt_source`, `refresh_all`, static `format_money`, `action_key_text`),
`RoundEndOverlay`, `PauseMenu`, `HudToast`. The ShopUI lives on CanvasLayer 5 (above the HUD on layer 1).

## Story (autoload, owner: narrative pass) — local-only narrative glue, no RPCs
Listens to GameState/Net/Game signals on every peer: writes the debt board (`Room.set_debt_board_text`: "OWED $x /
SHIFT n" counting down, "PAID… FOR NOW", "YOU'RE DONE"), and makes the Boss `bark()` on events (shift start, first
deposit, 50%, payment met, missed, purchase, worker joined/left, last 30 s "Tick tock.") with a 6 s rate limit and a
one-slot queue; falls back to a toast if the NPC has no `bark()`. API: `lines`, `blurbs`, `line(key)`, `get_blurb(id)`,
`bark_now(text)`, `get_board_text()`, `refresh_board()`, `find_boss()`, `reset_state()`, `last_bark`, `bark_log`,
signal `bark_shown`; `boss_override` / `board_override` for tests.
GameState additions: `get_team_size()` (Net registry size, ≥1), `get_quota_for(round)`; shift start and reset use
`Config.balance.quota_for_round(round, team_size)`; while WAITING the host re-prices the coming shift when workers
join or leave; a running shift keeps its number.
Vocabulary (all copy): shift, payment due, cash on hand, workers, supply window, favors (upgrades), deposit (sell).

## Sfx / Juice (autoloads, owner: art agent)
```gdscript
Sfx.play(name: StringName, position: Vector3 = Vector3.INF)   # 2D when no position
# names: &"buy" &"plant" &"water" &"harvest" &"sell" &"pickup" &"drop" &"error" &"grow" &"round_win" &"round_lose" &"tick" &"ui_click" &"ui_open" &"ui_close" &"round_start" &"countdown"
Juice.pop_in(node: Node, duration := 0.35)           # scale 0 -> 1 with overshoot (Node3D or Control)
Juice.bounce(node: Node, strength := 0.2)            # quick squash & stretch
Juice.pulse(node: Node)                              # subtle attention pulse (loops until Juice.stop(node))
Juice.burst(position: Vector3, color: Color, count := 12)   # one-shot 3D particle burst
Juice.float_text(position: Vector3, text: String, color := Color.WHITE)  # rising 3D label ("+$120")
Juice.punch_ui(control: Control)                     # scale punch for HUD numbers
```
Materials: `res://art/materials/toon_<name>.tres` (see STYLE.md for the list). UI theme: `res://art/ui/theme.tres`.

## Command line (for local multi-instance testing)
`godot --path . -- --host [--name=Alice] [--port=7777]` · `godot --path . -- --join=127.0.0.1 [--name=Bob]`
`--fast` (growth 20x, 60 s rounds) · `--round-sec=N` · `--growth-mult=N`. Handled by main_menu.gd (auto host/join) and Config.

---

# M10 — Friendslop pass (lead; rationale in FRIENDSLOP.md, tasks in PLAN.md)

New autoloads, in project.godot order after Story: `Voice` (scripts/core/voice.gd, voice agent), `Events`
(scripts/core/events.gd, events agent), `Comms` (scripts/core/comms.gd, ui agent). The lead committed STUBS with
the exact surfaces below so every agent can build against them; the owner replaces the bodies, never the surface.
New input actions (project.godot): `throw` (RMB, R), `shove` (F), `ping` (MMB, X), `chat` (T), `push_to_talk` (V),
`spectate_next` (D, Right), `spectate_prev` (A, Left). `audio/driver/enable_input` is on (microphone).
New balance knobs (BalanceConfig groups "Discipline", "Events", "Physical", "Voice"): see balance_config.gd.
New Const: `GROUP_NPCS`, `STAT_*` keys, `WRITE_UP_*` reasons, `UI_LOCK_BACKROOM`.

## GameState additions (lead) — stats, write-ups, back room, audits
```gdscript
signal stats_changed                                          # every peer: `stats` changed
signal worker_written_up(peer_id: int, reason: String, count: int)   # every peer; count = strikes after this one (0 = sent to the back room)
signal backroom_changed(peer_id: int, active: bool)           # every peer
var stats: Dictionary       # peer_id -> {Const.STAT_* -> int}; reset at every shift start / game reset, kept through the end screen
var write_ups: Dictionary   # peer_id -> strikes this shift (cleared when sent to the back room, at shift end and on reset)
var backroom: Dictionary    # peer_id -> round time_left at which the worker is released
func get_stat(peer_id, key) -> int; func get_worker_stats(peer_id) -> Dictionary; func get_write_ups(peer_id) -> int
func is_in_backroom(peer_id) -> bool; func get_backroom_time_left(peer_id) -> float; func get_backroom_peers() -> Array[int]
# SERVER ONLY:
func server_add_stat(peer_id, key: StringName, amount := 1) -> void          # broadcasts the state
func server_write_up(peer_id, reason: String) -> int   # fine (write_up_fine), STAT_WRITE_UPS++, strikes++; at write_ups_to_backroom -> back room; returns strikes (0 after the back room)
func server_send_to_backroom(peer_id, seconds := -1.0) -> bool               # PLAYING only (uses the shift timer), false otherwise
func server_release_from_backroom(peer_id) -> void
func server_raise_quota(fraction: float) -> int                              # audit: quota *= 1 + fraction while PLAYING; returns the new quota
```
Deposits are counted by `server_add_sale` itself (STAT_DEPOSITED += amount). GrowPlot counts planted / watered /
harvested in `_server_interact`. Everything else (throws, hits, shoves, pings) is the feature owner's call.
The host releases back-room workers when the shift timer passes their release time, at shift end, and when the
peer leaves. The UI (ui agent) locks input with `Game.set_ui_lock(Const.UI_LOCK_BACKROOM, true)` and shows the
overlay on `backroom_changed` for the local peer; the events agent moves the body (`Player.server_teleport`) to
the room's `BackRoomSpot` when `backroom_changed(peer, true)` fires on the host, and back to a spawn on release.

## Voice (voice agent) — scripts/core/voice.gd
```gdscript
signal speaking_changed(peer_id: int, speaking: bool)     # remote heard / local transmitting
signal input_level_changed(level: float)                  # local mic 0..1 (~20 Hz while capturing)
var enabled: bool; var push_to_talk: bool; var output_volume_db: float; var input_gain: float; var transmitting: bool
func is_speaking(peer_id) -> bool; func is_transmitting() -> bool; func get_input_level() -> float
func is_mic_available() -> bool; func get_speaking_peers() -> Array[int]
```
Capture: `AudioStreamMicrophone` on a muted `Mic` bus + `AudioEffectCapture`; 20 ms frames, 16 kHz mono, mu-law
8-bit (320 bytes). Transport: `@rpc("any_peer", "call_remote", "unreliable")` `_rpc_voice(seq: int, frame:
PackedByteArray)` sent with `rpc()` (server relay). Receivers drop frames larger than 400 bytes, more than 60 per
second per peer, or from peers not in `Net.players`. Known limit: Godot's server relay forwards a client's
`rpc()` before any receiver-side check runs, so a flooding client still costs the host its upload times the other peers;
`server_relay` stays on because the owner-authority `MultiplayerSynchronizer` movement depends on it.
Playback: one `AudioStreamPlayer3D` + `AudioStreamGenerator`
per remote peer under `Game.world` ("VoiceOut/<peer>"), moved to the speaker's head each frame, unit_size about
`voice_range / 2`, max_distance `voice_range`. Back room: see the header of voice.gd. `push_to_talk` action = hold to
send; open mic = energy gate. Headless: no capture, receive path still works (tests feed synthetic frames).

## Events (events agent) — scripts/core/events.gd
```gdscript
signal event_started(kind: StringName, params: Dictionary); signal event_ended(kind: StringName); signal power_changed(on: bool)
const EVENT_INSPECTION, EVENT_POWER_CUT, EVENT_AUDIT, EVENT_RAT
var active_event: StringName; var power_on: bool
func is_power_on() -> bool; func is_event_active(kind := &"") -> bool; func get_event_time_left() -> float
func are_events_enabled() -> bool     # balance.events_enabled and not --no-events and (window or --events)
func server_start_event(kind, params := {}) -> bool; func server_end_event() -> void; func request_event(kind) -> void
```
Host schedules events only while PLAYING (first after `event_first_delay_sec`, then gaps in
[event_gap_min_sec, event_gap_max_sec]); one at a time; late joiners get the current state. Signals fire on every
peer from call_local RPCs. **Inspection:** the Boss (ShopkeeperNPC, `walk_route(points)`, `is_walking()`, group
GROUP_NPCS) leaves the booth and walks `Room.get_inspection_route()` for `inspection_sec`; every 0.5 s the host
checks each worker on the floor: within 5 m, inside a 120 degree cone in front of him, line of sight (ray on
LAYER_WORLD from his eyes to the worker's chest, 1.0 m up when standing, 0.6 m crouched): holding a product ->
`GameState.server_write_up(peer, Const.WRITE_UP_SKIMMING)` + the product despawned; not moving (< 0.3 m in
`loiter_sec`) -> WRITE_UP_LOITERING; a worker is written up at most once per 5 s. **Power cut:** `Room.set_power(false)`
(lights to ~6 %, grow bars off, fluoros dark; `Room.is_power_on()`), growth pauses (`GrowPlot.tick` checks
`Events.is_power_on()`), ends when a worker holds E for `fuse_reset_sec` at `Stations/FuseBox` (`FuseBox`
station, `scripts/stations/fuse_box.gd`, `is_tripped()`, progress synced for the prompt) or after
`power_cut_max_sec`. **Audit:** `GameState.server_raise_quota(fraction)` (lead) once, instant. **Rat (stretch):**
a `Rat` NPC runs from a wall gap to a growing plot and eats stage progress until a worker comes within 1.5 m. A late joiner
sees him where he is by now (part-way along the run, or eating at the tray), like the Boss's resumed walk.
Story (ui agent) owns every line of copy for these; Events only emits signals (plus `worker_written_up` from GameState).

## Comms (ui agent) — scripts/core/comms.gd
```gdscript
signal ping_received(peer_id: int, position: Vector3); signal chat_received(peer_id: int, text: String)
const CHAT_MAX_CHARS := 120; const PING_MIN_GAP_SEC := 0.8; const CHAT_MIN_GAP_SEC := 0.5; const PING_MAX_RANGE := 40.0
func ping(world_position: Vector3) -> void; func say(text: String) -> void; static func sanitize_chat(text) -> String
```
`@rpc("any_peer", "call_local", "unreliable")` for pings, `reliable` for chat; receivers validate the sender is in
`Net.players`, rate-limit per sender, sanitize, and emit. The HUD draws a marker (Label3D + a small diamond in the
sender's colour, 4 s) and the chat log (bottom-left, 8 s fade; T opens the line, Enter sends, Esc closes; the chat
box takes a UI lock `&"chat"` while open). `STAT_PINGS` via `GameState.server_add_stat` from the host receiver.

## Player / items additions (physics agent)
```gdscript
# Player
func request_shove(target_peer: int) -> void                  # local -> server; validated (range shove_range, cooldown)
func server_shove(target: Player, direction: Vector3, from_behind: bool) -> void   # server -> target owner RPC
func apply_stagger(impulse: Vector3, stun_sec: float) -> void  # owner: velocity += impulse, input off for stun_sec, camera kick
func is_stunned() -> bool
signal staggered(by_peer: int)                                 # every peer (cosmetic RPC), for sounds / faces
# Interactor: "throw" -> ItemManager.request_throw(); "shove" -> a Player under the crosshair within shove_range
# Item (synced, server authority): flight_origin: Vector3, flight_velocity: Vector3, flight_serial: int (0 = not flying)
func is_flying() -> bool
# ItemManager
func request_throw() -> void                                                        # local: throw what I hold
func server_throw_item(item: Item, origin: Vector3, velocity: Vector3, thrower: int) -> bool
```
Flight: the server sets the three synced values once; every peer integrates the arc locally (gravity 9.8) from
`flight_origin` at `flight_velocity`; the server steps the same arc in `_physics_process`, raycasts each step on
LAYER_WORLD | LAYER_INTERACTABLE, and ends the flight by placing the item (`server_drop_item` rules: free spot, never
inside geometry) and clearing `flight_serial`. A worker whose chest is within `throw_hit_radius` of the arc is hit:
`server_shove(target, dir, true)` with `hit_stun_sec`, their held item is released, STAT_HITS for the thrower,
`Sfx "bonk"`. A product that ends its flight inside the TurnInStation's collider is sold as if deposited by the
thrower (`TurnInStation.server_sell_item(product, seller_peer)`). Players collide with players
(`collision_mask` world | player); footsteps: `Sfx.play(&"step", feet)` per stride on remote players, 2D and quiet
on the local one. A stunned player ignores movement input; the shove itself is `@rpc("any_peer", "call_remote",
"reliable")` on the Player with a server-sender check (players have owner authority).

## Sounds added by the lead (placeholder recipes; the audio agent refines them)
`step`, `throw`, `bonk`, `shove`, `ping`, `chat`, `alarm` (event start), `power_down`, `power_up`, `keys` (the Boss
walking; loops), `write_up`, `door_slam`, `confiscate`, `hum` (room ambience; loops), `rat`. Delivered by the audio
agent: `play(sound, position := Vector3.INF, volume_offset_db := 0.0)`, `play_loop(name, target) -> int` (INF = 2D, Vector3 =
fixed, Node3D = follows), `stop_loop(handle, fade_sec := 0.15)`, `stop_all_loops()`, `is_loop_playing(handle)`,
`set_loop_volume(handle, db)`, `static measure(stream) -> {peak, rms, dc, seconds, samples, clipped}`.

## M10 as delivered (integration notes, lead)
Additions and deviations reported by the agents and merged as is; the stub surfaces above still hold.
- **Net (lead):** every ENet link gets `throttle_configure(5000, 2, 0)` on both ends (`Net._disable_packet_throttle`):
  the throttle dropped 20-80 % of unreliable voice frames under jitter.
- **Voice:** `settings_path`, `static get_route(listener_in_backroom, speaker_in_backroom)`, `static encode_mulaw /
  decode_mulaw`, `load_settings() / save_settings()`, `get_stats()`, `get_output_node(peer)`, `debug_inject_frame(peer,
  frame, seq := -1)`, `debug_send_frame(frame)`; `--no-mic` disables capture. Speaking marks are arrival-based (a
  floor worker still sees a muted back-room worker's mark). Suites: voice_test (+43), voice_mp (+44).
- **Physics:** `Player.server_shove(target, direction, from_behind, stun_sec := -1.0, hit := false)` (the from-behind
  item release lives inside it), static `Player.server_stagger(target, direction, from_behind, by_peer, stun_sec :=
  -1.0, hit := false)`, `get_flat_forward()`, `get_chest_position()`, signal `footstep(position)`; the stagger fx RPC
  `_rpc_stagger_fx` is RELIABLE (a lost packet left a remote body stepping while stunned); `_rpc_request_shove`,
  `_rpc_staggered(impulse, stun_sec, by_peer, hit)`. `Item.flight_changed(flying)`, `get_flight_point(t)`,
  `get_flight_time()`, `thrower_id` (server only), `REASON_IN_THE_AIR`; `ItemManager.compute_throw_origin /
  compute_throw_velocity`, `_rpc_request_throw`; `TurnInStation.get_collider_aabb()`, `accepts_flight_point()`;
  `Interactor.shove_target`, `shove_target_changed`, `try_throw()`, `try_shove()`. `_can_stand_up` ignores players.
  Suites: physics (+61), physics_mp (+62).
- **Events:** signal `worker_spotted(peer_id, reason)` (cosmetic); inspection params carry `speed`; `tick(delta)`,
  `pick_kind(previous)`, `get_next_event_in()`, `get_event_params()`, `server_sight_check()`, `server_set_power(on)`.
  ShopkeeperNPC: `walk_route(points, speed := 1.6, start_offset_sec := 0.0)`, `return_home()`, `is_walking()`,
  `get_eye_position()`, `get_facing()`, `get_walk_progress()`. Room: `STATION_NAMES` has 10 entries (FuseBox),
  `WALL_STATION_NAMES`, `is_wall_station()`, `get_inspection_route()`, `get_backroom_spot() / get_backroom_transform(slot)`,
  `get_backroom_door*()`, `set_backroom_door_open(open)`, `set_power(on)` (also dims the ambient to 25 %),
  `is_power_on()`; the room runs the `hum` ambience loop while the power is on (lead). FuseBox: hold progress is local
  only (not synced); `is_tripped()`, `get_hold_progress()`, `is_holding()`, `request_reset()`. The booth door's
  collider is always solid. Suites: events (+42, `--events --round-sec=900`), events_mp (+47).
- **UI / Comms / Story:** Comms `CHAT_MAX_RAW_CHARS`, `pings_sent`, `lines_sent`, `reset_limits()`, RPCs `_rpc_ping` /
  `_rpc_chat`; new classes `ChatBox` (lock `&"chat"`), `BackRoomOverlay`, `PingMarker`, `ShiftReport`; HUD
  `%QuotaColumn` wraps `%QuotaPanel` + `%EventPanel`, helpers `refresh_marks`, `get_event_text`, `ping_here`...;
  Story keys `inspection_start/end`, `skimming`, `loitering`, `write_up_other`, `backroom`, `backroom_release`,
  `confiscated` (not auto-triggered), `power_cut`, `power_back`, `audit`, `rat`, `verdict_least/noticed/worst`,
  `get_report_verdicts()`, static `get_report_peers() / get_report_score()`. Suites: ui_m10 (+45), ui_m10_mp (+46).
- **Models:** `fuse_box.glb` (instanced as the station's `Visual`, lever tripped = +130 degrees about X),
  `clipboard.glb` (the Boss's `Clipboard/Visual`, laid flat by a -90 degree X rotation), `rat.glb` (rat.tscn `Visual`,
  `Visual/Tail` swishes), `backroom_door.glb` (`Decor/BackRoomDoor/Model`, rotated -90 degrees about Y so its hinge
  edge sits on the placeholder hinge; `Model/Door` swings +80 degrees; `Backing` hidden). Built on this PC with
  Blender 5.2 through `blender.exe --background --python tools/blender/build.py -- <family>`; never run a full
  unnamed build here (MODELING.md "Windows / Blender 5.2").

## Lan (lead, M11) — scripts/core/lan.gd
```gdscript
signal games_changed
const DISCOVERY_PORT := 7778; const BEACON_SEC := 1.0; const EXPIRE_SEC := 3.5
func listen() -> Error; func stop_listening() -> void; func is_listening() -> bool
func get_games() -> Array[Dictionary]      # [{"ip", "port", "name", "players", "max", "seen"}], newest first
func debug_inject_beacon(ip: String, payload) -> bool   # tests: the receive path
var last_beacon: Dictionary                # tests: what the host sent last
```
A hosting peer broadcasts `{"gwf": 1, "name", "port", "players", "max"}` every second to 255.255.255.255:7778 (and to
127.0.0.1 for local windows). The main menu listens while it is open (`%LanCaption` "Floors open nearby" /
"No floors open nearby.", `%LanList`: select fills the IP + port, activate joins). Beacons are size-, type- and
range-checked, names sanitized, the list capped at 32 entries. Suite: lan (+51).

## M11 review outcomes (merged)
- **Back room is server-enforced:** every gameplay request from a back-room worker is refused with
  `Interactable.REASON_BACKROOM` ("You're in the back room."): interactions (pick-ups, planting, watering, harvesting,
  deposits), shop purchases, the fuse-box reset, drop, throw, shove. Chat and pings stay allowed; the pause menu opens
  over the back room (`Game.get_ui_lock_sources()`); the supply window closes itself. On entry the host drops whatever
  the worker holds at their SPAWN point (`ItemManager.server_release_holder` places a back-room worker's item there), so
  the team is never down a can; a departed back-room worker's item goes there too.
- **Stagger immunity:** `Player.STAGGER_IMMUNITY_SEC` (1.0 s after a stun); `can_be_staggered()`; a hit on an immune
  worker is a dud (the item lands, no stagger, no STAT_HITS), a refused shove does not spend the cooldown.
- **Shove line of sight:** a LAYER_WORLD ray between the two chests on the server (no shoves through fences).
- Suites: review_m10 (+48), review_m10_mp (random port).
- **QA outcomes (qa_m10_4p, +52):** back-room slots are claimed by the lowest free index on the host
  (`Events._claim_backroom_slot`), never by the sorted-peer position; `Player._ready` sets `platform_floor_layers =
  LAYER_WORLD` and `platform_wall_layers = 0`, so a worker standing on another is not flung when that one teleports.

## WindowsFirewall (lead, M11) — scripts/core/windows_firewall.gd
```gdscript
signal firewall_result(result: Dictionary)   # {"status": skipped|exists|created|declined|failed, "message", "port"}
func is_windows() -> bool; func is_check_enabled() -> bool; func get_skip_reason() -> String
func get_rule_name(port) -> String           # "Grow With Friends Multiplayer UDP <port>"
func get_program_path() -> String            # OS.get_executable_path() (the exported .exe; the editor binary in dev runs)
func check_rule(port) -> Dictionary          # read-only netsh query: {"exists", "healthy", "details", "raw"}
func ensure_multiplayer_firewall_access(port := 7777, force := false) -> Dictionary   # coroutine, at most one UAC prompt
func request_again(port := 7777) -> Dictionary                                        # the menu's retry
static func parse_rule_output(text, port, program) -> Dictionary; static func classify_result_text(text) -> String
static func build_helper_script() -> String
```
Transport is ENet = UDP only: one inbound rule, `dir=in action=allow protocol=UDP localport=<port> program=<exe>
profile=any enable=yes`, created or repaired by a PowerShell helper written to `user://` that runs netsh through
`Start-Process -Verb RunAs` (the normal UAC prompt); the game itself never runs elevated, the firewall is never
disabled, no port range, no TCP. Called from the main menu's Host path only (never at launch, never when joining).
Skipped on non-Windows, headless, `--no-firewall`, and in dev runs (editor binary) unless `--firewall` (launcher
`-Firewall`). A decline or failure never blocks hosting: status line + toast + the menu's retry button; no prompt is
repeated until the player presses it. LAN discovery's inbound UDP 7778 (joining side) is not covered on purpose.
Suite: firewall (+53).

## M12 — more strains, the hostile plant, the emergency flamethrower, more disruptions (lead prep, 2026-10-01)
Four agents in worktrees `.claude/worktrees/<agent>` on `m12/<agent>`: **strains** (data + models), **hostile**,
**flame**, **disrupt**. Shared files stay lead-only: project.godot, CONTRACTS.md, PLAN.md, tools/test_all.sh, const.gd,
balance_config.gd, seed_def.gd, world.tscn, sfx.gd (names + placeholder recipes are in; an agent may ADD a recipe branch
for its own sounds inside a `# --- M12 <agent> ---` block). Files two agents touch (grow_plot.gd, story.gd, room.tscn,
player.gd) are edited only inside clearly delimited `# --- M12 <agent> ---` regions or the stubs named below; the lead
merges. Test ports: strains +54, hostile +55 / hostile_mp +56, flame +57 / flame_mp +58, disrupt +59 / disrupt_mp +60.

### Prep already in place (lead)
- `Const`: `STAT_BITTEN`, `STAT_SCORCHED`, `STAT_BURNS`; `WRITE_UP_ARSON`, `WRITE_UP_MISUSE`, `WRITE_UP_ABSENT`.
  Agents add their own: `ITEM_FLAMETHROWER = &"flamethrower"` (flame), `GROUP_HOSTILES = &"hostiles"` (hostile) — tell
  the lead; until merged keep them as local consts in your files.
- `BalanceConfig` groups "Hostile plant (M12)", "Emergency cabinet (M12)", "Disruptions (M12)": `mutation_warning_sec`
  6, `hostile_speed` 2.2, `hostile_sense_range` 5, `hostile_bite_stun_sec` 1, `hostile_bite_cooldown_sec` 1.5,
  `hostile_eat_per_sec` 0.08, `hostile_burn_sec` 3, `hostile_max` 2; `cabinet_deposit` 40, `cabinet_restock_sec` 90,
  `flamethrower_fuel_sec` 8, `flamethrower_range` 3.5, `flamethrower_half_angle_deg` 25, `scorch_sec` 0.5;
  `headcount_sec` 15, `headcount_radius` 2.5, `water_off_sec` 30, `shortage_sec` 45.
- `SeedDef.mutation_chance` (0..1, default 0).
- Input: `use_item` = left mouse button (hold). `interact` is E only now (LMB used to double for it).
- Autoload `Hostiles` (scripts/core/hostiles.gd) after Events: a stub with the agreed API (below).
- `World/Hostiles` (Node3D) container in world.tscn; `GrowPlot.server_scorch(by_peer) -> bool` stub.
- Sfx names (default blip recipes until refined): `hostile_rise`, `hostile_bite`, `hostile_eat` (loop), `hostile_die`,
  `flame` (loop), `ignite`, `glass_break`, `scorch`, `headcount`, `water_off`, `shortage`.

### Strains (strains agent) — data/balance.tres, Story blurbs, models
Three new `SeedDef`s with `mutation_chance`: `nightshift` "Night Shift" (cost 70, grow 1.2, value 170, mutation 0.35,
dark violet), `creeper` "Creeper" (cost 30, grow 0.8, value 70, mutation 0.12, teal), `brick` "Floor Brick" (cost 120,
grow 2.0, yield 3, value 110, mutation 0.2, rust). Existing: budget 0, purple 0.05, golden 0.1. Descriptions in the
house tone (STYLE.md: no cheer, no "!"). The shop lists `Config.balance.seeds` dynamically; check the counter layout and
the HUD still fit six strains. Models (MODELING.md recipe, Blender 5.2 on this PC): `hostile_plant.glb` (a gnarled
uprooted bud on root legs, a mouth; origin at the feet, faces -Z, about 1.1 m tall; `Visual` content is swapped in by the
lead), `emergency_cabinet.glb` (red wall box 0.45 x 0.6 x 0.2 m with a glass pane and a plate; origin at the back
centre, mounts on a wall), `flamethrower.glb` (tank + hose + nozzle, about 0.6 m long, origin at the grip, nozzle -Z).
Test suite `strains` (+54): ids unique, every strain plantable / harvestable / sellable, mutation in [0,1], models load.

### Hostile plant (hostile agent) — scripts/core/hostiles.gd, scripts/npcs/hostile_plant.gd + scenes/npcs/hostile_plant.tscn, grow_plot.gd (mutation region), story.gd (its region)
Mutation (GrowPlot, server): when a plant becomes READY roll `seed.mutation_chance` once; if it turns, synced
`turning: bool` + `turn_left: float` count down `mutation_warning_sec` (the plant visibly twitches on every peer, HUD
status "Moving"), then `server_reset()` (crop lost) and `Hostiles.server_spawn(strain_id, plot.global_position)`.
Hostiles (autoload, API in the stub): `server_spawn(strain_id, position) -> id`, `server_despawn_all()`,
`server_apply_fire(id, seconds, by_peer)`, `get_hostiles()`, `get_hostile(id)`, `count()`, `is_any_alive()`,
`nearest_to(position)`; signals `hostile_spawned(id, strain_id, position)`, `hostile_bit(id, peer_id)`,
`hostile_ate(id, plot_index)`, `hostile_died(id, by_peer)`. Nodes: class `HostilePlant` (Node3D with a StaticBody3D
collider on Const.LAYER_WORLD so workers cannot walk through it, group `hostiles` + Const.GROUP_NPCS), plain children of
`World/Hostiles` on every peer, created by a reliable spawn RPC and removed by a reliable despawn RPC; the host sends
position / yaw / state at about 10 Hz (unreliable), clients interpolate; `Net.peer_registered` replays the list to a
late joiner (like Events). Behaviour (host): ROOT 2 s at the plot (`hostile_rise`), then ROAM to the nearest growing
plot and EAT it (`hostile_eat_per_sec` off `stage_progress`; at 0 the crop is lost: `plot.server_reset()`,
`hostile_ate`); CHASE the nearest worker within `hostile_sense_range` who is not in the back room; BITE within 1.0 m:
`player.server_shove(player, away, false, Config.balance.hostile_bite_stun_sec, true)` + `items.server_release_holder
(peer)` + `STAT_BITTEN`, then `hostile_bite_cooldown_sec`; after two bites it goes back to eating. BURNING: total flame
seconds >= `hostile_burn_sec` -> DEAD (`hostile_die`, ash puff, node removed after 1.5 s, `STAT_BURNS` for the shooter).
`GameState.game_reset` / round end -> `server_despawn_all()`. Tint = the strain colour. Story lines in its region
("Something came out of GrowPlot 3.", "It bit Dale.", "It is eating GrowPlot 2.", "It stopped moving."). Suites
`hostile` (+55, solo: mutation roll with a forced chance, spawn, eat, bite, fire, despawn, late-join replay by direct
RPC) and `hostile_mp` (+56: a client sees the node, the bite stun and the death).

### Emergency cabinet + flamethrower (flame agent) — scripts/stations/emergency_cabinet.gd + scene, scripts/items/flamethrower.gd + scenes/items/flamethrower.tscn, item_manager.gd (scene map), player.gd (`server_ignite` region + use_item), grow_plot.gd (`server_scorch` + scorched soil), story.gd (its region)
Cabinet: `Interactable` named "EmergencyCabinet" under Room/Stations on a wall near the fuse box (one node added to
room.tscn; placeholder box with a glass pane under `Visual`). Synced `broken: bool`, `restock_left: float`. Prompt
"Break glass" / "Restocking (42 s)" / "Cash short" / "Hands full". `_server_interact`: `GameState.server_try_spend(
cabinet_deposit, peer, "Emergency equipment deposit")` must succeed; then `items.server_spawn_item(&"flamethrower",
{"fuel": flamethrower_fuel_sec}, pos, peer)` straight into the hands, `broken = true`, restock countdown (host), cosmetic
`glass_break` RPC; if `not Hostiles.is_any_alive()`: `GameState.server_write_up(peer, Const.WRITE_UP_MISUSE)`.
Flamethrower (`Item`, type `flamethrower`, props `fuel: float`, `firing: bool`): the holder holds `use_item` ->
`request_fire(on)` -> `@rpc("any_peer", "call_local", "reliable") _rpc_request_fire(on)` validated on the server
(sender is the holder, fuel > 0, not in the back room, shift PLAYING) -> `firing` synced through props -> flame VFX
(a cone of GPUParticles3D or stretched toon meshes from the nozzle) + `flame` loop on every peer. Server, every physics
tick while firing: fuel -= delta (0 -> firing stops, label "Flamethrower (empty)"); cone test from the nozzle along the
holder's `get_look_direction()` (reach `flamethrower_range`, half-angle `flamethrower_half_angle_deg`): hostiles ->
`Hostiles.server_apply_fire(id, delta, shooter)`; GrowPlots with a plant -> after `scorch_sec` of exposure
`plot.server_scorch(shooter)` (crop lost, soil black for 20 s, `scorch`, `STAT_SCORCHED`; `WRITE_UP_ARSON` when no
hostile is within 4 m of that plot); workers -> `player.server_ignite(shooter)` once per victim per 10 s (stagger away
from the shooter with `hit_stun_sec`, held item released, 2 s flame cosmetic `ignite`, `WRITE_UP_ARSON` for the shooter).
An empty flamethrower can still be carried and thrown. Suites `flame` (+57) and `flame_mp` (+58: a client breaks the
glass, fires, the server drains fuel and scorches; the deposit and write-ups land). Burning a real hostile is tested
after the merge (the stub's `server_apply_fire` is a no-op): assert the call count through a test double if you want it.

### Disruptions (disrupt agent) — events.gd, story.gd (its region), room.tscn (one Marker3D), well.gd, shop_counter.gd
Three new event kinds with `Events.KINDS` / `WEIGHTS` rebalanced (inspection 30, power_cut 20, audit 10, rat 10,
headcount 15, water_off 10, shortage 5): **headcount** (`headcount_sec`): the Boss walks to `Room.get_headcount_spot()`
(a `HeadcountSpot` Marker3D added to room.tscn by the agent, in front of the counter); when the timer ends every worker
further than `headcount_radius` from the spot who is not in the back room gets `WRITE_UP_ABSENT`; params `{seconds,
spot}`. **water_off** (`water_off_sec`): `Well.server_set_pressure(false)` (synced; prompt "No pressure", refills
refused), back on at the end; params `{seconds}`. **shortage** (`shortage_sec`): `ShopCounter.server_set_shortage(
strain_id)` (synced; that strain's prompt "Out of stock", purchases refused) for the most-planted strain of the shift
(`GameState.stats`), cleared at the end; params `{seconds, strain}`. Late joiners get the running event through the
existing replay; HUD banner copy and Story lines in the house tone ("Head count. The line. Now.", "Water main is off.",
"No more Night Shift this shift."). Suites `disrupt` (+59) and `disrupt_mp` (+60: a late joiner sees the shortage and
the well state).

### M12 as delivered (integration notes, lead, 2026-10-01)
All four branches merged (strains e8ecc25, hostile 202b039, flame c53e388, disrupt 30660bf); suites `strains` (+54),
`hostile` (+55), `hostile_mp` (+56), `flame` (+57), `flame_mp` (+58), `disrupt` (+59), `disrupt_mp` (+60) registered.
Lead additions after the merges: `Const.GROUP_HOSTILES`, `Const.ITEM_FLAMETHROWER` (the agents' local consts removed),
the three GLBs hooked into their scenes (hostile_plant.tscn: the GLB is `Visual`, `Visual/Jaw` opens on a bite;
emergency_cabinet.tscn: the GLB is `Visual` with a 0.55-scale flamethrower standing under `Visual/Stock`;
flamethrower.tscn: the GLB under `Visual/Model`, `Visual` lifted 0.08 m so a dropped one rests on the floor, `Nozzle` at
the model tip z -0.34). The flamethrower's cone reads each hostile's `id` (the hostile branch named it `id`, not
`hostile_id`).
Deviations from the brief worth knowing:
- **Hostiles** adds `hostile_eating(id, plot_index)`, `tick(delta)` (public host step, sub-stepped at 30 Hz),
  `get_replay_entries()` / `_rpc_replay(entries)` (idempotent late-join payload). Poses travel unreliably at 10 Hz,
  state changes reliably. The mutation watch lives in Hostiles.tick: it polls GrowPlots and calls
  `GrowPlot.server_roll_mutation()` once per READY and `server_tick_mutation(delta)` while turning. After two bites
  the plant is calm for 5 s; it only bites a worker whose stagger immunity has lapsed; burning halves its speed; the
  dead node stays 1.5 s. Hostiles never bite back-room workers and never walk through walls (a 0.4 m probe, no
  pathfinding).
- **GrowPlot**: `turning` / `turn_left` synced (replication entries 4 and 5), `is_turning()`, status and prompt say
  "Moving"; harvesting a turning plant is allowed. `server_scorch` steps a READY crop through FLOWERING for one frame
  so a burnt crop does not play the harvest snip; ash is a runtime `Visual/Ash` overlay for 20 s; `scorched(by_peer)`
  signal, `is_scorched()`, `get_scorch_label()`.
- **EmergencyCabinet**: `restock_left` is synced in whole seconds (one packet a second); `server_break(player)`,
  `server_restock()`, `glass_broken(by_peer)` / `restocked` signals; a game reset restocks at once and despawns
  every flamethrower. **Flamethrower**: `server_request_fire(sender, on) -> bool` is the public validation; the item
  itself polls `use_item` while the local player holds it (player.gd untouched apart from the `server_ignite` region);
  the cone origin is the holder's camera (synced yaw / pitch), a LAYER_WORLD line check must be clear; fuel is written
  in 0.1 s steps. **Player.server_ignite** skips back-room workers; `_rpc_ignited` is any_peer with a server-sender
  check (players have owner authority).
- **Disruptions**: headcount params carry `speed` too; `Events.server_headcount() -> Array[int]`,
  `pick_shortage_strain()`, `get_planted_counts()` (the host counts plantings per strain by watching the plots; stats
  have no per-strain key). `ShopkeeperNPC.walk_to(points, speed, start_offset_sec, face)` / `is_at_post()` /
  `get_walk_length()` were added so the Boss can stand at the line; `Room.get_headcount_spot()` /
  `get_headcount_route()`; `Well.server_set_pressure(on)` + `pressure_changed`; `ShopCounter.server_set_shortage(id)`
  + `shortage_changed`, the OUT OF STOCK card in the supply window; HUD banner titles HEAD COUNT / WATER OFF /
  SHORTAGE. A force-ended head count writes nobody up. The keys loop and the booth door now follow the Boss on any walk.
- **Story**: each agent's lines live in a `# --- M12 <agent> ---` region (hostile: `HOSTILE_LINES`; flame:
  `FLAME_LINES`; disrupt: `DISRUPT_LINES` + the "absent" write-up line); `_ready` calls `_connect_hostile_signals()`
  and `_disrupt_setup()`. **Sfx**: recipe blocks for the hostile and disrupt sounds; `flame`, `ignite`, `glass_break`,
  `scorch` still use the default blip (audio pass pending).
Follow-ups the same day: the hostile plant is 2x (the GLB sits scaled under `Visual/Model`; collider, shadow, bite
reach 1.7 m, stop 1.3 m, eating distance 1.3 m, wall probe and the flame aim height 1 m follow); the flame suite burns a
live hostile and checks that breaking the glass with one alive is not misuse; `flame`, `ignite`, `glass_break` and
`scorch` have real recipes. A visual pass on the real renderer (tools/tests/m12_shots_body.gd, a windowed
lead tool with a watchdog) checked the first-person flamethrower pose (fine as shipped), made the flame a full plume
(150 larger particles) and added on-screen notices (Game.toast, kind error, every peer) for "GrowPlot N is moving." and
"Something came out of GrowPlot N.", because Story lines are only a label over the Boss. A chain-link fence blocks the
flame (the cone needs a clear LAYER_WORLD line): someone has to go into the pen. Known gaps:
`Room.STATION_NAMES` does not list "EmergencyCabinet" (resolved by path).

## M13 — hardening M12 (review + lead, merged 2026-10-02)
Review branch `m13/review` (16 fixes, suites `review_m12` +63 and `review_m12_mp` +64) plus lead follow-ups. The
four-process suite `qa_m12_4p` (+65) lands with `m13/qa`.
- **Flamethrower:** a stunned holder cannot start the flame and a stagger puts it out; at most
  `Flamethrower.MAX_STARTS_PER_FRAME` (2) starts per physics frame (stops are always granted); one cone pass stops once
  its write-ups send the shooter to the back room. The cone needs a clear LAYER_WORLD line, so a chain-link fence blocks
  it. The flame effect is `Visual/Nozzle/Flame` (150 particles).
- **Back room:** the Boss keeps the flamethrower of a worker he sends to the back room: the host despawns it and every
  peer gets `Events._rpc_flamethrower_kept(peer_id)` (the `confiscate` sound, the toast "The Boss keeps <Name>'s
  flamethrower.", the Boss line "That's mine now."). Every other held item still goes back to the floor at the
  worker's spawn.
- **A turning tray is trouble on the floor:** breaking the glass while any tray `is_turning()` is not misuse;
  scorching a turning plant is not arson and cancels the mutation. On every peer "GrowPlot N is moving." and
  "Something came out of GrowPlot N." are also toasts (kind `error`), because Story lines are only a label over the Boss.
- **hostile_max:** `Hostiles.has_room()` (live plants < `hostile_max`; a burnt body does not count). A tray that turns
  with no room keeps twitching, stays harvestable, and uproots when a slot frees.
- **HostilePlant:** 2x size (`Visual/Model` scaled; collider radius 0.64, `BITE_RANGE` 1.7, `CHASE_STOP` 1.3,
  `EAT_DISTANCE` 1.3). A bite needs a clear LAYER_WORLD line (no bites through a fence). A chase with no movement for
  `STUCK_SEC` (2 s) is dropped and the plant is calm for `CALM_SEC`. A tray it cannot reach sends it round by
  `Decor/FenceGate`, then to a random spot. It never steps within `BODY_CLEARANCE` (1.1 m) of a worker on the floor.
  After its two bites it retreats `RETREAT_DISTANCE` from that worker. A tray is eaten for at least `MIN_EAT_SEC` (4 s)
  before the crop is lost; `stage_progress` is clamped at 0 meanwhile.
- **Events:** `pick_shortage_strain()` ties go to the dearest strain the team can afford (the cheapest when none);
  `server_headcount()` only counts workers who were on the floor when the count began (`_headcount_roster`).
- **Room / ItemManager:** `Room.is_in_booth(point)`; a thrown item never comes to rest inside the Boss's booth.
- **HUD / copy:** arson / misuse / absent write-up toasts name the reason ("Bob written up: arson."); cabinet denials
  are "Cash short." / "Hands full."; the well's is "No pressure."; the supply window's footer says "More below: wheel
  or arrows" while part of the seed page is below the fold.
- **Shift report:** `Story.get_report_verdicts()` appends, when the stat is above zero, "<Name> dealt with it. Noted.
  Not thanked." (most `STAT_BURNS`), "<Name> burnt stock. The fine came out of cash on hand." (most `STAT_SCORCHED`)
  and "<Name> got bitten. No claim was filed." (most `STAT_BITTEN`).
- **Numbers:** Night Shift deposits for 210 (at 170 it never beat Golden Kush even played perfectly).
- **Tools:** `tools/tests/m12_shots_body.gd` (windowed screenshot pass with a watchdog; never captures the mouse);
  `tools/dev/splice.pl <file> <old block> <new block>` (exact block replace, `<T>` = tab, keeps CRLF).
- **QA (`m13/qa`, merged):** `qa_m12_4p` (+65), a host and three client processes, 652 checks: mutation under load,
  the chase, fire, events on top, churn; every scenario ends with `canonical_state()` and the M12 state equal on every
  peer. Two fixes came with it: a stunned worker is not loitering (the loiter clock restarts while `is_stunned()`), and
  a holder who was just sent to the back room sends no stop request for the flamethrower the host already despawned.
  Decisions it pinned: a bite is the punishment (no loitering write-up for the stun); the plant blocks the Boss's view
  like a crate; the Boss walks through a plant on his route; during a power cut the plant keeps eating.
Not done: an uprooting plant still plays the harvest snip (READY to EMPTY is the harvest transition); a late joiner does
not see a plant that is already dead for its last 1.5 s. Also: empty flamethrowers pile up until RETRY; the supply card shows the margin but not the mutation chance; no
pathfinding (a worker outside the fence is unreachable: the plant drops the chase and eats instead).

## M14 — the lobby and the van, a bigger floor, mayhem, strain traits (lead prep, 2026-10-02)
Design: FRIENDSLOP.md section 8. Four agents in worktrees `.claude/worktrees/<agent>` on `m14/<agent>`: **lobby**,
**level**, **mayhem**, **loop**; the lead does the footsteps. Lead-only files: project.godot, CONTRACTS.md, PLAN.md,
README.md, tools/test_all.sh, const.gd, balance_config.gd, config.gd, sfx.gd (an agent may ADD a recipe branch inside
a `# --- M14 <agent> ---` block). Files two agents touch are edited only inside `# --- M14 <agent> ---` regions.
Test ports: lobby +66 / lobby_mp +67, level +68, mayhem +69 / mayhem_mp +70, loop +75 / loop_mp +76.

### Prep already in place (lead)
- `Config.lobby_enabled`: true in a windowed run, false under `--headless`; `--lobby` forces it on, `--no-lobby` off.
  With it off NOTHING changes (workers spawn on the floor, Enter starts the shift): the 59 existing suites run that way.
- `Const`: `STAT_SHOT`, `STAT_SLIPS`, `STAT_CURED`; `GROUP_DRYING_RACKS`.
- `BalanceConfig` groups "Lobby (M14)" (`van_countdown_sec` 2, `transition_fade_sec` 0.5), "Mayhem (M14)" (`leak_sec`
  45, `leak_patch_sec` 2.5, `leak_empty_sec` 60, `puddle_sec` 30, `slip_stun_sec` 0.8, `driveby_warning_sec` 2.5,
  `driveby_sec` 6, `driveby_tray_loss` 0.35, `driveby_fine` 30), "Loop (M14)" (`cure_sec` 20, `cure_bonus` 0.4,
  `heavy_speed_factor` 0.7, `counted_fine` 25).
- `SeedDef` traits (defaults = no trait): `thirst_multiplier` 1.0, `dark_growth_multiplier` 0.0, `spread_chance` 0.0,
  `heavy` false, `counted` false, `trait_text` "".
- `Room` stubs the level agent replaces: `get_arrival_transform(index) -> Transform3D` (stub: the spawn transform),
  `get_gunfire_lanes() -> Array` of `{"from": Vector3, "to": Vector3}` in global space (stub: three lanes across the
  main room from the south wall), `get_play_areas() -> Array[AABB]` (stub: `[get_bounds()]`).
- Sfx names with default blips: `step2`, `step3`, `land`, `van_door`, `leak` (loop), `slip`, `tires`, `gunshot`,
  `ricochet`, `glass_shot`, `rack_hang`, `cured`.

### Lobby + van (lobby agent)
Files: scenes/world/lobby.tscn + scripts/world/lobby.gd (class `Lobby`), scenes/world/van.tscn + scripts/world/van.gd
(class `Van`), one `Lobby` node in world.tscn at (0, 0, 80), game_state.gd / game.gd / world.gd / hud.gd in
`# --- M14 lobby ---` regions, a `van.glb` model (MODELING.md recipe; a beat-up panel van, rear doors open, cargo floor
about 1.8 x 2.8 m, a bumper step so walking in works), suites `lobby` (+66) and `lobby_mp` (+67), both with `--lobby`.
- The alley: night, one street lamp, brick walls on every side (nobody leaves), bins, the van. `Lobby.get_spawn_transform
  (index)`, `Lobby.get_van() -> Van`, `Lobby.get_bounds() -> AABB`.
- With `Config.lobby_enabled`, `World.server_spawn_player` puts a worker in the alley while the phase is MENU or
  WAITING; a worker who joins during a shift lands at `Room.get_arrival_transform(spawn_index)`.
- `Van` (host): every 0.25 s counts the registered workers whose body is inside the cargo volume. When ALL of them are
  in (at least one), a countdown of `van_countdown_sec` runs (synced: `Van.countdown_left`, -1 when idle; it resets
  when anyone steps out); at zero `GameState.server_begin_shift_from_lobby()`.
- `GameState.server_begin_shift_from_lobby()` (host): `_rpc_transition(&"to_floor", seconds)` on every peer (signal
  `transition_started(kind: StringName, seconds: float)`; the HUD fades to black over `transition_fade_sec`, holds, fades
  back in); after the fade-out the host teleports every worker to `Room.get_arrival_transform(spawn_index)`
  (`Player.server_teleport`) and calls `server_start_round()`. The drive is never shown. `van_door` plays at the start.
- The host's Enter (`request_start_round`) in the alley does the same thing without waiting for stragglers.
- After a shift: `request_next_round` / `request_retry` with the lobby on bring everyone back to the alley through
  `_rpc_transition(&"to_lobby", seconds)` and leave the game in WAITING with the money, the round number and the
  upgrades as the old path would have them at the start of the next shift; the next shift starts from the van.
- HUD in the alley: "Everyone in the van. 2 / 4 in." and "Doors closing 2" during the countdown.
- A worker who leaves the session while the countdown runs is no longer counted; the countdown continues if the
  rest are in.

### Bigger floor (level agent)
Files: scenes/world/room.tscn, scenes/world/room.gd, new scenes under scenes/world/props/, item_manager.gd (bounds),
hostile_plant.gd (crossing rooms, in a `# --- M14 level ---` region), tests/world_test.gd where it pins geometry that
changed on purpose, suite `level` (+68).
- Every existing station, spawn point, marker, the pen and the Boss's booth stay where they are. `INTERIOR_SIZE` and
  `get_bounds()` keep describing the main room.
- **Grow hall**: east of the main room (x 10 to 22, the main room's z range), through two doorways cut in the east wall.
  `Stations/GrowPlot7` to `GrowPlot10` (same scene and group as the six), room for two drying racks.
- **Loading dock**: south of the main room (about x -9 to 3, z 7.5 to 15.5) through a wide opening. `Arrivals/Arrival0`
  to `Arrival3` (`get_arrival_transform`), crates as cover (LAYER_WORLD), a roll-up door and windows to the outside,
  a parked van as decor (a placeholder box until `van.glb` exists).
- `get_play_areas() -> Array[AABB]` (main, hall, dock), `contains_point(point) -> bool`, `get_play_bounds() -> AABB`
  (the union). Everything that clamps to the room (thrown item landing, out-of-bounds recovery, the plant's wander) uses
  the play areas, so an item thrown into the hall stays there.
- `get_gunfire_lanes()`: at least four lanes from outside the dock door and the west windows across the dock and the
  main room, each blocked by the crates where they stand.
- The hostile plant can walk between the pen, the hall and the dock: `Room.get_route(from, to) -> PackedVector3Array`
  (a small hand-made waypoint graph through the doorways) and HostilePlant follows it when the straight line is blocked.
- Lighting, decor and collision in the style of the existing room (STYLE.md); no new stations of its own.

### Mayhem (mayhem agent)
Files: scripts/core/events.gd, scripts/stations/well.gd, story.gd / hud.gd (its regions), sfx.gd (its block), suites
`mayhem` (+69) and `mayhem_mp` (+70).
- `Events.EVENT_LEAK` (`leak_sec`): `Well.server_set_leaking(true)` (synced `leaking`; a jet and a spreading puddle on
  every peer, the `leak` loop). Holding E on the tank for `leak_patch_sec` (the fuse box's hold pattern) patches it:
  event over, nothing lost. Not patched: `Well.server_set_pressure(false)` for `leak_empty_sec`, then back. The puddle
  (radius about 2.2 m, `puddle_sec` after the event) makes a worker who moves faster than walking speed slip: a stagger
  of `slip_stun_sec`, the held item released, `STAT_SLIPS`. Params `{seconds}`.
- `Events.EVENT_DRIVEBY` (`driveby_warning_sec` + `driveby_sec`): `tires`, banner "DRIVE-BY" with the hint "Get
  down."; then a shot every 0.15 s along a random `Room.get_gunfire_lanes()` lane, cut at the first LAYER_WORLD hit. A
  worker within 0.45 m of the lane who is neither crouching nor in the back room is knocked down (stagger of twice
  `hit_stun_sec`, item released, `STAT_SHOT`); a growing tray within 0.6 m loses `driveby_tray_loss` of stage progress;
  every shot is a cosmetic RPC (tracer, `gunshot`, `ricochet` at the hit). Afterwards the floor is fined `driveby_fine`
  (as far as cash on hand goes) and the Boss says so. Nobody dies. Params `{seconds, warning}`.
- Weights: inspection 26, power_cut 16, audit 8, rat 8, headcount 12, water_off 8, shortage 6, leak 8, driveby 8.
  Late-join replay through the existing path; `--first-event=leak|driveby` works.

### Loop (loop agent)
Files: data/balance.tres, tools/gen_balance.gd, seed_def.gd is prepared, grow_plot.gd / player.gd / story.gd (its
regions), scripts/stations/drying_rack.gd + scenes/stations/drying_rack.tscn, turn_in_station.gd, the product item
script, scenes/ui/shop_card.gd (trait line), two rack nodes under Room/Stations in the main room's north-west corner
at (-7.5, 0, -6.6) and (-5.0, 0, -6.6) (the lead moves them into the hall after the level merge), suites `loop` (+75)
and `loop_mp` (+76).
- Traits: Purple Haze `thirst_multiplier` 1.6 (water drains that much faster); Golden Kush `counted` (a Golden plant
  lost to the hostile plant, to fire or to gunfire costs the floor `counted_fine`, announced); Night Shift
  `dark_growth_multiplier` 2.0 (grows at that speed while the power is off, when everything else is frozen); Creeper
  `spread_chance` 0.33 (a harvest leaves a watered seedling of the same strain in the tray); Floor Brick `heavy` (the
  carrier moves at `heavy_speed_factor` of walking speed and cannot sprint; enforced where movement is already
  validated, cosmetic on the owner). `trait_text` on every card ("Thirsty.", "Counted.", "Grows in the dark.",
  "Spreads.", "Heavy.").
- `DryingRack` (Interactable, group `Const.GROUP_DRYING_RACKS`): three hooks. E with a product bundle hangs it on a
  free hook (the item rests at the hook, props `rack: true`, `dry_left`); the rack counts `cure_sec` down on the host
  and sets `cured: true` (`cured` sound, darker tint, label "Cured"); a bundle taken off early is not cured. The chute
  pays `1 + cure_bonus` for a cured bundle (`STAT_CURED` for the seller). A hanging bundle is an ordinary item: it can
  be taken, thrown at, eaten is not a thing, burnt by the flamethrower is not a thing (items do not burn), stolen is.

### M14 as delivered (integration notes, lead, 2026-10-02)
Branches merged: lobby d449f70, mayhem bff3d6f, loop 7bc9588 (its events.gd loiter commit dropped in favour of mayhem's
`LOITER_EPSILON`), level 3ac2cdd. Suites: `lobby` (+66), `lobby_mp` (+67), `level` (+68), `mayhem` (+69), `mayhem_mp`
(+70), `loop` (+75), `loop_mp` (+76). Lead integration: the two racks stand in the grow hall at (14, 0, -6.6) and
(16.5, 0, -6.6); `Dock/DockVan/Visual/Model` is `van.glb` (offset z 1.66 so it fills the collider); `qa_base.
canonical_state()` covers `Room.GROW_PLOT_COUNT` trays; footsteps and the drive-by effect below.
- **Flow.** `GameState.transition_started(kind, seconds)` with `TRANSITION_TO_FLOOR` / `TRANSITION_TO_LOBBY`
  (`seconds` is ONE fade; a ride is fade + `TRANSITION_HOLD_SEC` 0.3 + fade), `server_begin_shift_from_lobby()`,
  `server_return_to_lobby(reset)`, `is_transitioning()`. `World.lobby`, `World.get_lobby_transform(i)`,
  `get_arrival_transform(i)`, `server_move_players_to_floor()` / `_to_lobby()`. `Lobby` (10 x 15 m alley at (0, 0, 80);
  `get_spawn_transform`, `get_van`, `get_bounds`, `contains_point`, `is_in_use`). `Van` (synced `occupants`, `total`,
  `countdown_left`; `is_everyone_in`, `get_seat_transform`, `get_entry_point`, `get_cargo_aabb`; an invisible ramp
  over the bumper step). Clients read "lobby on" from the van's synced `total`, not from their own
  `Config.lobby_enabled`. START OVER resets first, then moves to the alley. Held items stay on the floor.
  Windowed runs start in the alley: capture and playtest tools that stage the floor pass `--no-lobby` or set
  `Config.lobby_enabled = false` before hosting. `-s` scripts must not name `Lobby` / `Van` as types.
- **Floor.** Main room unchanged (x -10..10, z -7.5..7.5). Grow hall x 10..22 through `pen_door` (from inside the pen,
  centre (10.3, 0, -1.25)) and `corridor_door` (centre (10.3, 0, 6.25)); trays `GrowPlot7`..`10` at (16 / 18.6, 0,
  -1.5 / 1.5). Loading dock x -10..5, z 7.5..15.6 through `dock_passage` (centre (-5, 0, 7.8), 4.2 m wide);
  `Arrivals/Arrival0..3`; crate stacks as cover; `Decor/RollerDoor` on the dock's south wall. Room API:
  `get_play_areas()`, `get_play_bounds()`, `contains_point(point, margin)`, `get_area_index(point)`,
  `get_arrival_points()` / `get_arrival_transform(i)`, `get_gunfire_lanes()` (six lanes, each starting 0.3 m inside
  the outer wall), `get_route(from, to)` (waypoints through the doorways; empty when the line is clear),
  `is_wall_between(a, b)`, `get_doorways()`, `GROW_PLOT_COUNT` 10, `STATION_NAMES` 14. A thrown item rests in any
  play area (and in the alley). The plant follows `get_route` to a tray it cannot walk straight to, does not start a
  chase through a solid wall, and wanders inside the room it stands in. The rat, the shortage count and Story's
  "came out of GrowPlot N" cover ten trays. Balance was not retuned for ten trays.
- **Mayhem.** `Events.EVENT_LEAK` / `EVENT_DRIVEBY`; signals `leak_resolved`, `tank_refilled`, `worker_slipped`,
  `worker_shot`, `tray_shot`, `driveby_billed`, `shot_fired`; `server_fire_lane(lane, first)`. `Well.leaking`,
  `server_set_leaking`, `server_patch`, `request_patch`, `is_in_puddle`, the puddle grows 0.5 to 2.2 m over 10 s.
  A slip needs 5.5 m/s over a 0.25 s window; crouched, jumping and back-room workers never slip. Lane distances are
  flat (x / z); a tray takes one round per drive-by; a planted tray stops a round; a collider named or grouped
  "glass" lets it through; a worker is knocked down about once per 2 s at most. `water_off` and `leak` are refused
  while the tank is empty. Force-ended events lose and bill nothing. Lead: tracers are 6 cm, hold 0.07 s and fade
  over 0.26 s; every round has a muzzle flash (`OmniLight3D`, 0.09 s) and leaves a dark pock for 25 s (36 at most).
- **Loop.** Traits as in the brief; the card tag shows the trait in place of "SEED PACKET". `GrowPlot.
  server_crop_lost(cause)` (`LOSS_EATEN`, `LOSS_FIRE`, `LOSS_GUNFIRE`) takes the counted fine and announces it;
  `crop_lost(cause, strain, fine)`. `spread_force` / `spread_rng` for tests. `DryingRack` (`server_hang`, `tick`,
  three hooks; nothing on the rack is synced: occupancy is derived from each bundle's own props `rack`, `dry_left`,
  `cured`); the countdown runs only while PLAYING. `TurnInStation.compute_sale_value(seed, amount, multiplier,
  cured)`. `Player.is_carrying_heavy()`, `get_move_speed()`. Balance note from the agent: curing is nearly always
  right outside the last half minute, Purple Haze is the weakest strain per unit of labour, Golden's trait is a pure
  penalty; not retuned yet.
- **Footsteps (lead).** `Player.STEP_STRIDE_WALK` 1.6 / `_SPRINT` 2.3 / `_CROUCH` 1.2 m, `STEP_SOUNDS` (`step`,
  `step2`, `step3`, never the same twice), crouch -7 dB, sprint +2 dB, `land` after a fall faster than 2.5 m/s; remote
  bodies count the same strides on their smoothed movement. `Sfx._dc_block`. `tools/tests/step_demo_body.gd` writes an
  audition WAV.
- **Events suite flake fixed.** The loiter clock is a sum of float steps and could land a hair under `loiter_sec`:
  `Events.LOITER_EPSILON` (0.001 s).
Known gaps: economy not retuned for ten trays and cured bundles; `STAT_CURED`, `STAT_SHOT`, `STAT_SLIPS` are counted
but the shift report shows only the two mayhem verdicts; no lamp goes out in a drive-by; the alley has no items to
play with while waiting.

## M15 — three more events, the economy, the alley (lead prep, 2026-10-02)
Design: FRIENDSLOP.md section 8.5 (raid, sprinklers, the collector) and the M14 balance notes. Three agents in
worktrees `.claude/worktrees/<agent>` on `m15/<agent>`: **mayhem2**, **economy**, **alley**. Lead-only files as in
M14 (project.godot, CONTRACTS.md, PLAN.md, README.md, tools/test_all.sh, const.gd, balance_config.gd, config.gd, the
tables of sfx.gd). Shared files are edited only inside `# --- M15 <agent> ---` regions plus tagged one-line hooks.
Test ports: mayhem2 +77 / mayhem2_mp +78, economy +79, alley +81 / alley_mp +82.

### Prep already in place (lead)
- `Const`: `WRITE_UP_RAID` ("raid": holding a bundle when the raid looks at you), `ITEM_BALL` (&"ball").
- `BalanceConfig` group "Mayhem 2 (M15)": `raid_warning_sec` 20, `raid_sec` 6, `sprinkler_sec` 25,
  `sprinkler_wet_sec` 10, `collector_sec` 25, `collector_fee` 40, `collector_hold_sec` 1.5.
- Sfx names with default blips: `siren` (loop), `sprinkler` (loop), `collector_knock`, `ball`.

### Mayhem 2 (mayhem2 agent) — events.gd, room.gd / room.tscn (its markers), story.gd / hud.gd regions, sfx recipes
- `Events.EVENT_RAID` (`raid_warning_sec` + `raid_sec`): the `siren` loop outside and a banner "RAID" with the hint
  "Get the product out of sight."; red and blue light sweeping in through the roller door during the warning. Then
  the look: every 1.5 s for `raid_sec` the host tests sight from the next of `Room.get_raid_points()` (three eye
  points: the roller door, the dock passage, the middle of the main room; the agent adds them). Every product bundle
  (held, on the floor or on a rack) with a clear LAYER_WORLD line to that point and within 16 m is taken (despawned,
  `confiscate`), and a worker holding one gets `Const.WRITE_UP_RAID`. Out of sight means behind a wall, a crate stack,
  in the hall, or deposited. Trays are not touched. Params `{seconds, warning}`. Signals `raid_swept(point_index,
  taken)`, `raid_took(item_name, holder_peer)`.
- `Events.EVENT_SPRINKLERS` (`sprinkler_sec`): every tray's water goes to 1.0 at the start, water falls in every play
  area (cheap particles per area), the `sprinkler` loop; the whole floor is wet for the event plus
  `sprinkler_wet_sec`: the leak's slip rule (faster than `Events.get_slip_speed()`, not crouched, not in the back
  room, one slip per 3 s) applies at every `Room.contains_point` position. Params `{seconds}`.
- `Events.EVENT_COLLECTION` (`collector_sec`): a man stands at `Room.get_collector_spot()` on the dock (a reskin of
  the Boss scene with another tint and no booth; a plain child of the Room on every peer, like the rat), banner
  "COLLECTION" with the hint "He wants $40. Dock."; `collector_knock` at the start. Holding E on him for
  `collector_hold_sec` pays `collector_fee` from cash on hand (prompt "Pay $40"; "Cash short." when it is not there):
  he leaves, event over. Unpaid when the time runs out: he takes the dearest product bundle on the floor plan
  (despawned); with no bundle, the most advanced growing tray is lost (`GrowPlot.server_crop_lost` with a new cause
  `LOSS_COLLECTED`, then reset). Params `{seconds, fee}`.
- Weights for twelve kinds: inspection 22, power_cut 13, audit 7, rat 7, headcount 10, water_off 6, shortage 5,
  leak 7, driveby 7, raid 6, sprinklers 5, collection 5. Late-join replay through the existing path;
  `--first-event=raid|sprinklers|collection`. Suites `mayhem2` (+77) and `mayhem2_mp` (+78).

### Economy (economy agent) — data/balance.tres, tools/gen_balance.gd, a simulation tool, the suites that pin numbers
The floor went from six trays to ten and a cured bundle pays 40% more, but the payment due did not move.
- A deterministic model of a shift (`tools/tests/econ_sim.gd`, plain GDScript, no physics): workers, trays, real
  travel distances between the stations (from the Room's station positions and doorways), action times, strain
  numbers, curing, an expected cost of events and mutations. It prints the expected deposit per shift for 1 to 4
  workers at three skill levels.
- From it: `base_quota`, the growth of the payment due across shifts, the per-player multiplier, `cure_sec`
  (target: curing is a real choice, not always right), Purple Haze (weakest per unit of labour today) and Golden
  Kush (its trait is a pure penalty) get retuned. Target: a careful solo player makes shift 1 with a margin of about
  a quarter; four players who split up make shift 3; nobody makes shift 6 without upgrades and cured bundles.
- Every changed number is pinned in the suites that own it (strains, econ, flow) and listed in the report with the
  model's before / after table. Suite `economy` (+79) pins the model's own invariants.

### The alley (alley agent) — lobby.tscn / lobby.gd, a ball item, the alley's report board
- A ball (`Const.ITEM_BALL`, scenes/items/ball.tscn + script, a small model): an ordinary carryable, throwable item
  that lives in the alley (spawned there by the host when the alley is in use, removed when the shift starts).
  A thrown ball that hits a worker staggers them like any thrown item.
- A board on the alley wall showing the last shift's result (paid or missed, the payment due, the three top verdict
  lines), fed from GameState / Story on every peer; blank before the first shift.
- A hoop or a bin on the wall: the ball going through it plays a dull sound and counts on a small counter next to it
  (host-counted, synced). Nothing more.
- Suites `alley` (+81) and `alley_mp` (+82), both with `--lobby`.

### Replayability (asked for by the user on 2026-10-02: "I want to be able to have good replayability")
Two more agents, **replay** and **career** (ports replay +83 / replay_mp +84, career +85 / career_mp +86). Everything
below is behind `Config.replay_enabled` (lead prep: true in a windowed run, false under `--headless`; `--replay` /
`--no-replay` force it), so the existing suites keep running a plain, deterministic game.
More prep in place: `SeedDef.unlock_round` (1 = always), `BalanceConfig` group "Replay (M15)"
(`conditions_from_round` 2, `conditions_per_shift` 1, `market_swing` 0.25, `event_gap_shrink_per_round` 0.08,
`contract_reward` 60), `Const.STAT_CONTRACTS`, autoload `Career` (scripts/core/career.gd, a stub the career agent
fills).

### Replay (replay agent) — scripts/core/shift_conditions.gd, game_state.gd region, the consumers' one-line hooks
- **Shift conditions.** A catalog of at least ten (`ShiftConditions`: id, title, one flat line, effect keys), for
  example dry air (trays dry 50% faster), a twitchy batch (mutation chances doubled), a buyer for one strain (it pays
  50% more), clearance (seeds 30% off), inspection week (the Boss walks twice as often), bad wiring (power cuts last
  twice as long and Night Shift likes it), a short clock (the shift is 40 s shorter, the payment due 15% lower),
  overtime (40 s longer, 15% more due), a slick floor (the whole floor is wet), thin walls (drive-bys more likely).
  From shift `conditions_from_round` on the host rolls `conditions_per_shift` of them (two from shift 5) when the
  game enters WAITING for that shift, so the alley can show them before boarding; with the lobby off they are rolled
  at the start. Synced to every peer and to late joiners.
  API: `GameState.get_conditions() -> Array[StringName]`, `GameState.condition_value(key: StringName, default:
  float) -> float` (the product of the active conditions' values for that key), `GameState.server_set_conditions(ids)`
  for tests, signal `conditions_changed`. Consumers read `condition_value` (grow_plot water drain / mutation roll,
  shop prices, sale value, round length and quota at shift start, event weights and gaps, slip rule): each consumer
  hook is one tagged line.
- **Market.** Each shift every strain's deposit value is multiplied by a rolled factor in `1 - market_swing ..
  1 + market_swing` (rounded to 5%), synced like the conditions. `GameState.get_market_multiplier(strain_id)`,
  `server_set_market(dict)`, signal `market_changed`. The supply card shows the day's deposit value with an arrow.
- **A run that builds.** Strains unlock by shift (`SeedDef.unlock_round`: Budget, Purple, Creeper at 1; Golden at 2;
  Night Shift at 3; Floor Brick at 4): a locked card reads "From shift 3". Event gaps shrink by
  `event_gap_shrink_per_round` per shift (floor at half).
- HUD: the active conditions as short chips under the payment bar; `GameState.get_shift_briefing() -> Array[String]`
  (conditions, the market's best and worst strain, new unlocks) for the alley board.
- Suites `replay` (+83) and `replay_mp` (+84), both with `--replay`.

### Career (career agent) — scripts/core/career.gd (autoload), game_state.gd region, hud.gd region
- **Contracts.** One optional job per shift from a catalog of at least eight (deposit N cured bundles, deposit N of
  one strain, finish with no write-ups on the floor, burn a hostile plant, patch a leak within ten seconds, nobody
  knocked down in a drive-by, harvest N trays in the grow hall, finish with more than X cash on hand). Rolled by the
  host with the conditions, synced (`GameState.contract: Dictionary` with id, text, goal, progress, reward, done),
  progress counted on the host from existing signals and stats, paid `contract_reward` into cash on hand the moment
  it is met (`Const.STAT_CONTRACTS` for the floor), a toast and a flat Boss line. A HUD line shows it with progress.
  `GameState.server_set_contract(id)` for tests, signal `contract_changed`.
- **Career file** (local, per player, `user://career.cfg`; `--career-file=<path>` for tests; never synced): shifts
  worked, best shift reached, total deposited, contracts met, plants burnt, times bitten / shot / sent to the back
  room, each strain's deposits. Updated at the end of every shift from this peer's own stats. `Career.get_record(key)`,
  `Career.get_summary_lines() -> Array[String]`, `Career.get_title() -> String` (a flat job title that follows the
  best shift reached: "New hire", "Floor hand", "Lead hand", ...; shown next to the player's name in the WORKERS list
  to everyone: the title is the one thing that is sent, with the name registration or a small RPC).
- The pause menu gets a "Record" page listing the career lines; `Career.get_summary_lines()` is also what the alley
  board shows under the last shift (the alley agent reads it through `has_method` guards).
- Suites `career` (+85) and `career_mp` (+86), both with `--replay`.

### M15 as delivered (integration notes, lead, 2026-10-02)
Five branches merged (alley, replay, mayhem2, career, economy). What differs from the plan above, and what a later
change has to know:

**Switches.** `Config.replay_enabled` (true in a windowed run, false under `--headless`; `--replay` / `--no-replay`)
gates the conditions, the market, the unlocks, the rolled job, the title RPC and the Record card. With it off the game
is the plain deterministic one the older suites pin. `GameState.server_set_contract` works either way (tests).

**Shift conditions (replay).** Thirteen, in `ShiftConditions` (`scripts/core/shift_conditions.gd`): dry air, twitchy
batch, a buyer for one strain (`ShiftConditions.make_id(ID_BUYER, strain)`), seed clearance, inspection week, bad
wiring, short clock, mandatory overtime, slick floor, thin walls, heat wave, quiet night, cured order. One per shift
from shift 2, two from shift 5, rolled when the game enters WAITING for that shift (so the alley board has them
before the ride), synced in the state dictionary under `"replay"` (late joiners get it with the state).
`GameState.get_conditions()`, `condition_value(key, default)`, `server_set_conditions(ids)`, `conditions_changed`,
`get_shift_briefing()`. HUD chips: `World/HUD/Root/Stats/QuotaColumn/ConditionChips`. The shift report ends with
"Conditions: ...".

**Market (replay).** A factor per strain on a 5% grid inside `1 - market_swing .. 1 + market_swing`, at least one
strain on sale at par or better. `market_swing` is **0.15** (lead, from the economy model: the window between "makes
shift 6 without racks" and "with racks" is about 10%, so 0.25 made that target luck of the day). The supply card
shows the day's deposit value with an arrow. `GameState.get_market_multiplier(strain)`, `server_set_market(dict)`.

**Unlocks (replay).** `SeedDef.unlock_round`: Budget Bud, Purple Haze, Creeper 1; Golden Kush 2; Night Shift 3; Floor
Brick 4. A locked card's button reads "FROM SHIFT N". Event gaps shrink 8% a shift (floor at half).

**Events (mayhem2).** Twelve kinds; weights inspection 22, power_cut 13, audit 7, rat 7, headcount 10, water_off 6,
shortage 5, leak 7, driveby 7, raid 6, sprinklers 5, collection 5; a condition can scale a kind's weight
(`Events.get_weight(kind)`).
- Raid: `raid_warning_sec` 20 of sirens, then four looks 1.5 s apart from `Room.get_raid_points()` (roller door,
  dock passage, middle of the main room, door again). A bundle within 16 m with a clear world-layer line is taken; a
  worker holding one is written up (`Const.WRITE_UP_RAID`). **The grow hall is out of sight by rule**
  (`Room.is_in_hall`), because the middle eye has a clear line through the pen gate. Lights: `Room/RaidLights`
  (beams `RAID_BEAM_ENERGY` 15, angle 46, hues from `Events.raid_light_color(Toon.TOMATO / Toon.SKY)`: the palette
  colours themselves read as a pink smudge).
- Sprinklers: every tray filled, `Events.is_floor_wet()` for the event plus `sprinkler_wet_sec`. The slip judge is
  one predicate now: a puddle, the sprinklers (`is_wet_at`) or the slick floor condition (`is_floor_slick_at`).
- Collector: `scenes/npcs/collector.tscn` on the dock, "Hold E · Pay $40" (`Events.request_pay_collector()`; the
  request RPC is on the Events autoload, not on his node). Unpaid: the dearest bundle by
  `TurnInStation.get_sale_value`, else the most advanced tray (`GrowPlot.LOSS_COLLECTED`).

**The job (career).** Nine in `Contracts` (`scripts/core/contracts.gd`): cured, strain, hall, early, clean, cash,
burn, leak, driveby. One per shift, never the same kind twice in a row; an event job whose event has not come by
half time is swapped for one that needs nothing. `GameState.contract` is NOT in the state dictionary: its own RPC
`_rpc_contract`, sent to late joiners on `Net.peer_registered`. Paid `contract_reward` ($60) on the spot; `clean`
and `cash` are judged at the end and need the payment made. HUD line:
`.../QuotaPanel/VBox/CareerBox/JobLine`; report line `%Report/JobLine`; the alley board's NEXT column ends with it
(`AlleyBoard.get_job_line()`, lead).

**Career (career).** Autoload `Career`, file `user://career.cfg` (plain INI, own tolerant parser, written through
`.tmp` + rename), never synced. `--career-file=<path>` for tests and capture tools; without it a run under
`--headless` or started with `-s <script>` keeps the record in memory only, so no tool can touch the real file.
The title (ladder by best shift: New hire, Floor hand, Tray hand, Lead hand, Shift lead, The Boss's problem) is the
one thing sent: `Net._rpc_set_title`, accepted only when it is exactly a ladder string, at most 16 changes a peer.
Shown on a line under the worker's row and on the Record card beside the ON BREAK card (`%Record`).

**Economy (economy + lead).** `tools/tests/econ_sim.gd` is the model (assumptions in its header); the `economy`
suite pins its targets. Shipped: `quota_per_extra_player` 0.1 (ten trays saturate at three workers), `cure_sec` 45
(at 20 s hanging everything was always right), Purple Haze $140, Golden Kush $125 a unit. **Payment due: 350, x1.82
+ 688 a shift** (solo 350 / 1325 / 2535 / 4174 / 6592 / 10429; four workers x1.3). The economy branch shipped 500,
x1.75 + 450; the lead put shift 1 back to 350 because the model has an average worker alone at $384 there, and
shift 2 is where the conditions, the market and the first unlock start. Shifts 2 to 6 are within 4% of the
branch's curve and its shift 6 targets hold (three or four careful workers need favors and the racks).

**HUD layout (lead).** The payment column grew, so the centre banner (`%Banner`) follows its bottom edge
(`HUD.get_banner_top()`), never higher than 146.

**Suites and ports.** alley +81 / alley_mp +82, replay +83 (also run as `replay_off` with `--no-replay`) /
replay_mp +84, mayhem2 +77 / mayhem2_mp +78, career +85 / career_mp +86, economy +79 (pure).
`tools/tests/m15_shots_body.gd` is the capture tool (windowed, `--career-file` pointing at a seeded temp file).

**Known gaps.** `twitchy` doubles Night Shift's mutation chance to 0.70 (untuned). The mid-run is slack for a full
crew (average four deposit about $8,900 against $3,296 in shift 3): only a per-shift payment table could follow the
capacity jump at shift 3. The siren, sprinkler and collector sounds pass `art_test` but nobody has heard them.
Three more job ideas from the career branch are not built (one bundle each of three strains; lose no plant; a raid
that takes nothing).

## M16 — the floor moves, issued kit, more jobs (lead prep, 2026-10-02)
Design: FRIENDSLOP.md section 10. Three agents in worktrees `.claude/worktrees/<agent>` on `m16/<agent>`:
**variety**, **hats**, **polish**. Lead-only files as before (project.godot, CONTRACTS.md, PLAN.md, README.md,
HANDOFF.md, FRIENDSLOP.md, tools/test_all.sh, const.gd, balance_config.gd, config.gd, the tables of sfx.gd). Shared
files are edited only inside `# --- M16 <agent> ---` regions plus tagged one-line hooks (`# M16 <agent>`).
Everything new that changes a run sits behind `Config.replay_enabled`, so the 76 existing suites keep running the
plain game. Test ports: hats +87 / hats_mp +88, variety +89 / variety_mp +90, polish +91.

### Prep already in place (lead)
- `Config.run_code: String` (`--run=<code>`, "" = the host rolls one).
- `BalanceConfig` group "M16": `mutation_chance_cap` 0.5 (no condition pushes a strain's chance to walk past this),
  `empty_flamethrower_sec` 30 (an empty flamethrower left lying is cleared after this).
- Sfx names with default blips: `uproot`, `locker`.

### Variety (variety agent) — scripts/core/run_seed.gd, game_state.gd region, room.gd / room.tscn, the menu, the board
- **A run code.** `RunSeed` (static, `class_name RunSeed`): `to_code(seed: int) -> String` (four characters from an
  alphabet without look-alikes), `from_code(text: String) -> int` (0 for junk; case and spaces ignored),
  `weekly(unix_time: int) -> int` (the same for everyone in one ISO week), `stream(seed: int, name: StringName) ->
  int` (an independent sub-seed per consumer). The host picks the run's seed when a session's first shift is set up
  and on START OVER: `Config.run_code` when given, else random. Synced in the state dictionary under `"run"`
  (`{"seed": int, "cover": int}`), so late joiners have it. `GameState.get_run_seed() -> int`, `get_run_code() ->
  String`, `server_set_run_seed(seed: int)` (tests; WAITING only), signal `run_changed`.
- **Seeded dice.** With replay on, the host seeds from the run seed, each with its own stream: `GameState.replay_rng`
  (conditions, market), the job roll, `Events` (`Events.server_seed(seed: int)`: kinds, gaps, picks),
  `Hostiles.server_seed(seed: int)`, `GrowPlot.spread_rng`. The same code gives the same card: the same conditions,
  market, jobs and order of events, shift by shift. What the workers do is not seeded. With replay off nothing is
  seeded and nothing changes.
- **Cover that moves.** The loose cover (the crates and pallets under `Dock`, `Decor` and `Hall` in room.tscn) gets
  at least four arrangements: `Room.COVER_LAYOUTS` (layout 0 is exactly today's), `Room.get_cover_layout() -> int`,
  `Room.apply_cover_layout(index: int)` (moves the existing nodes: never reparent, never free). The host derives the
  layout from the run seed (`stream(seed, &"cover")`), it is applied on every peer from the synced state while the
  game is WAITING or as the first shift is set up, never during a shift. Every layout keeps: the route graph
  (`ROUTE_POINTS` / doorways) clear by `ROUTE_MARGIN`, every station's interaction side free, each drive-by lane
  with a spot behind cover, and on the dock at least one spot out of sight of all three raid eyes. The suite proves
  these for every layout from the geometry.
- **The menu and the board.** The host panel gets a run code field (blank: random) and a "THIS WEEK" button that
  fills in the week's code. The alley board's NEXT column ends with "Run 7K2M." (alley_board.gd: variety agent
  only).
- Suites `variety` (+89) and `variety_mp` (+90), both with `--replay`.

### Hats (hats agent) — scripts/core/hats.gd, career.gd, net.gd region, player, a locker in the alley, models
- **Issued, not bought.** `Hats` (static, `class_name Hats`): a catalog of at least six, each `{id, name, line (what
  it is issued for, flat), record key, threshold, scene}`, issued from the player's own record: for example a
  hairnet (one shift worked), a paper cap (ten shifts), a hard hat (best shift 3), a traffic cone (sent to the back
  room three times), a bucket (bitten five times), a welding mask (five plants burnt). `Hats.ids()`,
  `Hats.get_def(id)`, `Hats.issued_for(career: Object) -> Array[StringName]`.
- **Career.** `Career.get_issued_hats() -> Array[StringName]`, `get_hat() -> StringName` (&"" = none),
  `set_hat(id: StringName) -> bool` (only an issued one or &""), signal `hat_issued(id)` when the end of a shift
  issues a new one (a toast: "Issued: hard hat. It is in your locker."). The chosen hat is kept in the career file.
- **Everyone sees it.** The hat id is the second thing a peer sends: `Net._rpc_set_hat(id)` (any_peer, call_local,
  reliable; sender must be registered; accepted only when it is a catalog id or empty; at most 32 changes a peer a
  session), `Net._rpc_hats_sync(dict)` to all and to a late joiner, `Net.get_player_hat(peer) -> StringName`,
  signal `hats_changed`. The host cannot check a record it never sees: any catalog id is accepted. Every peer shows
  the hat on that worker's body model (a socket on the head; the local player's own first-person view is not
  blocked by it). Models are built by the Blender pipeline (`tools/blender/models/hats.py`, one GLB each, MODELING.md
  rows), chunky and worn, nothing cheerful.
- **The locker.** An interactable in the alley (`scenes/world/locker.tscn`, placed in lobby.tscn by this agent): E
  puts on the next issued hat, round to none ("Locker · hard hat", "Locker · nothing issued"); sound `locker`. The
  pause menu's Record card lists "Issued: 3 of 6".
- Gated like the title: with replay off no hat is sent and the locker says "Locker · locked".
- Suites `hats` (+87) and `hats_mp` (+88), with `--replay --lobby --career-file=<temp>`. NEVER the real
  `user://career.cfg`.

### Polish (polish agent) — contracts.gd + the career region of game_state.gd, grow_plot.gd, flamethrower, a sound tool
- **Three more jobs** (twelve in all): `variety` (one bundle each of three different strains), `keep` (lose no plant
  this shift: fails on any `GrowPlot` crop loss; judged at the end, payment made), `raid` (a raid that takes
  nothing: fails on `Events.raid_took`, met when a raid ends clean; an event job: pool and half-time swap as the
  others).
- **A cap on walking plants.** After conditions, a strain's chance to turn is capped at
  `Config.balance.mutation_chance_cap` (twitchy took Night Shift to 0.70).
- **Uprooting sounds like uprooting** (`uproot`, not the harvest snip): recipe in the agent's block of sfx.gd.
- **Empty flamethrowers do not pile up.** An empty one lying on the floor (not held, not in the cabinet) is removed
  by the host after `empty_flamethrower_sec`, on every peer through the item system's own despawn.
- **A way to hear the new sounds.** `tools/tests/sound_demo_body.gd` (headless, no audio device needed) writes one
  WAV per name given with `--sounds=a,b,c` into `--out=<dir>` from the Sfx recipes, so the user can audition `siren`,
  `sprinkler`, `collector_knock`, `ball`, `uproot`, `locker` (and the footsteps) in any player.
- Suite `polish` (+91); the career, strains and flame suites follow where a pinned number moves.

### M16 as delivered (integration notes, lead, 2026-10-02)
Three branches merged (polish, variety, hats). What differs from the plan above, and what a later change has to know:

**Run codes (variety).** `RunSeed` (`scripts/core/run_seed.gd`): seeds are 1..923521, each with exactly one
four-character code (alphabet without 0 O 1 I L); the hash is hand-written 32-bit arithmetic, so a code means the
same run in every build. `GameState.get_run_seed()`, `get_run_code()`, `get_run_cover()`,
`server_set_run_seed(seed)` (WAITING only), signal `run_changed`; state entry `"run": {"seed", "cover"}`.
**The dice are seeded once per shift**, not once per run: `RunSeed.stream(seed, "<consumer>:<shift>")` for
`replay`, `job`, `events`, `hostiles`, `spread`, so a swapped job or an extra event in one shift does not move the
next shift's card. Events has two dice: `_rng` (picks) and `_card_rng` (kinds and gaps, read through `_card()`).
A die a test seeded itself stays the test's. Not seeded: the mutation roll (global `randf()`) and each hostile
plant's own wander.
- START OVER with a typed code deals the same run again; without one the host rolls a new seed.
- The weekly code is by UTC week.

**Cover (variety).** `Room.COVER_LAYOUTS` (four; layout 0 is the scene), `COVER_NODES` (19),
`apply_cover_layout(index)`, `get_cover_layout()`, `get_cover_footprints()`, `is_in_cover(point, margin)`. The host
changes the layout only in `server_reset_game` and `server_set_run_seed`; a late joiner applies it on arrival.
The variety suite proves per layout, from the geometry: routes and stations clear, a standing spot near every
drive-by lane that no round reaches, a dock spot no raid eye sees, and that no two layouts stop the same lanes or
share most of their hidden cells.

**Suites that run with `--replay` pass `--run=B5VP`** (layout 0 and one fixed card): replay, replay_mp, career,
career_mp, polish, hats, hats_mp. Without it they get a random layout and card (the career suite's half-time swap
check fails when shift 2 rolls the short clock). The replay suite also sets `contract_reward` to 0: it counts money
to the dollar and a job met by one of its deposits paid $60 on top.

**Hats (hats).** Seven in `Hats.CATALOG` (`scripts/core/hats.gd`): hairnet (1 shift), paper cap (10 shifts),
yellow hard hat (best shift 3), traffic cone (3 back rooms), bucket (5 bites), welding mask (5 burns), bandage
(shot 3 times). "No hat" is the worker as shipped: **the white stock hard hat is its own mesh now**
(`Visual/Model/Hat`, with an empty `Visual/Model/HatSocket`; `player.glb` rebuilt on Blender 5.2 from player.py),
hidden while an issued hat hangs under the socket. `Career.get_issued_hats()`, `get_hat()`, `set_hat(id)`,
`hat_issued(id)`; `hat=<id>` under `[career]` in the file. `Net._rpc_set_hat` / `_rpc_hats_sync`,
`Net.get_player_hat(peer)`, `hats_changed`; the host takes any catalog id (it never sees a record) and at most
`Net.MAX_HAT_CHANGES` changes a peer a session: **160** (the branch shipped 32, four trips round the locker; lead).
The locker (`World/Lobby/Locker`, west wall under the street lamp, world (-4.7, 0, 80.1)) acts locally; its prompt
names what is on now ("Locker · traffic cone", "· no hat", "· nothing issued", "· locked" with replay off,
"· jammed" when the session's changes are used up). Record card: `%RecordIssued` ("Issued: 3 of 7").

**Jobs (polish).** Twelve: `variety` (one bundle each of three strains; pool needs three strains on sale), `keep`
(lose no plant: eaten, burnt, collected or walked off fails it; gunfire only sets a tray back and does not), `raid`
(a raid that looked at least once and took nothing). `GameState.server_note_crop_lost(plot, cause)` is the hook.

**The cap (polish).** `GrowPlot.get_mutation_chance(seed_def)` = `min(own x conditions, max(cap, own))`: the cap
is on what conditions add, a strain whose own chance is above it keeps its own (older suites force 1.0). Twitchy
Night Shift is 0.50. The twitchy line reads "More of them get up and walk." (lead).

**Small things (polish).** A plant that walks off plays `uproot` (`_rpc_uprooted` marks the tray just before the
reset); an empty flamethrower lying on the floor is despawned by the host after `empty_flamethrower_sec`
(`Flamethrower.server_tick_empty`), silently; `tools/tests/sound_demo_body.gd` writes one WAV per Sfx name.

**Known gaps.** `qa_m12_4p` has a race of its own (the cabinet's whole-second restock countdown can tick between
two snapshots: "host 78, peer 77"); it passed on re-run. A flamethrower lying on a cover piece at START OVER is not
re-rested when the cover moves. The uproot sound's arrival order on a client is proven only by an ad hoc run.

## M17 — a run has an end, a hand truck, two more events (lead prep, 2026-10-02)
Design: FRIENDSLOP.md section 11. Three agents in worktrees `.claude/worktrees/<agent>17` on `m17/<agent>`:
**finale**, **cart**, **mayhem3**. Lead-only files as before (project.godot, CONTRACTS.md, PLAN.md, README.md,
HANDOFF.md, FRIENDSLOP.md, tools/test_all.sh, const.gd, balance_config.gd, config.gd, the tables of sfx.gd). Shared
files are edited only inside `# --- M17 <agent> ---` regions plus tagged one-line hooks (`# M17 <agent>`).
Test ports: finale +93 / finale_mp +94, cart +98 / cart_mp +99, mayhem3 +33 / mayhem3_mp +34. Every suite that runs
with `--replay` passes `--run=B5VP` (cover layout 0, one fixed card).

### Prep already in place (lead)
- `Const.ITEM_HAND_TRUCK` (&"hand_truck").
- `BalanceConfig` group "M17": `final_shift_by_team` [4, 5, 6, 6], `final_interim_share` 0.4, `final_interim_raise`
  0.1, `hand_truck_capacity` 4, `scale_sec` 40, `scale_cut` 0.15, `phone_sec` 14, `phone_hold_sec` 1.2,
  `phone_fine` 30, `phone_discount` 0.2, `phone_discount_sec` 60.
- Sfx names with default blips: `phone_ring` (loop), `phone_pickup`, `scale_hit`, `truck_load`, `paid_in_full`.

### Finale (finale agent) — game_state.gd region, round_end / shift report, story / hud regions, career.gd, hats
- **The final notice.** With replay on, a run has a last shift: `Config.balance.final_shift_by_team[size - 1]` for
  the largest team seen in this run (4 for one worker, 5 for two, 6 for three or four: the shifts the economy model
  has a careful crew of that size reach). `GameState.get_final_shift() -> int` (0 with replay off: the run never
  ends, as today), `is_final_shift() -> bool`, `is_run_cleared() -> bool`, signal `run_cleared`; synced in the
  state dictionary under `"final"` (`{"shift": int, "cleared": bool}`), type-checked and clamped on receive.
- **That shift is different.** The payment panel's title reads "FINAL NOTICE" instead of "THIS SHIFT"; the alley
  board's NEXT column starts with "Final notice. Pay it and the debt is cleared."; it always has two conditions; at
  half time the host looks at the payment: under `final_interim_share` of it deposited, the payment due rises by
  `final_interim_raise` (the audit's own raise path) with a flat Boss line ("Half the clock. Not half the money.");
  at or over it, one line and nothing else ("On schedule. Keep it there.").
- **Clearing it.** Paying the final notice ends the run: ROUND_SUCCESS with `cleared`; the round-end overlay reads
  "PAID IN FULL" / "The debt is cleared. He will find another."; the host's button is "NEW RUN" (a full reset: a
  new run code unless one was typed) and NEXT SHIFT is not offered; sound `paid_in_full` (flat, not a fanfare).
  Missing it is a missed payment like any other.
- **On file.** Career record `cleared` (runs cleared), a summary line "Debts cleared: 1", and one more hat issued
  for the first clear (an accountant's eyeshade or the like: catalog row, model in hats.py, MODELING.md row).
- Suites `finale` (+93) and `finale_mp` (+94), with `--replay --run=B5VP --career-file=<temp>`.

### Cart (cart agent) — a hand truck item, its model, room.tscn marker, player carry, the chute, the raid hook
- **A hand truck** (`Const.ITEM_HAND_TRUCK`, scenes/items/hand_truck.tscn + script, model `hand_truck.glb` by the
  Blender pipeline). One stands at `Dock/HandTruckSpot` (a marker this agent adds) from the start of a run; the host
  puts it back there at the start of every shift.
- **Carried like something heavy.** Held in both hands with the heavy-carry rules Floor Brick already has (no
  sprint, slower); it can be dropped, not thrown.
- **It carries bundles.** Up to `hand_truck_capacity` product bundles. Loading: a worker holding the truck presses
  E on a bundle lying on the floor, or a worker holding a bundle presses E on a standing truck. Unloading: E on a
  standing truck with empty hands takes the top bundle. Items are never reparented: loading despawns the bundle
  through the item system and keeps its data (`strain_id`, `amount`, `cured`) in the truck's synced `load`
  (host-owned, sent to every peer and to late joiners); unloading spawns a bundle with that data. The load is
  drawn on the truck on every peer.
- **At the chute.** Interacting with the chute while holding the truck deposits every loaded bundle, one deposit
  each for the holder, through the chute's own sale path (so the market, the buyer, cured, the job hooks and the
  stats all apply).
- **Trouble.** A raid that sees the truck takes its whole load (`Events.raid_took` once per bundle; the holder is
  written up like any holder). The collector, the rat and the hostile plant ignore the load.
- API: `HandTruck.get_load() -> Array[Dictionary]`, `server_load(bundle: Item, peer_id: int) -> bool`,
  `server_unload(peer_id: int) -> Item`, `server_clear_load() -> int`, signal `load_changed`.
- Suites `cart` (+98) and `cart_mp` (+99).

### Mayhem 3 (mayhem3 agent) — events.gd region, a wall phone (model, room.tscn), story / hud regions, sfx recipes
- `Events.EVENT_SCALE` (`scale_sec`): the chute's scale reads light: every deposit pays `scale_cut` less until
  somebody hits it (a shove, F, within reach of the chute, or any thrown item that strikes it); then the event is
  over with `scale_hit`. Banner "SCALE IS OFF", hint "It reads light. Hit it." Unfixed, it ends with the timer.
  Params `{seconds, cut}`. The cut goes through the sale value the chute already computes (one tagged hook).
- `Events.EVENT_PHONE` (`phone_sec`): the wall phone rings (`phone_ring` loop at the phone; a model by the Blender
  pipeline, hung in the main room by this agent). Holding E on it for `phone_hold_sec` answers; the host rolls one
  of three from the card dice (`_card()`): a tip (the kind of the next event is told to the whole floor: "Next:
  a raid."), a favor (seeds `phone_discount` off for `phone_discount_sec`), or a wrong number ("Wrong number.").
  Nobody answers: `phone_fine` from cash on hand (as far as there is cash) and a flat Boss line ("He called.
  Nobody picked up. Thirty."). Banner "PHONE", hint "Somebody pick that up." Params `{seconds}`. Signals
  `phone_answered(peer_id, outcome)`, `phone_missed(fine)`.
- Weights for fourteen kinds: inspection 20, power_cut 12, audit 7, rat 6, headcount 9, water_off 6, shortage 5,
  leak 7, driveby 7, raid 6, sprinklers 5, collection 5, scale 3, phone 2. Late-join replay through the existing
  path; `--first-event=scale|phone`. The suites and the economy model that pin twelve kinds and their weights
  (`disrupt`, `mayhem`, `mayhem2`, `economy` / `tools/tests/econ_sim.gd`) follow.
- Suites `mayhem3` (+33) and `mayhem3_mp` (+34), with `--events`.

### M17 as delivered (integration notes, lead, 2026-10-02)
Three branches merged (finale, mayhem3, cart). The first three agents stopped on the account's Fable usage limit
with nothing committed; fresh agents on Opus finished from their worktrees. What differs from the plan above:

**The final notice (finale).** `GameState.get_final_shift()`, `is_final_shift()` (true from WAITING before that
shift through its end screen), `is_run_cleared()`, `get_largest_team()` (host), signals `final_changed`,
`run_cleared` (before `round_ended`), `final_look(short, raised)`; state entry `"final": {"shift", "cleared"}`.
- The last shift is locked once the final notice starts: a worker joining during it does not move the end of the
  run; one joining earlier (alley, end screen) does.
- "Always two conditions" is `maxi(count, 2)` and only when the shift rolls any. A shift rolled as final keeps its
  two conditions if the team grows in the alley afterwards (the replay region's "rolled once" rule). The same code
  still deals the same card for the same team size.
- After a clear, `request_next_round` is ignored; `server_start_round` / `server_return_to_lobby(false)` warn.
- Copy: Boss on the clear "That's all of it. I'll think of something."; toast "Final notice. Pay it and the debt is
  cleared."; the board on the end screen "PAID IN FULL"; the panel title uses `Toon.WARNING`.
- Career `cleared` (in `KEYS`), "Debts cleared: N"; hat `eyeshade` ("green eyeshade", one debt cleared): eight hats.
- The replay suite clears `final_shift_by_team` (it plays nine shifts of one run).

**The scale and the phone (mayhem3).** Fourteen kinds, weights as specified.
- Scale: `Events.is_scale_off()`, `get_scale_factor()`, `server_hit_scale(peer)`, `request_hit_scale()`,
  `try_hit_scale()`; F at the chute goes through `Events._input` (a worker under the crosshair is still shoved);
  thrown hits are checked in `Events._physics_process` on the host with the same cast ItemManager uses, so a
  thrown bundle that strikes the chute fixes the scale first and is sold at full price. The cut is in
  `TurnInStation.get_sale_value` (and, lead, in the truck's prompt total); the supply card does not show it.
- Phone: `Decor/WallPhone` at (-7.8, 1.15, -7.5) (`WallPhone`, greyed "Phone" while silent);
  `Events.request_answer_phone()`, `server_answer_phone(peer)`, `get_phone_discount()`,
  `get_phone_discount_left()`, signals `phone_answered`, `phone_missed`, `phone_discount_changed`. When it starts
  ringing the host rolls both the call and the next kind from `_card()`; the tip only reveals that kind, the
  scheduler starts it next either way. **A told kind is retried at most `PHONE_TOLD_MAX_TRIES` (6) times, 5 s
  apart** (lead: a told rat with nothing growing stopped every event for the rest of the shift).
- The fine goes through `server_try_spend(taken, 0, "phone")`; the jar tags refresh through a `has_method` guard on
  ShopCounter's private `_decorate_from_balance`.

**The hand truck (cart).** `HandTruck` (`scripts/items/hand_truck.gd`), spot `Dock/HandTruckSpot` at (-8, 0, 8.6),
clear in all four cover layouts. The synced property is **`cargo`** (`load` would shadow GDScript's `load()`): an
array of `{strain_id, amount, cured, dry_left}`, replaced whole, cleaned on receive (16 entries at most); a bundle
off a rack keeps its remaining drying. The truck spawns when the first shift starts (inside the van ride's black
screen), keeps its load across shifts, and START OVER despawns it. With empty hands, aiming at the bags takes the
top bundle, aiming at the frame picks the truck up. At the chute each bundle is spawned at the slot and sold through
`server_sell_item`, top first, so every sale rule applies; a sale that meets the payment ends the shift and the rest
stays on. RMB: "Too heavy to throw." A raid looks at a standing truck at the middle of its load. The Boss's
inspection does not count a loaded truck as skimming. qa_4p, qa_robust and qa_m10_4p count the truck among the items.

**Suites and ports.** finale +93 / finale_mp +94, mayhem3 +33 / mayhem3_mp +34, cart +98 / cart_mp +99.
`tools/tests/m17_shots_body.gd` is the capture tool (`--board` for the alley board).
