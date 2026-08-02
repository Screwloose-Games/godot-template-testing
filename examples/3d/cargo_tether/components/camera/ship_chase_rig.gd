class_name ShipChaseRig
extends Node3D

## Third-person chase camera for a ship that can point anywhere.
##
## Derived from examples/3d/vehicle_jeep/components/camera/chase_camera_rig.gd,
## which keeps the good parts: a SIBLING of the target rather than a child, its
## own frame-rate-independent position smoothing, and a SpringArm3D masking only
## the world so it can never catch on the thing it is following.
##
## THE EULER YAW/PITCH CHAIN IS GONE. That chain is anchored to world up and
## gimbal-locks the moment the ship flies straight up, which in 6DOF is a normal
## Tuesday rather than an edge case. Orientation here is a Basis built with
## looking_at and slerped as a Quaternion, so there is no pole.
##
## IT DOES NOT READ THE MOUSE. In a 6DOF ship the mouse steers the ship, so
## ShipController owns the mouse, the mouse mode and the release. One owner.
##
## FRAMING THE CARGO IS THE JOB. The camera looks at a point biased from the ship
## toward the cargo, and pulls back as the two separate, so the swinging mass
## stays on screen without the player having to chase it. Past about 22 m of
## tether that stops being winnable with camera alone and the HUD's off-screen
## marker takes over -- pulling back far enough to frame a 30 m tether would
## render the ship a dot.

@export_group("Wiring")
## The ship.
@export var target: Node3D
## The cargo. Optional -- with none, the rig frames the ship alone.
@export var secondary: Node3D

@export_group("Follow")
## Offset from the target, in the TARGET's frame, not the world's. There is no
## ground plane out here, so "two metres above the world" is meaningless and "two
## metres above the deck" is not.
@export var follow_offset_local: Vector3 = Vector3(0.0, 3.0, 0.0)
## Position follow stiffness, 1/s.
@export var follow_speed: float = 9.0
## Orientation follow stiffness, 1/s. Slower than position, so the frame settles
## after a yank instead of snapping with it.
@export var turn_speed: float = 7.0

@export_group("Framing")
## How far toward the cargo the look point sits, at minimum and maximum tether
## separation. Never past 0.5: the ship has to stay the subject of the shot, and
## the look point must also stay AHEAD of the camera -- bias * separation greater
## than the arm length would put it behind the eye and flip the view.
@export var cargo_bias_near: float = 0.22
@export var cargo_bias_far: float = 0.5
## Separations those two biases correspond to. Matches the winch band.
@export var bias_near_distance: float = 6.0
@export var bias_far_distance: float = 30.0

@export_group("Dolly")
@export var spring_length_min: float = 9.0
@export var spring_length_max: float = 22.0
## Arm length added at `dolly_speed`. Pulling back with speed is most of what
## makes 100 m/s read as fast.
@export var speed_dolly: float = 3.5
@export var dolly_speed: float = 90.0
## Arm length added per metre of ship-to-cargo separation past the slack point.
@export var separation_gain: float = 0.4
@export var separation_free: float = 8.0
## Metres the camera rises per metre of separation past `separation_free`.
##
## The arm can never outrun the tether -- it caps at 22 m and the line reaches 30
## -- so a crate trailing straight astern will sometimes sit exactly where the
## camera is, and it renders as a wall of cargo across the lens. Lifting the eye
## as the line extends makes the crate pass BELOW the camera instead of through
## it, which both unblocks the view and puts the crate on screen where the player
## wants it. Capped so it never becomes a top-down view.
@export var separation_lift: float = 0.3
@export var separation_lift_max: float = 6.0

@export_group("Orientation")
## How much of the ship's own roll the frame adopts, 0 to 1.
##
## 0.35 rather than 1.0, deliberately. Full roll-follow barrel-rolls the whole
## frame with the ship: it is the textbook 6DOF motion-sickness trigger, and --
## more decisive here -- it destroys the read on the cargo, because the swing is
## then happening in a rotating reference frame and the player cannot tell an arc
## from a roll. Zero makes roll invisible, so you cannot tell where your lateral
## thrusters point. 0.35 banks enough to read the roll while keeping a stable
## horizon. "World up" is arbitrary in deep space, but it is CONSISTENT, and the
## consistency is the whole value.
@export_range(0.0, 1.0) var roll_follow: float = 0.35
## How fast the up reference may swing, 1/s. Low enough that the forced swap near
## the pole (below) is a lean rather than a snap.
@export var up_blend_speed: float = 4.0

@export_group("Lens")
## Godot's Camera3D.fov is VERTICAL by default (keep_aspect is KEEP_HEIGHT), not
## horizontal. The first pass here ramped 70 -> 88 on the assumption it was
## horizontal, which at 16:9 is a ~120 degree horizontal lens: the ship shrank to
## fifty pixels at a 22 m arm and the speed ramp read as the camera retreating.
## 60 -> 78 vertical is roughly 90 -> 110 horizontal, which is a wide-but-sane
## space lens.
@export var fov_min: float = 60.0
@export var fov_max: float = 78.0
@export var fov_boost_bonus: float = 6.0
@export var fov_speed: float = 4.0

var _orientation: Quaternion = Quaternion.IDENTITY
var _up_ref: Vector3 = Vector3.UP
var _looking_back: bool = false

@onready var _arm: SpringArm3D = %SpringArm as SpringArm3D
@onready var _camera: Camera3D = %Camera as Camera3D


