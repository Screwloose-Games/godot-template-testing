class_name RtsHq
extends StaticBody3D

## A team's headquarters: production, rally point, a light defensive gun, and the thing you
## lose the match by losing.
##
## Production is a single queue rather than instant purchase on purpose. Instant spawning
## makes gold the only limiter, and a player sitting on 400 banked gold can convert it into an
## army the moment they feel threatened — which means the buy *order* never mattered. A queue
## turns "what do I build first" into a real decision with a real cost.

signal queue_changed(queue: Array)

@export_enum("Neutral", "Player", "Enemy") var team: int = RtsTeam.Id.PLAYER

var _world: RtsWorld
var _health: float = RtsConfig.HQ_MAX_HEALTH
var _queue: Array[UnitStats] = []
var _build_remaining: float = 0.0
var _rally_point: Vector3 = Vector3.ZERO
var _attack_cooldown: float = 0.0
## Until the player right-clicks a destination with the HQ selected, new units route
## themselves to whatever objective matters most. Everything an AI unit builds gets a job
## within a second or two; a player's units used to walk 8m from the base and stand there
## until told otherwise, which made simply keeping pace a matter of clicking rather than of
## deciding anything.
var _rally_is_manual: bool = false
var _alive: bool = true
var _body_material: StandardMaterial3D
var _base_color: Color = Color.WHITE
var _flash_tween: Tween

@onready var body: MeshInstance3D = %Body
@onready var roof: MeshInstance3D = %Roof
@onready var selection_ring: MeshInstance3D = %SelectionRing
@onready var health_bar: Node3D = %HealthBar
@onready var health_bar_fill: MeshInstance3D = %HealthBarFill


func _ready() -> void:
	_world = RtsWorld.find_in(self)
	collision_layer = RtsTeam.building_layer(team)
	collision_mask = 0
	_base_color = RtsTeam.color_of(team)
	_apply_team_colors()
	selection_ring.visible = false
	# Rally in front of the HQ, toward the middle of the map, so new units walk clear of the
	# spawn pad instead of piling onto it.
	_rally_point = global_position + _toward_center() * RtsConfig.HQ_RALLY_OFFSET
	if _world != null:
		_world.register_hq(self)


func _physics_process(delta: float) -> void:
	if not _alive:
		return
	_tick_production(delta)
	_tick_defence(delta)


func is_alive() -> bool:
	return _alive


func health_fraction() -> float:
	return clampf(_health / RtsConfig.HQ_MAX_HEALTH, 0.0, 1.0)


## Attack range is measured centre to centre, so melee units need to know how wide this is or
## they would stand outside the walls swinging at nothing.
func hit_radius() -> float:
	return 3.6


func set_selected(selected: bool) -> void:
	selection_ring.visible = selected


## An explicit rally order takes over from the automatic one permanently — once the player
## has expressed an intent, the HQ must not quietly override it a few seconds later.
func set_rally_point(point: Vector3) -> void:
	_rally_point = Vector3(point.x, 0.0, point.z)
	_rally_is_manual = true


## Fraction of the unit currently being built, 0 when the queue is empty. The HUD polls this
## rather than being signalled every frame.
func build_progress() -> float:
	if _queue.is_empty() or _queue[0].build_seconds <= 0.0:
		return 0.0
	return 1.0 - clampf(_build_remaining / _queue[0].build_seconds, 0.0, 1.0)


func queued_stats() -> Array:
	return _queue


## Charges the gold and queues the unit. Returns false and spends nothing if the team cannot
## afford it, the queue is full, or the population cap would be exceeded — callers can treat
## it as the guard rather than duplicating the checks.
func request_unit(stats: UnitStats) -> bool:
	if not _alive or _world == null:
		return false
	if _queue.size() >= RtsConfig.PRODUCTION_QUEUE_LIMIT:
		return false
	if _world.population_of(team) + _queue.size() >= RtsConfig.POPULATION_CAP:
		return false
	var economy: RtsEconomy = _world.economy_of(team)
	if economy == null or not economy.try_spend(stats.gold_cost):
		return false
	_queue.append(stats)
	if _queue.size() == 1:
		_build_remaining = stats.build_seconds
	queue_changed.emit(_queue)
	return true


func take_damage(amount: float, _attacker_kind: int) -> void:
	if not _alive:
		return
	# Buildings have no place in the counter triangle: a Tank being good against Grunts should
	# not also make it the right answer to a base.
	_health -= amount
	_flash()
	_update_health_bar()
	if _world != null:
		_world.report_hq_damage(team, health_fraction())
	if _health <= 0.0:
		_destroy()


