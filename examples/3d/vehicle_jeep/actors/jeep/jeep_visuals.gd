class_name JeepVisuals
extends Node3D

## Everything the jeep LOOKS like, and the only file in this example allowed to
## know a node name inside sm_jeep_turret.tscn.
##
## This is the vehicle's answer to the wolf example's wolf_animator.tscn. The
## controller drives physics and talks to this through the facade below; it never
## says `wheel_fl_steer`, `turret_yaw` or `mk_headlight_l`, and
## verify_jeep_static.gd check 9 greps its source -- comments included -- to prove
## it. The reason is the usual one: a node this file renames should break exactly
## one file, and a rename that half-works is worse than one that fails loudly.
##
## Owning the vocabulary means owning the tuning too, so the turret slew rates and
## headlight settings are exported here rather than passed in per call.
##
## This node must stay at IDENTITY relative to the body. Wheel poses arrive in body
## space and are written onto model pivots; a pitch, roll or scale here would tilt
## every wheel by a constant that nothing would flag. Model offsets, if ever
## needed, go on a pivot INSIDE this scene.

## Wheel indices. Shared vocabulary with the controller, which builds its
## VehicleWheel3D array in this order.
enum Wheel {
	FRONT_LEFT,
	FRONT_RIGHT,
	REAR_LEFT,
	REAR_RIGHT,
}

## Wheel index -> model pivot that carries steering. Rear wheels have none, so the
## suspension origin lands on their spin pivot instead.
const STEER_PIVOT_PATHS: Array = [
	"jeep_turret_root/wheel_fl_steer",
	"jeep_turret_root/wheel_fr_steer",
	"",
	"",
]
## Wheel index -> model pivot that carries roll.
const SPIN_PIVOT_PATHS: Array = [
	"jeep_turret_root/wheel_fl_steer/wheel_fl_spin",
	"jeep_turret_root/wheel_fr_steer/wheel_fr_spin",
	"jeep_turret_root/wheel_rl_spin",
	"jeep_turret_root/wheel_rr_spin",
]
const COLLISION_CONTAINER: String = "jeep_turret_root/collision"
## Godot's importer strips the -convcolonly suffix, so the eight proxies arrive as
## StaticBody3D nodes named body / cage / hood / turret / wheel_fl..rr. The four
## wheel proxies must NOT become hull collision -- VehicleWheel3D raycasts instead.
const WHEEL_PROXY_PREFIX: String = "wheel_"
## Second gate on the harvest, because a name predicate alone breaks the day the
## importer disambiguates a name clash. Measured with tools/dump_jeep_model.gd:
## every hull proxy's lowest vertex is at y >= 0.49, every wheel proxy reaches
## y = 0.00. 0.30 sits cleanly between them.
const HULL_MIN_Y: float = 0.30
## Which way get_rpm() counts. The GEOMETRIC sign is settled -- rotating a wheel
## about +X by a positive angle sends its top point toward +Z, i.e. backward, so
## forward roll is negative about +X and the minus below is not negotiable.
##
## What is not derivable is get_rpm()'s own convention, so it lives here as one
## flippable constant. MEASURED: driving forward at +11.25 m/s, all four wheels
## report rpm -258.8. get_rpm() is therefore negative when moving forward, and this
## is -1.0 so that rpm * RPM_SIGN agrees in sign with forward speed.
## verify_jeep_runtime.gd [rpm-convention] asserts exactly that product, so if a
## future engine release flips the convention the test says so and this flips back.
const RPM_SIGN: float = -1.0

@export_group("Turret")
## Degrees per second. The turret deliberately lags the camera -- that lag is what
## makes one mouse driving both read as "the gun follows my gaze" rather than as
## two controls fighting.
@export var turret_yaw_rate_degrees: float = 120.0
@export var turret_pitch_rate_degrees: float = 75.0
@export var turret_pitch_min_degrees: float = -8.0
@export var turret_pitch_max_degrees: float = 48.0

@export_group("Steering wheel")
## Lock-to-lock travel of the rim, in full turns, mapped onto steering input -1..1.
@export var steering_wheel_lock_turns: float = 1.0

@export_group("Headlights")
@export var headlight_energy: float = 4.0
@export var headlight_range: float = 28.0
@export var headlight_angle_degrees: float = 32.0
@export var headlight_pitch_degrees: float = -8.0

