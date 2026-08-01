class_name MarkerPilot
extends Marker3D

## The player's INTENT, flown directly. A 6DOF free-fly marker in zero g.
##
## This node is not the creature and does not touch it. CrawlerBody reads this
## marker's position as a target and lags behind it on a spring; everything that
## makes the crawl look like a crawl happens over there. Which means you can fly
## this around with no creature in the scene at all, and the creature can be driven
## with no player, no camera and no HUD -- that separation is the whole reason the
## marker exists rather than the player controlling the body directly.
##
## THE ROOT OF THE SCENE IS THE MARKER. Not a Node3D with a Marker3D inside it: one
## node, so there is never a question about which of the two actually moved.
##
## FLIGHT IS MEASURED OFF THE CAMERA, not off the mouse. While the orbit rig is live
## -- which it is by default -- this marker ADOPTS that rig's facing and flies along
## it, so forward is "away from the camera" and orbiting the view while W is still
## held is how you steer. With no camera wired, or under the chase rig, the mouse
## rotates the marker directly and it flies in its own frame; that is the older
## look-to-fly scheme and it is what every tool and verifier runs on.
##
## IT IS THE ONLY FILE IN THIS EXAMPLE THAT READS INPUT. It owns `Input`,
## `Input.mouse_mode`, the `ui_cancel` release and every `crawler_*` action,
## including the camera toggle. `[input]` in the static suite greps for that and
## fails if a second file starts reading the keyboard.

## The six directions containment probes along. World axes rather than local: the
## marker's own orientation is a look direction, and a wall does not care which way
## you are facing.
const AXES: Array[Vector3] = [
	Vector3.RIGHT,
	Vector3.LEFT,
	Vector3.UP,
	Vector3.DOWN,
	Vector3.BACK,
	Vector3.FORWARD,
]

@export_group("Flight")
## Metres per second at full stick.
@export var move_speed: float = 9.0
@export var boost_multiplier: float = 2.1
## How fast the marker converges on the commanded velocity, 1/s.
@export var accel: float = 26.0
## And how fast it stops when nothing is held, 1/s. Lower than `accel` so releasing
## the stick coasts rather than stopping dead -- a marker that halts instantly makes
## the creature's leash spring snap taut, which reads as a hitch in the creature.
@export var brake: float = 14.0

@export_group("Look")
## Radians of rotation per pixel of mouse movement.
@export var mouse_sensitivity: float = 0.0022
## Just short of the pole. At exactly 90 the Euler composition below degenerates.
@export var pitch_limit_degrees: float = 88.0
## Radians per second of roll from Q/E, when `allow_roll` is on.
@export var roll_speed: float = 1.6
## Whether Q and E roll the marker.
##
## OFF by default, and that is a design decision rather than an omission. The marker
## is an INTENT: CrawlerBody derives its own up vector from whichever wall is
## nearest, so marker roll means precisely nothing to the solver -- it changes
## nothing about how the creature moves or looks. What it does do is make W
## ambiguous the moment you are upside down. Translation is still fully 6DOF in the
## marker's own frame; this only governs whether the frame can spin about its nose.
@export var allow_roll: bool = false

@export_group("Containment")
## Metres of clearance the marker keeps from the corridor shell.
##
## Without this the player parks the marker inside a wall, the leash drags the body
## in after it, the body's own depenetration shoves it back out, and the creature
## buzzes against the wall at the physics rate forever. It looks like a bug in the
## body solver and it is not.
@export var clearance_radius: float = 1.0
@export_flags_3d_physics var containment_mask: int = CrawlerLayers.MASK_MARKER_PROBE

@export_group("Wiring")
## Optional, and load-bearing when present: the live orbit rig is where forward
## comes from. With none, V does nothing, mouse deltas only ever steer the marker,
## and flight falls back to the marker's own frame -- which is exactly the state
## every tool and both verifier suites drive it in.
@export var camera: CrawlerCameraDirector
## Whether to grab the pointer on the first click. EVERY tool sets this false -- a
## capture run that steals the mouse has no way to give it back.
@export var capture_mouse: bool = true

var _velocity: Vector3 = Vector3.ZERO
var _mouse_delta: Vector2 = Vector2.ZERO
var _yaw: float = 0.0
var _pitch: float = 0.0
var _roll: float = 0.0


func _ready() -> void:
	var euler: Vector3 = global_basis.get_euler()
	_pitch = euler.x
	_yaw = euler.y
	_roll = euler.z


func _unhandled_input(event: InputEvent) -> void:
	if not capture_mouse:
		return

	# Capture on the FIRST CLICK, never in _ready(). Setting MOUSE_MODE_CAPTURED
	# before a user gesture is a silent no-op in a browser, and this project is
	# web-first -- so a pointer lock requested at startup simply never happens and
	# the game ships with a camera that does not respond to the mouse.
	if event is InputEventMouseButton and (event as InputEventMouseButton).pressed:
		if Input.mouse_mode != Input.MOUSE_MODE_CAPTURED:
			Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
			return

	if event.is_action_pressed(&"ui_cancel"):
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
		return

	if event is InputEventMouseMotion and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
		var motion: InputEventMouseMotion = event as InputEventMouseMotion
		# The orbit rig needs the mouse too, so the pilot ROUTES it rather than
		# sharing it. One input owner, and exactly one deliberate, greppable hop
		# into the camera component.
		if camera != null and camera.wants_look():
			camera.orbit_look(motion.relative)
		else:
			_mouse_delta += motion.relative


