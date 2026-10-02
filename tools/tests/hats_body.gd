extends "res://tools/tests/qa_base.gd"
## M16 hats suite (hats agent): issued kit on a single headless host with one fake worker (Bob: a host-side body
## without an owning peer), the lobby and replay on.
##   godot --headless --path . -s res://tools/tests/run_test.gd -- --body=res://tools/tests/hats_body.gd --replay --lobby --career-file=user://hats_test.cfg --port=7987
## The run REFUSES to start without --career-file (it must never touch a real record) and removes its files at the end.
## Pins:
##   catalog    at least six hats, unique file-safe ids, every row complete, flat copy, a record key Career keeps;
##              issued exactly at each threshold; the worst record has every hat; the locker's round
##   models     one GLB per hat: a Toonify root with the ink outline, authored in the head socket's space (it covers
##              the seat of the stock hat and the head under it), within the budget, in the manifest; the body model
##              carries the stock hat as its own mesh and the socket; the locker's model and its door
##   the file   `hat=` under [career]: read, written, removed; an unknown id, one the record has not issued, junk and
##              a line outside [career] all read as none without an error line; the counts are untouched
##   worn       the host's hat reaches Net and its own body (shadow-only: the camera sits inside it); Bob's hat on
##              Bob's body, on the socket, following a crouch; a change frees the old model; none brings the stock
##              hard hat back; nobody is reparented
##   the locker where it stands (a free stretch of the west wall, clear of the spawns, the ball and the way to the
##              van), the interaction ray finds it, the prompt names what is on, E goes round the issued hats and back
##              to none, the door, the sound, the file; nothing issued; another worker's body cannot use it
##   the wire   junk ids are dropped and the old hat stays; "" takes it off; a synced list is checked again; the
##              budget: the locker jams when the host would take no more, and what is worn stays what is shown
##   issued     the end of a shift issues the paper cap once, with the toast; a second shift issues nothing
##   the card   "Issued: 4 of 7" on the pause menu's Record card, under the record's own lines
##   replay off nothing is sent or shown, the locker is locked, a hat is issued without a toast
## Every engine/script error fails the run unless announced (qa_base.gd).

const BOB := 2
const CAREER_SCRIPT := "res://scripts/core/career.gd"
const PLAYER_GLB := "res://art/models/player.glb"
const LOCKER_GLB := "res://art/models/locker.glb"
const MANIFEST := "res://art/models/manifest.json"
const MAX_TRIS := 2500
## The record this run starts from: nine shifts, three trips to the back room, bitten five times, the cone on.
const SEED := "[career]\nshifts=9\nbest_round=2\ndeposited=1000\ncontracts=0\nburns=0\nbitten=5\nshot=0\nbackroom=3\nhat=cone\n\n[strains]\npurple=4\n"


## Anything with get_record(): what Hats.issued_for reads.
class Record extends RefCounted:
	var values: Dictionary = {}

	func get_record(key: String) -> int:
		return int(values.get(key, 0))


class Nothing extends RefCounted:
	pass


var _port: int = 7987
var _path: String = ""
var _temp_files: PackedStringArray = []
var world: World
var lobby: Lobby
var locker: Locker
var me: Player
var bob: Player
var hud: HUD
var _issued: Array[StringName] = []
var _used: Array[StringName] = []
var _hat_signals: int = 0


func _run() -> void:
	_label = "hats"
	_port = port_arg(7987)
	await get_tree().process_frame
	get_tree().root.size = Vector2i(1280, 720)
	_path = str(Config.get_arg("career-file", ""))
	if not check(_path != "" and _path != Career.DEFAULT_PATH and Career.path == _path and Career.persistent,
			"this run has its own career file (%s)" % _path):
		finish(); return
	check(Config.replay_enabled and Config.lobby_enabled, "the suite runs with --replay --lobby")
	_remove(_path)
	Career.clear_record()
	Career.hat_issued.connect(func(id: StringName) -> void: _issued.append(id))
	Net.hats_changed.connect(func() -> void: _hat_signals += 1)

	_test_catalog()
	await _test_models()
	_test_file()
	if await _host("replay on"):
		await _test_locker_place()
		await _test_worn()
		await _test_locker_use()
		await _test_wire()
		await _leave()
		check(Net.hats.is_empty() and Net.get_player_hat(1) == &"", "the session's hats go with the session")
	if await _host("issue and budget"):
		await _test_issue()
		await _test_pause_menu()
		await _test_budget()
		await _leave()
		check(Net.hats.is_empty() and Career.get_hat_changes_left() == Net.MAX_HAT_CHANGES, "a new session starts with a full budget")
	Config.replay_enabled = false
	if await _host("replay off"):
		await _test_replay_off()
		await _leave()
	Config.replay_enabled = true
	_cleanup()
	finish()


func _host(tag: String) -> bool:
	step("hosting (%s)" % tag)
	Config.growth_speed_override = 0.0
	var b: BalanceConfig = Config.balance
	for s: SeedDef in b.seeds:
		s.mutation_chance = 0.0
	Game.start_host("Tester", _port)
	await wait_until(func() -> bool: return Game.world != null and Game.local_player != null, 5.0, "%s: world + local player exist" % tag)
	if Game.world == null or Game.local_player == null:
		return false
	world = Game.world
	lobby = world.lobby
	me = Game.local_player
	hud = world.get_node_or_null(^"HUD") as HUD
	locker = lobby.get_locker() if lobby != null else null
	Net.players[BOB] = {"name": "Bob", "color": Net.PALETTE[BOB - 1]}
	bob = world.server_spawn_player(BOB)
	Net.players_changed.emit()
	await wait_frames(3)
	if not check(lobby != null and locker != null and bob != null and hud != null, "%s: the alley, its locker, Bob and the HUD exist" % tag):
		return false
	_used.clear()
	locker.used.connect(func(id: StringName) -> void: _used.append(id))
	return true


func _leave() -> void:
	Game.return_to_menu()
	await wait_until(func() -> bool: return GameState.phase == GameState.Phase.MENU and Game.world == null, 5.0, "back in the menu")


# --- the catalog ------------------------------------------------------------------------------------------------------

