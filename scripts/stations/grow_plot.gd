class_name GrowPlot
extends Interactable
## One planting spot. Server ticks growth/water; state is synced to clients via MultiplayerSynchronizer.
## (STUB - owned by the farming agent. Contract below must be kept.)

enum Stage { EMPTY, SEEDLING, VEGETATIVE, FLOWERING, READY }

## Synced (server authority).
var stage: int = Stage.EMPTY
var strain_id: StringName = &""
## 0..1 water level. Growth pauses below Config.balance.dry_threshold.
var water: float = 0.0
## 0..1 progress through the current stage.
var stage_progress: float = 0.0

func _enter_tree() -> void:
	super()
	add_to_group(Const.GROUP_GROW_PLOTS)

func is_empty() -> bool: return stage == Stage.EMPTY
func is_ready_to_harvest() -> bool: return stage == Stage.READY
func is_dry() -> bool: return water < Config.balance.dry_threshold
