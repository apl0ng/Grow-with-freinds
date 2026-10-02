class_name Hats
extends RefCounted
## Issued kit (M16 hats agent; FRIENDSLOP 10.2, CONTRACTS "M16 / Hats"). Static: a catalog of hats and the rule that
## issues them. Nothing is bought and nothing is a reward: a hat is issued by the player's own record (the Career
## autoload, `Career.get_record(key) >= threshold`), so the worst record has the most kit. The chosen hat is kept in
## the career file and is the second thing a peer sends (Net._rpc_set_hat); every peer shows it on that worker's body
## (Player.set_hat, a socket on the head of the body model). The locker in the alley (scenes/world/locker.tscn) is
## where a worker changes it.
##
## A catalog row:
##   id         StringName, a-z 0-9 _ (it is written to the career file and sent on the wire as a String)
##   name       what the locker and the toast call it, lower case, flat
##   line       what it is issued for, flat, no exclamation mark
##   key        the record it reads (a Career key: "shifts", "best_round", "backroom", "bitten", "burns", "shot", M17 finale: "cleared")
##   threshold  issued when the record is at least this
##   scene      the model (art/models/hat_<id>.glb, built by tools/blender/models/hats.py): a Toonify root authored in
##              the head socket's space (origin = where the stock hard hat sits, front on -Z)
## "No hat" (&"") is the worker as the model ships: the white hard hat a size too small, with the sprout. An issued
## hat replaces it (Player hides the stock one while another is worn).
##
## Copy: lower-case names, flat lines, no exclamation marks (the suite checks).

## The toast when the end of a shift issues one ("Issued: yellow hard hat. It is in your locker.").
const TEXT_ISSUED := "Issued: %s. It is in your locker."
## The pause menu's Record card ("Issued: 3 of 8").
const TEXT_RECORD := "Issued: %d of %d"
## Longest id (the career file's key rule; Net looks at no more than this).
const MAX_ID_LENGTH: int = 24
## Ink outline of a worn hat (the body model's own width, scenes/player/player.tscn).
const OUTLINE_WIDTH: float = 0.025

const CATALOG: Array[Dictionary] = [
	{"id": &"hairnet", "name": "hairnet", "line": "One shift worked.", "key": "shifts", "threshold": 1,
			"scene": "res://art/models/hat_hairnet.glb"},
	{"id": &"paper_cap", "name": "paper cap", "line": "Ten shifts worked.", "key": "shifts", "threshold": 10,
			"scene": "res://art/models/hat_paper_cap.glb"},
	{"id": &"hard_hat", "name": "yellow hard hat", "line": "Reached shift 3. This one has a lamp.", "key": "best_round", "threshold": 3,
			"scene": "res://art/models/hat_hard_hat.glb"},
	{"id": &"cone", "name": "traffic cone", "line": "Sent to the back room three times.", "key": "backroom", "threshold": 3,
			"scene": "res://art/models/hat_cone.glb"},
	{"id": &"bucket", "name": "bucket", "line": "Bitten five times.", "key": "bitten", "threshold": 5,
			"scene": "res://art/models/hat_bucket.glb"},
	{"id": &"welding_mask", "name": "welding mask", "line": "Five plants burnt.", "key": "burns", "threshold": 5,
			"scene": "res://art/models/hat_welding_mask.glb"},
	{"id": &"bandage", "name": "bandage", "line": "Shot three times.", "key": "shot", "threshold": 3,
			"scene": "res://art/models/hat_bandage.glb"},
	# --- M17 finale: the one hat a run's end issues (Career "cleared": the final notice paid while on the floor) ---
	{"id": &"eyeshade", "name": "green eyeshade", "line": "One debt cleared.", "key": "cleared", "threshold": 1,
			"scene": "res://art/models/hat_eyeshade.glb"},
	# --- end M17 finale ---
]

## id -> PackedScene (or null when the model is missing), loaded on first use.
static var _scenes: Dictionary = {}


## Every hat id, in catalog order (the order the locker goes round in).
static func ids() -> Array[StringName]:
	var out: Array[StringName] = []
	for row: Dictionary in CATALOG:
		out.append(row["id"] as StringName)
	return out


## How many hats there are.
static func count() -> int:
	return CATALOG.size()


## True for a catalog id (never for &"").
static func has(id: StringName) -> bool:
	for row: Dictionary in CATALOG:
		if (row["id"] as StringName) == id:
			return true
	return false


## The catalog row of `id` (a copy: id, name, line, key, threshold, scene), or {} for an unknown id.
static func get_def(id: StringName) -> Dictionary:
	for row: Dictionary in CATALOG:
		if (row["id"] as StringName) == id:
			return row.duplicate()
	return {}


## What the locker calls it ("" for an unknown id or none).
static func display_name(id: StringName) -> String:
	return String(get_def(id).get("name", ""))


## True for an id as it may travel or sit in a file: 1..MAX_ID_LENGTH characters and a catalog id. Constant cost for
## any input (the length is looked at before anything else).
static func is_wire_id(text: String) -> bool:
	if text.length() == 0 or text.length() > MAX_ID_LENGTH:
		return false
	return has(StringName(text))


## The hats `career`'s record has issued, in catalog order. `career` is anything with `get_record(key) -> int` (the
## Career autoload, a second reader of a career file, a test double); anything else has nothing issued.
static func issued_for(career: Object) -> Array[StringName]:
	var out: Array[StringName] = []
	if career == null or not is_instance_valid(career) or not career.has_method(&"get_record"):
		return out
	for row: Dictionary in CATALOG:
		if int(career.call(&"get_record", String(row["key"]))) >= int(row["threshold"]):
			out.append(row["id"] as StringName)
	return out


## The locker's round: none, then every issued hat in catalog order, then none again. `current` not in `issued`
## counts as none.
static func next_in(issued: Array[StringName], current: StringName) -> StringName:
	if issued.is_empty():
		return &""
	var at := issued.find(current)
	if at < 0:
		return issued[0]
	if at + 1 >= issued.size():
		return &""
	return issued[at + 1]


## The toast for a newly issued hat ("" for an unknown id).
static func issued_text(id: StringName) -> String:
	var hat_name := display_name(id)
	return TEXT_ISSUED % hat_name if hat_name != "" else ""


## The Record card's line for `career` ("Issued: 3 of 8").
static func record_text(career: Object) -> String:
	return TEXT_RECORD % [issued_for(career).size(), count()]


## The model of `id`, or null (unknown id, or the model is not in this build). Cached.
static func get_scene(id: StringName) -> PackedScene:
	if _scenes.has(id):
		return _scenes[id] as PackedScene
	var scene: PackedScene = null
	var path := String(get_def(id).get("scene", ""))
	if path != "" and ResourceLoader.exists(path, "PackedScene"):
		scene = load(path) as PackedScene
	_scenes[id] = scene
	return scene


## A fresh instance of the hat `id` for a head socket (a Toonify root named "Hat_<id>", with the ink outline), or
## null. The caller adds it to the tree and frees it.
static func make(id: StringName) -> Node3D:
	var scene := get_scene(id)
	if scene == null or not scene.can_instantiate():
		return null
	var node := scene.instantiate() as Node3D
	if node == null:
		return null
	node.name = "Hat_%s" % id
	if node is Toonify:
		(node as Toonify).outline_width = OUTLINE_WIDTH
	return node