func _test_catalog() -> void:
	step("catalog")
	var ids := Hats.ids()
	var unique: Dictionary = {}
	for id in ids:
		unique[id] = true
	check(ids.size() >= 6 and unique.size() == ids.size() and Hats.count() == ids.size(), "%d hats, every id once %s" % [ids.size(), ids])
	for id: StringName in [&"hairnet", &"paper_cap", &"hard_hat", &"cone", &"bucket", &"welding_mask"]:
		check(Hats.has(id), "the catalog has '%s'" % id)
	var rows_ok := true
	var copy_ok := true
	var keys_ok := true
	for id in ids:
		var row := Hats.get_def(id)
		for key: String in ["id", "name", "line", "key", "threshold", "scene"]:
			if not row.has(key):
				rows_ok = false
		if row.get("id") != id or int(row.get("threshold", 0)) < 1:
			rows_ok = false
		var text := String(id)
		if not Career._is_key(text) or text.length() > Hats.MAX_ID_LENGTH or not Hats.is_wire_id(text):
			rows_ok = false
		var hat_name := String(row.get("name", ""))
		var line := String(row.get("line", ""))
		if hat_name == "" or hat_name != hat_name.to_lower() or hat_name != hat_name.strip_edges() or hat_name.contains("!") or Hats.display_name(id) != hat_name:
			copy_ok = false
		if line == "" or line.contains("!") or not line.ends_with(".") or line != line.strip_edges():
			copy_ok = false
		if not Career.KEYS.has(String(row.get("key", ""))):
			keys_ok = false
		if String(row.get("scene", "")) != "res://art/models/hat_%s.glb" % id:
			rows_ok = false
	check(rows_ok, "every row has id, name, line, key, threshold >= 1 and its own model; every id is file-safe")
	check(copy_ok, "names in lower case, flat lines that end with a full stop, no exclamation mark")
	check(keys_ok, "every hat reads a record the career file keeps")
	check(Hats.get_def(&"crown").is_empty() and not Hats.has(&"crown") and not Hats.has(&"") and Hats.display_name(&"") == "", "an unknown id is nothing; neither is none")
	check(not Hats.is_wire_id("") and not Hats.is_wire_id("CONE") and not Hats.is_wire_id("cone ") and not Hats.is_wire_id("x".repeat(5000)) and Hats.is_wire_id("cone"),
			"is_wire_id: a catalog id, exactly")
	check(not Hats.TEXT_ISSUED.contains("!") and not Hats.TEXT_RECORD.contains("!"), "toast and card copy without an exclamation mark")
	check(Hats.issued_text(&"hard_hat") == "Issued: yellow hard hat. It is in your locker." and Hats.issued_text(&"crown") == "", "the toast: '%s'" % Hats.issued_text(&"hard_hat"))
	var edited := Hats.get_def(&"cone")
	edited["threshold"] = 0
	check(int(Hats.get_def(&"cone")["threshold"]) == 3, "get_def hands out a copy")

	step("catalog: issued from the record")
	var rec := Record.new()
	check(Hats.issued_for(rec).is_empty() and Hats.issued_for(null).is_empty() and Hats.issued_for(Nothing.new()).is_empty(), "an empty record, no record and something that is not a record: nothing issued")
	var edges_ok := true
	for id in ids:
		var row := Hats.get_def(id)
		var key := String(row["key"])
		var at := int(row["threshold"])
		rec.values = {key: at - 1}
		if Hats.issued_for(rec).has(id):
			edges_ok = false
		rec.values = {key: at}
		if not Hats.issued_for(rec).has(id):
			edges_ok = false
	check(edges_ok, "every hat is issued at its threshold and not one short of it")
	rec.values = {"shifts": 1}
	check(_same(Hats.issued_for(rec), [&"hairnet"]), "one shift worked: the hairnet")
	rec.values = {"shifts": 10, "best_round": 3}
	check(_same(Hats.issued_for(rec), [&"hairnet", &"paper_cap", &"hard_hat"]), "ten shifts and shift 3: hairnet, paper cap, hard hat (catalog order)")
	rec.values = {"shifts": 2, "backroom": 3, "bitten": 5, "burns": 5}
	check(_same(Hats.issued_for(rec), [&"hairnet", &"cone", &"bucket", &"welding_mask"]), "trouble is kit: cone, bucket, welding mask")
	var clean := Record.new()
	clean.values = {"shifts": 40, "best_round": 6, "deposited": 90000, "contracts": 30}
	rec.values = {"shifts": 40, "best_round": 6, "backroom": 9, "bitten": 9, "burns": 9, "shot": 9}
	check(Hats.issued_for(rec).size() == ids.size() and Hats.issued_for(clean).size() < ids.size(), "the worst record has the most kit (%d against %d)" % [Hats.issued_for(rec).size(), Hats.issued_for(clean).size()])
	check(Hats.record_text(rec) == "Issued: %d of %d" % [ids.size(), ids.size()] and Hats.record_text(Record.new()) == "Issued: 0 of %d" % ids.size(), "the card's line: '%s'" % Hats.record_text(rec))

	step("catalog: the locker's round")
	var three: Array[StringName] = [&"hairnet", &"cone", &"bucket"]
	var none: Array[StringName] = []
	check(Hats.next_in(three, &"") == &"hairnet" and Hats.next_in(three, &"hairnet") == &"cone" and Hats.next_in(three, &"cone") == &"bucket" and Hats.next_in(three, &"bucket") == &"",
			"none, hairnet, cone, bucket, none")
	check(Hats.next_in(three, &"paper_cap") == &"hairnet" and Hats.next_in(none, &"") == &"" and Hats.next_in(none, &"cone") == &"", "a hat that is not issued counts as none; nothing issued stays none")


# --- the models -------------------------------------------------------------------------------------------------------

