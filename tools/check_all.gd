extends SceneTree
## Loads every .gd, .tscn, .tres and .gdshader under res:// so parse errors and broken references surface.
## Run via tools/check.sh (which also greps the engine output for errors).
## Work happens in _initialize() (not _init) so autoload singletons exist when scripts compile.
##   godot --headless --path . -s res://tools/check_all.gd

var _failures: Array[String] = []
var _count := 0

func _initialize() -> void:
	_walk("res://")
	print("check_all: loaded %d resources, %d failures" % [_count, _failures.size()])
	for f in _failures:
		print("  FAIL: " + f)
	quit(1 if _failures.size() > 0 else 0)

func _walk(dir_path: String) -> void:
	var dir := DirAccess.open(dir_path)
	if dir == null:
		return
	dir.list_dir_begin()
	var name := dir.get_next()
	while name != "":
		if name.begins_with("."):
			name = dir.get_next()
			continue
		var full := dir_path.path_join(name)
		if dir.current_is_dir():
			if name not in ["addons", "export"]:
				_walk(full)
		else:
			_check_file(full)
		name = dir.get_next()
	dir.list_dir_end()

func _check_file(path: String) -> void:
	var ext := path.get_extension()
	if ext not in ["gd", "tscn", "tres", "gdshader"]:
		return
	_count += 1
	var res: Resource = ResourceLoader.load(path, "", ResourceLoader.CACHE_MODE_REPLACE)
	if res == null:
		_failures.append(path + " (load returned null)")
		return
	if ext == "gd":
		var s := res as GDScript
		if s == null or not s.can_instantiate():
			# Autoload scripts and abstract bases still instantiate; a non-instantiable script means a compile error.
			_failures.append(path + " (script cannot instantiate: compile error?)")
	elif ext == "tscn":
		var ps := res as PackedScene
		if ps == null or not ps.can_instantiate():
			_failures.append(path + " (scene cannot instantiate)")
		else:
			# Instantiate off-tree to catch missing scripts / broken node references early.
			var inst := ps.instantiate()
			if inst == null:
				_failures.append(path + " (instantiate returned null)")
			else:
				inst.free()
