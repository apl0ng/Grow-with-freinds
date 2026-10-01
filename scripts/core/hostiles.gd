extends Node
## Hostiles (autoload, M12, owner: hostile agent). Server-authoritative hostile plants: a ready plant of a strain with
## `mutation_chance` can twitch for `mutation_warning_sec`, then uproot into a HostilePlant that roams the floor, eats
## growing plots and bites workers. Only fire kills it (the flamethrower, M12 flame agent).
##
## Contract (CONTRACTS.md "M12"): hostile nodes are plain children of World/Hostiles on EVERY peer (like the rat: not
## spawned nodes); the host runs the behaviour and syncs position / yaw / state over RPCs on this autoload; a late
## joiner gets the current list on Net.peer_registered. This file is the LEAD'S STUB: every method is a no-op with the
## agreed signature so the flame agent can build against it before the hostile branch merges.

## Every peer: a hostile plant exists (after its node was added under World/Hostiles).
signal hostile_spawned(id: int, strain_id: StringName, position: Vector3)
## Every peer: hostile `id` bit worker `peer_id`.
signal hostile_bit(id: int, peer_id: int)
## Every peer: hostile `id` destroyed the crop in GrowPlot `plot_index`.
signal hostile_ate(id: int, plot_index: int)
## Every peer: hostile `id` burnt down (by_peer = the shooter, 0 = the shift ended).
signal hostile_died(id: int, by_peer: int)

## SERVER. Adds a hostile plant of `strain_id` at `position` (global, floor). Returns its id, 0 when refused
## (hostile_max reached, no world).
func server_spawn(_strain_id: StringName, _position: Vector3) -> int:
	return 0

## SERVER. Removes every hostile plant at once (shift end / reset), without `hostile_died` credit.
func server_despawn_all() -> void:
	pass

## SERVER. `seconds` of flame reached hostile `id` (the flamethrower calls this every physics tick it is in the cone);
## after Config.balance.hostile_burn_sec in total it dies and `by_peer` gets Const.STAT_BURNS.
func server_apply_fire(_id: int, _seconds: float, _by_peer: int) -> void:
	pass

## Every peer: the live hostile nodes (class HostilePlant, group Const.GROUP_HOSTILES), children of World/Hostiles.
func get_hostiles() -> Array[Node3D]:
	return []

func get_hostile(_id: int) -> Node3D:
	return null

func count() -> int:
	return 0

func is_any_alive() -> bool:
	return false

## The nearest live hostile to `position`, or null.
func nearest_to(_position: Vector3) -> Node3D:
	return null
