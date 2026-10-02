extends RefCounted
## Test helper (M15 alley suites): points a worker at the alley hoop so that a throw made by the SERVER's rules
## (ItemManager: the hand socket + THROW_ORIGIN_FORWARD along the look, look * throw_speed + THROW_UP) falls through
## the ring. `socket` is the node the server takes as that worker's hand: Player.get_item_socket() for the server's
## own body (%HandSocket under the camera), %BodyHandSocket for a client's body as the server sees it.

const GRAVITY: float = 9.8


## Where a throw made right now comes DOWN through height `y` (global): the point, or Vector3.INF when the arc never
## gets that high.
static func predict(me: Player, socket: Node3D, y: float) -> Vector3:
	var look := me.get_look_direction().normalized()
	var from := socket.global_position + look * ItemManager.THROW_ORIGIN_FORWARD
	var v := look * Config.balance.throw_speed + Vector3.UP * ItemManager.THROW_UP
	var disc := v.y * v.y - 2.0 * GRAVITY * (y - from.y)
	if disc < 0.0:
		return Vector3.INF
	var t := (v.y + sqrt(disc)) / GRAVITY
	return from + v * t + Vector3.DOWN * (0.5 * GRAVITY * t * t)


## Turns `me` (yaw) and its head (pitch, between the two limits in degrees) so that predict() lands on `target`.
## Leaves the best pose it found on the body and returns its miss in metres (INF when no pitch reaches).
static func aim(me: Player, socket: Node3D, target: Vector3, min_pitch_deg: float = 30.0, max_pitch_deg: float = 80.0) -> float:
	var best := INF
	var best_yaw := me.rotation.y
	var best_pitch := me.head.rotation.x
	var here := me.global_position
	var want := Vector2(target.x - here.x, target.z - here.z)
	var deg := min_pitch_deg
	while deg <= max_pitch_deg:
		me.head.rotation.x = deg_to_rad(deg)
		me.look_at(Vector3(target.x, here.y, target.z), Vector3.UP)
		var p := Vector3.INF
		for i in 4:
			p = predict(me, socket, target.y)
			if p == Vector3.INF:
				break
			# The hand is off to one side: turn until the arc's foot lines up with the target.
			me.rotation.y -= Vector2(p.x - here.x, p.z - here.z).angle_to(want)
		p = predict(me, socket, target.y)
		if p != Vector3.INF:
			var miss := Vector2(p.x - target.x, p.z - target.z).length()
			if miss < best:
				best = miss
				best_yaw = me.rotation.y
				best_pitch = me.head.rotation.x
		deg += 0.25
	me.rotation = Vector3(0.0, best_yaw, 0.0)
	me.head.rotation.x = best_pitch
	return best
