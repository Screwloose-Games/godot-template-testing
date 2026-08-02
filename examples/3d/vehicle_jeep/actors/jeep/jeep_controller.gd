class_name JeepController
extends VehicleBody3D

## Drives the jeep: input, engine and brakes, per-wheel surface grip, respawn.
##
## Names no node inside the model. Everything visible -- wheels turning, the rim
## moving, the turret slewing, the headlights -- is handed to %Visuals, which owns
## that vocabulary. verify_jeep_static.gd check 9 greps this file, comments
## included, to keep it that way.
##
## Godot's VehicleBody3D is a raycast vehicle: each VehicleWheel3D casts down from
## its own node position and applies suspension and tyre forces to the body. That
## means it works under Jolt (it is scene-level, not a physics-engine constraint),
## and it means the wheel nodes must be DIRECT children of this body.

## Emitted after the jeep is teleported back to its spawn, so a HUD or a lap timer
## can reset without polling.
signal respawned
## A wheel started touching a different surface. (wheel index, surface name)
signal surface_changed(wheel_index: int, surface: StringName)

const WHEEL_COUNT: int = 4
## Display labels, in JeepVisuals.Wheel order. Not model node names.
const WHEEL_LABELS: Array[String] = ["FL", "FR", "RL", "RR"]
## How far ahead the turret looks when nothing has told it otherwise -- with no
## camera connected the gun should rest pointing forward, not at the driver's feet.
const DEFAULT_AIM_DISTANCE: float = 60.0
## Below this speed, "reverse" means reverse rather than brake.
const REVERSE_THRESHOLD: float = 0.6
## Which way VehicleBody3D.engine_force pushes.
##
## MEASURED, not assumed: with engine_force = +1200 this jeep accelerates along its
## own +Z, which is BACKWARD (Godot's forward is -Z). So driving forward needs a
## negative engine force. Getting this wrong is not a quiet cosmetic bug -- the
## reverse/brake logic below reads forward_speed, so a jeep accelerating backwards
## under throttle immediately decides it should be braking, and the result is a
## vehicle that oscillates at walking pace and never reaches anything.
## verify_jeep_runtime [drive] asserts travel aligns with -basis.z, which is the
## guard: if a future engine release flips the convention, flip this constant.
const FORWARD_ENGINE_SIGN: float = -1.0

@export_group("Drive")
## Per traction wheel, so 4x this is what actually pushes the jeep. Sized against
## the tyre limit rather than picked for feel: with wheel_friction_slip at 1.0 the
## tyres can pass about 19.6 kN on tarmac and about 5.5 kN on mud, so 8.8 kN total
## is enough to be traction-limited on mud and ice and not on tarmac. That gap IS
## the demo -- below it, mud looks exactly like tarmac.
@export var max_engine_force: float = 2200.0
## Metres per second. 22 is about 79 km/h; the engine cuts out above it rather than
## the drag curve being modelled, which is the honest arcade choice.
@export var max_speed: float = 22.0
@export var brake_force: float = 22.0
## Rear wheels only. That asymmetry is what makes the ice circle fun.
@export var handbrake_force: float = 55.0

@export_group("Steering")
@export var max_steer_degrees: float = 32.0
## Steering lock at max_speed. Without this taper a jeep carrying a turret rolls
## over on the first corner taken at speed.
@export var steer_at_max_speed_degrees: float = 11.0
## Radians per second toward the held direction, and back to centre when released.
@export var steer_rate: float = 1.8
@export var steer_return_rate: float = 3.2

@export_group("Physics")
## The gravity this vehicle is tuned for, in m/s^2. Higher than Earth on purpose:
## the whole suspension tune is derived from it. Applied by calibrating
## gravity_scale against the world's actual gravity on the first physics tick, so
## the jeep handles identically in a host project whose gravity is anything at all
## -- and without reading a project setting.
@export var target_gravity: float = 14.0

@export_group("Wiring")
## Where jeep_respawn puts the jeep. Falls back to wherever it started.
@export var spawn_point: Node3D

var _steer_value: float = 0.0
var _throttle: float = 0.0
var _brake_input: float = 0.0
var _handbrake: bool = false
var _aim_point: Vector3 = Vector3.ZERO
var _spawn_transform: Transform3D = Transform3D.IDENTITY
var _gravity_calibrated: bool = false
var _wheels: Array[VehicleWheel3D] = []
## Authored values, captured before anything modulates them, so restoring a
## surface is exact rather than approximately-the-default.
var _base_friction: PackedFloat32Array = PackedFloat32Array()
var _base_brake: PackedFloat32Array = PackedFloat32Array()
## Suspension rest height per wheel. Only readable BEFORE the first physics frame:
## the engine rewrites each wheel node's position every step, and nothing exposes
## the current compression, so this is the only source the readout has.
var _wheel_rest_y: PackedFloat32Array = PackedFloat32Array()
var _wheel_surface: Array[StringName] = []