func _ready() -> void:
	_arm.collision_mask = TetherLayers.MASK_CAMERA_ARM
	if target == null:
		return
	global_position = _follow_point()
	_up_ref = _wanted_up(_view_direction())
	_orientation = _wanted_orientation()
	quaternion = _orientation


func _process(delta: float) -> void:
	if target == null:
		return
	_looking_back = Input.is_action_pressed(&"ship_look_back")

	var wanted_position: Vector3 = _follow_point()
	global_position = global_position.lerp(wanted_position, 1.0 - exp(-follow_speed * delta))

	var forward: Vector3 = _view_direction()
	_up_ref = _blend_direction(_up_ref, _wanted_up(forward), 1.0 - exp(-up_blend_speed * delta))
	_orientation = _orientation.slerp(_wanted_orientation(), 1.0 - exp(-turn_speed * delta))
	quaternion = _orientation

	_arm.spring_length = _wanted_arm_length()
	_camera.fov = lerpf(_camera.fov, _wanted_fov(), 1.0 - exp(-fov_speed * delta))


func _follow_point() -> Vector3:
	var offset: Vector3 = follow_offset_local
	if secondary != null:
		var gap: float = target.global_position.distance_to(secondary.global_position)
		offset.y += minf(separation_lift * maxf(gap - separation_free, 0.0), separation_lift_max)
	return target.global_position + target.global_basis * offset


## What the camera aims at: the ship, pulled toward the cargo as the two separate.
func _look_point() -> Vector3:
	var ship_point: Vector3 = target.global_position
	if secondary == null:
		return ship_point
	var separation: float = ship_point.distance_to(secondary.global_position)
	var span: float = maxf(bias_far_distance - bias_near_distance, 0.001)
	var t: float = clampf((separation - bias_near_distance) / span, 0.0, 1.0)
	return ship_point.lerp(secondary.global_position, lerpf(cargo_bias_near, cargo_bias_far, t))


## Where the camera will actually end up, given the arm it is hanging off.
##
## The rig sits ON the ship, so it cannot be oriented by "look from here at the
## ship" -- that direction degenerates to whatever tiny offset separates the rig
## from its own look point, and the SpringArm then pushes the camera along it in
## whichever direction that happens to be. The first version did exactly that and
## parked the camera in FRONT of the ship, looking back at its own nose.
##
## So the eye is predicted first, from the ship's own +Z (which is astern), and
## the orientation is solved from there. One iteration is enough: the camera lands
## within a few centimetres of the predicted point every frame.
func _eye_point() -> Vector3:
	var astern: Vector3 = target.global_basis.z
	if _looking_back:
		astern = -astern
	return global_position + astern * _arm.spring_length


func _view_direction() -> Vector3:
	var to_look: Vector3 = _look_point() - _eye_point()
	if to_look.length_squared() < 0.000001:
		to_look = -target.global_basis.z
	return to_look.normalized()


func _wanted_orientation() -> Quaternion:
	var forward: Vector3 = _view_direction()
	var up: Vector3 = _up_ref
	if absf(forward.dot(up)) > 0.999:
		up = target.global_basis.x.normalized()
	return Basis.looking_at(forward, up).get_rotation_quaternion()


## The up reference, blended between world up and the ship's own up by
## `roll_follow`, and forced onto the ship's up near the pole.
##
## Without that forcing, Basis.looking_at degenerates as the view direction lines
## up with the reference and the frame spins. Swapping hard would be a visible
## snap-roll, which is why the caller slerps toward this rather than assigning it.
func _wanted_up(forward: Vector3) -> Vector3:
	var ship_up: Vector3 = target.global_basis.y.normalized()
	var blended: Vector3 = _blend_direction(Vector3.UP, ship_up, roll_follow)
	if absf(forward.dot(blended)) > 0.985:
		return ship_up
	return blended


## Normalised lerp between two directions.
##
## NOT Vector3.slerp. Slerp rotates about the cross product of its arguments and
## asserts that axis is unit length, and a physics-driven basis drifts off unit
## length by a part in a thousand within seconds of the ship being tumbled -- so
## the rig spammed "The axis Vector3 (...) must be normalized" every frame once a
## tether yank had spun the hull. Normalising the inputs is not enough; the
## complaint comes from inside the rotation. An nlerp has no axis-angle step at
## all, and for a camera up vector the difference in easing is invisible.
func _blend_direction(from: Vector3, to: Vector3, weight: float) -> Vector3:
	var blended: Vector3 = from.lerp(to, clampf(weight, 0.0, 1.0))
	# Near-antipodal inputs lerp through zero, and normalising that is a NaN that
	# poisons the whole transform.
	if blended.length_squared() < 0.000001:
		return to.normalized()
	return blended.normalized()


func _wanted_arm_length() -> float:
	var speed: float = 0.0
	if target is RigidBody3D:
		speed = (target as RigidBody3D).linear_velocity.length()
	var length: float = spring_length_min
	length += speed_dolly * clampf(speed / maxf(dolly_speed, 0.001), 0.0, 1.0)
	if secondary != null:
		var gap: float = target.global_position.distance_to(secondary.global_position)
		length += separation_gain * maxf(gap - separation_free, 0.0)
	return clampf(length, spring_length_min, spring_length_max)


func _wanted_fov() -> float:
	var speed: float = 0.0
	var boosting: bool = false
	if target is ShipController:
		var ship: ShipController = target as ShipController
		speed = ship.linear_velocity.length()
		boosting = ship.is_boosting()
	var ratio: float = clampf(speed / maxf(dolly_speed, 0.001), 0.0, 1.0)
	return lerpf(fov_min, fov_max, ratio) + (fov_boost_bonus if boosting else 0.0)
