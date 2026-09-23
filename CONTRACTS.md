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
Server slots = max_players + 1 so a 5th joiner gets "Server is full" instead of a timeout. Unregistered peers are dropped
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
`request_buy_seed(id)` / `request_buy_upgrade(id)` (client) → `_rpc_request_buy_*` → server `server_buy_seed(peer, id)` /
`server_buy_upgrade(peer, id)` returning `{"ok", "reason", "message"}`; validation order: player exists, range, def exists,
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
