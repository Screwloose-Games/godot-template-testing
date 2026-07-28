extends SceneTree

## Prints the imported wolf scene's node tree, AnimationPlayer wiring, and every
## animation's name / loop_mode / track paths. Run this BEFORE authoring the
## AnimationTree -- the exact node paths and animation names it reports are what
## wolf.tscn's root_motion_track and the blend points must reference.
##
## Usage:
##   Godot_v4.7.1-stable_win64_console.exe --headless \
##     --path <godot project root> --script res://examples/3d/exploration_quadraped/tools/dump_glb_info.gd

## Relative to this script -- see _res().
const GLB_SCENE: String = "../assets/models/wolf/grey-wolf-gaits-and-jump.glb"


func _initialize() -> void:
	var packed: PackedScene = load(_res(GLB_SCENE))
	if packed == null:
		printerr("Could not load %s -- did --import succeed?" % _res(GLB_SCENE))
		quit(1)
		return

	var scene_root: Node = packed.instantiate()
	print("=== SCENE ROOT: %s (%s) ===" % [scene_root.name, scene_root.get_class()])
	_dump_tree(scene_root, scene_root, 0)

	var player: AnimationPlayer = scene_root.find_child("AnimationPlayer", true, false)
	if player == null:
		printerr("No AnimationPlayer found in the imported scene.")
		quit(1)
		return

	print("\n=== ANIMATION PLAYER ===")
	print("  path from scene root: %s" % scene_root.get_path_to(player))
	print("  root_node:            %s" % player.root_node)
	print("  libraries:            %s" % str(player.get_animation_library_list()))
	print("  animations:           %s" % str(player.get_animation_list()))

	for anim_name: StringName in player.get_animation_list():
		var anim: Animation = player.get_animation(anim_name)
		print("\n--- '%s'  length=%.4f  loop_mode=%d  step=%.4f  tracks=%d" % [
				anim_name, anim.length, anim.loop_mode, anim.step, anim.get_track_count()])
		for i: int in anim.get_track_count():
			var path: NodePath = anim.track_get_path(i)
			var track_type: int = anim.track_get_type(i)
			var target: Node = scene_root.get_node_or_null(
					NodePath(path.get_concatenated_names()))
			var extra: String = ""
			if track_type == Animation.TYPE_POSITION_3D and anim.track_get_key_count(i) > 0:
				var first: Vector3 = anim.position_track_interpolate(i, 0.0)
				var last: Vector3 = anim.position_track_interpolate(i, anim.length)
				extra = "  first=%s last=%s delta=%s" % [
						str(first), str(last), str(last - first)]
			print("    [%2d] type=%d keys=%3d resolves=%s  %s%s" % [
					i, track_type, anim.track_get_key_count(i),
					str(target != null), path, extra])

	print("\n=== TRACK TYPE LEGEND ===")
	print("  0=VALUE 1=POSITION_3D 2=ROTATION_3D 3=SCALE_3D 4=BLEND_SHAPE 5=METHOD")
	print("=== LOOP MODE LEGEND: 0=NONE 1=LINEAR 2=PINGPONG ===")
	quit(0)


func _dump_tree(node: Node, root: Node, depth: int) -> void:
	var transform_info: String = ""
	if node is Node3D:
		var node_3d: Node3D = node as Node3D
		transform_info = "  pos=%s rot_deg=%s" % [
				str(node_3d.position), str(node_3d.rotation_degrees)]
	print("%s%s (%s)%s   [%s]" % [
			"  ".repeat(depth), node.name, node.get_class(), transform_info,
			root.get_path_to(node)])
	for child: Node in node.get_children():
		_dump_tree(child, root, depth + 1)


## Turns a path relative to this script into an absolute res:// path. load(),
## FileAccess and ResourceSaver do not resolve relative paths the way preload()
## does, so every path that reaches them goes through here.
func _res(relative_path: String) -> String:
	var dir: String = (get_script() as Script).resource_path.get_base_dir()
	return dir.path_join(relative_path).simplify_path()
