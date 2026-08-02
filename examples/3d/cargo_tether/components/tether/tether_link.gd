class_name TetherLink
extends Node

## The tether. An elastic spring-damper between the ship and the cargo, and the
## only file in this example that applies a tether force.
##
## ONE NODE COMPUTES ONE FORCE AND APPLIES +F AND -F. Newton's third law is
## guaranteed by construction rather than by two scripts agreeing on a sign, which
## matters more than it sounds: the whole feel of this prototype is the reaction
## the cargo puts back into the ship, and a sign error there produces a cargo that
## trails perfectly while the ship flies as if it were empty. That reads as
## "tether works", and it is the bug.
##
## Deliberately NOT `_integrate_forces`. That hands you the state of ONE body, so
## a two-body constraint written there has to read the other body's velocity
## out-of-band anyway -- you lose the symmetry and gain nothing. Forces queued in
## `_physics_process` are consumed by the very next server step, so there is no
## latency cost either.
##
## It reads no input. ShipController owns every `ship_*` action and writes
## `target_length` here, so this file can be driven programmatically by the
## verifier with no camera, no HUD and no player.

## The line broke. `at_overshoot` is how far past the rest length it was when it
## went, so a HUD or a scoring pass can tell a hard yank from a slow drag.
signal tether_snapped(at_overshoot: float, at_position: Vector3)
## Reconnected, either at spawn or by the player flying back to the cargo.
signal tether_attached
## Released on purpose. Distinct from `tether_snapped`: dropping the cargo to
## clear a gap is a tactic, breaking the line is a mistake.
signal tether_released

## Below this separation the axis is undefined and the force is skipped. The
## bodies are metres across, so this is only ever hit by a teleport.
const MIN_SEPARATION: float = 0.0001

@export_group("Wiring")
@export var ship: RigidBody3D
@export var cargo: RigidBody3D
## Where the line meets each body. Marker3Ds, not the body origins: the ship's
## sits at its tail, and that offset is what turns a sideways pull into yaw.
@export var ship_anchor: Node3D
@export var cargo_anchor: Node3D

@export_group("Spring")
## Newtons per metre of stretch.
##
## Sized so that steady towing is legible but safe. Stretch under constant
## acceleration is x = m_cargo * a / k, so at cruise (17.5 m/s^2 with the cargo
## attached) the line sits 1.54 m long, and boosting (33 m/s^2) takes it to
## 2.9 m. Break is at 6 m, so ordinary flight NEVER snaps the tether and only
## violence does -- which is the whole risk/reward shape of the game.
@export var spring_k: float = 6800.0
## Newton-seconds per metre of closing speed. Reduced mass here is
## m_s*m_c/(m_s+m_c) = 375 kg, giving omega = 4.26 rad/s (a 1.47 s axial period)
## and a critical damping of 3200. At 1200 the damping ratio is 0.38: deliberately
## under-damped, because at 1.0 the line stops feeling like a cable and starts
## feeling like a hydraulic strut.
@export var damping_c: float = 1200.0
## Metres of stretch past which the line breaks.
##
## ABSOLUTE, not a fraction of the rest length. A rope breaks at a TENSION, and
## with a constant spring rate an absolute overshoot is exactly a break tension --
## 6800 * 6 = 40.8 kN. Making it relative would make a short winch setting
## effectively unbreakable and a long one unbreakable in practice, which is an
## exploit the winch would find within a minute.
@export var max_overshoot: float = 6.0
## Hard ceiling on tension, ~1.5x break. Only bites during a damping spike on a
## high-speed closing hit. This is NaN insurance, not a design knob.
@export var max_tension: float = 60000.0
## How much of the tether's yaw torque on the ship is kept. 1.0 is fully physical.
## Lower it only if the yank turns out to fight the mouse harder than it is worth;
## the cargo dragging your nose around IS the mechanic, so start at 1.0.
@export_range(0.0, 1.0) var ship_torque_fraction: float = 1.0

