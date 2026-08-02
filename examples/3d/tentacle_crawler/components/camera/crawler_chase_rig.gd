class_name CrawlerChaseRig
extends Node3D

## Third-person chase camera for something that crawls on any surface.
##
## Ported from examples/3d/cargo_tether/components/camera/ship_chase_rig.gd, which
## keeps the parts that were expensive to learn: a SIBLING of the target rather
## than a child, frame-rate-independent smoothing, a SpringArm3D masking only the
## corridor shell, and -- above all -- NO EULER YAW/PITCH CHAIN. That chain is
## anchored to world up and gimbal-locks the moment the target goes vertical, which
## for a creature that crawls up walls and along ceilings is a normal Tuesday.
## Orientation here is a Basis built with looking_at and slerped as a Quaternion,
## so there is no pole.
##
## IT READS NO INPUT. MarkerPilot owns the mouse, the mouse mode and the release.
## One owner, which is what lets the whole creature be driven by a verifier with no
## player and no camera in the scene at all.
##
## IT MEASURES ITS TARGET'S SPEED RATHER THAN ASKING FOR IT. The obvious version
## calls something like `target.current_speed()`, which welds the camera to
## CrawlerBody and makes it useless for framing the marker, a test rig, or anything
## else. Differencing the target's position across frames costs one subtraction and
## works on any Node3D.

## Metres per second the dolly and lens ramps are measured against. The creature
## tops out near 14, so this is "flat out" rather than an arbitrary scale.
const REFERENCE_SPEED: float = 12.0

@export_group("Wiring")
## The creature.
@export var target: Node3D
## The marker it is chasing. Optional -- with none, the rig frames the body alone.
@export var secondary: Node3D

@export_group("Follow")
## Offset from the target, in the TARGET's frame, not the world's. The creature
## rolls and crawls on ceilings, so "two metres above the world" is meaningless
## here and "two metres off its own back" is not.
@export var follow_offset_local: Vector3 = Vector3(0.0, 0.8, 0.0)
## Position follow stiffness, 1/s.
@export var follow_speed: float = 8.0
## Orientation follow stiffness, 1/s. Slower than position on purpose, so the frame
## settles after a lurch instead of snapping with it -- this creature lurches by
## design and a rigid camera would make every stroke read as a camera glitch.
@export var turn_speed: float = 5.0

@export_group("Framing")
## How far from the body toward the marker the look point sits.
##
## Not zero. The marker is where the player is steering, and a camera locked on the
## body alone hides the intent -- you cannot see that you are asking for a turn
## until the creature has already taken it. Not past 0.5 either: the creature has
## to stay the subject of the shot.
@export_range(0.0, 0.5) var marker_bias: float = 0.35

@export_group("Dolly")
## Doubled from 5.5/9.0 for the model, and that is about the ceiling of what is useful.
##
## THE ARM IS WALL-LIMITED IN A TUBE, so past a point this number stops meaning
## anything. The arm rides the body's own backward axis, and the body rolls -- so in an
## 8 m-tall corridor any tilt walks the arm into the ceiling. Asking for 16 m measured
## an ACTUAL 4.6 m; `capture_crawler` prints hit-length against requested length for
## exactly this reason. The lens below is what actually widened the shot.
@export var spring_length_min: float = 12.0
@export var spring_length_max: float = 16.0
## Arm length added at REFERENCE_SPEED. Pulling back with speed is most of what
## makes a crawl read as fast rather than as a slow slide.
@export var speed_dolly: float = 3.5

@export_group("Orientation")
## How much of the creature's own roll the frame adopts, 0 to 1.
##
## 0.25, not 1.0. Full roll-follow barrel-rolls the whole frame with a body that
## writhes continuously -- it is the textbook motion-sickness trigger and it
## destroys the read on the tentacles, because a strand's swing is then happening
## in a rotating reference frame. Zero makes it impossible to tell you are crawling
## along a wall. 0.25 banks enough to read the roll against a stable horizon.
@export_range(0.0, 1.0) var roll_follow: float = 0.25
## How fast the up reference may swing, 1/s.
@export var up_blend_speed: float = 3.5

@export_group("Lens")
## Camera3D.fov is VERTICAL (keep_aspect defaults to KEEP_HEIGHT), NOT horizontal.
## 62 -> 72 vertical is about 92 -> 105 horizontal at 16:9, which is a wide-but-sane
## corridor lens. Typing 88 here on the assumption it is horizontal gives roughly a
## 120 degree horizontal view, and the creature shrinks to a smear at the centre.
@export var fov_min: float = 70.0
@export var fov_max: float = 80.0
@export var fov_speed: float = 4.0

