extends SceneTree

## Generates actors/wolf/wolf_animation_tree.tres.
##
## Built by script rather than hand-authored: a typo'd key in a hand-written
## .tres (blend_point_3/name, a node_connections triple) fails SILENTLY into a
## wrong-shaped tree, whereas this fails loudly and is regenerable whenever the
## ladder is retuned.
##
## Graph:
##   AnimationNodeStateMachine (root)
##     Ground   = BlendTree: Idle + GaitSpace -> GaitRate -> IdleMove -> output
##     Airborne = BlendTree: Jump -> AirRate -> output
##
## Usage:
##   Godot_v4.7.1-stable_win64_console.exe --headless \
##     --path <godot project root> --script res://examples/3d/exploration_quadraped/tools/build_wolf_animation_tree.gd

# preload() rather than the bare global class name: global_script_class_cache.cfg
# is stale in a fresh headless run that has never opened the editor.
const WolfGaitLadderScript := preload("../actors/wolf/wolf_gait_ladder.gd")

## Relative to this script -- see _res().
const OUT_PATH: String = "../actors/wolf/wolf_animation_tree.tres"

## Upper bound of the blend space axis, in m/s. Slightly above gallop (4.64) so
## the fastest point is not pinned to the very edge of the range.
const MAX_SPACE: float = 5.0


func _initialize() -> void:
	var state_machine := AnimationNodeStateMachine.new()
	state_machine.state_machine_type = \
			AnimationNodeStateMachine.STATE_MACHINE_TYPE_ROOT

	state_machine.add_node(&"Ground", _build_ground_tree(), Vector2(420.0, 60.0))
	state_machine.add_node(&"Airborne", _build_air_tree(), Vector2(760.0, 60.0))

	# Start -> Ground fires automatically when the tree becomes active.
	state_machine.add_transition(&"Start", &"Ground", _make_transition(
			AnimationNodeStateMachineTransition.ADVANCE_MODE_AUTO, 0.0, true))
	# Takeoff is snappy. reset = true starts the jump clip from frame 0.
	state_machine.add_transition(&"Ground", &"Airborne", _make_transition(
			AnimationNodeStateMachineTransition.ADVANCE_MODE_ENABLED, 0.08, true))
	# Landing is cushioned. reset = false so the gait cycle resumes at its
	# current phase instead of snapping back to frame 0.
	state_machine.add_transition(&"Airborne", &"Ground", _make_transition(
			AnimationNodeStateMachineTransition.ADVANCE_MODE_ENABLED, 0.15, false))

	var out_path: String = _res(OUT_PATH)
	var err: Error = ResourceSaver.save(state_machine, out_path)
	if err != OK:
		printerr("ResourceSaver.save(%s) failed: %d" % [out_path, err])
		quit(1)
		return

	print("Wrote %s" % out_path)
	print("  states:      Ground, Airborne (+ auto Start/End)")
	print("  blend points: %s" % str(WolfGaitLadderScript.GAIT_NAMES))
	for i: int in WolfGaitLadderScript.gait_count():
		print("    %-7s @ %.4f m/s  (L=%.2fs D=%.2fm)" % [
				WolfGaitLadderScript.GAIT_NAMES[i],
				WolfGaitLadderScript.gait_speed(i),
				WolfGaitLadderScript.GAIT_LENGTHS[i],
				WolfGaitLadderScript.GAIT_STRIDES[i]])
	quit(0)


func _make_transition(
		advance_mode: int, xfade_time: float, reset: bool
) -> AnimationNodeStateMachineTransition:
	var transition := AnimationNodeStateMachineTransition.new()
	transition.switch_mode = \
			AnimationNodeStateMachineTransition.SWITCH_MODE_IMMEDIATE
	transition.advance_mode = advance_mode
	transition.xfade_time = xfade_time
	transition.reset = reset
	transition.priority = 1
	return transition