func _physics_process(delta: float) -> void:
	if camera != null and Input.is_action_just_pressed(&"crawler_camera"):
		camera.toggle()
	_apply_look(delta)
	_apply_movement(delta)
	_apply_containment()


## Jump the marker somewhere and kill its momentum.
##
## For tools and verifiers. `[lag]` teleports the marker 20 m ahead and asserts the
## creature neither snaps to it nor fails to arrive; doing that by writing
## `global_position` alone would leave the old velocity running and measure the
## wrong thing.
func teleport(to: Vector3) -> void:
	global_position = to
	_velocity = Vector3.ZERO


func velocity() -> Vector3:
	return _velocity


func _apply_look(delta: float) -> void:
	if camera != null and camera.wants_look():
		_adopt_camera_facing()
		return

	_yaw -= _mouse_delta.x * mouse_sensitivity
	_pitch -= _mouse_delta.y * mouse_sensitivity
	_mouse_delta = Vector2.ZERO

	var limit: float = deg_to_rad(pitch_limit_degrees)
	_pitch = clampf(_pitch, -limit, limit)

	if allow_roll:
		var roll_input: float = (
			Input.get_action_strength(&"crawler_roll_right")
			- Input.get_action_strength(&"crawler_roll_left")
		)
		_roll += roll_input * roll_speed * delta

	# Assigned to global_basis, not the local one, so the marker behaves identically
	# whether or not whatever it is parented to has a transform of its own -- the
	# movement below reads global_basis, and the two must not be able to disagree.
	global_basis = Basis.from_euler(Vector3(_pitch, _yaw, _roll))


## Take the live camera's facing as this marker's own.
##
## This is the ENTIRE camera-relative movement change. `_apply_movement` already
## flies along `global_basis`, so once that basis is the camera's, forward is away
## from the camera and strafe and rise are the camera's right and up -- there is no
## second frame to keep in step with the first, and no branch down in the movement.
##
## It writes `_yaw` and `_pitch` rather than only the basis, so a `V` back to the
## chase rig picks the mouse up from where the player was already looking instead of
## snapping to whatever angle they last left the marker at.
##
## Roll is dropped on the floor here: the orbit rig has none, and Q/E therefore do
## nothing while it is live. `allow_roll` is off by default anyway, and the reason
## given at its declaration -- that marker roll means nothing to the body solver --
## applies twice over when the frame comes from a world-up-anchored camera.
##
## Never called from `_ready()`. The director is a sibling and is readied AFTER this
## node, so its rigs do not exist yet; `_physics_process` is late enough for both.
func _adopt_camera_facing() -> void:
	var euler: Vector3 = camera.drive_basis().get_euler()
	var limit: float = deg_to_rad(pitch_limit_degrees)
	_pitch = clampf(euler.x, -limit, limit)
	_yaw = euler.y
	_roll = 0.0
	# Whatever the pointer did this frame went to the orbit rig, not here. Cleared
	# anyway so a toggle mid-frame cannot leave a stale delta to be applied later.
	_mouse_delta = Vector2.ZERO
	global_basis = Basis.from_euler(Vector3(_pitch, _yaw, _roll))


func _apply_movement(delta: float) -> void:
	var wish: Vector3 = Vector3.ZERO
	wish.z -= Input.get_action_strength(&"crawler_forward")
	wish.z += Input.get_action_strength(&"crawler_back")
	wish.x -= Input.get_action_strength(&"crawler_left")
	wish.x += Input.get_action_strength(&"crawler_right")
	wish.y += Input.get_action_strength(&"crawler_rise")
	wish.y -= Input.get_action_strength(&"crawler_sink")
	# Clamped rather than normalised: a partial stick should stay partial, but
	# holding forward and right at once must not be 1.41 times faster than forward.
	wish = wish.limit_length(1.0)

	var speed: float = move_speed
	if Input.is_action_pressed(&"crawler_boost"):
		speed *= boost_multiplier

	var wanted: Vector3 = global_basis * wish * speed
	var rate: float = brake if wish.is_zero_approx() else accel
	_velocity = _velocity.lerp(wanted, 1.0 - exp(-rate * delta))
	global_position += _velocity * delta


## Push the marker back out of any wall it has been flown into.
##
## Only the INWARD component of velocity is killed, never reflected. A reflection
## makes the marker bounce off the corridor, which the player reads as the controls
## fighting them; killing the component just makes the wall feel solid.
func _apply_containment() -> void:
	var space: PhysicsDirectSpaceState3D = get_world_3d().direct_space_state
	for axis: Vector3 in AXES:
		var from: Vector3 = global_position
		var params: PhysicsRayQueryParameters3D = PhysicsRayQueryParameters3D.create(
			from, from + axis * clearance_radius, containment_mask
		)
		var hit: Dictionary = space.intersect_ray(params)
		if hit.is_empty():
			continue
		var normal: Vector3 = hit["normal"]
		var depth: float = clearance_radius - from.distance_to(hit["position"] as Vector3)
		if depth > 0.0:
			global_position += normal * depth
		var inward: float = _velocity.dot(-normal)
		if inward > 0.0:
			_velocity += normal * inward