@onready var _visuals: JeepVisuals = %Visuals as JeepVisuals


func _ready() -> void:
	_spawn_transform = global_transform
	for child: Node in get_children():
		if child is VehicleWheel3D:
			_wheels.append(child as VehicleWheel3D)
	if _wheels.size() != WHEEL_COUNT:
		push_error(
			(
				"JeepController expects %d VehicleWheel3D children, found %d."
				% [WHEEL_COUNT, _wheels.size()]
			)
		)

	for wheel: VehicleWheel3D in _wheels:
		_base_friction.append(wheel.wheel_friction_slip)
		_base_brake.append(wheel.brake)
		_wheel_rest_y.append(wheel.position.y)
		_wheel_surface.append(JeepSurfaces.DEFAULT)

	_adopt_hull_collision()
	_aim_point = global_position - global_basis.z * DEFAULT_AIM_DISTANCE


func _physics_process(delta: float) -> void:
	_calibrate_gravity()
	_read_input(delta)
	_apply_drive()
	_apply_surfaces()
	_update_visuals(delta)


## Points the turret at a world position. Called by whatever owns aiming -- in the
## demo that is the camera rig, via a signal, so this body knows nothing about any
## camera and the runtime test can aim the gun with no camera in the scene.
func set_aim_point(point: Vector3) -> void:
	_aim_point = point


## Teleports back to the spawn point, stationary and upright.
func respawn() -> void:
	var wanted: Transform3D = _spawn_transform
	if spawn_point != null:
		wanted = spawn_point.global_transform
	place_at(wanted)
	respawned.emit()


## Rights the jeep where it stands, keeping its heading. For the far more common
## case of landing on the roof two metres from where you wanted to be.
func flip_upright() -> void:
	var heading: float = global_rotation.y
	var wanted := Transform3D(Basis(Vector3.UP, heading), global_position + Vector3.UP * 0.6)
	place_at(wanted)


## Everything the HUD and the verifiers read. One call, so nothing outside needs a
## wheel node -- and the grip figure here is the same table the solver used.
func debug_state() -> Dictionary:
	var forward_speed: float = -global_basis.z.dot(linear_velocity)
	var wheels: Array[Dictionary] = []
	var airborne: int = 0
	for index: int in _wheels.size():
		var wheel: VehicleWheel3D = _wheels[index]
		var in_contact: bool = wheel.is_in_contact()
		if not in_contact:
			airborne += 1
		var contact_body: Node3D = wheel.get_contact_body() if in_contact else null
		(
			wheels
			. append(
				{
					"label": WHEEL_LABELS[index],
					"contact": in_contact,
					"surface": _wheel_surface[index],
					"grip": JeepSurfaces.grip(_wheel_surface[index]),
					"friction_slip": wheel.wheel_friction_slip,
					"base_friction_slip": _base_friction[index],
					"skid": wheel.get_skidinfo(),
					"rpm": wheel.get_rpm(),
					"suspension": _wheel_rest_y[index] - wheel.position.y,
					"contact_body": "" if contact_body == null else String(contact_body.name),
				}
			)
		)
	return {
		"speed_ms": linear_velocity.length(),
		"speed_kmh": absf(forward_speed) * 3.6,
		"forward_speed": forward_speed,
		"throttle": _throttle,
		"brake": _brake_input,
		"handbrake": _handbrake,
		"steering_deg": rad_to_deg(steering),
		"steer_input": _steer_value,
		"airborne_wheels": airborne,
		"gravity_scale": gravity_scale,
		"wheels": wheels,
	}


## Rebuilds this body's collision from the shapes the imported model carries, and
## destroys the static proxies they came from. See JeepVisuals.take_body_shapes().
func _adopt_hull_collision() -> void:
	var kept: int = 0
	for entry: Dictionary in _visuals.take_body_shapes():
		if entry["rejected"]:
			continue
		var collider := CollisionShape3D.new()
		collider.name = "Hull_%s" % entry["source"]
		# Not duplicated: the hulls are shared between jeeps on purpose. Nothing
		# mutates a shape at runtime, and a web build should not pay for four
		# copies per vehicle.
		collider.shape = entry["shape"]
		# The entry is in %Visuals space; this body is one hop up.
		collider.transform = _visuals.transform * (entry["transform"] as Transform3D)
		add_child(collider)
		kept += 1
	if kept == 0:
		push_error("JeepController adopted no hull collision -- the jeep will fall through.")