func _build_ground_tree() -> AnimationNodeBlendTree:
	var gait_space := AnimationNodeBlendSpace1D.new()
	gait_space.blend_mode = AnimationNodeBlendSpace1D.BLEND_MODE_INTERPOLATED
	# CYCLIC_MUTABLE scales each point's delta by L_i / T, so every clip's
	# normalised phase advances at the same rate and footfalls stay locked
	# together across the whole ladder. WolfGaitLadder.blend_position_for_speed()
	# compensates for the speed skew this introduces.
	gait_space.sync_mode = AnimationNodeBlendSpace1D.SYNC_MODE_CYCLIC_MUTABLE
	gait_space.min_space = 0.0
	gait_space.max_space = MAX_SPACE
	gait_space.snap = 0.01
	gait_space.value_label = "speed (m/s)"

	for i: int in WolfGaitLadderScript.gait_count():
		var clip := AnimationNodeAnimation.new()
		clip.animation = StringName(WolfGaitLadderScript.GAIT_NAMES[i])
		# Do NOT set clip.loop_mode -- it is ignored unless use_custom_timeline
		# is true. Looping comes from the importer's "-loop" suffix detection,
		# which sets LOOP_LINEAR on the Animation resource itself.
		#
		# Blend points must stay bare AnimationNodeAnimation: _check_can_sync()
		# rejects nested nodes, so wrapping a point in a TimeScale would silently
		# disable cyclic sync.
		gait_space.add_blend_point(
				clip,
				WolfGaitLadderScript.gait_speed(i),
				-1,
				StringName(WolfGaitLadderScript.GAIT_NAMES[i]))

	var idle := AnimationNodeAnimation.new()
	idle.animation = &"idle"

	# Idle is deliberately OUTSIDE the blend space. Its 4.00 s length would
	# poison the cyclic-synced target cycle length T -- a 50/50 idle/walk blend
	# would force a 2.5 s cycle and play walk at 0.4x as a slow-motion crawl.
	var idle_move := AnimationNodeBlend2.new()
	# sync keeps the gait cycle advancing while blend_amount is 0, so moving off
	# from a standstill does not hitch on a cold cycle.
	idle_move.sync = true

	var tree := AnimationNodeBlendTree.new()
	tree.add_node(&"Idle", idle, Vector2(0.0, 0.0))
	tree.add_node(&"GaitSpace", gait_space, Vector2(0.0, 200.0))
	# GaitRate sits between IdleMove and GaitSpace so it time-scales the gait
	# ladder without touching idle. It does not break cyclic sync: scaling the
	# incoming delta leaves every point's normalised phase rate identical.
	tree.add_node(&"GaitRate", AnimationNodeTimeScale.new(), Vector2(280.0, 200.0))
	tree.add_node(&"IdleMove", idle_move, Vector2(520.0, 80.0))

	tree.connect_node(&"GaitRate", 0, &"GaitSpace")
	tree.connect_node(&"IdleMove", 0, &"Idle")      # input 0 == "in"
	tree.connect_node(&"IdleMove", 1, &"GaitRate")  # input 1 == "blend"
	tree.connect_node(&"output", 0, &"IdleMove")
	return tree


func _build_air_tree() -> AnimationNodeBlendTree:
	var jump := AnimationNodeAnimation.new()
	jump.animation = &"jump"

	var tree := AnimationNodeBlendTree.new()
	tree.add_node(&"Jump", jump, Vector2(0.0, 0.0))
	# AirRate fits the fixed 0.75 s clip to the real ballistic airtime, which is
	# known at takeoff as 2 * jump_velocity / gravity.
	tree.add_node(&"AirRate", AnimationNodeTimeScale.new(), Vector2(280.0, 0.0))
	tree.connect_node(&"AirRate", 0, &"Jump")
	tree.connect_node(&"output", 0, &"AirRate")
	return tree


## Turns a path relative to this script into an absolute res:// path. load(),
## FileAccess and ResourceSaver do not resolve relative paths the way preload()
## does, so every path that reaches them goes through here.
func _res(relative_path: String) -> String:
	var dir: String = (get_script() as Script).resource_path.get_base_dir()
	return dir.path_join(relative_path).simplify_path()
