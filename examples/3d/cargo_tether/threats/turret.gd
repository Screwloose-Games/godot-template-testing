class_name TetherTurret
extends StaticBody3D

## A fixed emplacement that leads its shots.
##
## TURRETS ARE TERRAIN WITH A CLOCK. The player has no weapon, so a turret is not
## an enemy to be beaten -- it is a hazard with a rhythm and a shadow, and you
## learn to route around it the same way you learn to route around a rock. It is
## indestructible for the same reason a rock is.
##
## Three things turn a perfect firing solution into a FAIR one, and all three
## matter more than the solution itself:
##
##   * The slew rate limit. This is what makes juking work: change your velocity
##     vector and the turret's aim is now wrong and takes time to correct.
##     Without it a turret is a hitscan with no counterplay whatsoever.
##   * The fire cone. It only shoots when actually aligned, so a mid-slew turret
##     visibly holds fire and the player can read that it is about to shoot.
##   * Seeded lead error. Bursts spread, so flying a straight line past a turret
##     is survivable-but-punished rather than instantly fatal. Seeded off the
##     turret's own index, so a run is reproducible and the verifier deterministic.
##
## It finds its targets through TetherRun rather than through exported NodePaths,
## because a course carries a dozen of these and wiring three paths into each one
## by hand is how a generator script grows bugs.

enum State { IDLE, TRACKING, FIRING }

## Physics frames between target re-evaluations. Distance and line-of-sight do not
## need re-deciding at 60 Hz, and seven turrets doing so is seven wasted rays.
const RETARGET_INTERVAL: int = 4

@export_group("Targeting")
@export var range_metres: float = 240.0
## Preference for shooting the cargo over the ship. Above 1.0 the turret favours
## the crate -- THE THREAT MODEL IS THAT THEY SHOOT THE THING YOU ARE PROTECTING,
## and it costs one multiply.
@export var cargo_preference: float = 1.15
## Degrees per second the barrel can slew. The counterplay knob.
@export var slew_rate_degrees: float = 70.0
## How closely aligned it must be before firing.
@export var fire_cone_degrees: float = 4.0
## Peak angular error added per burst, in degrees.
@export var lead_error_degrees: float = 1.2
## Distinguishes this turret's error rolls from its neighbours'. The course
## generator writes the index; a hand-placed turret should be given a unique one.
@export var seed_index: int = 0

@export_group("Firing")
@export var muzzle_speed: float = 220.0
@export var shots_per_burst: int = 3
@export var burst_spacing: float = 0.12
@export var fire_interval: float = 0.9
@export var damage: float = 8.0

var _state: State = State.IDLE
var _target: Node3D = null
var _aim: Vector3 = Vector3.FORWARD
var _cooldown: float = 0.0
var _burst_left: int = 0
var _burst_timer: float = 0.0
var _frame: int = 0
var _error: Vector3 = Vector3.ZERO
var _rng := RandomNumberGenerator.new()
var _run: TetherRun = null

@onready var _yaw: Node3D = %Yaw as Node3D
@onready var _pitch: Node3D = %Pitch as Node3D
@onready var _muzzle: Marker3D = %Muzzle as Marker3D


func _ready() -> void:
	_rng.seed = hash("cargo_tether_turret") + seed_index
	_cooldown = _rng.randf() * fire_interval  # Stagger, so a row does not volley.
	_run = TetherRun.find_in(self)


func _physics_process(delta: float) -> void:
	_frame += 1
	if _run == null:
		_run = TetherRun.find_in(self)
		return
	if _frame % RETARGET_INTERVAL == 0:
		_choose_target()
	if _target == null:
		_state = State.IDLE
		return

	_aim = _lead_direction(_target)
	_slew(delta)
	_tick_firing(delta)


func state() -> State:
	return _state


## Where the barrel is currently pointing. Public so a verifier can measure the
## solution without waiting for a shot.
func aim_direction() -> Vector3:
	return -_muzzle.global_basis.z