@export_group("Reattach")
## How close the ship must be to grab a loose cargo.
@export var reattach_radius: float = 8.0
## And how gently. Without this you could re-attach at 80 m/s and instantly snap
## the new line, which reads as the reattach being broken.
@export var reattach_speed: float = 12.0

## Live rest length, in metres. Only TetherWinch.step() may move it -- see the
## rate-limit note in that file. Read it, do not write it.
var rest_length: float = TetherWinch.START_LENGTH
## Where the winch is being asked to take the rest length. ShipController writes
## this from input; the verifier writes it directly.
var target_length: float = TetherWinch.START_LENGTH

var _attached: bool = true
var _tension: float = 0.0
var _separation: float = 0.0


func _ready() -> void:
	rest_length = clampf(rest_length, TetherWinch.MIN_LENGTH, TetherWinch.MAX_LENGTH)
	target_length = rest_length
	_guard_sleep()
	_guard_stiffness()


func _physics_process(delta: float) -> void:
	if ship == null or cargo == null or ship_anchor == null or cargo_anchor == null:
		return

	# Last frame's tension is what the winch pulls against. Using this frame's
	# would need the force solved before the length that determines it.
	rest_length = TetherWinch.step(rest_length, target_length, _tension, delta)

	var anchor_a: Vector3 = ship_anchor.global_position
	var anchor_b: Vector3 = cargo_anchor.global_position
	var span: Vector3 = anchor_b - anchor_a
	_separation = span.length()
	if not _attached or _separation < MIN_SEPARATION:
		_tension = 0.0
		return

	var axis: Vector3 = span / _separation
	var overshoot: float = _separation - rest_length
	if overshoot <= 0.0:
		# Slack. EXACTLY zero force -- not a small residual. A spring that leaks
		# force below its rest length shows up as the cargo creeping toward the
		# ship whenever you coast, and it is invisible until you look for it.
		_tension = 0.0
		return

	var offset_a: Vector3 = anchor_a - ship.global_position
	var offset_b: Vector3 = anchor_b - cargo.global_position
	# Velocity AT THE ANCHOR, not at the body origin. The angular terms cost two
	# cross products and they damp the mode where the cargo spins about its own
	# anchor while the line is taut; without them a tumbling crate jitters.
	var vel_a: Vector3 = ship.linear_velocity + ship.angular_velocity.cross(offset_a)
	var vel_b: Vector3 = cargo.linear_velocity + cargo.angular_velocity.cross(offset_b)
	var closing: float = (vel_b - vel_a).dot(axis)

	# A ROPE CANNOT PUSH. When the bodies are closing fast at low stretch the
	# damping term goes negative and outruns the spring term, and an unclamped
	# result shoves the cargo away -- which reads to a player as the crate
	# bouncing off an invisible wall. This clamp is the single most commonly
	# omitted line in an elastic tether.
	_tension = clampf(spring_k * overshoot + damping_c * closing, 0.0, max_tension)

	var force: Vector3 = axis * _tension
	_apply_to_ship(force, offset_a)
	cargo.apply_force(-force, offset_b)

	if overshoot > max_overshoot:
		_snap(overshoot, anchor_b)


## Newtons currently in the line. Zero when slack or detached.
func tension() -> float:
	return _tension


## Metres of stretch past the rest length. Negative means slack.
func overshoot() -> float:
	return _separation - rest_length


## Straight-line metres between the two anchors, attached or not.
func separation() -> float:
	return _separation


func is_attached() -> bool:
	return _attached


## How close the line is to breaking, 0 to 1. What the HUD colours the line by.
func strain() -> float:
	if not _attached or max_overshoot <= 0.0:
		return 0.0
	return clampf(overshoot() / max_overshoot, 0.0, 1.0)


