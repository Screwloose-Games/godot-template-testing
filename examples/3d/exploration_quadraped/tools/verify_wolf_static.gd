extends SceneTree

## Static assertions on the wolf. Catches the failure modes that are silent at
## runtime -- a root_motion_track that never matches, animation names that
## drifted, or gait clips that lost their loop flag.
##
## Checks 1-8 run against actors/wolf/wolf_animator.tscn, which owns the whole
## animation rig. Check 9 runs against actors/wolf/wolf.tscn and asserts that the
## rig did NOT leak back out of it.
##
## Usage:
##   Godot_v4.7.1-stable_win64_console.exe --headless \
##     --path <godot project root> --script res://examples/3d/exploration_quadraped/tools/verify_wolf_static.gd

const WolfGaitLadderScript := preload("../actors/wolf/wolf_gait_ladder.gd")

## Paths are relative to this script so the example keeps working wherever the
## folder is dropped inside a project. _res() turns them into res:// paths --
## load() and FileAccess do not resolve relative paths the way preload() does.
const WOLF_SCENE: String = "../actors/wolf/wolf.tscn"
const ANIMATOR_SCENE: String = "../actors/wolf/wolf_animator.tscn"
const WOLF_CONTROLLER_SCRIPT: String = "../actors/wolf/wolf_controller.gd"
## Clips that must be LOOP_LINEAR. Guards the _subresources/loop_mode gotcha:
## adding any _subresources/animations entry to the .glb.import silently resets
## these to LOOP_NONE, and the wolf then takes one step and freezes.
const LOOPING_CLIPS: PackedStringArray = [
	"idle", "walk", "amble", "pace", "trot", "canter", "gallop",
]

var _failures: int = 0
var _warnings: int = 0


func _initialize() -> void:
	var packed: PackedScene = load(_res(ANIMATOR_SCENE))
	if packed == null:
		printerr("FATAL: could not load %s" % _res(ANIMATOR_SCENE))
		quit(1)
		return

	var animator: Node = packed.instantiate()
	get_root().add_child(animator)

	var tree: AnimationTree = animator.get_node_or_null("%AnimationTree") as AnimationTree
	if tree == null:
		printerr("FATAL: %AnimationTree not found under the WolfAnimator root.")
		quit(1)
		return

	var player: AnimationPlayer = tree.get_node_or_null(tree.anim_player) as AnimationPlayer
	if player == null:
		printerr("FATAL: anim_player '%s' does not resolve." % tree.anim_player)
		quit(1)
		return

	var mixer_root: Node = tree.get_node_or_null(tree.root_node)
	if mixer_root == null:
		printerr("FATAL: root_node '%s' does not resolve." % tree.root_node)
		quit(1)
		return
	print("mixer root resolves to: %s (%s)" % [mixer_root.name, mixer_root.get_class()])

	_check_1_tree_and_playback(tree)
	_check_2_animation_names(tree, player)
	_check_3_root_motion_resolves(tree, mixer_root)
	_check_4_gait_clips_have_root_motion(tree, player)
	_check_5_loop_modes(player)
	_check_6_all_tracks_resolve(player, mixer_root)
	_check_7_no_collateral_root_motion_tracks(tree, player)
	_check_8_root_motion_basis(animator)
	_check_9_component_boundary()

	print("\n=== %d failure(s), %d warning(s) ===" % [_failures, _warnings])
	quit(1 if _failures > 0 else 0)


func _fail(message: String) -> void:
	_failures += 1
	printerr("  FAIL: %s" % message)


func _warn(message: String) -> void:
	_warnings += 1
	print("  WARN: %s" % message)


func _check_1_tree_and_playback(tree: AnimationTree) -> void:
	print("\n[1] tree_root and playback")
	if tree.tree_root == null:
		_fail("tree_root is null")
		return
	print("  tree_root: %s" % tree.tree_root.get_class())
	tree.active = true
	var playback: Variant = tree.get("parameters/playback")
	if playback is AnimationNodeStateMachinePlayback:
		print("  parameters/playback OK")
	else:
		_fail("parameters/playback is not an AnimationNodeStateMachinePlayback (got %s)"
				% type_string(typeof(playback)))
	tree.active = false