func _test_models() -> void:
	step("models: one per hat")
	var holder := Node3D.new()
	holder.name = "Models"
	add_child(holder)
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(MANIFEST))
	var manifest: Dictionary = parsed if parsed is Dictionary else {}
	for id in Hats.ids():
		var hat := Hats.make(id)
		if not check(hat != null, "%s: the model loads" % id):
			continue
		holder.add_child(hat)
		await wait_frames(1)
		check(hat is Toonify and hat.name == "Hat_%s" % id and (hat as Toonify).outline_width > 0.0 and _has_outline(hat), "%s: a Toonify root named Hat_%s, with the ink outline" % [id, id])
		var box := _mesh_box(hat)
		check(box.position.x <= -0.29 and box.end.x >= 0.29 and box.position.z <= -0.29 and box.end.z >= 0.29 and box.end.y >= 0.25,
				"%s: covers the stock hat's seat and the head under it (%s)" % [id, box])
		check(box.position.y <= 0.0 and box.position.y > -0.3 and box.size.x < 0.9 and box.size.z < 0.9 and box.size.y < 0.65, "%s: sits on the socket, head sized (%s)" % [id, box.size])
		var tris := _tris(hat)
		check(tris > 300 and tris <= MAX_TRIS, "%s: %d tris (<= %d)" % [id, tris, MAX_TRIS])
		var info: Dictionary = manifest.get("hat_%s" % id, {})
		check(String(info.get("kind", "")) == "item" and String(info.get("mount", "")) == "free" and String(info.get("front", "")) == "-z" and String(info.get("script", "")).ends_with("hats.py"),
				"%s: in the manifest (item, free mount, front -Z, hats.py)" % id)
		check(Hats.get_scene(id) == Hats.get_scene(id) and Hats.get_scene(id) != null, "%s: the scene is loaded once" % id)
		hat.queue_free()
	check(Hats.make(&"crown") == null and Hats.make(&"") == null and Hats.get_scene(&"crown") == null, "no model for an unknown id or for none")

	step("models: the body carries the stock hat and the socket")
	var body := (load(PLAYER_GLB) as PackedScene).instantiate() as Node3D
	holder.add_child(body)
	await wait_frames(1)
	var stock := body.get_node_or_null(^"Hat") as MeshInstance3D
	var socket := body.get_node_or_null(^"HatSocket") as Node3D
	if check(stock != null and socket != null and not (socket is MeshInstance3D), "player.glb has the mesh Hat and the empty HatSocket"):
		var want := Player.HAT_SOCKET_FALLBACK
		var same := socket.transform.origin.distance_to(want.origin) < 0.002
		for axis in 3:
			if socket.transform.basis[axis].distance_to(want.basis[axis]) > 0.002:
				same = false
		check(same, "the socket is where player.py says (Player.HAT_SOCKET_FALLBACK): %s" % socket.transform)
		check(socket.transform.basis.get_scale().distance_to(Vector3.ONE) < 0.001 and socket.transform.origin.y > 1.45 and socket.transform.origin.y < 1.6, "unscaled, on top of the head (y %.3f)" % socket.transform.origin.y)
		var seat := _points_box(stock.mesh.get_faces(), socket.transform.affine_inverse() * stock.transform)
		check(seat.position.y > -0.08 and seat.position.y < 0.0 and seat.size.x > 0.6 and seat.size.x < 0.8 and absf(seat.get_center().x) < 0.08,
				"the stock hat sits on the socket (in its space: %s)" % seat)
		var trunk := body.get_node_or_null(^"Body") as MeshInstance3D
		check(trunk != null and trunk.get_aabb().end.y < 1.8 and trunk.get_aabb().end.y > 1.65, "the body mesh ends at the head now (%.2f)" % (trunk.get_aabb().end.y if trunk != null else 0.0))
		check(_mesh_box(body).end.y > 1.8, "with its hat the model is as tall as it was (%.2f)" % _mesh_box(body).end.y)
	body.queue_free()

	step("models: the locker")
	var model := (load(LOCKER_GLB) as PackedScene).instantiate() as Node3D
	holder.add_child(model)
	await wait_frames(1)
	var door := model.get_node_or_null(^"Door") as MeshInstance3D
	check(model is Toonify and model.get_node_or_null(^"Body") is MeshInstance3D and door != null, "locker.glb: a Toonify root with Body and Door")
	var lbox := _mesh_box(model)
	check(absf(lbox.position.y) < 0.01 and lbox.size.y > 1.8 and lbox.size.y < 1.95 and lbox.size.x > 0.8 and lbox.size.x < 0.95 and lbox.size.z > 0.45 and lbox.size.z < 0.62,
			"a locker's size, standing on its origin (%s)" % lbox.size)
	if door != null:
		check(door.rotation.is_zero_approx() and door.position.x > 0.35 and door.position.z > 0.2, "the door: rest shut, pivot on the right-hand front edge %s" % door.position)
		var edge := door.get_aabb().position.x
		check(edge < -0.3 and (Basis(Vector3.UP, deg_to_rad(40.0)) * Vector3(edge, 0.0, 0.0)).z > 0.15, "turning it + about Y swings its free edge out, towards the front")
	var tinted := 0
	for n in model.find_children("*", "MeshInstance3D", true, false):
		var mi := n as MeshInstance3D
		for s in mi.mesh.get_surface_count():
			if Toonify.is_tint(mi.mesh.surface_get_material(s)):
				tinted += 1
	check(tinted >= 2, "its paint is a TINT (the scene gives the colour): %d surfaces" % tinted)
	holder.queue_free()
	await wait_frames(1)
	var clip := Sfx.get_stream(&"locker")
	check(Sfx.has_sound(&"locker") and clip != null and Sfx.measure(clip).seconds > 0.3, "the sound 'locker' has a recipe of its own (%.2f s)" % (Sfx.measure(clip).seconds if clip != null else 0.0))


# --- the career file --------------------------------------------------------------------------------------------------

