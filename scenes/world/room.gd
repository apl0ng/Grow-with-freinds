class_name Room
extends Node3D
## The starting room: geometry, lights, station placement, spawn points.
## (STUB - owned by the world/level agent. Contract below must be kept.)
##   $Spawns/Spawn1..4 (Marker3D)  - player spawn points
##   $Stations/*                    - instances of the four station scenes

func get_spawn_points() -> Array[Marker3D]:
	var out: Array[Marker3D] = []
	for c in $Spawns.get_children():
		if c is Marker3D:
			out.append(c)
	return out

func get_spawn_transform(index: int) -> Transform3D:
	var pts := get_spawn_points()
	if pts.is_empty():
		return Transform3D(Basis.IDENTITY, Vector3(0, 1, 0))
	return pts[index % pts.size()].global_transform
