extends SceneTree

## Measures how far the paws sit above (or below) the animator's origin over each
## gait cycle, so ModelPivot can be offset to put the planted paw exactly on the
## ground instead of floating or sinking.
##
## Reports the minimum world-space AABB bottom of the four paw meshes, sampled
## across each clip. The offset to apply is -min_over_all_gaits.
##
## Instantiates wolf_animator.tscn rather than wolf.tscn: this measures the rig, so
## its internals are legitimately in scope -- see "Component boundaries" in
## CLAUDE.md. The animator's origin coincides with the Wolf capsule bottom because
## %Animator's transform is identity, which verify_wolf_static.gd check 9 asserts.
##
## Usage:
##   Godot_v4.7.1-stable_win64_console.exe --headless \
##     --path <godot project root> --script res://examples/3d/exploration_quadraped/tools/measure_paw_contact.gd

## Relative to this script -- see _res().
const ANIMATOR_SCENE: String = "../actors/wolf/wolf_animator.tscn"
const PAWS: PackedStringArray = ["paw_l", "paw_r", "hindpaw_l", "hindpaw_r"]
const SAMPLES: int = 120


var _done: bool = false


## Runs on the first frame rather than in _initialize(): the SceneTree root is not
## yet inside the tree during _initialize(), so AnimationPlayer.seek() cannot
## resolve its track targets and every global_transform read returns identity.
func _process(_delta: float) -> bool:
	if _done:
		return true
	_done = true
	_measure()
	return true


func _measure() -> void:
	var packed: PackedScene = load(_res(ANIMATOR_SCENE))
	var animator: Node3D = packed.instantiate() as Node3D
	get_root().add_child(animator)

	var tree: AnimationTree = animator.get_node_or_null("%AnimationTree") as AnimationTree
	var player: AnimationPlayer = tree.get_node_or_null(tree.anim_player) as AnimationPlayer
	# Drive the AnimationPlayer directly: one clip at a time, no blending, which is
	# what we want for a per-gait contact measurement.
	tree.active = false

	var paw_nodes: Array[MeshInstance3D] = []
	for paw_name: String in PAWS:
		var node: MeshInstance3D = animator.find_child(paw_name, true, false) as MeshInstance3D
		if node == null:
			printerr("Could not find paw mesh '%s'" % paw_name)
			quit(1)
			return
		paw_nodes.append(node)

	print("Animator origin is at y=%.4f in its own space." % animator.position.y)
	print("Values below are relative to the animator origin, which is the Wolf")
	print("capsule bottom (%Animator's transform is identity by invariant).\n")
	print("%-9s %10s %10s   %s" % ["clip", "min_y", "max_y", "lowest paw"])
	print("-".repeat(52))

	var global_min: float = INF
	var clips: PackedStringArray = [
		"idle", "walk", "amble", "pace", "trot", "canter", "gallop", "jump",
	]
	for clip: String in clips:
		if not player.has_animation(clip):
			continue
		var anim: Animation = player.get_animation(clip)
		var clip_min: float = INF
		var clip_max: float = -INF
		var lowest_paw: String = ""
		for i: int in SAMPLES:
			var t: float = anim.length * float(i) / float(SAMPLES)
			player.play(clip)
			player.seek(t, true)
			for index: int in paw_nodes.size():
				var paw: MeshInstance3D = paw_nodes[index]
				var aabb: AABB = paw.global_transform * paw.get_aabb()
				var bottom: float = aabb.position.y - animator.global_position.y
				if bottom < clip_min:
					clip_min = bottom
					lowest_paw = PAWS[index]
				clip_max = maxf(clip_max, bottom)
		print("%-9s %10.4f %10.4f   %s" % [clip, clip_min, clip_max, lowest_paw])
		# jump is airborne by design; do not let it drive the ground offset.
		if clip != "jump":
			global_min = minf(global_min, clip_min)

	print("-".repeat(52))
	print("\nLowest paw bottom across all GROUND gaits: %.4f" % global_min)
	print("Apply %%ModelPivot.position.y = %.4f in wolf_animator.tscn to plant it."
			% -global_min)
	quit(0)


## Turns a path relative to this script into an absolute res:// path. load(),
## FileAccess and ResourceSaver do not resolve relative paths the way preload()
## does, so every path that reaches them goes through here.
func _res(relative_path: String) -> String:
	var dir: String = (get_script() as Script).resource_path.get_base_dir()
	return dir.path_join(relative_path).simplify_path()
