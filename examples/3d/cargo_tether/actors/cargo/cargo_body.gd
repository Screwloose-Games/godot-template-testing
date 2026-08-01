class_name CargoBody
extends RigidBody3D

## The towed crate.
##
## Almost nothing: it is a mass on the end of a spring, and TetherLink does all
## the work. What lives here is the handful of body settings that are silently
## wrong by default in zero gravity, and the teleport that survives Jolt.
##
## Integrity and impact detection belong to %Damage (TetherDamage), which is the
## single owner of the delta-v measurement for both this and the ship.

var _spawn_transform: Transform3D = Transform3D.IDENTITY

@onready var _damage: TetherDamage = get_node_or_null("%Damage") as TetherDamage


func _ready() -> void:
	_spawn_transform = global_transform
	if not is_zero_approx(gravity_scale):
		gravity_scale = 0.0
	# A sleeping body silently ignores apply_force(), which in zero gravity means
	# the tether stops existing until something wakes the crate. See TetherLink.
	can_sleep = false


## Drops the crate at an arbitrary pose, stationary. Same physics-server route as
## ShipController.place_at(), and for the same reason: under Jolt, assigning
## global_transform on a rigid body can be ignored outright.
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


func respawn() -> void:
	place_at(_spawn_transform)
	if _damage != null:
		_damage.restore()


func debug_state() -> Dictionary:
	return {
		"speed": linear_velocity.length(),
		"spin": angular_velocity.length(),
		"delta_v": 0.0 if _damage == null else _damage.last_delta_v,
		"integrity": 1.0 if _damage == null else _damage.fraction(),
	}