var _orientation: Quaternion = Quaternion.IDENTITY
var _up_ref: Vector3 = Vector3.UP
var _measured_speed: float = 0.0
var _last_target_position: Vector3 = Vector3.ZERO
var _has_last_position: bool = false

@onready var _arm: SpringArm3D = %SpringArm as SpringArm3D
@onready var _camera: Camera3D = %Camera as Camera3D


func _ready() -> void:
	_arm.collision_mask = CrawlerLayers.MASK_CAMERA_ARM
	snap()


## The Camera3D this rig drives. The director needs it to set `current`; nothing
## else should reach inside.
func camera() -> Camera3D:
	return _camera


## Jump straight to the framing this rig would have settled into, with no easing.
##
## Called on _ready, and again by the director every time this rig becomes the
## active camera. That second call is the one that matters: a disabled rig does not
## _process, so while the orbit camera was live this one stayed parked where the
## creature used to be. Without a snap, switching back plays a second-long swoop
## across the corridor from a stale position, which reads as the camera being
## broken rather than as it catching up.
func snap() -> void:
	if target == null:
		return
	_last_target_position = target.global_position
	_has_last_position = true
	_measured_speed = 0.0
	global_position = _follow_point()
	_up_ref = _wanted_up(_view_direction())
	_orientation = _wanted_orientation()
	quaternion = _orientation


func _process(delta: float) -> void:
	if target == null:
		return
	_measure_speed(delta)

	global_position = global_position.lerp(_follow_point(), 1.0 - exp(-follow_speed * delta))

	var forward: Vector3 = _view_direction()
	var up_blend: float = CrawlerMath.smoothing(up_blend_speed, delta)
	_up_ref = CrawlerMath.blend_direction(_up_ref, _wanted_up(forward), up_blend)
	_orientation = _orientation.slerp(_wanted_orientation(), 1.0 - exp(-turn_speed * delta))
	quaternion = _orientation

	_arm.spring_length = _wanted_arm_length()
	_camera.fov = lerpf(_camera.fov, _wanted_fov(), 1.0 - exp(-fov_speed * delta))


## The camera's own view of how fast the target is moving.
##
## Smoothed hard: the raw frame difference of a body that ratchets is a square wave,
## and feeding that straight into the dolly makes the camera pump in and out on
## every stroke, which reads as the camera being broken rather than the creature
## being fast.
func _measure_speed(delta: float) -> void:
	if delta <= 0.0:
		return
	var here: Vector3 = target.global_position
	if not _has_last_position:
		_last_target_position = here
		_has_last_position = true
		return
	var instant: float = here.distance_to(_last_target_position) / delta
	_last_target_position = here
	_measured_speed = lerpf(_measured_speed, instant, 1.0 - exp(-2.5 * delta))


func _follow_point() -> Vector3:
	return target.global_position + target.global_basis * follow_offset_local


## What the camera aims at: the body, pulled toward the marker so the player can
## see where they are steering as well as what they are steering.
func _look_point() -> Vector3:
	if secondary == null:
		return target.global_position
	return target.global_position.lerp(secondary.global_position, marker_bias)


## Where the camera will actually end up, given the arm it hangs off.
##
## The rig sits ON the creature, so it cannot be oriented by "look from here at the
## creature" -- that direction degenerates to whatever tiny offset separates the rig
## from its own look point, and the SpringArm then pushes the camera along it in
## whichever direction that happens to be. In cargo_tether this exact bug parked the
## camera in FRONT of the ship looking back at its own nose.
##
## So the eye is predicted first, from the target's own +Z (which is astern), and
## the orientation is solved from there.
func _eye_point() -> Vector3:
	return global_position + target.global_basis.z * _arm.spring_length


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


## The up reference, blended between world up and the creature's own up by
## `roll_follow`, and forced onto the creature's up near the pole.
##
## Without that forcing, Basis.looking_at degenerates as the view direction lines up
## with the reference and the frame spins. Swapping hard would be a visible snap, so
## the caller slerps toward this rather than assigning it.
func _wanted_up(forward: Vector3) -> Vector3:
	var body_up: Vector3 = target.global_basis.y.normalized()
	var blended: Vector3 = CrawlerMath.blend_direction(Vector3.UP, body_up, roll_follow)
	if absf(forward.dot(blended)) > 0.985:
		return body_up
	return blended


func _wanted_arm_length() -> float:
	var ratio: float = clampf(_measured_speed / REFERENCE_SPEED, 0.0, 1.0)
	return clampf(spring_length_min + speed_dolly * ratio, spring_length_min, spring_length_max)


func _wanted_fov() -> float:
	return lerpf(fov_min, fov_max, clampf(_measured_speed / REFERENCE_SPEED, 0.0, 1.0))
