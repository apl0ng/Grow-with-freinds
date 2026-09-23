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
```
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
func start_host(player_name: String, port: int) -> void
func start_join(ip: String, port: int, player_name: String) -> void
func return_to_menu(message: String = "") -> void   # any peer; disconnects and shows the menu (with message)
func get_player(peer_id: int) -> Player
func get_local_peer_id() -> int
func toast(text: String, kind: StringName = &"info") -> void
func set_ui_lock(source: StringName, locked: bool) -> void  # shop UI, pause menu, round-end screen
func is_ui_locked() -> bool                                  # player ignores input + frees mouse while locked
```
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
```
Spawned nodes (players, items) are **never reparented** (the spawner would despawn them on clients).

## Room (scenes/world/room.tscn, owner: world/level agent)
Must keep: `$Spawns/Spawn1..4` (Marker3D), `$Stations/ShopCounter`, `$Stations/Well`, `$Stations/TurnInStation`,
`$Stations/GrowPlot1..6` (instances of the station scenes — only their transforms are set here).
`func get_spawn_points() -> Array[Marker3D]`, `func get_spawn_transform(index: int) -> Transform3D`.

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
Held items follow `holder.get_item_socket()` every frame (copy global transform), collision disabled.
Interacting with a floor item = pick up (only with empty hands). Drop key drops at the player's feet.
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
```
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
```
Quota rule: `round_sales` (money earned from sales this round) must reach `quota` before `time_left` hits 0.
Spending does not reduce quota progress. Money carries over between rounds. Plants persist between rounds.
Round ends immediately on quota met if `Config.balance.end_round_on_quota_met`.

## Stations
**GrowPlot** (`scripts/stations/grow_plot.gd`, scenes/stations/grow_plot.tscn, owner: farming agent)
synced: `stage: Stage`, `strain_id`, `water: float 0..1`, `stage_progress: float 0..1`.
Interactions: seed packet + empty plot → plant · watering can (charges>0) + plant → water · READY + empty hands → harvest
(spawns product in hands: `{"strain_id", "amount": seed.yield_amount}`). Growth ticks on the server only while
`GameState.is_playing()` and `water >= dry_threshold`.
**Well** (`well.gd`): refills a held watering can to `get_capacity()`; spawns `starting_watering_cans` at `$CanSpots/*`.
**ShopCounter** (`shop_counter.gd`, owner: economy agent): opens `scenes/ui/shop_ui.tscn` locally; buy requests
are RPCs validated on the server (money, empty hands); seed packet spawns in the buyer's hands.
**TurnInStation** (`turn_in_station.gd`, owner: economy agent): sells a held Product:
`value = amount * seed.sale_value_per_unit * GameState.get_sale_multiplier()` → `GameState.server_add_sale`.

## HUD (scenes/ui/hud.tscn, owner: game-flow/UI agent)
Shows quota progress (round_sales / quota), wallet, timer, round number, phase banner, held item, prompt, toasts,
player list. Round-end overlay (success/fail; host: Next round / Retry / Menu, clients: waiting / Leave).
Pause menu on `pause` action (Resume / Leave to menu). All overlays use `Game.set_ui_lock`.

## Sfx / Juice (autoloads, owner: art agent)
```gdscript
Sfx.play(name: StringName, position: Vector3 = Vector3.INF)   # 2D when no position
# names: &"buy" &"plant" &"water" &"harvest" &"sell" &"pickup" &"drop" &"error" &"grow" &"round_win" &"round_lose" &"tick" &"ui_click" &"ui_open" &"ui_close"
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
