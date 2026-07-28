class_name WolfController
extends CharacterBody3D

## Player controller for the grey wolf.
##
## Movement is CODE-DRIVEN and the animation ladder follows it, rather than the
## animation's root motion driving movement. Reasons:
##   1. accel/brake stay tunable independently of animation blend times;
##   2. the jump clip is a fixed +1.2 m leap, while terrain, ledges and gravity
##      need a velocity.y we own;
##   3. move_and_slide() wants a velocity for slopes, snapping and wall sliding;
##   4. WolfGaitLadder's closed-form inverse already makes the ladder match
##      commanded speed exactly, so the usual accuracy argument for root-motion
##      driving does not apply here.
##
## Everything about HOW that reads on screen belongs to %Animator: the model, the
## pivot and the whole animation graph. This script names no clip, no state and no
## mixer parameter -- it reports speed and air state, and WolfAnimator decides what
## plays. See "Component boundaries" in CLAUDE.md.

signal jumped()
signal landed(impact_speed: float)
signal gait_changed(gait_name: StringName)

@export_group("Speeds")
## Top speed while the walk modifier is held (matches the walk clip).
@export var walk_speed: float = 0.55
## Top speed with no modifier (matches the trot clip -- a wolf's travel gait).
@export var cruise_speed: float = 1.76
## Top speed while sprint is held (matches the gallop clip).
@export var sprint_speed: float = 4.64

@export_group("Acceleration")
@export var ground_accel: float = 8.0
@export var ground_brake: float = 12.0
@export var air_accel: float = 2.0

@export_group("Turning")
## Yaw rate at a standstill, rad/s (~286 deg/s pivot).
@export var turn_rate_standing: float = 5.0
## Yaw rate at top speed, rad/s (~2.9 m turning radius at a gallop). A quadruped
## should not pivot on a dime mid-stride.
@export var turn_rate_top: float = 1.6

@export_group("Stepping")
## Tallest obstacle the wolf will step onto. CharacterBody3D has no built-in step
## climbing, so this is probed explicitly in _try_step_up(). Set to 0 to disable.
## At 0.3 the demo world's 0.2 m step is climbable and its 0.4 m step is not.
@export var max_step_height: float = 0.3
## How far ahead to probe for standable ground when stepping up.
@export var step_probe_distance: float = 0.28

@export_group("Jump")
@export var gravity: float = 20.0
## 2 * jump_velocity / gravity == 0.75 s, which is the air clip's native length,
## so it plays at its native rate by construction. See WolfAnimator.
@export var jump_velocity: float = 7.5
@export var coyote_time: float = 0.12
@export var jump_buffer: float = 0.15

## Horizontal speed in m/s, recomputed after every move_and_slide().
var horizontal_speed: float = 0.0

var _airborne: bool = false
var _coyote_timer: float = 0.0
var _jump_buffer_timer: float = 0.0

@onready var _animator: WolfAnimator = %Animator


func _ready() -> void:
	if Engine.is_editor_hint():
		return
	# Relayed so gameplay consumers (footstep audio) talk to the actor rather than
	# reaching into its animation component. Named method, not a lambda: GDScript
	# closures capture locals by value and signal handlers written that way go
	# quietly wrong.
	_animator.gait_changed.connect(_on_animator_gait_changed)


func _physics_process(delta: float) -> void:
	var move_dir: Vector3 = _read_move_input()
	var input_magnitude: float = move_dir.length()

	_tick_timers(delta)
	if Input.is_action_just_pressed(&"jump"):
		_jump_buffer_timer = jump_buffer

	if not is_on_floor():
		velocity.y -= gravity * delta
	elif not _airborne:
		_coyote_timer = coyote_time

	if _jump_buffer_timer > 0.0 and _coyote_timer > 0.0 and not _airborne:
		_begin_jump()

	_apply_horizontal(move_dir, input_magnitude, delta)
	_apply_turn(move_dir, delta)

	move_and_slide()
	_try_step_up(move_dir)

	horizontal_speed = Vector2(velocity.x, velocity.z).length()
	_update_motion_state()
	if not _airborne:
		_animator.update_ground(horizontal_speed)


## Camera-relative WASD. Returns a normalised horizontal direction, or ZERO.
func _read_move_input() -> Vector3:
	var raw: Vector2 = Input.get_vector(
			&"move_left", &"move_right", &"move_forward", &"move_back")
	if raw.is_zero_approx():
		return Vector3.ZERO

	var camera: Camera3D = get_viewport().get_camera_3d()
	if camera == null:
		return Vector3(raw.x, 0.0, raw.y).normalized()

	var camera_basis: Basis = camera.global_transform.basis
	# Input.get_vector maps "forward" onto -y, hence the negation.
	var direction: Vector3 = camera_basis.x * raw.x - (-camera_basis.z) * raw.y
	direction.y = 0.0
	if direction.length_squared() < 0.000001:
		return Vector3.ZERO
	return direction.normalized()