func _test_file() -> void:
	step("career file: the hat line")
	check(Career.get_hat() == &"" and Career.get_issued_hats().is_empty(), "the autoload starts with nothing issued and nothing on")
	check(not Career.set_hat(&"hairnet") and Career.set_hat(&"") and Career.get_hat() == &"", "set_hat: not a hat the record has not issued; none is always allowed")
	var long_line := "[career]\nshifts=9\nbackroom=3\nhat=" + "x".repeat(4000) + "\n"
	var cases: Array = [
		[SEED, &"cone", "the hat on file, issued by the record"],
		["[career]\nhat=cone\nshifts=9\nbackroom=3\n", &"cone", "the hat line before the counts"],
		[SEED.replace("\n", "\r\n"), &"cone", "CRLF line ends"],
		["[career]\nshifts=9\nbackroom=2\nhat=cone\n", &"", "a hat the record has not issued reads as none"],
		["[career]\nshifts=9\nbackroom=3\nhat=crown\n", &"", "an unknown id reads as none"],
		["[career]\nshifts=9\nbackroom=3\nhat=CONE\n", &"", "the wrong case is not the id"],
		[long_line, &"", "four thousand characters"],
		["[career]\nshifts=9\nbackroom=3\nhat=\n", &"", "an empty value"],
		["[career]\nshifts=9\nbackroom=3\nhat=cone bucket\n", &"", "two words"],
		["[career]\nshifts=9\nbackroom=3\nhat=3\n", &"", "a count where a hat goes"],
		["[career]\nshifts=9\nbackroom=3\n\n[strains]\nhat=cone\n", &"", "a hat line outside [career]"],
		["[career]\nshifts=9\nbackroom=3\nhat=cone\nhat=crown\n", &"", "the last line wins"],
		["[career]\nshifts=9\nbackroom=3\n", &"", "an M15 file: no hat line"],
	]
	for c: Array in cases:
		var p := _temp("case")
		_write_text(p, String(c[0]))
		var reader := _reader()
		var read: bool = reader.load_file(p)
		check(read and reader.get_hat() == (c[1] as StringName) and reader.get_record("shifts") == 9 and reader.get_record("hat") == 0 and reader.get_strain_deposits().get("hat", 0) == 0,
				"%s: '%s', the counts as written" % [c[2], reader.get_hat()])
		reader.free()

	step("career file: written")
	var p := _temp("write")
	_write_text(p, SEED)
	var writer := _reader()
	writer.path = p
	writer.persistent = true
	var changes: Array = [0]
	writer.changed.connect(func() -> void: changes[0] += 1)
	writer.load_file(p)
	changes[0] = 0
	check(_same(writer.get_issued_hats(), [&"hairnet", &"cone", &"bucket"]) and writer.get_hat() == &"cone", "the seed: hairnet, cone and bucket issued, the cone on")
	check(writer.set_hat(&"bucket") and writer.get_hat() == &"bucket" and changes[0] == 1, "set_hat(bucket): taken, `changed` once")
	var text := FileAccess.get_file_as_string(p)
	check(text.contains("\nhat=bucket\n") and text.find("hat=bucket") < text.find("[strains]") and not FileAccess.file_exists(p + ".tmp"), "the file has hat=bucket under [career]")
	var second := _reader()
	check(second.load_file(p) and second.get_hat() == &"bucket" and second.get_record("shifts") == 9 and second.get_record("bitten") == 5 and second.get_record("purple") == 4
			and second.get_summary_lines() == writer.get_summary_lines(), "a second reader sees the bucket and the same record")
	check(writer.set_hat(&"bucket") and changes[0] == 1, "the same hat again: fine, nothing is written twice")
	check(not writer.set_hat(&"hard_hat") and not writer.set_hat(&"crown") and writer.get_hat() == &"bucket" and changes[0] == 1, "a hat that is not issued and an unknown id are refused: the bucket stays")
	check(writer.set_hat(&"") and writer.get_hat() == &"" and not FileAccess.get_file_as_string(p).contains("hat="), "taken off: the line is gone from the file")
	check(second.load_file(p) and second.get_hat() == &"" and second.get_record("backroom") == 3, "and a reader sees none")
	check(writer.get_hat_changes_left() == Net.MAX_HAT_CHANGES and writer.can_change_hat(), "outside a session there is no budget to run out of")
	writer.free()
	second.free()


# --- the locker: where it stands --------------------------------------------------------------------------------------

func _test_locker_place() -> void:
	step("the locker: where it stands")
	check(GameState.phase == GameState.Phase.WAITING and lobby.is_in_use() and locker.is_visible_in_tree(), "WAITING in the alley, the locker is drawn")
	check(locker is Interactable and locker.is_in_group(Const.GROUP_INTERACTABLES) and locker.get_parent() == lobby, "an Interactable, a child of the Lobby")
	var at := lobby.to_local(locker.global_position)
	check(at.distance_to(Vector3(-4.7, 0.0, 0.1)) < 0.01, "at (-4.7, 0, 0.1) in the alley's own space (%s; world %s)" % [at, locker.global_position])
	check(locker.global_transform.basis.z.normalized().distance_to(lobby.global_transform.basis.x.normalized()) < 0.01, "its doors face east, into the alley")
	var body := locker.get_node_or_null(^"Collider") as StaticBody3D
	check(body != null and body.collision_layer == (Const.LAYER_WORLD | Const.LAYER_INTERACTABLE) and body.collision_mask == 0, "one collider: solid, and what the interaction ray hits")
	var box := _mesh_box_in(locker.get_node(^"Visual") as Node3D, lobby)
	check(box.position.x > -5.0 and box.position.x < -4.9 and box.end.x < -4.3 and box.position.y > -0.01 and box.end.y < 2.0, "its back on the west wall (x %.2f .. %.2f)" % [box.position.x, box.end.x])
	check(box.position.z > -1.1 and box.end.z < 1.1, "between the lamp's pole (z -1.4) and the first bin (z 1.2): z %.2f .. %.2f" % [box.position.z, box.end.z])
	var near_spawn := INF
	for spot in lobby.get_spawn_points():
		near_spawn = minf(near_spawn, _flat(spot.global_position).distance_to(_flat(locker.global_position)))
	check(near_spawn > 4.0, "clear of every spawn (%.1f m)" % near_spawn)
	check(_flat(lobby.get_ball_spot()).distance_to(_flat(locker.global_position)) > 2.5, "clear of the ball's spot (%.1f m)" % _flat(lobby.get_ball_spot()).distance_to(_flat(locker.global_position)))
	var van := lobby.get_van()
	var cargo := van.get_cargo_aabb()
	check(_flat(cargo.get_center()).distance_to(_flat(locker.global_position)) > 4.0, "clear of the van (%.1f m from its cargo bay)" % _flat(cargo.get_center()).distance_to(_flat(locker.global_position)))
	var space := world.get_world_3d().direct_space_state
	var sill := cargo.get_center()
	sill.z = cargo.end.z + 0.4
	var crossed := 0
	var lanes: Array = []
	for spot in lobby.get_spawn_points():
		lanes.append([spot.global_position + Vector3.UP, Vector3(sill.x, spot.global_position.y + 1.0, sill.z)])
	var hoop := lobby.get_hoop()
	lanes.append([lobby.get_ball_spot() + Vector3.UP * 1.4, hoop.global_position])
	for lane: Array in lanes:
		var hit := space.intersect_ray(PhysicsRayQueryParameters3D.create(lane[0], lane[1], Const.LAYER_WORLD))
		if not hit.is_empty() and hit["collider"] == body:
			crossed += 1
	check(crossed == 0, "the way from every spawn to the van's doors and from the ball to the hoop does not cross it")
	var probe := SphereShape3D.new()
	probe.radius = 0.38
	var params := PhysicsShapeQueryParameters3D.new()
	params.shape = probe
	params.transform = Transform3D(Basis.IDENTITY, locker.global_position + locker.global_transform.basis.z.normalized() * 1.0 + Vector3.UP * 0.9)
	params.collision_mask = Const.LAYER_WORLD
	check(space.intersect_shape(params, 4).is_empty(), "there is room to stand in front of it")

	step("the locker: the interaction ray")
	stand_near(locker, 1.4)
	await get_tree().physics_frame
	await get_tree().physics_frame
	me.get_interactor().refresh()
	check(me.get_interactor().current_target == locker, "a worker standing in front of it has it under the crosshair")
	check(me.get_interactor().prompt_text == "Locker · nothing issued" and not me.get_interactor().prompt_enabled, "an empty record: '%s', greyed out" % me.get_interactor().prompt_text)
	var t := toasts.size()
	locker.interact(me)
	check(_used.is_empty() and Career.get_hat() == &"" and toasts.size() == t, "E does nothing, and says nothing")


