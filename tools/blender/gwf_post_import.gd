@tool
extends EditorScenePostImport
## Post-import step for every res://art/models/*.glb (set as `import_script/path` by tools/blender/build.py).
## Owner: pipeline agent. See MODELING.md "Rigged models".
##
## Blender object names are unique per file, Godot's glTF import makes node names unique per scene
## ("Hand" + "Hand" -> "Hand", "Hand2"), but scene scripts address parts by path
## (Visual/Torso/ArmLeft/Hand and Visual/Torso/ArmRight/Hand). So a Blender object named "Hand__L" is
## imported as a node named "Hand": everything from the first "__" on is dropped (names only need to be
## unique among siblings). Nothing else is changed: toon conversion happens at runtime (Toonify).


func _post_import(scene: Node) -> Object:
	for n in scene.find_children("*__*", "", true, false):
		var nm := String(n.name)
		var cut := nm.find("__", 1)
		if cut > 0:
			n.name = nm.substr(0, cut)
			if String(n.name) != nm.substr(0, cut):
				push_warning("gwf_post_import: '%s' clashes with a sibling; got '%s'" % [nm, n.name])
	return scene
