class_name ChaseCameraRig
extends Node3D

## Third-person chase camera, and the source of the turret's aim point.
##
## Deliberately a SIBLING of the jeep, not a child: the hull yaws through every
## corner and a camera parented to it would swing with the body. The rig lerps its
## own position toward the target and owns its yaw.
##
## The SpringArm3D collides only with layer 1 (world) while the jeep sits on
## layer 2, so the arm can never catch on the thing it is following and no
## exclusion bookkeeping is needed.
##
## ONE MOUSE, TWO CONSUMERS. The mouse orbits this camera, and the turret slews
## toward whatever is under the crosshair -- this rig casts a ray from the camera
## through screen centre and emits the first world hit as `aim_point_changed`.
## Three things make that read as a single control rather than two fighting:
##
##   * The camera is instantaneous and the turret is rate-limited, so the gun
##     visibly trails the look. That lag reads as a heavy weapon, and the player's
##     model becomes "I look, the gun follows my gaze."
##   * Aiming at the hit POINT rather than parallel to the camera removes parallax
##     by construction. The turret sits 1.24 m above and 0.95 m behind the optical
##     axis, so a parallel gun misses badly at close range.
##   * No special cases. Looking back over the hull is just a large yaw error.
##
## The signal, rather than a direct call, is what keeps the jeep ignorant of any
## camera -- which is also what lets the runtime verifier aim the turret with no
## camera in the scene at all.

## The world point under the crosshair. Connect this to JeepController.set_aim_point
## WITH Object.CONNECT_PERSIST if you wire it in a builder script, or
## PackedScene.pack() drops the connection and the turret silently never moves.
signal aim_point_changed(point: Vector3)

## Far point used when the ray hits nothing -- aiming at the sky still has to
## produce a finite answer.
const MAX_AIM_DISTANCE: float = 250.0

@export var target: Node3D
## Height above the target's origin to frame, roughly the top of the roll cage.
@export var target_height: float = 1.4
## Position follow stiffness, 1/s. Higher snaps harder to the target.
@export var follow_speed: float = 9.0
@export var mouse_sensitivity: float = 0.0025
@export var pitch_min_degrees: float = -60.0
@export var pitch_max_degrees: float = 40.0
## Captures the mouse on startup. Turn off when embedding in a tool scene.
@export var capture_mouse: bool = true

@export_group("Dolly")
## Arm length at a standstill, and at `dolly_speed`. Pulling back with speed is
## most of what makes 80 km/h read as fast.
@export var spring_length_min: float = 7.5
@export var spring_length_max: float = 10.5
@export var dolly_speed: float = 22.0

@export_group("Aim")
## Layer 1 only: the world. The jeep is on layer 2, so it cannot occlude its own
## aim ray, and a second jeep would not either.
@export_flags_3d_physics var aim_collision_mask: int = 1

var _yaw: float = 0.0
var _pitch: float = -0.18
## Measured from the rig's own motion rather than read off the target's
## linear_velocity, so this component works with any Node3D target.
var _measured_speed: float = 0.0
var _last_position: Vector3 = Vector3.ZERO

@onready var _yaw_node: Node3D = %Yaw as Node3D
@onready var _pitch_node: Node3D = %Pitch as Node3D
@onready var _arm: SpringArm3D = %SpringArm as SpringArm3D
@onready var _camera: Camera3D = %Camera as Camera3D


func _ready() -> void:
	if Engine.is_editor_hint():
		return
	if capture_mouse:
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
	if target != null:
		global_position = target.global_position + Vector3.UP * target_height
	_last_position = global_position
	_arm.collision_mask = aim_collision_mask
	_apply_rotation()


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseMotion and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
		var motion: InputEventMouseMotion = event as InputEventMouseMotion
		_yaw -= motion.relative.x * mouse_sensitivity
		_pitch = clampf(
			_pitch - motion.relative.y * mouse_sensitivity,
			deg_to_rad(pitch_min_degrees),
			deg_to_rad(pitch_max_degrees)
		)
		_apply_rotation()
	elif event.is_action_pressed(&"ui_cancel"):
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE


func _physics_process(delta: float) -> void:
	if target == null:
		return
	var wanted: Vector3 = target.global_position + Vector3.UP * target_height
	# Exponential smoothing, frame-rate independent.
	global_position = global_position.lerp(wanted, 1.0 - exp(-follow_speed * delta))

	_measured_speed = (global_position - _last_position).length() / maxf(delta, 0.0001)
	_last_position = global_position
	_arm.spring_length = lerpf(
		spring_length_min,
		spring_length_max,
		clampf(_measured_speed / maxf(dolly_speed, 0.001), 0.0, 1.0)
	)

	# Ray queries are only valid inside a physics step, which is why aiming lives
	# here rather than in _process.
	aim_point_changed.emit(aim_point())


## First world hit along the camera's centre line, or the far point if it hits
## nothing. Public so a verifier can ask for it without waiting a frame.
func aim_point() -> Vector3:
	var from: Vector3 = _camera.global_position
	var to: Vector3 = from - _camera.global_basis.z * MAX_AIM_DISTANCE
	var exclude: Array[RID] = []
	if target is CollisionObject3D:
		exclude.append((target as CollisionObject3D).get_rid())
	var query := PhysicsRayQueryParameters3D.create(from, to, aim_collision_mask, exclude)
	var hit: Dictionary = _camera.get_world_3d().direct_space_state.intersect_ray(query)
	return hit.get("position", to)


func _apply_rotation() -> void:
	_yaw_node.rotation.y = _yaw
	_pitch_node.rotation.x = _pitch