# --- worn -------------------------------------------------------------------------------------------------------------

func _test_worn() -> void:
	step("worn: the host's own hat")
	var stock_me := me.get_node_or_null(Player.STOCK_HAT_PATH) as Node3D
	check(me.get_hat() == &"" and me.get_hat_node() == null and stock_me != null and stock_me.visible, "nothing issued: the stock hard hat")
	check(me.get_hat_socket() == me.get_node_or_null(Player.HAT_SOCKET_PATH) and me.get_hat_socket() != null, "the socket is the body model's HatSocket")
	_write_text(_path, SEED)
	_hat_signals = 0
	Career.load_file(_path)
	await wait_frames(1)
	check(_same(Career.get_issued_hats(), [&"hairnet", &"cone", &"bucket"]) and Career.get_hat() == &"cone", "the record on file: hairnet, cone, bucket; the cone on")
	check(Net.get_player_hat(1) == &"cone" and Net.hats == {1: "cone"} and _hat_signals == 1, "Career handed it to the host: Net.hats %s, hats_changed once" % [Net.hats])
	var hat := me.get_hat_node()
	check(me.get_hat() == &"cone" and hat != null and hat.name == "Hat_cone" and hat.get_parent() == me.get_hat_socket() and hat.transform.is_equal_approx(Transform3D.IDENTITY),
			"the host's body wears it, on the socket")
	check(not stock_me.visible, "the stock hard hat is hidden while it does")
	var shown := 0
	var total := 0
	for n in me.get_node(^"Visual").find_children("*", "GeometryInstance3D", true, false):
		total += 1
		if (n as GeometryInstance3D).cast_shadow != GeometryInstance3D.SHADOW_CASTING_SETTING_SHADOWS_ONLY:
			shown += 1
	check(shown == 0 and total > 12, "the local worker's own hat is shadow-only like the rest of the body: the camera sits inside it (%d meshes)" % total)

	step("worn: Bob")
	var parent := bob.get_parent()
	Net._rpc_hats_sync({1: "cone", BOB: "bucket"})
	await wait_frames(1)
	var bucket := bob.get_hat_node()
	if not check(Net.get_player_hat(BOB) == &"bucket" and bob.get_hat() == &"bucket" and bucket != null and bucket.name == "Hat_bucket", "Bob wears the bucket"):
		return
	check(bucket.get_parent() == bob.get_node_or_null(Player.HAT_SOCKET_PATH) and not (bob.get_node(Player.STOCK_HAT_PATH) as Node3D).visible, "on his head socket, his stock hat hidden")
	var visible_meshes := 0
	for n in bucket.find_children("*", "MeshInstance3D", true, false):
		var mi := n as MeshInstance3D
		if not mi.has_meta(&"toonify_outline") and mi.cast_shadow != GeometryInstance3D.SHADOW_CASTING_SETTING_SHADOWS_ONLY and mi.is_visible_in_tree():
			visible_meshes += 1
	check(visible_meshes >= 1 and _has_outline(bucket), "everyone else sees it, with its outline")
	var up := bucket.global_position
	check(up.y - bob.global_position.y > 1.4 and up.y - bob.global_position.y < 1.65 and _flat(up).distance_to(_flat(bob.global_position)) < 0.25,
			"it sits on top of his head (%.2f m up)" % (up.y - bob.global_position.y))
	bob.crouching = true
	await wait_sec(0.5)
	var down := bucket.global_position
	check(down.y < up.y - 0.35, "he crouches: the hat goes down with the head (%.2f -> %.2f)" % [up.y - bob.global_position.y, down.y - bob.global_position.y])
	bob.crouching = false
	await wait_sec(0.5)
	check(absf(bucket.global_position.y - bob.global_position.y - (up.y - bob.global_position.y)) < 0.12, "and comes back up")
	Juice.bounce(bob.visual, 0.25)
	await wait_frames(2)
	check(bucket.get_parent() == bob.get_node_or_null(Player.HAT_SOCKET_PATH) and bucket.is_visible_in_tree(), "a stumble's bounce moves the body, the hat stays on")

	step("worn: a change frees the old one")
	Net._rpc_hats_sync({1: "cone", BOB: "hairnet"})
	var hairnet := bob.get_hat_node()
	check(bob.get_hat() == &"hairnet" and hairnet != null and hairnet != bucket and hairnet.name == "Hat_hairnet", "Bob wears the hairnet now")
	var face := bob.get_node(^"Visual/Face") as Node3D
	check(_global_box(hairnet).position.y > face.global_position.y + 0.05, "above the face (the hat%ss lowest point %.2f, the face %.2f)" % ["'", _global_box(hairnet).position.y, face.global_position.y])
	check(bucket.get_parent() == null and bucket.is_queued_for_deletion() and bob.get_hat_socket().get_child_count() == 1, "the bucket is out of the tree and freed; one hat on the socket")
	await wait_frames(2)
	check(not is_instance_valid(bucket), "gone")
	Net._rpc_hats_sync({1: "cone", BOB: "crown"})
	check(Net.get_player_hat(BOB) == &"" and bob.get_hat() == &"" and bob.get_hat_node() == null and (bob.get_node(Player.STOCK_HAT_PATH) as Node3D).visible,
			"an id that is not in the catalog is not kept: Bob is back in the stock hard hat")
	check(bob.get_hat_socket().get_child_count() == 0 and me.get_hat() == &"cone", "nothing left on his socket; the host still wears the cone")
	bob.set_hat(&"welding_mask")
	check(bob.get_hat() == &"welding_mask" and bob.get_hat_node() != null, "Player.set_hat shows a hat on that body")
	bob.set_hat(&"cone")
	var label := bob.get_node(^"%NameLabel") as Node3D
	var tip := _global_box(bob.get_hat_node()).end.y - bob.global_position.y
	check(label.position.y > Player.STAND_LABEL_Y + 0.1 and label.position.y > tip + 0.15, "the name label clears the cone (the tip %.2f m up, the label %.2f)" % [tip, label.position.y])
	bob.set_hat(&"paper_cap")
	check(is_equal_approx(label.position.y, Player.STAND_LABEL_Y), "and is where it always was over a hat that leaves it room")
	bob.set_hat(&"crown")
	check(bob.get_hat() == &"" and bob.get_hat_node() == null, "and an unknown id shows none")
	check(bob.get_parent() == parent and me.get_parent() == parent, "nobody was reparented")
	Net._rpc_hats_sync({1: "cone"})