## Body space -> model-root space. Wheel poses arrive in body space and are written
## onto pivots that hang off the model root. Identity in practice; computed rather
## than assumed so a model offset cannot silently misplace all four wheels.
var _body_to_model: Transform3D = Transform3D.IDENTITY
## Accumulated wheel roll, radians. get_rpm() is a rate, and no angle is exposed.
var _spin_angle: PackedFloat32Array = PackedFloat32Array([0.0, 0.0, 0.0, 0.0])
## Last frame's roll increment, kept because _spin_angle is wrapped and a wrapped
## accumulator cannot tell a verifier which way the wheel turned.
var _spin_delta: PackedFloat32Array = PackedFloat32Array([0.0, 0.0, 0.0, 0.0])
var _steer_pivots: Array[Node3D] = []
var _spin_pivots: Array[Node3D] = []
var _steering_wheel_rest: Transform3D = Transform3D.IDENTITY
## Rotation axis of the raked steering column, in the column's parent space. Read
## off mk_steering_axis rather than hand-derived: the container scene's comment
## says "~22 degrees" and the matrix actually says 48.58.
var _steering_wheel_axis: Vector3 = Vector3.BACK
## The rim's "up" at rest, perpendicular to the column axis. Only used to report
## which way the rim is turned, which is what makes that direction testable.
var _steering_wheel_up_rest: Vector3 = Vector3.UP
var _turret_yaw_angle: float = 0.0
var _turret_pitch_angle: float = 0.0
var _headlights_on: bool = false

@onready var _model: Node3D = %Model as Node3D
@onready var _turret_yaw: Node3D = %Model.get_node(^"jeep_turret_root/turret_yaw") as Node3D
@onready var _turret_pitch: Node3D = _turret_yaw.get_node(^"turret_pitch") as Node3D
@onready
var _steering_wheel: Node3D = %Model.get_node(^"jeep_turret_root/steering_wheel_pivot") as Node3D
@onready
var _steering_axis_marker: Node3D = %Model.get_node(^"jeep_turret_root/mk_steering_axis") as Node3D
@onready var _muzzle: Node3D = _turret_pitch.get_node(^"mk_muzzle") as Node3D
@onready var _headlight_l: SpotLight3D = %HeadlightL as SpotLight3D
@onready var _headlight_r: SpotLight3D = %HeadlightR as SpotLight3D


func _ready() -> void:
	var model_root: Node3D = _model.get_node(^"jeep_turret_root") as Node3D
	# The parent is the vehicle body -- that is this component's contract. Falling
	# back to self keeps a standalone instantiation (the verifiers do this) working.
	var body: Node3D = get_parent_node_3d()
	if body == null:
		body = self
	_body_to_model = model_root.global_transform.affine_inverse() * body.global_transform

	for index: int in Wheel.size():
		var steer_path: String = STEER_PIVOT_PATHS[index]
		var steer_pivot: Node3D = null
		if not steer_path.is_empty():
			steer_pivot = _model.get_node(NodePath(steer_path)) as Node3D
		_steer_pivots.append(steer_pivot)
		_spin_pivots.append(_model.get_node(NodePath(SPIN_PIVOT_PATHS[index])) as Node3D)

	_steering_wheel_rest = _steering_wheel.transform
	# mk_steering_axis and steering_wheel_pivot share a parent, so the marker's
	# LOCAL basis is already the right frame -- no global round-trip, and the
	# result does not depend on where the jeep is in the world. Normalising is not
	# decoration: Basis(axis, angle) errors on an unnormalised axis.
	_steering_wheel_axis = _steering_axis_marker.transform.basis.z.normalized()
	_steering_wheel_up_rest = _steering_axis_marker.transform.basis.y.normalized()

	_place_headlight(_headlight_l, ^"jeep_turret_root/mk_headlight_l")
	_place_headlight(_headlight_r, ^"jeep_turret_root/mk_headlight_r")
	set_headlights(false)


