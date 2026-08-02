class_name TetherDamage
extends Node

## An integrity pool for whatever body it is parented to, and the impact detector
## that drains it.
##
## The same component runs on the ship and on the cargo with different numbers, so
## the damage curve exists exactly once and the HUD reads the same table the
## solver used.
##
## IMPACT IS MEASURED AS CHANGE IN VELOCITY ACROSS ONE PHYSICS STEP, deliberately
## not as PhysicsDirectBodyState3D.get_contact_impulse(). Contact-impulse
## normalisation has moved between Jolt bridge releases, and a damage curve built
## on a number that changes meaning between engine patches is a landmine that goes
## off during an engine upgrade, months later, as "combat feels wrong now".
## Delta-v IS impulse/mass -- the actual "how hard did it hit" quantity -- and it
## is computed from linear_velocity, which every backend agrees on.

signal integrity_changed(current: float, maximum: float)
signal damage_taken(amount: float, source_kind: StringName)
signal destroyed

## Below this closing speed an impact costs nothing.
##
## It is also the NOISE FLOOR, and that is not a coincidence -- it is why the
## number is 8 and not 2. Delta-v also picks up thrust and tether acceleration,
## and the worst case there is (33 boost + 68 tether) / 60 Hz = 1.7 m/s per step.
## Anything below the free threshold is therefore indistinguishable from flying
## hard, by construction. Do not "tidy" this down.
const NOISE_FLOOR_HINT: float = 1.7

@export var max_integrity: float = 100.0
## Flat cost of one turret hit. Flat rather than proportional because a raycast
## has no impulse to be proportional to.
@export var projectile_damage: float = 8.0
## Closing speed, in m/s, below which a collision is free. Drifting into a rock
## should cost nothing; whipping the cargo into one should nearly kill it.
@export var impact_free_speed: float = 8.0
## Integrity lost per m/s of delta-v above the free speed.
@export var impact_per_ms: float = 1.6
## Seconds of immunity after a contact hit.
##
## CONTACT ONLY. Jolt reports multiple contacts per frame for a single collision
## and a scrape along a rock is continuous, so without this one graze drains the
## bar in half a second. Projectiles deliberately BYPASS it: each raycast hit is
## one discrete event, and a three-shot burst has to cost three times or turrets
## are toothless. That asymmetry looks like a bug in the code, which is why it is
## written down here and in CLAUDE.md.
@export var contact_iframes: float = 0.25

## Metres per second of velocity change across the last physics step.
var last_delta_v: float = 0.0

var _current: float = 0.0
var _body: RigidBody3D
var _last_velocity: Vector3 = Vector3.ZERO
var _iframes_left: float = 0.0
var _touching: int = 0
var _last_source: Node = null


func _ready() -> void:
	_current = max_integrity
	_body = get_parent() as RigidBody3D
	if _body == null:
		push_error("TetherDamage must be a child of a RigidBody3D.")
		return
	# Both are required for body_entered/body_exited to fire at all.
	_body.contact_monitor = true
	_body.max_contacts_reported = maxi(_body.max_contacts_reported, 4)
	# Named methods, never lambdas: a lambda captures by value and the flag it
	# sets stays false forever.
	_body.body_entered.connect(_on_body_entered)
	_body.body_exited.connect(_on_body_exited)
	_last_velocity = _body.linear_velocity


func _physics_process(delta: float) -> void:
	if _body == null:
		return
	last_delta_v = (_body.linear_velocity - _last_velocity).length()
	_last_velocity = _body.linear_velocity
	_iframes_left = maxf(_iframes_left - delta, 0.0)
	if _touching > 0 and _iframes_left <= 0.0:
		apply_impact(last_delta_v, _last_source)


## One turret hit. Bypasses i-frames on purpose -- see contact_iframes.
func apply_projectile(amount: float = -1.0) -> void:
	_spend(projectile_damage if amount < 0.0 else amount, &"projectile")


## A collision, priced off the closing speed. Below the free speed this is a
## no-op, which is what teaches the player that gentle contact is survivable.
func apply_impact(delta_v: float, source: Node = null) -> void:
	var amount: float = maxf(delta_v - impact_free_speed, 0.0) * impact_per_ms
	if amount <= 0.0:
		return
	_iframes_left = contact_iframes
	_last_source = source
	_spend(amount, &"impact")


func integrity() -> float:
	return _current


func fraction() -> float:
	return clampf(_current / maxf(max_integrity, 0.001), 0.0, 1.0)


func is_destroyed() -> bool:
	return _current <= 0.0


## Back to full, for a restart.
func restore() -> void:
	_current = max_integrity
	_iframes_left = 0.0
	_touching = 0
	last_delta_v = 0.0
	_last_velocity = Vector3.ZERO if _body == null else _body.linear_velocity
	integrity_changed.emit(_current, max_integrity)


func _spend(amount: float, kind: StringName) -> void:
	if _current <= 0.0:
		return
	_current = maxf(_current - amount, 0.0)
	damage_taken.emit(amount, kind)
	integrity_changed.emit(_current, max_integrity)
	if _current <= 0.0:
		destroyed.emit()


func _on_body_entered(body: Node) -> void:
	_touching += 1
	_last_source = body


func _on_body_exited(_body_left: Node) -> void:
	_touching = maxi(_touching - 1, 0)