# --- the locker: using it ---------------------------------------------------------------------------------------------

func _test_locker_use() -> void:
	step("the locker: round the issued hats")
	check(locker.get_prompt(me) == "Locker · traffic cone" and locker.can_interact(me), "'%s'" % locker.get_prompt(me))
	var door := locker.get_door()
	check(door != null and absf(door.rotation.y - deg_to_rad(Locker.DOOR_AJAR_DEG)) < 0.001, "the door hangs ajar")
	var want: Array[StringName] = [&"bucket", &"", &"hairnet", &"cone"]
	var prompts: Array[String] = ["Locker · bucket", "Locker · no hat", "Locker · hairnet", "Locker · traffic cone"]
	_used.clear()
	var round_ok := true
	for i in want.size():
		await wait_sec(0.06) # the sound's own retrigger guard
		locker.interact(me)
		if Career.get_hat() != want[i] or Net.get_player_hat(1) != want[i] or me.get_hat() != want[i] or locker.get_prompt(me) != prompts[i]:
			round_ok = false
			print("      step %d: career '%s', net '%s', body '%s', prompt '%s'" % [i, Career.get_hat(), Net.get_player_hat(1), me.get_hat(), locker.get_prompt(me)])
		if i == 0:
			var voice := Sfx.get_last_voice() as AudioStreamPlayer3D
			check(voice != null and voice.stream == Sfx.get_stream(&"locker") and voice.global_position.distance_to(locker.global_position + Vector3.UP * Locker.SOUND_HEIGHT) < 0.01,
					"the sound 'locker' at the door")
			await wait_sec(0.1)
			check(door.rotation.y > deg_to_rad(Locker.DOOR_AJAR_DEG) + 0.1, "the door swings out (%.0f deg)" % rad_to_deg(door.rotation.y))
			var reader := _reader()
			check(reader.load_file(_path) and reader.get_hat() == &"bucket", "the file has the bucket at once")
			reader.free()
		if i == 1:
			check((me.get_node(Player.STOCK_HAT_PATH) as Node3D).visible and me.get_hat_node() == null and not Net.hats.has(1), "none: the stock hard hat is back, no entry on the wire")
	check(round_ok and _used == want, "E goes bucket, none, hairnet, cone: Career, Net, the body and the prompt agree every time %s" % [_used])
	me.get_interactor().refresh()
	check(me.get_interactor().prompt_text == "Locker · traffic cone" and me.get_interactor().prompt_enabled, "the HUD prompt: '%s'" % me.get_interactor().prompt_text)
	await wait_sec(0.6)
	check(absf(door.rotation.y - deg_to_rad(Locker.DOOR_AJAR_DEG)) < 0.01, "the door has fallen back")
	check(locker.use() == &"bucket" and Career.get_hat() == &"bucket", "use() returns what is on now")

	step("the locker: only for the worker who stands there")
	_used.clear()
	locker.interact(bob)
	locker.interact(null)
	check(_used.is_empty() and Career.get_hat() == &"bucket", "another worker's body (not the local one) cannot use it")
	check(locker.has_method(&"_server_interact") and Net.get_player_hat(BOB) == &"", "nothing reaches Bob's head")

	step("the locker: nothing issued")
	Career.clear_record()
	await wait_frames(1)
	check(Career.get_hat() == &"" and Net.get_player_hat(1) == &"" and me.get_hat() == &"", "an empty record: the hat is off, for everyone")
	var t := toasts.size()
	check(locker.get_prompt(me) == "Locker · nothing issued" and not locker.can_interact(me) and locker.get_denied_reason(me) == "", "'%s'" % locker.get_prompt(me))
	locker.interact(me)
	check(_used.is_empty() and Career.get_hat() == &"" and toasts.size() == t and locker.use() == &"", "E and use() do nothing")
	Career.load_file(_path)
	await wait_frames(1)
	check(Career.get_hat() == &"bucket" and Net.get_player_hat(1) == &"bucket" and me.get_hat() == &"bucket", "the record read again: the bucket is back on")


# --- the wire ---------------------------------------------------------------------------------------------------------

func _test_wire() -> void:
	step("the wire: what the host takes")
	_hat_signals = 0
	var junk: Array[String] = ["x".repeat(5000), "CONE", "cone ", " cone", "cone\n", "crown", "hat_cone", "res://art/models/hat_cone.glb", "[b]cone[/b]", "0"]
	for text in junk:
		Net._rpc_set_hat(text)
	check(Net.get_player_hat(1) == &"bucket" and _hat_signals == 0 and me.get_hat() == &"bucket", "%d strings that are not a catalog id are dropped: the bucket stays" % junk.size())
	Net._rpc_set_hat("bucket")
	check(_hat_signals == 0, "the same hat again is not sent round")
	Net._rpc_set_hat("welding_mask")
	check(Net.get_player_hat(1) == &"welding_mask" and _hat_signals == 1 and me.get_hat() == &"welding_mask", "any catalog id is taken (the host cannot see the record): the welding mask")
	Net._rpc_set_hat("")
	check(Net.get_player_hat(1) == &"" and not Net.hats.has(1) and _hat_signals == 2 and me.get_hat() == &"", "\"\" takes it off")
	Net._rpc_set_hat("")
	check(_hat_signals == 2, "none again is not sent round")
	Net._rpc_set_hat("bucket")
	check(Net.get_player_hat(1) == Career.get_hat() and _hat_signals == 3, "back to what the host's own record says")

	step("the wire: a synced list is checked again")
	Net._rpc_hats_sync({1: "bucket", BOB: "hairnet", 7: "cone", "x": "cone", 9: 4, 2.0: "cone", 11: "CONE", 12: "x".repeat(5000)})
	check(Net.get_player_hat(1) == &"bucket" and Net.get_player_hat(BOB) == &"cone" and Net.get_player_hat(7) == &"" and Net.get_player_hat(9) == &"" and Net.get_player_hat(11) == &"",
			"catalog ids of registered workers only (Bob: '%s')" % Net.get_player_hat(BOB))
	var kept_ok := true
	for k: Variant in Net.hats:
		if not (k is int) or not (Net.hats[k] is String) or not Hats.is_wire_id(Net.hats[k]):
			kept_ok = false
	check(kept_ok and not Net.hats.has(9) and not Net.hats.has(11) and not Net.hats.has(12), "what is kept: int peer -> catalog id %s" % [Net.hats])
	check(bob.get_hat() == &"cone" and me.get_hat() == &"bucket", "and the bodies follow")
	var many := {}
	for i in 200:
		many[100 + i] = "cone"
	Net._rpc_hats_sync(many)
	check(Net.hats.size() <= Net.MAX_HATS_SYNCED, "a list of 200 is cut at %d" % Net.MAX_HATS_SYNCED)
	Net._rpc_hats_sync({1: "bucket"})
	check(bob.get_hat() == &"" and me.get_hat() == &"bucket", "the list as it should be again")
	Net.server_send_hats(BOB)
	Net.server_send_hats(1)
	Net.server_send_hats(999)
	await wait_frames(1)
	check(true, "server_send_hats to a peer that is not connected, or to the host itself, sends nothing")


