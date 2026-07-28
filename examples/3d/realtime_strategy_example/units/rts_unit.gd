class_name RtsUnit
extends CharacterBody3D

## One soldier. All three types share this script; only the UnitStats resource differs.
##
## CharacterBody3D rather than Area3D or a plain Node3D: it already carries the collision
## shape that mouse-picking raycasts need, move_and_slide() gives obstacle sliding for free,
## and kinematic bodies are the cheapest thing Jolt has to simulate. There is no gravity —
## the arena is flat, motion_mode is FLOATING, and units do not collide with the ground at
## all, which removes every "unit sank through the floor" failure mode at a stroke.

enum State {
	IDLE,
	MOVING,
	DEAD,
}

var team: int = RtsTeam.Id.PLAYER
var stats: UnitStats

var _world: RtsWorld
var _state: int = State.IDLE
var _health: float = 1.0
var _selected: bool = false
var _destination: Vector3 = Vector3.ZERO
var _has_destination: bool = false
## Whether the current move order is an attack-move. Plain moves are obeyed to the letter:
## the unit does not stop to pick fights on the way. See move_to().
var _attack_move: bool = false
var _command_target: Node3D
var _auto_target: Node3D
var _attack_cooldown: float = 0.0
var _scan_timer: float = 0.0

@onready var collision: CollisionShape3D = %Collision
@onready var agent: NavigationAgent3D = %Agent
@onready var visuals: UnitVisuals = %Visuals


## Must be called before add_child(). The mesh, collision shape and agent are all sized from
## the stat block, so the node is not usable until this has run.
func setup(world: RtsWorld, unit_stats: UnitStats, unit_team: int) -> void:
	_world = world
	stats = unit_stats
	team = unit_team
	_health = unit_stats.max_health


func _ready() -> void:
	if stats == null:
		push_error("RtsUnit entered the tree without setup() being called.")
		return
	motion_mode = CharacterBody3D.MOTION_MODE_FLOATING
	collision_layer = RtsTeam.unit_layer(team)
	# Units block each other and the rocks, but deliberately ignore the ground: with no
	# gravity there is nothing to stand on, and skipping it avoids any floor-snap jitter.
	collision_mask = RtsLayers.MASK_UNIT_BLOCKERS
	_configure_agent()
	visuals.apply(stats, team)
	visuals.play_spawn()
	# A randomised first scan spreads target acquisition across frames instead of having
	# every unit spawned on the same tick re-scan together forever after.
	_scan_timer = randf() * RtsConfig.TARGET_SCAN_INTERVAL
	if _world == null:
		_world = RtsWorld.find_in(self)
	if _world != null:
		_world.register_unit(self)


func _physics_process(delta: float) -> void:
	if _state == State.DEAD:
		return
	_attack_cooldown = maxf(0.0, _attack_cooldown - delta)
	_scan_timer -= delta
	if _scan_timer <= 0.0:
		_scan_timer = RtsConfig.TARGET_SCAN_INTERVAL
		_reacquire_target()

	var target: Node3D = _effective_target()
	if target != null and _in_attack_range(target):
		_halt()
		_face(target.global_position)
		_try_attack(target)
		return
	if target != null:
		_advance_toward(target.global_position)
	elif _has_destination:
		_advance_toward(_destination)
	else:
		_halt()


func is_alive() -> bool:
	return _state != State.DEAD


func health_fraction() -> float:
	return clampf(_health / stats.max_health, 0.0, 1.0)


## How far from this unit's origin its surface is. Attack range is measured centre-to-centre,
## so without this a melee unit could never reach something as wide as an HQ.
func hit_radius() -> float:
	return stats.body_radius


func is_selected() -> bool:
	return _selected


func set_selected(selected: bool) -> void:
	if _selected == selected:
		return
	_selected = selected
	visuals.set_selected(selected)


## Go there. With `engage_on_the_way` false — a plain right-click — this is an order, not a
## suggestion: the unit drops whatever it is shooting at and leaves.
##
## It used to be an implicit attack-move, which meant a squad ordered out of a losing fight
## simply refused to go: the auto-acquired target outranked the destination, and the 0.25s
## re-scan handed the target straight back even when it was cleared. Disengaging is half of
## what movement orders are *for*, so the default now obeys and attack-move is explicit.
##
## Units still defend themselves the moment they arrive and go idle, so this does not turn
## them into pacifists — it just stops them overruling you mid-order.
func move_to(destination: Vector3, engage_on_the_way: bool = false) -> void:
	_destination = Vector3(destination.x, 0.0, destination.z)
	_has_destination = true
	_attack_move = engage_on_the_way
	_command_target = null
	if not engage_on_the_way:
		_auto_target = null
	_state = State.MOVING


func order_attack(target: Node3D) -> void:
	_command_target = target
	_has_destination = false
	_attack_move = false
	_state = State.MOVING


func hold_position() -> void:
	_has_destination = false
	_attack_move = false
	_command_target = null
	_auto_target = null
	_state = State.IDLE


