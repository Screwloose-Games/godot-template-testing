class_name AsteroidField
extends Node3D

## Drifts and spins every asteroid under it, from one script.
##
## ANALYTIC, NOT INTEGRATED. Each rock's pose is a pure function of elapsed time
## and its own index, so the field is deterministic across runs, accumulates no
## drift over a four-minute course, rewinds to the start by assigning `_elapsed =
## 0`, and can be asserted at t = 12 s without simulating twelve seconds. An
## integrated velocity would fail all four.
##
## The motion is a BOUNDED OSCILLATION rather than linear travel: nothing ever
## leaves the course, so there is no wrap-around teleport to hide and the
## generator's corridor-clearance check stays true for the whole run rather than
## only at t = 0.
##
## One manager rather than a script per rock. Ninety nodes each with their own
## _physics_process is ninety script calls a frame to move ninety transforms, and
## the rocks are AnimatableBody3D precisely so that moving them is a transform
## write and nothing else.

## Metres of travel either side of rest. Kept small: the corridor clearance the
## generator asserts has to survive the whole oscillation, so every metre here is
## a metre off the guaranteed gap.
@export var drift_amplitude: float = 3.0
## Radians per second, roughly. Slow enough to read as drift, not as machinery.
@export var drift_rate: float = 0.12
@export var spin_rate: float = 0.15
## Only rocks within this range of the ship are animated. Nobody can see a rock
## drift three metres from four hundred away.
@export var drift_radius: float = 250.0
@export var field_seed: int = 20260730

var _bodies: Array[Node3D] = []
var _rest: Array[Transform3D] = []
var _phase: PackedVector3Array = PackedVector3Array()
var _rate: PackedVector3Array = PackedVector3Array()
var _spin_axis: PackedVector3Array = PackedVector3Array()
var _spin: PackedFloat32Array = PackedFloat32Array()
var _elapsed: float = 0.0
var _ship: Node3D = null


func _ready() -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = field_seed
	for child: Node in get_children():
		var body: Node3D = child as Node3D
		if body == null:
			continue
		_bodies.append(body)
		_rest.append(body.transform)
		_phase.append(Vector3(rng.randf() * TAU, rng.randf() * TAU, rng.randf() * TAU))
		_rate.append(
			Vector3(
				drift_rate * rng.randf_range(0.6, 1.4),
				drift_rate * rng.randf_range(0.6, 1.4),
				drift_rate * rng.randf_range(0.6, 1.4)
			)
		)
		var axis := Vector3(rng.randfn(), rng.randfn(), rng.randfn())
		if axis.length_squared() < 0.0001:
			axis = Vector3.UP
		_spin_axis.append(axis.normalized())
		_spin.append(spin_rate * rng.randf_range(-1.0, 1.0))


func _physics_process(delta: float) -> void:
	_elapsed += delta
	if _ship == null:
		var run: TetherRun = TetherRun.find_in(self)
		_ship = null if run == null else run.ship
	var focus: Vector3 = Vector3.ZERO if _ship == null else _ship.global_position
	var radius_squared: float = drift_radius * drift_radius
	for i: int in _bodies.size():
		var rest: Transform3D = _rest[i]
		if _ship != null and rest.origin.distance_squared_to(focus) > radius_squared:
			continue
		_bodies[i].transform = pose_at(i, _elapsed)


## The pose of asteroid `index` at time `seconds`. Public and pure, so a verifier
## can assert a future position without waiting for it.
func pose_at(index: int, seconds: float) -> Transform3D:
	var rest: Transform3D = _rest[index]
	var phase: Vector3 = _phase[index]
	var rate: Vector3 = _rate[index]
	var offset := Vector3(
		sin(seconds * rate.x + phase.x),
		sin(seconds * rate.y + phase.y),
		sin(seconds * rate.z + phase.z)
	)
	var basis: Basis = Basis(_spin_axis[index], _spin[index] * seconds) * rest.basis
	return Transform3D(basis, rest.origin + offset * drift_amplitude)


func asteroid_count() -> int:
	return _bodies.size()