func _tick_production(delta: float) -> void:
	if _queue.is_empty():
		return
	_build_remaining -= delta
	if _build_remaining > 0.0:
		return
	var stats: UnitStats = _queue.pop_front()
	_build_remaining = _queue[0].build_seconds if not _queue.is_empty() else 0.0
	queue_changed.emit(_queue)
	_spawn(stats)


func _spawn(stats: UnitStats) -> void:
	if _world == null:
		return
	var offset: Vector3 = _toward_center() * (hit_radius() + 2.0)
	offset += Vector3(randf_range(-1.6, 1.6), 0.0, randf_range(-1.6, 1.6))
	var unit: Node3D = _world.spawn_unit(stats, team, global_position + offset)
	# Reinforcements walking to the front attack-move: they are heading into a fight by
	# definition, and nobody issued them a "get there specifically" order to override.
	unit.move_to(_current_rally(), true)


## The automatic rally is re-evaluated per unit rather than cached, so a squad built over
## thirty seconds follows the fight instead of all piling onto wherever the front was when
## the first one rolled out.
func _current_rally() -> Vector3:
	if _rally_is_manual or _world == null:
		return _rally_point
	var objectives: Array[Vector3] = _world.ranked_objectives_for(team)
	if objectives.is_empty():
		return _rally_point
	var spread: Vector3 = Vector3(randf_range(-4.0, 4.0), 0.0, randf_range(-4.0, 4.0))
	return objectives[0] + spread


func _tick_defence(delta: float) -> void:
	_attack_cooldown = maxf(0.0, _attack_cooldown - delta)
	if _attack_cooldown > 0.0 or _world == null:
		return
	var target: Node3D = _world.nearest_hostile(team, global_position, RtsConfig.HQ_ATTACK_RANGE)
	if target == null:
		return
	_attack_cooldown = RtsConfig.HQ_ATTACK_INTERVAL
	# -1 is not a UnitStats.Kind, so the counter table leaves the damage unmodified.
	target.take_damage(RtsConfig.HQ_DAMAGE_PER_HIT, -1)


func _toward_center() -> Vector3:
	var flat: Vector3 = Vector3(-global_position.x, 0.0, -global_position.z)
	return flat.normalized() if flat.length_squared() > 0.01 else Vector3.FORWARD


func _apply_team_colors() -> void:
	# Dark team-tinted walls with a bright cap on top. The building has to read as "yours" or
	# "theirs" at a glance from a zoomed-out camera, but a whole structure in full saturation
	# blows out under the sun and stops reading as a building at all.
	_body_material = StandardMaterial3D.new()
	_body_material.albedo_color = _base_color.darkened(0.62)
	_body_material.roughness = 0.95
	body.material_override = _body_material

	var roof_material: StandardMaterial3D = StandardMaterial3D.new()
	roof_material.albedo_color = _base_color.darkened(0.15)
	roof_material.roughness = 0.85
	roof.material_override = roof_material

	var ring_material: StandardMaterial3D = StandardMaterial3D.new()
	ring_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	ring_material.albedo_color = _base_color.lightened(0.35)
	ring_material.cull_mode = BaseMaterial3D.CULL_DISABLED
	selection_ring.material_override = ring_material


func _update_health_bar() -> void:
	var fraction: float = health_fraction()
	health_bar.visible = fraction < 0.999
	health_bar_fill.scale.x = maxf(fraction, 0.001)
	health_bar_fill.position.x = -(1.0 - fraction) * 4.0 * 0.5


func _flash() -> void:
	if _body_material == null:
		return
	if _flash_tween != null and _flash_tween.is_valid():
		_flash_tween.kill()
	var dark: Color = _base_color.darkened(0.55)
	_body_material.albedo_color = dark.lerp(Color.WHITE, 0.7)
	_flash_tween = create_tween()
	_flash_tween.tween_property(_body_material, "albedo_color", dark, 0.12)


func _destroy() -> void:
	_alive = false
	collision_layer = 0
	set_selected(false)
	health_bar.visible = false
	var tween: Tween = create_tween()
	tween.set_parallel(true)
	tween.tween_property(body, "scale", Vector3(1.1, 0.12, 1.1), 0.5)
	tween.tween_property(roof, "scale", Vector3(0.4, 0.1, 0.4), 0.5)
	tween.tween_property(roof, "position:y", 0.4, 0.5)
	if _world != null:
		_world.end_match(RtsTeam.opponent_of(team), "Headquarters destroyed")