## Pins ride height to `target_gravity` regardless of the host project's gravity.
## Reads the world through the physics server rather than through a project
## setting, and once rather than per frame.
func _calibrate_gravity() -> void:
	if _gravity_calibrated:
		return
	_gravity_calibrated = true
	var state: PhysicsDirectBodyState3D = PhysicsServer3D.body_get_direct_state(get_rid())
	if state == null or is_zero_approx(gravity_scale):
		return
	var world_gravity: float = state.total_gravity.length() / gravity_scale
	if is_zero_approx(world_gravity):
		return
	gravity_scale = target_gravity / world_gravity


func _read_input(delta: float) -> void:
	var forward_speed: float = -global_basis.z.dot(linear_velocity)
	var throttle_held: bool = Input.is_action_pressed(&"jeep_throttle")
	var reverse_held: bool = Input.is_action_pressed(&"jeep_reverse")
	_handbrake = Input.is_action_pressed(&"jeep_handbrake")

	_throttle = 0.0
	_brake_input = 0.0
	if throttle_held and not reverse_held:
		# Rolling backwards with throttle held is braking, not accelerating.
		if forward_speed < -REVERSE_THRESHOLD:
			_brake_input = 1.0
		else:
			_throttle = 1.0
	elif reverse_held and not throttle_held:
		if forward_speed > REVERSE_THRESHOLD:
			_brake_input = 1.0
		else:
			_throttle = -1.0

	var steer_target: float = 0.0
	if Input.is_action_pressed(&"jeep_steer_left"):
		steer_target += 1.0
	if Input.is_action_pressed(&"jeep_steer_right"):
		steer_target -= 1.0
	var rate: float = steer_rate if not is_zero_approx(steer_target) else steer_return_rate
	_steer_value = move_toward(_steer_value, steer_target, rate * delta)

	if Input.is_action_just_pressed(&"jeep_headlights"):
		_visuals.set_headlights(not _visuals.headlights_on())
	if Input.is_action_just_pressed(&"jeep_reset"):
		flip_upright()
	if Input.is_action_just_pressed(&"jeep_respawn"):
		respawn()


func _apply_drive() -> void:
	var speed: float = linear_velocity.length()
	# Above max_speed the engine simply stops pulling. Deliberately blunt: modelling
	# a drag curve would be a nicer lie, and this one is legible in the HUD.
	var throttle: float = 0.0 if speed > max_speed else _throttle
	engine_force = throttle * max_engine_force * FORWARD_ENGINE_SIGN

	# NOTE: this sets the body's engine_force, which broadcasts to every wheel
	# flagged use_as_traction, but never the body's `brake` -- that setter would
	# overwrite the per-wheel braking applied in _apply_surfaces().
	var lock: float = lerpf(
		max_steer_degrees,
		steer_at_max_speed_degrees,
		clampf(speed / maxf(max_speed, 0.001), 0.0, 1.0)
	)
	steering = _steer_value * deg_to_rad(lock)


## Per wheel, not per vehicle. A wheel knows which body its raycast hit, so two
## wheels can be on mud while the other two are on ice -- which is exactly what
## straddling the join between the two lanes in the proving ground does, and what
## a single Area3D on the chassis could never express.
func _apply_surfaces() -> void:
	for index: int in _wheels.size():
		var wheel: VehicleWheel3D = _wheels[index]
		var surface: StringName = JeepSurfaces.DEFAULT
		if wheel.is_in_contact():
			surface = JeepSurfaces.name_for(wheel.get_contact_body())

		if surface != _wheel_surface[index]:
			_wheel_surface[index] = surface
			# Only wheel_friction_slip is modulated. It is the traction
			# coefficient -- what mud and ice actually reduce. wheel_roll_influence
			# is an anti-roll-bar knob: it changes how much the body LEANS, not how
			# much the tyre SLIDES, so touching it here would be a category error.
			# Written on change only, so tweaking friction in the inspector at
			# runtime still works everywhere except across a surface transition.
			wheel.wheel_friction_slip = _base_friction[index] * JeepSurfaces.grip(surface)
			surface_changed.emit(index, surface)

		var brake_total: float = _base_brake[index] + JeepSurfaces.drag(surface)
		brake_total += _brake_input * brake_force
		# Rear wheels only.
		if _handbrake and index >= 2:
			brake_total += handbrake_force
		wheel.brake = brake_total


func _update_visuals(delta: float) -> void:
	for index: int in _wheels.size():
		var wheel: VehicleWheel3D = _wheels[index]
		_visuals.set_wheel_pose(index, wheel.transform, wheel.steering, wheel.get_rpm(), delta)
	_visuals.set_steering_normalized(_steer_value)
	_visuals.aim_turret(_aim_point, delta)


## Drops the jeep at an arbitrary pose, stationary. Public because checkpoints,
## level restarts and the runtime verifier all need it, and because respawn() and
## flip_upright() are just two policies over the same move.
##
## Moving a rigid body by assigning global_transform fights the solver, and under
## Jolt it can be ignored outright. Going through the physics server is the form
## that survives both backends.
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