## Hands the imported hull collision to the caller and destroys the static proxies.
##
## The proxies import as StaticBody3D nodes. Static bodies riding inside a moving
## VehicleBody3D are a contradiction, and the four wheel proxies would sit exactly
## where the wheel rays are cast, so they are removed rather than disabled.
##
## Returns one entry per shape: {shape, transform (in this node's space), source,
## rejected}. Rejects are reported, not dropped silently -- a harvest that quietly
## returned nothing would present as a jeep falling through the floor.
##
## Call order is load-bearing: Godot runs a child's _ready() before its parent's,
## so by the time the controller calls this, this node has cached its references,
## both nodes are in the tree, and no physics frame has run yet.
func take_body_shapes() -> Array[Dictionary]:
	var harvested: Array[Dictionary] = []
	var container: Node = _model.get_node_or_null(NodePath(COLLISION_CONTAINER))
	if container == null:
		push_error(
			(
				"JeepVisuals: no '%s' in the model. The jeep will have no hull collision."
				% COLLISION_CONTAINER
			)
		)
		return harvested

	for proxy: Node in container.get_children():
		if not proxy is StaticBody3D:
			continue
		var is_wheel: bool = String(proxy.name).begins_with(WHEEL_PROXY_PREFIX)
		for child: Node in proxy.get_children():
			if not child is CollisionShape3D:
				continue
			var collider: CollisionShape3D = child as CollisionShape3D
			if collider.shape == null:
				continue
			var local: Transform3D = global_transform.affine_inverse() * collider.global_transform
			var below_hull: bool = _lowest_point(collider.shape, local) < HULL_MIN_Y
			(
				harvested
				. append(
					{
						"shape": collider.shape,
						"transform": local,
						"source": String(proxy.name),
						"rejected": is_wheel or below_hull,
					}
				)
			)

	# free(), not queue_free(): a deferred free leaves the proxies alive for the
	# rest of the frame, and a physics step landing in that window would have four
	# static bodies sitting where the wheel rays are about to be cast.
	container.get_parent().remove_child(container)
	container.free()
	return harvested


## Writes one wheel's live physics pose onto the model.
##
## `wheel_local` is the VehicleWheel3D node's own transform, which the engine
## rewrites every physics step -- its origin already carries suspension travel.
## Only the origin is taken: the engine's wheel basis is built as
## (right, up, up x right), which for up=+Y right=+X has determinant -1, and
## whether that mirror is compensated is exactly the kind of thing that compiles
## clean and fails at runtime. The basis is rebuilt from the two scalars instead.
func set_wheel_pose(
	index: int, wheel_local: Transform3D, steer: float, rpm: float, delta: float
) -> void:
	# wrapf keeps the accumulator from losing float precision over a long session --
	# which is also why the raw delta is kept separately: once the angle wraps, "did
	# it advance the right way" is unanswerable from the angle alone.
	#
	# The sign is derivable and is not a guess. A point at the bottom of the wheel,
	# (0, -r, 0), rotated about +X by a positive angle moves to (0, -r cos a,
	# -r sin a), i.e. toward -Z -- forward. A wheel whose contact patch travels
	# forward is rolling BACKWARD, so driving forward must decrease this angle.
	_spin_delta[index] = -rpm * TAU / 60.0 * delta * RPM_SIGN
	_spin_angle[index] = wrapf(_spin_angle[index] + _spin_delta[index], -PI, PI)
	var origin: Vector3 = _body_to_model * wheel_local.origin
	var spin: Basis = Basis(Vector3.RIGHT, _spin_angle[index])
	var steer_pivot: Node3D = _steer_pivots[index]
	if steer_pivot != null:
		steer_pivot.transform = Transform3D(Basis(Vector3.UP, steer), origin)
		_spin_pivots[index].transform = Transform3D(spin, Vector3.ZERO)
	else:
		_spin_pivots[index].transform = Transform3D(spin, origin)


## Turns the rim about the raked steering column. `value` is steering input, -1..1,
## positive for left -- matching VehicleBody3D.steering, where positive yaws the
## road wheels left. Applied as a set against the cached rest pose, never an
## accumulating rotate().
##
## The sign is derived, not eyeballed. The column axis `a` is mk_steering_axis's
## basis.z = (0, +0.75, +0.66): up and toward +Z, which is toward the driver, who
## sits behind the rim. Rotating the rim's up-vector u by `t` about `a` gives
## u cos t + (a x u) sin t, and a x u = -basis.x = (-1, 0, 0), so a POSITIVE angle
## carries the top of the rim toward -X -- the driver's left. Steering left is
## therefore a positive rotation. verify_jeep_runtime [visual-rig] asserts the
## rim's up-vector actually ends up left of centre under left steering, so this
## cannot silently invert.
func set_steering_normalized(value: float) -> void:
	var angle: float = value * steering_wheel_lock_turns * PI
	_steering_wheel.transform = Transform3D(
		Basis(_steering_wheel_axis, angle) * _steering_wheel_rest.basis, _steering_wheel_rest.origin
	)


