class_name ProjectilePool
extends Node3D

## Every turret shot in the scene: a fixed pool of raycast projectiles and one
## MultiMesh of tracers.
##
## RAYCASTS, NOT BODIES. Three reasons, and the first is decisive: a 220 m/s body
## advances 3.7 m per physics step and would tunnel straight through a crate,
## which is a bug that shows up as "fast shots sometimes miss" and is miserable to
## diagnose. A ray between last frame's point and this frame's cannot miss
## anything it passes through. Beyond that, bodies would mean 96 rigid bodies
## entering and leaving the Jolt broadphase sixty times a second, and an
## instantiate()/queue_free() churn whose allocation cost shows up as GC stutter
## in a web build. TetherLayers.PROJECTILE is defined, deliberately unoccupied,
## and asserted empty for exactly this reason.
##
## ONE DRAW CALL FOR ALL 96 TRACERS. That is the argument that decides the design
## on a GL Compatibility target: `instance_count` is allocated once in _ready()
## and never resized (a resize reallocates the buffer), and only
## `visible_instance_count` moves per frame.

## Hard ceiling on shots in flight. Seven turrets firing three-round bursts every
## 0.9 s cannot reach this; it is a bound, not a budget.
const MAX_SHOTS: int = 96

@export var tracer_length: float = 6.0
@export var tracer_material: Material
## Seconds a shot lives before expiring, in case it hits nothing at all.
@export var lifetime: float = 4.0

var _positions: PackedVector3Array = PackedVector3Array()
var _directions: PackedVector3Array = PackedVector3Array()
var _speeds: PackedFloat32Array = PackedFloat32Array()
var _damage: PackedFloat32Array = PackedFloat32Array()
var _ttl: PackedFloat32Array = PackedFloat32Array()
var _live: Array[bool] = []
var _free: PackedInt32Array = PackedInt32Array()
var _shooters: Array[RID] = []

@onready var _tracers: MultiMeshInstance3D = %Tracers as MultiMeshInstance3D


func _ready() -> void:
	_positions.resize(MAX_SHOTS)
	_directions.resize(MAX_SHOTS)
	_speeds.resize(MAX_SHOTS)
	_damage.resize(MAX_SHOTS)
	_ttl.resize(MAX_SHOTS)
	_live.resize(MAX_SHOTS)
	_shooters.resize(MAX_SHOTS)
	for i: int in MAX_SHOTS:
		_live[i] = false
		_free.append(MAX_SHOTS - 1 - i)
	_build_tracers()


func _physics_process(delta: float) -> void:
	var space: PhysicsDirectSpaceState3D = get_world_3d().direct_space_state
	var drawn: int = 0
	for i: int in MAX_SHOTS:
		if not _live[i]:
			continue
		if _advance(i, delta, space):
			_draw_tracer(drawn, i)
			drawn += 1
	_tracers.multimesh.visible_instance_count = drawn


## Launches a shot. Silently drops it when the pool is full, which is correct:
## the alternative is growing an array during a physics step to fire a bullet
## nobody would have noticed.
func fire(
	from: Vector3, direction: Vector3, speed: float, damage: float, shooter: RID = RID()
) -> bool:
	if _free.is_empty():
		return false
	var index: int = _free[_free.size() - 1]
	_free.remove_at(_free.size() - 1)
	_positions[index] = from
	_directions[index] = direction.normalized()
	_speeds[index] = speed
	_damage[index] = damage
	_ttl[index] = lifetime
	_shooters[index] = shooter
	_live[index] = true
	return true


## Shots currently in flight. The runtime verifier reports this as a budget check.
func live_count() -> int:
	return MAX_SHOTS - _free.size()


func clear_all() -> void:
	_free.clear()
	for i: int in MAX_SHOTS:
		_live[i] = false
		_free.append(MAX_SHOTS - 1 - i)
	_tracers.multimesh.visible_instance_count = 0


## Marches one shot and resolves what it hits. Returns whether it is still alive.
func _advance(index: int, delta: float, space: PhysicsDirectSpaceState3D) -> bool:
	var from: Vector3 = _positions[index]
	var to: Vector3 = from + _directions[index] * _speeds[index] * delta
	var exclude: Array[RID] = []
	if _shooters[index].is_valid():
		exclude.append(_shooters[index])
	var query := PhysicsRayQueryParameters3D.create(
		from, to, TetherLayers.MASK_PROJECTILE_QUERY, exclude
	)
	var hit: Dictionary = space.intersect_ray(query)
	if not hit.is_empty():
		_resolve_hit(hit.get("collider"), _damage[index])
		_release(index)
		return false

	_positions[index] = to
	_ttl[index] -= delta
	if _ttl[index] <= 0.0:
		_release(index)
		return false
	return true


func _resolve_hit(collider: Variant, amount: float) -> void:
	var node: Node = collider as Node
	if node == null:
		return
	var damage: TetherDamage = node.get_node_or_null("%Damage") as TetherDamage
	if damage != null:
		# Bypasses i-frames on purpose: a three-round burst has to cost three
		# times or turrets are toothless. See TetherDamage.contact_iframes.
		damage.apply_projectile(amount)


func _release(index: int) -> void:
	_live[index] = false
	_free.append(index)


func _draw_tracer(slot: int, index: int) -> void:
	var basis := Basis.looking_at(_directions[index], Vector3.UP)
	basis = basis.scaled(Vector3(1.0, 1.0, tracer_length))
	_tracers.multimesh.set_instance_transform(slot, Transform3D(basis, _positions[index]))


func _build_tracers() -> void:
	var mesh := BoxMesh.new()
	mesh.size = Vector3(0.18, 0.18, 1.0)
	var multi := MultiMesh.new()
	multi.transform_format = MultiMesh.TRANSFORM_3D
	multi.mesh = mesh
	# Allocated once. Resizing this at runtime reallocates the whole buffer.
	multi.instance_count = MAX_SHOTS
	multi.visible_instance_count = 0
	_tracers.multimesh = multi
	if tracer_material != null:
		_tracers.material_override = tracer_material
	_tracers.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