## Back to a fresh line at the starting length, attached. Used by a restart, so a
## run that ended with a snapped tether does not begin the next one snapped.
func reset() -> void:
	rest_length = TetherWinch.START_LENGTH
	target_length = TetherWinch.START_LENGTH
	_tension = 0.0
	if not _attached:
		_attached = true
		tether_attached.emit()


## Drops the cargo deliberately. Distinct from a snap, and a real tactic: let the
## crate coast through a gap on its own momentum and pick it up on the far side.
func release() -> void:
	if not _attached:
		return
	_attached = false
	_tension = 0.0
	tether_released.emit()


## Grabs a loose cargo, if the ship is close enough and slow enough relative to
## it. Returns whether it took. Rest length snaps to the current separation so
## reconnecting never produces a yank -- a reattach that immediately re-snaps the
## line reads as the reattach being broken rather than as the player being fast.
func try_attach() -> bool:
	if _attached or ship == null or cargo == null:
		return false
	var gap: float = ship_anchor.global_position.distance_to(cargo_anchor.global_position)
	if gap > reattach_radius:
		return false
	if (cargo.linear_velocity - ship.linear_velocity).length() > reattach_speed:
		return false
	_attached = true
	rest_length = clampf(gap, TetherWinch.MIN_LENGTH, TetherWinch.MAX_LENGTH)
	target_length = rest_length
	tether_attached.emit()
	return true


## One call for the HUD and the verifiers, so nothing outside needs to know how
## tension is derived.
func debug_state() -> Dictionary:
	return {
		"attached": _attached,
		"rest_length": rest_length,
		"target_length": target_length,
		"separation": _separation,
		"overshoot": overshoot(),
		"tension": _tension,
		"strain": strain(),
		"reel_rate": TetherWinch.reel_in_rate(_tension),
		"band": TetherWinch.band_fraction(rest_length),
	}


func _apply_to_ship(force: Vector3, offset: Vector3) -> void:
	if is_equal_approx(ship_torque_fraction, 1.0):
		ship.apply_force(force, offset)
		return
	ship.apply_central_force(force)
	ship.apply_torque(offset.cross(force) * ship_torque_fraction)


func _snap(at_overshoot: float, at_position: Vector3) -> void:
	_attached = false
	_tension = 0.0
	tether_snapped.emit(at_overshoot, at_position)


## A sleeping RigidBody3D silently ignores apply_force(). In zero gravity with no
## input a drifting body WILL fall asleep, and the symptom is a tether that
## "works sometimes" -- the highest-probability silent failure in this example.
## The scenes set can_sleep = false; this is the belt to that pair of braces.
func _guard_sleep() -> void:
	for body: RigidBody3D in [ship, cargo]:
		if body != null and body.can_sleep:
			body.can_sleep = false
			push_warning("TetherLink: forced can_sleep = false on %s." % body.name)


## Explicit Euler needs omega * dt < 2 to stay bounded. Clamping the spring to
## 0.25 * reduced_mass / dt^2 puts omega * dt at 0.5, a factor of four of margin.
##
## This reads the tick rate off Engine rather than off a project setting, because
## the example must behave in a host project whose physics runs at 30 Hz -- and
## since we may not edit project.godot, raising the tick rate is NOT available as
## a fix. Degrading the spring is the only lever there is.
func _guard_stiffness() -> void:
	if ship == null or cargo == null:
		return
	var total: float = ship.mass + cargo.mass
	if total <= 0.0:
		return
	var reduced: float = ship.mass * cargo.mass / total
	var step: float = 1.0 / maxf(float(Engine.physics_ticks_per_second), 1.0)
	var ceiling: float = 0.25 * reduced / (step * step)
	if spring_k > ceiling:
		push_warning(
			(
				"TetherLink: spring_k %.0f exceeds the %.0f stable at %d Hz; clamped."
				% [spring_k, ceiling, Engine.physics_ticks_per_second]
			)
		)
		spring_k = ceiling