func _check_2_animation_names(tree: AnimationTree, player: AnimationPlayer) -> void:
	print("\n[2] every referenced animation exists")
	var available: PackedStringArray = []
	for name: StringName in player.get_animation_list():
		available.append(String(name))
	print("  player has: %s" % str(available))

	var referenced: PackedStringArray = []
	_collect_animation_names(tree.tree_root, referenced)
	for name: String in referenced:
		if available.has(name):
			print("  '%s' OK" % name)
		else:
			_fail("tree references animation '%s', which the player does not have. "
					% name
					+ "The glTF importer strips the '-loop' suffix, so 'walk-loop' "
					+ "arrives as 'walk'.")


func _collect_animation_names(node: AnimationNode, into: PackedStringArray) -> void:
	if node == null:
		return
	if node is AnimationNodeAnimation:
		var name: String = String((node as AnimationNodeAnimation).animation)
		if not into.has(name):
			into.append(name)
		return
	if node is AnimationNodeBlendTree:
		var blend_tree: AnimationNodeBlendTree = node as AnimationNodeBlendTree
		for child_name: StringName in blend_tree.get_node_list():
			_collect_animation_names(blend_tree.get_node(child_name), into)
		return
	if node is AnimationNodeStateMachine:
		var state_machine: AnimationNodeStateMachine = node as AnimationNodeStateMachine
		for state: StringName in state_machine.get_node_list():
			_collect_animation_names(state_machine.get_node(state), into)
		return
	if node is AnimationNodeBlendSpace1D:
		var space: AnimationNodeBlendSpace1D = node as AnimationNodeBlendSpace1D
		for i: int in space.get_blend_point_count():
			_collect_animation_names(space.get_blend_point_node(i), into)
		return
	# Generic single/multi-input wrappers (TimeScale, Blend2, OneShot, ...).
	for i: int in node.get_input_count():
		pass  # Inputs are wired by the parent BlendTree, already walked above.


func _check_3_root_motion_resolves(tree: AnimationTree, mixer_root: Node) -> void:
	print("\n[3] root_motion_track resolves")
	if tree.root_motion_track.is_empty():
		_fail("root_motion_track is empty -- the baked forward slide will play raw")
		return
	print("  root_motion_track = '%s'" % tree.root_motion_track)
	if String(tree.root_motion_track).contains(":"):
		_fail("root_motion_track contains a ':' subname. For a Node3D track it must "
				+ "be the bare node path (the ':Hips' form in the docs is for "
				+ "skeleton bones) and will never match.")
	var target: Node = mixer_root.get_node_or_null(tree.root_motion_track)
	if target == null:
		_fail("root_motion_track does not resolve from the mixer root")
	else:
		print("  resolves to: %s (%s)" % [target.name, target.get_class()])


func _check_4_gait_clips_have_root_motion(
		tree: AnimationTree, player: AnimationPlayer
) -> void:
	print("\n[4] each gait clip has a position track at root_motion_track")
	if tree.root_motion_track.is_empty():
		_warn("skipped -- root_motion_track is empty")
		return
	for gait: String in WolfGaitLadderScript.GAIT_NAMES:
		if not player.has_animation(gait):
			_fail("no animation named '%s'" % gait)
			continue
		var anim: Animation = player.get_animation(gait)
		var index: int = anim.find_track(tree.root_motion_track, Animation.TYPE_POSITION_3D)
		if index == -1:
			_fail("'%s' has no POSITION_3D track at '%s' -- nothing to cancel, so the "
					% [gait, tree.root_motion_track]
					+ "clip will slide")
			continue
		var stride: Vector3 = anim.position_track_interpolate(index, anim.length) \
				- anim.position_track_interpolate(index, 0.0)
		var expected: float = WolfGaitLadderScript.GAIT_STRIDES[
				WolfGaitLadderScript.GAIT_NAMES.find(gait)]
		var expected_length: float = WolfGaitLadderScript.GAIT_LENGTHS[
				WolfGaitLadderScript.GAIT_NAMES.find(gait)]
		var stride_ok: bool = is_equal_approx(snappedf(stride.z, 0.0001), expected)
		var length_ok: bool = is_equal_approx(snappedf(anim.length, 0.0001), expected_length)
		print("  '%s' stride.z=%.4f (ladder %.4f, %s)  length=%.4f (ladder %.4f, %s)" % [
				gait, stride.z, expected, "OK" if stride_ok else "MISMATCH",
				anim.length, expected_length, "OK" if length_ok else "MISMATCH"])
		if not stride_ok:
			_fail("'%s' baked stride %.4f != WolfGaitLadder.GAIT_STRIDES %.4f"
					% [gait, stride.z, expected])
		if not length_ok:
			_fail("'%s' clip length %.4f != WolfGaitLadder.GAIT_LENGTHS %.4f"
					% [gait, anim.length, expected_length])


