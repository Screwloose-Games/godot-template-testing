class_name ShipController
extends RigidBody3D

## The player's ship: 6DOF Newtonian flight, the inertial dampener, boost, and the
## winch controls.
##
## A RigidBody3D rather than a CharacterBody3D, for three reasons in order of
## weight. The tether's reaction force on the hull IS the feel of this prototype,
## and a kinematic body means re-deriving F = ma here so that two files both
## believe they own the ship's velocity. Clipping an asteroid has to impart spin
## and the tether's off-centre pull has to produce yaw, and a CharacterBody3D has
## no angular integrator at all. And "6DOF Newtonian drift" is a literal
## description of a rigid body with gravity_scale = 0 -- writing it kinematically
## means reimplementing the solver that is already there.
##
## This is the ONLY file in the example that reads input. It owns the mouse, the
## mouse mode, and every `ship_*` action, including the winch pair -- so the
## tether can be driven programmatically by a verifier with no player present.

## Which way is roll-left.
##
## A positive rotation about the body's +Z carries +X toward +Y, i.e. lifts the
## right wing, which is a roll to the LEFT. Derivable rather than measured, but
## pinned as a constant for the same reason JeepController pins
## FORWARD_ENGINE_SIGN: if a future engine release flips a convention, flip this,
## do not rewrite the control mapping around it.
const ROLL_SIGN: float = 1.0

@export_group("Thrust")
## Newtons along the ship's -Z. 28 kN on a 1000 kg hull is 28 m/s^2 free, and
## 17.5 with the 600 kg cargo attached -- you keep 62.5% of your acceleration
## while towing, which is a load you feel constantly and never resent.
@export var thrust_main: float = 28000.0
## Strafe and vertical thrusters. Deliberately much weaker than the main engine:
## turning the nose has to stay the fast way to change direction, or the ship
## flies like a hovering camera and the tether never swings.
@export var thrust_lateral: float = 12000.0
## Retro thrust as a fraction of main. Backing up is for corrections, not travel.
@export var reverse_fraction: float = 0.45

@export_group("Boost")
@export var boost_multiplier: float = 1.9
## Seconds of boost from full.
@export var boost_capacity: float = 3.2
## Seconds of boost regained per second of not boosting.
@export var boost_refill: float = 0.55
## Forced wait after running the tank dry, so boost cannot be stuttered.
@export var boost_lockout: float = 1.0

@export_group("Rotation")
## Peak torque the attitude controller may command.
##
## Sized against the tether, not picked. The hull is a 3.0 x 1.6 x 6.0 m box at
## 1000 kg, so its yaw inertia is m(w^2 + l^2)/12 = 3750 kg.m^2. A hard swing puts
## ~17 kN in the line, and the tail anchor is 3.0 m back, so the tether can ask
## for 51 kN.m -- 13.6 rad/s^2 of yaw the player did not command. At 110 kN.m the
## player has 29 rad/s^2, about 2.2x that. You always win the fight, but not
## instantly, and the second it costs you is what makes a bad swing hurt.
##
## These three numbers move together. Retune the mass, the hull size or the anchor
## offset and this has to be recomputed; verify_cargo_tether_runtime [torque-yank]
## is what catches it if it is not.
@export var torque_max: float = 110000.0
@export var torque_roll: float = 75000.0
## Radians per second the mouse may ask for.
@export var rate_max: float = 2.4
@export var roll_rate_max: float = 3.2
## Radians per second of commanded rate per pixel of mouse motion.
@export var mouse_sensitivity: float = 0.0055
## How hard the controller chases the commanded rate.
@export var rate_gain: float = 3.0
## How fast an uncommanded rate bleeds back to zero, 1/s. This is what makes the
## mouse feel like a stick rather than a gyro; it is pure taste, so it is exported.
@export var rate_decay: float = 6.0

@export_group("Dampener")
## Starts off. Drifting sideways while pointing backwards is the fantasy; the
## dampener is the assist you switch on to park.
@export var dampener_on: bool = false
## 1/s. How hard the dampener pulls uncommanded axes toward zero velocity.
@export var damp_gain: float = 2.2
## Same, for the held all-axis brake.
@export var brake_gain: float = 6.0

@export_group("Speed")
## Metres per second past which drag starts. Not a clamp: a hard velocity clamp
## is a wall you can feel, and it fights the tether by silently eating the
## momentum the spring just gave you.
@export var soft_speed_cap: float = 110.0
## Quadratic drag coefficient above the cap. 7.2 kN at 130 m/s against 28 kN of
## thrust, so boost can still punch through and it stays Newtonian below the cap.
@export var cap_gain: float = 18.0

@export_group("Wiring")
## The tether this ship's winch controls. Optional: the ship flies without one.
@export var tether: TetherLink
## Captures the mouse on the first click. Turn off when embedding in a tool scene.
@export var capture_mouse: bool = true

