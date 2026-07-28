extends Node

## Renders the demo world from fixed angles and saves PNGs, so the wolf can be
## eyeballed without a human at the keyboard. Checks facing direction, gait pose
## and general asset sanity.
##
## Must run WITH a window (no --headless -- there is no rendering device then):
##   Godot_v4.7.1-stable_win64_console.exe \
##     --path <godot project root> --resolution 1280x720 \
##     res://examples/3d/exploration_quadraped/tools/capture_wolf_shots.tscn

const DemoWorld := preload("../scenes/demo_world.tscn")
const WolfGaitLadderScript := preload("../actors/wolf/wolf_gait_ladder.gd")
const WolfAnimatorScript := preload("../actors/wolf/wolf_animator.gd")

const OUT_DIR: String = "user://wolf_shots"

## name, camera position, look-at target, commanded speed for the gait ladder.
const SHOTS: Array = [
	["01_idle_side", Vector3(4.0, 1.2, 0.6), Vector3(0.0, 0.55, 0.0), 0.0],
	["02_trot_side", Vector3(4.0, 1.2, 0.6), Vector3(0.0, 0.55, 0.0), 1.76],
	["03_gallop_side", Vector3(4.5, 1.4, 0.6), Vector3(0.0, 0.6, 0.0), 4.64],
	# The wolf faces -Z, so a camera at +Z is BEHIND it and a camera at -Z sees
	# its face. Named for what each shot actually shows.
	["04_rear", Vector3(0.3, 1.1, 3.6), Vector3(0.0, 0.6, 0.0), 1.76],
	["05_head_on", Vector3(0.3, 1.1, -3.6), Vector3(0.0, 0.6, 0.0), 1.76],
	["06_three_quarter", Vector3(3.2, 2.0, 3.0), Vector3(0.0, 0.55, 0.0), 2.5],
	["07_world_overview", Vector3(-6.0, 9.0, 18.0), Vector3(0.0, 0.0, 2.0), 0.0],
]

var _animator: WolfAnimatorScript = null
var _camera: Camera3D = null


func _ready() -> void:
	DirAccess.make_dir_recursive_absolute(OUT_DIR)

	var world: Node = DemoWorld.instantiate()
	add_child(world)

	# The rig would grab the mouse and fight our fixed camera.
	var rig: Node = world.get_node_or_null("CameraRig")
	if rig != null:
		rig.set("capture_mouse", false)
		rig.queue_free()
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE

	var wolf: Node = world.get_node_or_null("Wolf")
	if wolf == null:
		printerr("FATAL: Wolf not found in demo world")
		get_tree().quit(1)
		return

	# Through the facade: this tool needs the wolf inside the demo world for its
	# lighting and ground, so it does not get to reach into the rig.
	_animator = wolf.get_node_or_null("%Animator") as WolfAnimatorScript
	if _animator == null:
		printerr("FATAL: %Animator not found")
		get_tree().quit(1)
		return

	_camera = Camera3D.new()
	_camera.fov = 55.0
	add_child(_camera)
	_camera.make_current()

	# Freeze the controller so it cannot fight the poses we dial in, and drive the
	# tree manually for deterministic gait phase.
	wolf.set_physics_process(false)
	_animator.set_manual_advance(true)
	_animator.enter_ground()

	print("wolf global_position: %s" % str((wolf as Node3D).global_position))
	print("wolf forward (-Z basis): %s" % str(-(wolf as Node3D).global_transform.basis.z))

	await _run_shots()

	print("\nSaved %d shots to %s" % [SHOTS.size(), ProjectSettings.globalize_path(OUT_DIR)])
	get_tree().quit(0)


func _run_shots() -> void:
	# Settle the state machine.
	for _i: int in 40:
		_animator.advance(1.0 / 60.0)

	for shot: Array in SHOTS:
		var shot_name: String = shot[0]
		var camera_position: Vector3 = shot[1]
		var look_target: Vector3 = shot[2]
		var speed: float = shot[3]

		_camera.global_position = camera_position
		_camera.look_at(look_target, Vector3.UP)

		_animator.update_ground(speed)
		# Recomputed only to report the blend position the call above applied --
		# same function, same constant, so the two cannot drift.
		var params: Vector3 = WolfGaitLadderScript.ground_animation_params(
				speed, WolfAnimatorScript.GAIT_RATE_MIN)

		# Advance into the stride so limbs are mid-swing rather than at frame 0,
		# and let the idle/locomotion crossfade settle.
		for _i: int in 40:
			_animator.advance(1.0 / 60.0)

		# Two frames so the transforms written by advance() reach the renderer.
		await RenderingServer.frame_post_draw
		await RenderingServer.frame_post_draw

		var image: Image = get_viewport().get_texture().get_image()
		var path: String = "%s/%s.png" % [OUT_DIR, shot_name]
		var err: Error = image.save_png(path)
		if err != OK:
			printerr("save_png(%s) failed: %d" % [path, err])
		else:
			print("  %s  (speed %.2f, blend_pos %.3f)" % [shot_name, speed, params.z])