# --- issued at the end of a shift -------------------------------------------------------------------------------------

func _test_issue() -> void:
	step("issued: the end of the tenth shift")
	var b: BalanceConfig = Config.balance
	_write_text(_path, SEED)
	Career.load_file(_path)
	await wait_frames(1)
	check(Career.get_record("shifts") == 9 and Career.get_hat() == &"cone" and Net.get_player_hat(1) == &"cone" and me.get_hat() == &"cone", "nine shifts on file, the cone on (sent when the session began)")
	_issued.clear()
	var t := toasts.size()
	if not await _play_shift(b, true):
		return
	check(Career.get_record("shifts") == 10 and _same(_issued, [&"paper_cap"]), "ten shifts worked: hat_issued(paper_cap), once %s" % [_issued])
	var said := 0
	for i in range(t, toasts.size()):
		if String(toasts[i][0]) == "Issued: paper cap. It is in your locker.":
			said += 1
		elif String(toasts[i][0]).begins_with("Issued"):
			said += 10
	check(said == 1, "the toast, once: 'Issued: paper cap. It is in your locker.'")
	check(_same(Career.get_issued_hats(), [&"hairnet", &"paper_cap", &"cone", &"bucket"]) and Career.get_hat() == &"cone" and me.get_hat() == &"cone", "it is in the locker; nobody put it on for him")
	var reader := _reader()
	check(reader.load_file(_path) and reader.get_issued_hats() == Career.get_issued_hats() and reader.get_hat() == &"cone", "the file agrees")
	reader.free()
	GameState.request_next_round()
	await wait_until(func() -> bool: return GameState.phase == GameState.Phase.WAITING, b.transition_fade_sec + 1.5, "NEXT SHIFT: WAITING in the alley")
	await wait_frames(3)
	_used.clear()
	locker.interact(me)
	check(_same(_used, [&"bucket"]), "the round goes on from the cone")
	Career.set_hat(&"hairnet")
	locker.interact(me)
	check(Career.get_hat() == &"paper_cap" and me.get_hat() == &"paper_cap" and locker.get_prompt(me) == "Locker · paper cap", "after the hairnet comes the paper cap now")

	step("issued: the next shift issues nothing")
	t = toasts.size()
	if not await _play_shift(b, true):
		return
	var again := false
	for i in range(t, toasts.size()):
		if String(toasts[i][0]).begins_with("Issued"):
			again = true
	check(Career.get_record("shifts") == 11 and _issued.size() == 1 and not again, "eleven shifts: no signal, no toast")
	GameState.request_next_round()
	await wait_until(func() -> bool: return GameState.phase == GameState.Phase.WAITING, b.transition_fade_sec + 1.5, "back in the alley")
	await wait_frames(3)


## One shift from the alley: the ride, the payment made (or not), the end.
func _play_shift(b: BalanceConfig, paid: bool) -> bool:
	GameState.request_start_round()
	if not await wait_until(func() -> bool: return GameState.is_playing(), b.transition_fade_sec + 2.5, "the shift runs"):
		return false
	if paid:
		GameState.server_add_sale(GameState.quota + 15, 1)
	if not GameState.is_round_over():
		GameState.time_left = 0.01
	var want: int = GameState.Phase.ROUND_SUCCESS if paid else GameState.Phase.ROUND_FAILED
	var ok := await wait_until(func() -> bool: return GameState.phase == want, 3.0, "the shift ends")
	await wait_frames(3)
	return ok


# --- the pause menu ---------------------------------------------------------------------------------------------------

func _test_pause_menu() -> void:
	step("pause menu: the Record card's issued line")
	var pm: PauseMenu = hud.pause_menu
	pm.open()
	await wait_sec(0.5)
	var lines: Array[String] = Career.get_summary_lines()
	var texts := pm.get_record_texts()
	check(pm.record_card.visible and pm.get_record_issued_text() == "Issued: 4 of %d" % Hats.count() and pm.get_record_issued_text() == Hats.record_text(Career), "'%s'" % pm.get_record_issued_text())
	check(texts.size() == lines.size() + 1 and texts[0] == Career.get_title(), "the title and the record's own lines are what they were (%d)" % texts.size())
	var card := pm.record_card.get_global_rect()
	var line := pm.record_issued.get_global_rect()
	var last := (pm.record_lines.get_child(pm.record_lines.get_child_count() - 1) as Control).get_global_rect()
	check(card.grow(1.0).encloses(line) and line.position.y >= last.end.y - 1.0 and get_viewport().get_visible_rect().encloses(card), "inside the card, under the last line, on the screen (%s in %s)" % [line, card])
	check(not pm.card.get_global_rect().intersects(card), "the card still stands beside the ON BREAK card")
	Career.clear_record()
	await wait_frames(2)
	check(pm.get_record_issued_text() == "" and not pm.record_issued.visible and pm.get_record_texts().size() == 2, "nothing on file: no issued line")
	Career.load_file(_path)
	await wait_frames(2)
	check(pm.get_record_issued_text() == "Issued: 4 of %d" % Hats.count(), "back with the record")
	Config.replay_enabled = false
	pm.sync_record()
	check(pm.get_record_issued_text() == "" and not pm.record_card.visible, "replay off: no card, no line")
	Config.replay_enabled = true
	pm.sync_record()
	pm.close()
	await wait_frames(2)


# --- the budget -------------------------------------------------------------------------------------------------------