var _mouse_delta: Vector2 = Vector2.ZERO
var _target_rate: Vector3 = Vector3.ZERO
var _thrust_input: Vector3 = Vector3.ZERO
var _boost_left: float = 0.0
var _boost_held: bool = false
var _lockout_left: float = 0.0
var _braking: bool = false
var _winch_held: bool = false
var _spawn_transform: Transform3D = Transform3D.IDENTITY


func _ready() -> void:
	_spawn_transform = global_transform
	_boost_left = boost_capacity
	# Zero gravity is the setting, but the scene file is where it belongs; this is
	# only a guard so a hand-edited scene cannot quietly reintroduce a floor.
	if not is_zero_approx(gravity_scale):
		gravity_scale = 0.0
	can_sleep = false


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseMotion:
		if Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
			_mouse_delta += (event as InputEventMouseMotion).relative
		return
	# Capture on the first click rather than in _ready(). Setting
	# MOUSE_MODE_CAPTURED before a user gesture is a silent no-op in a browser,
	# and this repo is web-first -- doing it in _ready() ships a build whose
	# controls half-work and gives no error.
	if event is InputEventMouseButton and (event as InputEventMouseButton).pressed:
		if capture_mouse and Input.mouse_mode != Input.MOUSE_MODE_CAPTURED:
			Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
		return
	if event.is_action_pressed(&"ui_cancel"):
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE


func _physics_process(delta: float) -> void:
	_read_input(delta)
	_apply_thrust()
	_apply_rotation(delta)
	_apply_dampener()
	_apply_speed_cap()


## Drops the ship at an arbitrary pose, stationary.
##
## Assigning global_transform on a rigid body fights the solver, and under Jolt it
## can be ignored outright, so the move goes through the physics server. Lifted
## from JeepController.place_at(), which is where this was learned.
func place_at(wanted: Transform3D) -> void:
	linear_velocity = Vector3.ZERO
	angular_velocity = Vector3.ZERO
	PhysicsServer3D.body_set_state(get_rid(), PhysicsServer3D.BODY_STATE_TRANSFORM, wanted)
	PhysicsServer3D.body_set_state(
		get_rid(), PhysicsServer3D.BODY_STATE_LINEAR_VELOCITY, Vector3.ZERO
	)
	PhysicsServer3D.body_set_state(
		get_rid(), PhysicsServer3D.BODY_STATE_ANGULAR_VELOCITY, Vector3.ZERO
	)
	global_transform = wanted
	_target_rate = Vector3.ZERO


## Back to the spawn pose, stationary, with a full boost tank.
func respawn() -> void:
	place_at(_spawn_transform)
	_boost_left = boost_capacity
	_lockout_left = 0.0


## Whether boost is actually firing, as opposed to merely being held.
func is_boosting() -> bool:
	return _boost_held and _boost_left > 0.0 and _lockout_left <= 0.0


## Everything the HUD and the verifiers read. One call, so nothing outside needs
## to know how boost or the dampener are bookkept.
func debug_state() -> Dictionary:
	return {
		"speed": linear_velocity.length(),
		"forward_speed": -global_basis.z.dot(linear_velocity),
		"velocity": linear_velocity,
		"boost_left": _boost_left,
		"boosting": is_boosting(),
		"dampener": dampener_on,
		"braking": _braking,
		"thrust_input": _thrust_input,
		"spin": angular_velocity.length(),
	}


func _read_input(delta: float) -> void:
	var strafe: float = Input.get_axis(&"ship_strafe_left", &"ship_strafe_right")
	var vertical: float = Input.get_axis(&"ship_sink", &"ship_rise")
	var forward: float = 0.0
	if Input.is_action_pressed(&"ship_thrust"):
		forward += 1.0
	if Input.is_action_pressed(&"ship_reverse"):
		forward -= reverse_fraction
	_thrust_input = Vector3(strafe, vertical, forward)

	_braking = Input.is_action_pressed(&"ship_brake")
	_tick_boost(delta)

	var roll: float = Input.get_axis(&"ship_roll_right", &"ship_roll_left")
	_target_rate.x = clampf(-_mouse_delta.y * mouse_sensitivity, -rate_max, rate_max)
	_target_rate.y = clampf(-_mouse_delta.x * mouse_sensitivity, -rate_max, rate_max)
	_target_rate.z = roll * roll_rate_max * ROLL_SIGN
	_mouse_delta = Vector2.ZERO

	if Input.is_action_just_pressed(&"ship_dampener"):
		dampener_on = not dampener_on
	# ship_restart is deliberately NOT handled here. TetherRun owns it, because
	# restarting is a property of the run, and two nodes both calling
	# reload_current_scene() on the same frame is a race worth not having.

	_read_winch()