func _check_5_loop_modes(player: AnimationPlayer) -> void:
	print("\n[5] looping clips are LOOP_LINEAR")
	for clip: String in LOOPING_CLIPS:
		if not player.has_animation(clip):
			_fail("no animation named '%s'" % clip)
			continue
		var mode: int = player.get_animation(clip).loop_mode
		if mode == Animation.LOOP_LINEAR:
			print("  '%s' LOOP_LINEAR OK" % clip)
		else:
			_fail("'%s' loop_mode is %d, expected 1 (LOOP_LINEAR). Something added a "
					% [clip, mode]
					+ "_subresources/animations entry to the .glb.import, which makes "
					+ "settings/loop_mode apply with its default of 0.")


func _check_6_all_tracks_resolve(player: AnimationPlayer, mixer_root: Node) -> void:
	print("\n[6] every animation track path resolves")
	var broken: int = 0
	var total: int = 0
	for name: StringName in player.get_animation_list():
		var anim: Animation = player.get_animation(name)
		for i: int in anim.get_track_count():
			total += 1
			var path: NodePath = anim.track_get_path(i)
			if mixer_root.get_node_or_null(NodePath(path.get_concatenated_names())) == null:
				broken += 1
				_fail("'%s' track %d path '%s' does not resolve" % [name, i, path])
	print("  %d tracks checked, %d broken" % [total, broken])


func _check_7_no_collateral_root_motion_tracks(
		tree: AnimationTree, player: AnimationPlayer
) -> void:
	print("\n[7] root_motion_track has no rotation/scale tracks to cancel collaterally")
	if tree.root_motion_track.is_empty():
		_warn("skipped -- root_motion_track is empty")
		return
	# One root_motion_track path cancels POSITION_3D, ROTATION_3D and SCALE_3D on
	# that node together, so a surviving rotation track would be silently eaten.
	for name: StringName in player.get_animation_list():
		var anim: Animation = player.get_animation(name)
		for track_type: int in [Animation.TYPE_ROTATION_3D, Animation.TYPE_SCALE_3D]:
			if anim.find_track(tree.root_motion_track, track_type) != -1:
				_warn("'%s' has a %s track on the root motion node; it will be cancelled too"
						% [name, "ROTATION_3D" if track_type == Animation.TYPE_ROTATION_3D
								else "SCALE_3D"])
	print("  done")


func _check_8_root_motion_basis(animator: Node) -> void:
	print("\n[8] the 180-degree ModelPivot is present and the facade is complete")
	var pivot: Node3D = animator.get_node_or_null("%ModelPivot") as Node3D
	if pivot == null:
		_fail("%ModelPivot not found inside the animator")
		return
	var yaw_degrees: float = rad_to_deg(pivot.rotation.y)
	print("  ModelPivot yaw = %.2f degrees" % yaw_degrees)
	if absf(absf(yaw_degrees) - 180.0) > 1.0:
		_fail("ModelPivot yaw is %.2f, expected +/-180. The wolf model faces +Z, "
				% yaw_degrees
				+ "which is Godot's backward, so it must be flipped.")

	# The facade the controller and the tools drive. A missing method here is a
	# runtime crash, because GDScript does not check calls on a typed node until
	# the call executes.
	for method: String in [
		"update_ground", "enter_ground", "enter_air", "enter_fall",
		"measured_speed", "measured_motion", "root_motion_slide",
		"root_motion_basis", "is_ground_state_active", "is_air_state_active",
		"set_manual_advance", "advance",
	]:
		if animator.has_method(method):
			print("  WolfAnimator.%s() OK" % method)
		else:
			_fail("WolfAnimator is missing %s()" % method)


