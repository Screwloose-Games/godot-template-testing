class_name OrbitCameraRig
extends Node3D

## Third-person orbit camera.
##
## Deliberately a SIBLING of the target, not a child: the wolf yaws to face its
## movement direction, and a camera parented to it would spin with the body.
## The rig instead lerps its own position toward the target and owns its yaw.
##
## The SpringArm3D collides only with layer 1 (world) while the wolf sits on
## layer 2, so the arm never collides with the thing it is following and no
## exclusion bookkeeping is needed.

@export var target: Node3D
## Height above the target's origin to aim at (roughly shoulder height).
@export var target_height: float = 0.7
## Position follow stiffness, 1/s. Higher snaps harder to the target.
@export var follow_speed: float = 8.0
@export var mouse_sensitivity: float = 0.0025
@export var pitch_min_degrees: float = -70.0
@export var pitch_max_degrees: float = 35.0
## Captures the mouse on startup. Turn off when embedding in a tool scene.
@export var capture_mouse: bool = true

var _yaw: float = 0.0
var _pitch: float = -0.2

@onready var _yaw_node: Node3D = %Yaw
@onready var _pitch_node: Node3D = %Pitch


func _ready() -> void:
	if Engine.is_editor_hint():
		return
	if capture_mouse:
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
	if target != null:
		global_position = target.global_position + Vector3.UP * target_height
	_apply_rotation()


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseMotion and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
		var motion: InputEventMouseMotion = event as InputEventMouseMotion
		_yaw -= motion.relative.x * mouse_sensitivity
		_pitch = clampf(
				_pitch - motion.relative.y * mouse_sensitivity,
				deg_to_rad(pitch_min_degrees),
				deg_to_rad(pitch_max_degrees))
		_apply_rotation()
	elif event.is_action_pressed(&"ui_cancel"):
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE


func _physics_process(delta: float) -> void:
	if target == null:
		return
	var wanted: Vector3 = target.global_position + Vector3.UP * target_height
	# Exponential smoothing, frame-rate independent.
	global_position = global_position.lerp(
			wanted, 1.0 - exp(-follow_speed * delta))


func _apply_rotation() -> void:
	_yaw_node.rotation.y = _yaw
	_pitch_node.rotation.x = _pitch