## The winch is a set-point, not a rate command, so the keys and the wheel drive
## the same variable. A wheel event is a press immediately followed by a release
## and cannot express "held", so it steps the target; the keys drag the target to
## the end of the band and let go of it where you released them. Either way
## TetherWinch.step() is what actually moves the rest length, which is what keeps
## a wheel click from becoming a step input into the spring.
func _read_winch() -> void:
	if tether == null:
		return
	var reeling_in: bool = Input.is_action_pressed(&"ship_reel_in")
	var paying_out: bool = Input.is_action_pressed(&"ship_reel_out")
	if reeling_in != paying_out:
		tether.target_length = TetherWinch.MIN_LENGTH if reeling_in else TetherWinch.MAX_LENGTH
		_winch_held = true
	elif _winch_held:
		# ON THE RELEASE EDGE ONLY: stop where the line actually is, rather than
		# where the target had run ahead to.
		#
		# Latching once rather than every idle frame matters more than it looks.
		# Writing target_length continuously means NOTHING ELSE CAN EVER DRIVE
		# THE WINCH -- a capture tool or a verifier sets a target and the ship
		# overwrites it on the next physics frame, so the rest length simply
		# never moves and the winch appears to be broken rather than overridden.
		tether.target_length = tether.rest_length
		_winch_held = false

	if Input.is_action_just_pressed(&"ship_reel_step_in"):
		tether.target_length = tether.rest_length - TetherWinch.WHEEL_STEP
	if Input.is_action_just_pressed(&"ship_reel_step_out"):
		tether.target_length = tether.rest_length + TetherWinch.WHEEL_STEP

	if Input.is_action_just_pressed(&"ship_tether_toggle"):
		if tether.is_attached():
			tether.release()
		else:
			tether.try_attach()


func _tick_boost(delta: float) -> void:
	_boost_held = Input.is_action_pressed(&"ship_boost")
	if _lockout_left > 0.0:
		_lockout_left -= delta
		return
	if _boost_held and _boost_left > 0.0:
		_boost_left -= delta
		if _boost_left <= 0.0:
			_boost_left = 0.0
			_lockout_left = boost_lockout
		return
	_boost_left = minf(_boost_left + boost_refill * delta, boost_capacity)


func _apply_thrust() -> void:
	var main: float = thrust_main
	if is_boosting():
		main *= boost_multiplier
	var local := Vector3(
		_thrust_input.x * thrust_lateral,
		_thrust_input.y * thrust_lateral,
		-_thrust_input.z * main,
	)
	if not local.is_zero_approx():
		apply_central_force(global_basis * local)


func _apply_rotation(delta: float) -> void:
	var local_rate: Vector3 = global_basis.transposed() * angular_velocity
	var error: Vector3 = _target_rate - local_rate
	var wanted := Vector3(
		error.x * rate_gain * torque_max,
		error.y * rate_gain * torque_max,
		error.z * rate_gain * torque_roll,
	)
	apply_torque(global_basis * wanted.limit_length(torque_max))
	# Bleed the commanded rate rather than holding it. Rotation is ALWAYS damped,
	# even with the translational dampener off: with no rotational authority over
	# an existing spin, one clipped asteroid leaves the player tumbling behind a
	# mouse that can only add rate, and the game stops being playable. Roll stays
	# genuinely free -- hold E and you spin forever, you just do not keep spinning
	# after you let go.
	_target_rate = _target_rate.lerp(Vector3.ZERO, 1.0 - exp(-rate_decay * delta))


## Per body axis, and only on axes the player is not commanding.
##
## That is the whole trick: it lets you hold forward thrust while the dampener
## kills the lateral drift you picked up in the last corner, which a global
## linear_damp cannot express because it cannot tell the two apart.
func _apply_dampener() -> void:
	if not dampener_on and not _braking:
		return
	var gain: float = brake_gain if _braking else damp_gain
	# Boosting deliberately loosens the dampener, so committing to a burn slides.
	var authority: float = thrust_lateral * (0.25 if is_boosting() else 1.0)
	if _braking:
		authority = thrust_lateral
	var local_velocity: Vector3 = global_basis.transposed() * linear_velocity
	var local_force := Vector3.ZERO
	for axis: int in 3:
		# The brake overrides input; the dampener yields to it.
		if not _braking and not is_zero_approx(_thrust_input[axis]):
			continue
		local_force[axis] = clampf(-local_velocity[axis] * gain * mass, -authority, authority)
	if not local_force.is_zero_approx():
		apply_central_force(global_basis * local_force)


func _apply_speed_cap() -> void:
	var speed: float = linear_velocity.length()
	if speed <= soft_speed_cap:
		return
	var excess: float = speed - soft_speed_cap
	apply_central_force(-linear_velocity / speed * cap_gain * excess * excess)