## The boundary. Everything about the animation rig must be unreachable from the
## Wolf root, and the controller must not even name the mixer's vocabulary.
func _check_9_component_boundary() -> void:
	print("\n[9] wolf.tscn owns no animation")
	var packed: PackedScene = load(_res(WOLF_SCENE))
	if packed == null:
		_fail("could not load %s" % _res(WOLF_SCENE))
		return
	var wolf: Node = packed.instantiate()
	get_root().add_child(wolf)

	# POSITIVE CONTROLS FIRST. Without these the negatives below could pass
	# vacuously: rename the facade node and every lookup returns null, which would
	# read as a perfectly enforced boundary on a completely broken scene.
	var animator: Node3D = wolf.get_node_or_null("%Animator") as Node3D
	if animator == null:
		_fail("%Animator not found under the Wolf root")
		return
	print("  %Animator resolves from Wolf OK")
	if animator.get_node_or_null("%AnimationTree") == null:
		_fail("%AnimationTree does not resolve from INSIDE the animator either, so "
				+ "the negative assertions below prove nothing")
		return
	print("  %AnimationTree resolves from inside the animator OK")

	# Scene-unique names resolve against a node's owner rather than by walking the
	# tree, so a name declared in wolf_animator.tscn is invisible from wolf.tscn.
	# If any of these starts resolving, the rig has leaked back into the wolf.
	for leaked: String in ["%AnimationTree", "%ModelPivot", "%Model"]:
		if wolf.get_node_or_null(leaked) == null:
			print("  %s is unreachable from Wolf OK" % leaked)
		else:
			_fail("%s resolves from the Wolf root. The animation rig must live "
					% leaked
					+ "entirely inside wolf_animator.tscn.")

	# WolfAnimator caches its root-motion correction against ITSELF and every
	# caller reads the result as the body's frame.
	if animator.transform.is_equal_approx(Transform3D.IDENTITY):
		print("  %Animator transform is identity OK")
	else:
		_fail("%%Animator's local transform is %s, expected identity. A pitch, roll "
				% str(animator.transform)
				+ "or scale tips baked forward motion onto Y, which the readout zeroes, "
				+ "so measured_speed() would silently under-report foot slip. Put model "
				+ "offsets on %ModelPivot inside wolf_animator.tscn.")

	# Node-shape checks alone are not enough: a literal
	# get_node("ModelPivot/Model/AnimationTree") would pass every one of them, and
	# no amount of scene inspection catches a "parameters/..." string. Grep the
	# source for the vocabulary instead. Comments count too -- the controller
	# should not even document the mixer.
	_assert_absent(_res(WOLF_CONTROLLER_SCRIPT), [
		"AnimationTree", "AnimationNode", "parameters/", "root_motion_track",
		"get_root_motion", "\"Ground\"", "\"Airborne\"",
	])
	_assert_absent(_res(WOLF_SCENE), [
		"grey-wolf-gaits-and-jump.glb", "wolf_animation_tree.tres",
	])


func _assert_absent(path: String, needles: PackedStringArray) -> void:
	var text: String = FileAccess.get_file_as_string(path)
	if text.is_empty():
		_fail("could not read %s for the vocabulary scan" % path)
		return
	var clean: bool = true
	for needle: String in needles:
		if text.contains(needle):
			clean = false
			_fail("%s still mentions '%s'. That vocabulary belongs to WolfAnimator."
					% [path.get_file(), needle])
	if clean:
		print("  %s names none of the mixer's vocabulary OK" % path.get_file())


## Turns a path relative to this script into an absolute res:// path. load(),
## FileAccess and ResourceSaver do not resolve relative paths the way preload()
## does, so every path that reaches them goes through here.
func _res(relative_path: String) -> String:
	var dir: String = (get_script() as Script).resource_path.get_base_dir()
	return dir.path_join(relative_path).simplify_path()