func _test_budget() -> void:
	step("the budget: the locker jams when the host would take no more")
	var presses := 0
	var agree := true
	while locker.can_interact(me) and presses < 200:
		locker.interact(me)
		presses += 1
		if Net.get_player_hat(1) != Career.get_hat() or me.get_hat() != Career.get_hat():
			agree = false
	check(presses > 0 and presses < Net.MAX_HAT_CHANGES and agree, "%d more presses, the host took every one" % presses)
	check(Career.get_hat_changes_left() == 0 and not Career.can_change_hat() and int(Net._hat_changes.get(1, 0)) == Net.MAX_HAT_CHANGES,
			"then %d changes are used up on both sides" % Net.MAX_HAT_CHANGES)
	var stuck: StringName = Career.get_hat()
	check(locker.get_prompt(me) == "Locker · jammed" and not locker.can_interact(me), "'%s'" % locker.get_prompt(me))
	_used.clear()
	locker.interact(me)
	var other: StringName = &"hairnet" if stuck != &"hairnet" else &"cone"
	check(_used.is_empty() and not Career.set_hat(other) and not Career.set_hat(&"" if stuck != &"" else other) and Career.get_hat() == stuck, "E does nothing; Career refuses a change the host would drop")
	Net._rpc_set_hat(String(other))
	check(Net.get_player_hat(1) == stuck and me.get_hat() == stuck, "the host drops a change past the cap: what is worn is what is shown ('%s')" % stuck)
	var reader := _reader()
	check(reader.load_file(_path) and reader.get_hat() == stuck, "and what is on file")
	reader.free()


# --- replay off -------------------------------------------------------------------------------------------------------

func _test_replay_off() -> void:
	step("replay off: nothing is sent or shown")
	var b: BalanceConfig = Config.balance
	_write_text(_path, "[career]\nshifts=0\nbackroom=3\nbitten=5\n")
	Career.load_file(_path)
	check(_same(Career.get_issued_hats(), [&"cone", &"bucket"]) and Career.set_hat(&"cone") and Career.get_hat() == &"cone", "the record still issues, and a hat can be on")
	await wait_frames(2)
	check(Net.hats.is_empty() and Net.get_player_hat(1) == &"", "it is not sent")
	check(me.get_hat() == &"" and me.get_hat_node() == null and (me.get_node(Player.STOCK_HAT_PATH) as Node3D).visible, "and not shown: the stock hard hat")
	Net._rpc_hats_sync({1: "cone", BOB: "bucket"})
	check(bob.get_hat() == &"" and bob.get_hat_node() == null and me.get_hat() == &"", "a list from somewhere is not shown either")
	Net._rpc_hats_sync({})
	check(locker.get_prompt(me) == "Locker · locked" and not locker.can_interact(me), "'%s'" % locker.get_prompt(me))
	_used.clear()
	locker.interact(me)
	check(_used.is_empty() and locker.use() == &"cone" and Career.get_hat() == &"cone", "E and use() do nothing")
	stand_near(locker, 1.4)
	await get_tree().physics_frame
	await get_tree().physics_frame
	me.get_interactor().refresh()
	check(me.get_interactor().current_target == locker and me.get_interactor().prompt_text == "Locker · locked" and not me.get_interactor().prompt_enabled, "the HUD prompt, greyed out")

	step("replay off: a hat is issued without a word")
	_issued.clear()
	var t := toasts.size()
	if not await _play_shift(b, false):
		return
	var said := false
	for i in range(t, toasts.size()):
		if String(toasts[i][0]).begins_with("Issued"):
			said = true
	check(Career.get_record("shifts") == 1 and _same(_issued, [&"hairnet"]) and not said, "the first shift issues the hairnet (the signal), no toast")
	check(Net.hats.is_empty() and me.get_hat() == &"", "still nothing on the wire or on a head")


# --- helpers ----------------------------------------------------------------------------------------------------------

func _reader() -> Node:
	var script: GDScript = load(CAREER_SCRIPT)
	return script.new()


func _temp(tag: String) -> String:
	var p := "%s.%s%d" % [_path, tag, _temp_files.size()]
	_temp_files.append(p)
	return p


func _write_text(p: String, text: String) -> void:
	var f := FileAccess.open(p, FileAccess.WRITE)
	f.store_string(text)
	f.close()


func _remove(p: String) -> void:
	if FileAccess.file_exists(p):
		DirAccess.remove_absolute(p)


func _cleanup() -> void:
	for p in _temp_files:
		_remove(p)
		_remove(p + ".tmp")
	_remove(_path)
	_remove(_path + ".tmp")


## True when `got` holds exactly the ids of `want`, in order.
static func _same(got: Array, want: Array) -> bool:
	if got.size() != want.size():
		return false
	for i in got.size():
		if StringName(got[i]) != StringName(want[i]):
			return false
	return true


## The box round `points` after `xform` (a box turned by a leaning transform would come out too large).
static func _points_box(points: PackedVector3Array, xform: Transform3D) -> AABB:
	var box := AABB()
	for i in points.size():
		var p := xform * points[i]
		box = AABB(p, Vector3.ZERO) if i == 0 else box.expand(p)
	return box


static func _flat(v: Vector3) -> Vector2:
	return Vector2(v.x, v.z)


## The meshes under `node` (outline hulls left out), as one box in `node`'s own space.
static func _mesh_box(node: Node3D) -> AABB:
	return _mesh_box_in(node, node)


## The meshes under `node` as one box in `frame`'s space.
static func _mesh_box_in(node: Node3D, frame: Node3D) -> AABB:
	var box := AABB()
	var first := true
	for n in node.find_children("*", "MeshInstance3D", true, false):
		var mi := n as MeshInstance3D
		if mi.mesh == null or mi.has_meta(&"toonify_outline"):
			continue
		var part: AABB = frame.global_transform.affine_inverse() * mi.global_transform * mi.get_aabb()
		box = part if first else box.merge(part)
		first = false
	return box


static func _global_box(node: Node3D) -> AABB:
	var box := AABB()
	var first := true
	for n in node.find_children("*", "MeshInstance3D", true, false):
		var mi := n as MeshInstance3D
		if mi.mesh == null or mi.has_meta(&"toonify_outline"):
			continue
		var part: AABB = mi.global_transform * mi.get_aabb()
		box = part if first else box.merge(part)
		first = false
	return box


static func _tris(node: Node) -> int:
	var tris := 0
	for n in node.find_children("*", "MeshInstance3D", true, false):
		var mi := n as MeshInstance3D
		if mi.mesh == null or mi.has_meta(&"toonify_outline"):
			continue
		for s in mi.mesh.get_surface_count():
			var arrays := mi.mesh.surface_get_arrays(s)
			var idx: PackedInt32Array = arrays[Mesh.ARRAY_INDEX] if arrays[Mesh.ARRAY_INDEX] != null else PackedInt32Array()
			var verts: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
			tris += (idx.size() if idx.size() > 0 else verts.size()) / 3
	return tris


static func _has_outline(node: Node) -> bool:
	for n in node.find_children("*", "MeshInstance3D", true, false):
		if n.has_meta(&"toonify_outline"):
			return true
	return false