## `attacker_kind` is a UnitStats.Kind, or any value not in the counter table (buildings pass
## -1) to take unmodified damage.
func take_damage(amount: float, attacker_kind: int) -> void:
	if _state == State.DEAD:
		return
	_health -= amount * RtsConfig.counter_multiplier(attacker_kind, stats.kind)
	visuals.flash_damage()
	visuals.set_health_fraction(health_fraction())
	if _health <= 0.0:
		_die()


func _configure_agent() -> void:
	var shape: CapsuleShape3D = CapsuleShape3D.new()
	shape.radius = stats.body_radius
	shape.height = maxf(stats.body_height, stats.body_radius * 2.0 + 0.01)
	collision.shape = shape
	collision.position.y = shape.height * 0.5

	agent.radius = stats.body_radius
	agent.height = stats.body_height
	agent.max_speed = stats.move_speed
	agent.path_desired_distance = 0.7
	agent.target_desired_distance = RtsConfig.ARRIVE_DISTANCE
	agent.neighbor_distance = 6.0
	agent.max_neighbors = 8
	agent.time_horizon_agents = 1.0
	agent.time_horizon_obstacles = 0.6
	agent.avoidance_enabled = false
	agent.velocity_computed.connect(_on_velocity_computed)


## Only ever acquires while it has nothing explicitly ordered. A commanded attack outranks
## whatever happens to wander past, otherwise player orders quietly stop meaning anything.
func _reacquire_target() -> void:
	if _command_target != null and _is_valid_target(_command_target):
		_auto_target = null
		return
	_command_target = null
	# The other half of making move orders mean something: while a plain move is outstanding,
	# the unit does not go looking for a fight. Clearing _auto_target in move_to() alone would
	# not hold — this scan runs every 0.25s and would hand the target right back.
	if _has_destination and not _attack_move:
		_auto_target = null
		return
	# Floored, so melee units are not effectively blind. See RtsConfig.MIN_ACQUIRE_RANGE.
	var reach: float = maxf(
		stats.attack_range * RtsConfig.ACQUIRE_RANGE_MULTIPLIER, RtsConfig.MIN_ACQUIRE_RANGE
	)
	_auto_target = _world.nearest_hostile(team, global_position, reach) if _world != null else null


func _effective_target() -> Node3D:
	if _command_target != null and _is_valid_target(_command_target):
		return _command_target
	if _auto_target != null and _is_valid_target(_auto_target):
		return _auto_target
	return null


func _is_valid_target(target: Node3D) -> bool:
	return is_instance_valid(target) and target.is_alive()


func _in_attack_range(target: Node3D) -> bool:
	var reach: float = stats.attack_range + target.hit_radius()
	var to_target: Vector3 = target.global_position - global_position
	to_target.y = 0.0
	return to_target.length_squared() <= reach * reach


func _try_attack(target: Node3D) -> void:
	_state = State.IDLE
	if _attack_cooldown > 0.0:
		return
	_attack_cooldown = stats.attack_interval
	target.take_damage(stats.damage_per_hit, stats.kind)


func _advance_toward(destination: Vector3) -> void:
	_state = State.MOVING
	_set_avoidance(true)
	if agent.target_position.distance_squared_to(destination) > 0.01:
		agent.target_position = destination
	if agent.is_navigation_finished():
		_on_arrived()
		return
	var to_next: Vector3 = agent.get_next_path_position() - global_position
	to_next.y = 0.0
	if to_next.length_squared() < 0.0001:
		return
	var desired: Vector3 = to_next.normalized() * stats.move_speed
	_face(global_position + desired)
	agent.velocity = desired


func _on_velocity_computed(safe_velocity: Vector3) -> void:
	if _state == State.DEAD:
		return
	velocity = Vector3(safe_velocity.x, 0.0, safe_velocity.z)
	move_and_slide()


func _on_arrived() -> void:
	_has_destination = false
	_attack_move = false
	_halt()


## Avoidance is switched off the moment a unit stops. RVO keeps nudging neighbours forever
## otherwise, and a squad that has arrived spends the rest of the match vibrating in place.
func _halt() -> void:
	_state = State.IDLE
	_set_avoidance(false)
	velocity = Vector3.ZERO
	move_and_slide()


func _set_avoidance(enabled: bool) -> void:
	if agent.avoidance_enabled != enabled:
		agent.avoidance_enabled = enabled


func _face(look_target: Vector3) -> void:
	var flat: Vector3 = Vector3(look_target.x, global_position.y, look_target.z)
	if flat.distance_squared_to(global_position) < 0.0004:
		return
	look_at(flat, Vector3.UP)


func _die() -> void:
	_state = State.DEAD
	set_physics_process(false)
	collision_layer = 0
	collision_mask = 0
	agent.avoidance_enabled = false
	set_selected(false)
	if _world != null:
		_world.unregister_unit(self)
	await visuals.play_death().finished
	queue_free()