## Slews the turret toward a point in world space, rate-limited.
func aim_turret(world_point: Vector3, delta: float) -> void:
	var yaw_parent: Node3D = _turret_yaw.get_parent_node_3d()
	var to_target: Vector3 = (
		yaw_parent.global_transform.affine_inverse() * world_point - _turret_yaw.position
	)
	# Rotating about +Y by `a` sends -Z (hull forward) to (-sin a, 0, -cos a),
	# hence both signs. Yaw 0 therefore means "gun points where the hull points".
	var wanted_yaw: float = atan2(-to_target.x, -to_target.z)
	_turret_yaw_angle = rotate_toward(
		_turret_yaw_angle, wanted_yaw, deg_to_rad(turret_yaw_rate_degrees) * delta
	)
	_turret_yaw.rotation.y = _turret_yaw_angle

	# Measured from the pitch pivot's own origin, not the yaw pivot's: the gun sits
	# 0.52 m above the ring and at close range that offset is most of the answer.
	var pitch_parent: Node3D = _turret_pitch.get_parent_node_3d()
	var to_target_pitch: Vector3 = (
		pitch_parent.global_transform.affine_inverse() * world_point - _turret_pitch.position
	)
	var horizontal: float = Vector2(to_target_pitch.x, to_target_pitch.z).length()
	var wanted_pitch: float = clampf(
		atan2(to_target_pitch.y, horizontal),
		deg_to_rad(turret_pitch_min_degrees),
		deg_to_rad(turret_pitch_max_degrees)
	)
	_turret_pitch_angle = move_toward(
		_turret_pitch_angle, wanted_pitch, deg_to_rad(turret_pitch_rate_degrees) * delta
	)
	_turret_pitch.rotation.x = _turret_pitch_angle


func set_headlights(on: bool) -> void:
	_headlights_on = on
	_headlight_l.visible = on
	_headlight_r.visible = on


func headlights_on() -> bool:
	return _headlights_on


## Where a round would leave the barrel. Nothing fires in this demo; the marker is
## exposed so that adding it later needs no change in here.
func muzzle_global_transform() -> Transform3D:
	return _muzzle.global_transform


## For the verifiers. Reports what the rig actually did, in the rig's own terms, so
## a test can tell "the code ran" from "the code ran and moved something".
func debug_state() -> Dictionary:
	var steer_rotations: Array[float] = []
	for pivot: Node3D in _steer_pivots:
		steer_rotations.append(0.0 if pivot == null else pivot.rotation.y)
	return {
		"spin_angles": Array(_spin_angle),
		"spin_deltas": Array(_spin_delta),
		"steer_rotations": steer_rotations,
		# Where the top of the rim currently points, in the column's parent frame.
		# Negative X means turned left. This is what makes the steering direction an
		# assertion rather than something somebody has to eyeball once and remember.
		"steering_wheel_up": _steering_wheel.transform.basis * _steering_wheel_up_rest,
		"steering_wheel_moved": not _steering_wheel.transform.is_equal_approx(_steering_wheel_rest),
		"steering_wheel_axis": _steering_wheel_axis,
		"turret_yaw": _turret_yaw_angle,
		"turret_pitch": _turret_pitch_angle,
		"headlights": _headlights_on,
	}


func _place_headlight(light: SpotLight3D, marker_path: NodePath) -> void:
	var marker: Node3D = _model.get_node(marker_path) as Node3D
	# The position lives in the asset, not duplicated here, so a re-export that
	# moves the lamps moves the beams with them.
	light.position = global_transform.affine_inverse() * marker.global_position
	light.rotation = Vector3(deg_to_rad(headlight_pitch_degrees), 0.0, 0.0)
	light.light_energy = headlight_energy
	light.spot_range = headlight_range
	light.spot_angle = headlight_angle_degrees
	light.spot_angle_attenuation = 0.6
	# Deliberately unshadowed. gl_compatibility supports spot shadows, but two
	# shadow-casting lamps is the wrong place to spend a web frame budget.
	light.shadow_enabled = false


## Lowest Y a shape reaches once placed, in this node's space.
func _lowest_point(shape: Shape3D, placement: Transform3D) -> float:
	if not shape is ConvexPolygonShape3D:
		# Not a hull we can measure; let the name predicate be the only gate.
		return INF
	var lowest: float = INF
	for point: Vector3 in (shape as ConvexPolygonShape3D).points:
		lowest = minf(lowest, (placement * point).y)
	return lowest
