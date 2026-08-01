class_name CrawlerCameraDirector
extends Node3D

## Owns the two camera rigs and decides which one is live.
##
## It exists so that the rest of the example has ONE camera reference instead of
## two. MarkerPilot holds a director, not a chase rig and an orbit rig and a rule
## about which is which; the world scene instances one node rather than wiring two
## sibling rigs by hand.
##
## Both rigs are children of this node and therefore SIBLINGS of the creature, never
## children of it. A camera parented to the creature inherits its rotation, and this
## creature writhes continuously -- the view would roll with every stroke.
##
## It reads no input either. MarkerPilot owns the mouse and the keys and calls
## `toggle()` / `orbit_look()` / `drive_basis()`.

@export_group("Wiring")
## The creature. Passed down to both rigs.
@export var target: Node3D
## The marker. Only the chase rig uses it, to bias the shot toward where the player
## is steering.
@export var marker: Node3D

@export_group("Startup")
## Which rig is live at spawn. ORBIT by default: it is the rig you drive with, and
## the frame the player's stick is measured in. The chase rig is the cinematic shot,
## one `V` away, and it steers the old way -- by aiming the marker itself.
@export var start_in_orbit: bool = true

var _orbit_active: bool = false

@onready var _chase: CrawlerChaseRig = %ChaseRig as CrawlerChaseRig
@onready var _orbit: CrawlerOrbitRig = %OrbitRig as CrawlerOrbitRig


func _ready() -> void:
	_chase.target = target
	_chase.secondary = marker
	_orbit.target = target
	# Both rigs cached their target in their own _ready, which has already run --
	# children are readied before their parent. Re-snapping is what makes assigning
	# `target` here work at all.
	_chase.snap()
	set_orbit_active(start_in_orbit)


## Swap cameras. Bound to `crawler_camera` by MarkerPilot.
func toggle() -> void:
	set_orbit_active(not _orbit_active)


## Is the orbit rig live? MarkerPilot asks this to decide where a mouse delta goes.
func wants_look() -> bool:
	return _orbit_active


## Route a mouse delta to the orbit rig. A no-op when the chase rig is live, so the
## caller does not need to branch twice.
func orbit_look(relative: Vector2) -> void:
	if _orbit_active:
		_orbit.apply_look(relative)


## The frame the player's stick is expressed in: -Z is away from the camera.
##
## ONLY MEANINGFUL WHILE `wants_look()` IS TRUE. The two answers come from the same
## flag on purpose -- the rig that takes the mouse is the rig that defines forward,
## and splitting those would let the player steer one camera while flying along
## another. Under the chase rig there is no camera frame to fly along at all: that
## camera derives its own angle from the creature, so measuring forward off it would
## close a loop between where you are pointed and where you are pushed.
func drive_basis() -> Basis:
	return _orbit.look_basis()


## The Camera3D currently rendering. Used by the verifier and the capture tool.
func active_camera() -> Camera3D:
	return _orbit.camera() if _orbit_active else _chase.camera()


## Make exactly one rig live.
##
## Two things here are less obvious than they look.
##
## The orbit yaw is SEEDED from the chase camera's current world yaw. Without it the
## orbit rig is still sitting at whatever angle it was last left at -- usually zero,
## meaning "looking down world -Z" -- and the first press of the toggle key hurls the
## view to an unrelated part of the corridor. Seeding makes the switch read as a
## change of camera behaviour rather than a teleport.
##
## The inactive rig is PROCESS_MODE_DISABLED, not merely un-`current`. Setting
## `current = true` on the second camera does silently un-`current` the first, so the
## rendering is correct either way -- but leaving both rigs processing means two
## SpringArm3D shape casts per frame for a camera nobody is looking through, and a
## profile that blames the wrong thing. The chase rig is re-snapped on the way back
## in, because a rig that has not processed for a while is parked somewhere stale.
func set_orbit_active(orbit_active: bool) -> void:
	if orbit_active:
		_orbit.seed_yaw(_chase.global_rotation.y)
	else:
		_chase.snap()
	_orbit_active = orbit_active

	_chase.process_mode = PROCESS_MODE_DISABLED if orbit_active else PROCESS_MODE_INHERIT
	_orbit.process_mode = PROCESS_MODE_INHERIT if orbit_active else PROCESS_MODE_DISABLED
	_chase.camera().current = not orbit_active
	_orbit.camera().current = orbit_active