func _target_speed(input_magnitude: float) -> float:
	var cap: float = cruise_speed
	if Input.is_action_pressed(&"sprint"):
		cap = sprint_speed
	elif Input.is_action_pressed(&"walk"):
		cap = walk_speed
	return cap * input_magnitude


func _apply_horizontal(move_dir: Vector3, input_magnitude: float, delta: float) -> void:
	var planar: Vector3 = Vector3(velocity.x, 0.0, velocity.z)
	var wanted: Vector3 = move_dir * _target_speed(input_magnitude)

	var rate: float = air_accel
	if not _airborne:
		rate = ground_accel if wanted.length() > planar.length() else ground_brake

	planar = planar.move_toward(wanted, rate * delta)
	velocity.x = planar.x
	velocity.z = planar.z


## Yaw-rate-limited turning. A Node3D with rotation.y == theta faces
## (-sin theta, 0, -cos theta), so the yaw that points -Z along `move_dir` is
## atan2(-x, -z).
func _apply_turn(move_dir: Vector3, delta: float) -> void:
	if move_dir.is_zero_approx():
		return
	var target_yaw: float = atan2(-move_dir.x, -move_dir.z)
	var speed_ratio: float = clampf(
			horizontal_speed / WolfGaitLadder.fastest_speed(), 0.0, 1.0)
	var max_step: float = lerpf(turn_rate_standing, turn_rate_top, speed_ratio) * delta
	rotation.y = rotate_toward(rotation.y, target_yaw, max_step)


func _on_animator_gait_changed(gait_name: StringName) -> void:
	gait_changed.emit(gait_name)


## Lifts the wolf onto small ledges.
##
## CharacterBody3D has no step-climbing of its own: the near face of a 0.2 m box
## is a vertical wall, so move_and_slide() just slides along it and the wolf stops
## dead. A quadruped should step over obstacles that low, so probe for them.
##
## Two test_move() probes distinguish a step from a wall and from a ledge:
##   * lifted by max_step_height, is the path forward clear? If not it is a wall.
##   * from there, is there ground within reach below? If not it is a ledge over a
##     drop, and stepping up would strand the wolf in mid-air.
## Only then is the body moved, and apply_floor_snap() settles it onto the surface
## so the lift does not read as a hop.
func _try_step_up(wish_dir: Vector3) -> void:
	if _airborne or wish_dir.is_zero_approx() or max_step_height <= 0.0:
		return
	if not is_on_wall():
		return
	# Only step when actually pushing into the obstacle, not brushing past it.
	if wish_dir.dot(get_wall_normal()) > -0.25:
		return

	var forward: Vector3 = Vector3(wish_dir.x, 0.0, wish_dir.z).normalized() \
			* step_probe_distance
	var lift: Vector3 = Vector3.UP * max_step_height

	var lifted: Transform3D = global_transform
	lifted.origin += lift
	# Still blocked when lifted clear of the obstacle: it is a wall, not a step.
	if test_move(lifted, forward):
		return

	var ahead: Transform3D = lifted
	ahead.origin += forward
	# Nothing to land on: a ledge over a drop rather than a step up.
	if not test_move(ahead, Vector3.DOWN * (max_step_height + 0.05)):
		return

	global_position += lift + forward
	apply_floor_snap()


func _begin_jump() -> void:
	velocity.y = jump_velocity
	_airborne = true
	_coyote_timer = 0.0
	_jump_buffer_timer = 0.0
	# Airtime is fully known at takeoff for a ballistic jump, so the animator can
	# fit the fixed 0.75 s clip to it exactly instead of slicing the clip into
	# takeoff/air/land states.
	_animator.enter_air(2.0 * jump_velocity / maxf(gravity, 0.001))
	jumped.emit()


func _update_motion_state() -> void:
	if _airborne:
		if is_on_floor() and velocity.y <= 0.0:
			_airborne = false
			_animator.enter_ground()
			landed.emit(absf(velocity.y))
	elif not is_on_floor() and _coyote_timer <= 0.0:
		# Walked off a ledge -- airtime is not known in advance, unlike a jump.
		_airborne = true
		_animator.enter_fall()


func _tick_timers(delta: float) -> void:
	_coyote_timer = maxf(_coyote_timer - delta, 0.0)
	_jump_buffer_timer = maxf(_jump_buffer_timer - delta, 0.0)


## Speed the ANIMATION is producing, in this body's local space. Not used to
## drive movement -- this is the foot-slip readout and the calibration hook.
##
## %Animator reports in its own space; that equals body space because the
## component sits unrotated under this node, which verify_wolf_static.gd asserts.
func measured_animation_speed(delta: float) -> float:
	return _animator.measured_speed(delta)