## The unit direction that puts a shot on `target` given its current velocity.
##
## Solves |T + V*t - P| = s*t for the flight time t, which is a quadratic in t:
##   (V.V - s^2) t^2 + 2 (D.V) t + D.D = 0,  D = T - P
## Falls back to the raw bearing when there is no positive root -- a target
## outrunning the shell has no interception, and aiming straight at it is the
## honest answer rather than a NaN.
func _lead_direction(target: Node3D) -> Vector3:
	var muzzle: Vector3 = _muzzle.global_position
	var offset: Vector3 = target.global_position - muzzle
	var velocity: Vector3 = Vector3.ZERO
	if target is RigidBody3D:
		velocity = (target as RigidBody3D).linear_velocity

	var flight: float = -1.0
	var a: float = velocity.dot(velocity) - muzzle_speed * muzzle_speed
	var b: float = 2.0 * offset.dot(velocity)
	var c: float = offset.dot(offset)
	if absf(a) < 0.0001:
		# Target speed equals muzzle speed: the quadratic collapses to linear.
		if absf(b) > 0.0001:
			flight = -c / b
	else:
		var discriminant: float = b * b - 4.0 * a * c
		if discriminant >= 0.0:
			var root: float = sqrt(discriminant)
			var first: float = (-b + root) / (2.0 * a)
			var second: float = (-b - root) / (2.0 * a)
			# Smallest positive root: the earliest interception.
			flight = _smallest_positive(first, second)

	if flight <= 0.0:
		return offset.normalized()
	return (offset + velocity * flight).normalized() + _error


func _smallest_positive(first: float, second: float) -> float:
	if first > 0.0 and second > 0.0:
		return minf(first, second)
	return maxf(first, second)


## Closest valid target, with the cargo weighted so it is preferred.
func _choose_target() -> void:
	_target = null
	if _run.ship == null:
		return
	var best: float = range_metres
	for candidate: Node3D in [_run.ship, _run.cargo]:
		if candidate == null:
			continue
		var distance: float = global_position.distance_to(candidate.global_position)
		if distance > range_metres:
			continue
		# Dividing by the preference makes the cargo *look* closer than it is.
		var weighted: float = distance
		if candidate == _run.cargo:
			weighted /= maxf(cargo_preference, 0.001)
		if weighted < best and _has_line_of_sight(candidate):
			best = weighted
			_target = candidate
	if _target != null and _state == State.IDLE:
		_state = State.TRACKING


## Only rock blocks sight. Turrets deliberately do not occlude each other, so two
## covering the same chokepoint both fire rather than one silently holding.
func _has_line_of_sight(target: Node3D) -> bool:
	var query := PhysicsRayQueryParameters3D.create(
		_muzzle.global_position, target.global_position, TetherLayers.MASK_TURRET_LOS
	)
	return get_world_3d().direct_space_state.intersect_ray(query).is_empty()


## Rate-limited tracking, decomposed into the yaw and pitch pivots. Both use
## rotate_toward so the shortest way round a wrap is taken.
func _slew(delta: float) -> void:
	var local: Vector3 = global_basis.inverse() * _aim
	if local.length_squared() < 0.000001:
		return
	local = local.normalized()
	var wanted_yaw: float = atan2(-local.x, -local.z)
	var wanted_pitch: float = asin(clampf(local.y, -1.0, 1.0))
	var step: float = deg_to_rad(slew_rate_degrees) * delta
	_yaw.rotation.y = rotate_toward(_yaw.rotation.y, wanted_yaw, step)
	_pitch.rotation.x = rotate_toward(_pitch.rotation.x, wanted_pitch, step)


func _tick_firing(delta: float) -> void:
	if _burst_left > 0:
		_burst_timer -= delta
		if _burst_timer <= 0.0:
			_shoot()
		return

	_cooldown -= delta
	if _cooldown > 0.0:
		_state = State.TRACKING
		return
	# Only once actually aligned. A turret still slewing visibly holds fire, which
	# is the tell the player reads.
	if aim_direction().angle_to(_aim) > deg_to_rad(fire_cone_degrees):
		_state = State.TRACKING
		return
	_state = State.FIRING
	_burst_left = shots_per_burst
	_burst_timer = 0.0
	_roll_error()


## One fresh error per burst, not per shot: within a burst the shots should group,
## between bursts they should not.
func _roll_error() -> void:
	var spread: float = tan(deg_to_rad(lead_error_degrees))
	_error = Vector3(_rng.randfn(0.0, spread), _rng.randfn(0.0, spread), _rng.randfn(0.0, spread))


func _shoot() -> void:
	_burst_left -= 1
	_burst_timer = burst_spacing
	if _burst_left <= 0:
		_cooldown = fire_interval
	var pool: ProjectilePool = null if _run == null else _run.projectiles
	if pool == null:
		return
	pool.fire(_muzzle.global_position, aim_direction(), muzzle_speed, damage, get_rid())
