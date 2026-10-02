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
Not done: empty flamethrowers pile up until RETRY; the supply card shows the margin but not the mutation chance; no
pathfinding (a worker outside the fence is unreachable: the plant drops the chase and eats instead).
