class_name CrawlerOrbitRig
extends Node3D

## THE CAMERA YOU DRIVE WITH. Orbits the creature on the mouse, and its facing is
## the frame the player's stick is expressed in.
##
## Holding forward flies the marker straight out of the screen, so a small orbit
## while W is still held is a small course correction -- steer by moving the camera
## rather than by re-aiming the thing you are flying. `look_basis()` is what makes
## that work: MarkerPilot adopts this basis instead of accumulating its own.
##
## Ported from examples/3d/exploration_quadraped/components/camera/orbit_camera_rig.gd,
## with one deliberate amputation: THE MOUSE READING IS GONE. The original owned
## `Input.mouse_mode` and read `InputEventMouseMotion` itself, which is fine when it
## is the only camera in the scene. Here there are two rigs and a pilot, and three
## files fighting over the pointer is how you get a camera that spins when you did
## not touch it. MarkerPilot owns the mouse and calls `apply_look()`.
##
## The Euler yaw/pitch chain that the chase rig refuses to use is CORRECT here. An
## orbit camera is explicitly anchored to world up -- that is what "orbit" means,
## and it is what keeps a held W predictable while you swing the view around. The
## chase rig cannot use it because it has to survive the creature going vertical;
## this rig never adopts the creature's orientation at all.
##
## It still has no opinion about where the creature is *going* -- it frames the
## creature, and the player decides. That is also what makes it the good camera for
## watching the procedural animation misbehave.

@export_group("Wiring")
## What to orbit around.
@export var target: Node3D

@export_group("Follow")
## Position follow stiffness, 1/s. Snappier than the chase rig -- when you have
## switched to this camera you are inspecting something and lag is just in the way.
@export var follow_speed: float = 12.0
## Offset from the target in WORLD space, so the pivot sits near the creature's
## middle rather than at its origin.
@export var pivot_offset: Vector3 = Vector3(0.0, 0.5, 0.0)

@export_group("Look")
## Radians of rotation per pixel of mouse movement.
@export var look_sensitivity: float = 0.0035
## How far up and down the orbit may go, in degrees. Just short of the pole: at
## exactly 90 the Euler chain degenerates and the view rolls for no visible reason.
@export var pitch_limit_degrees: float = 85.0

var _yaw: float = 0.0
## The resting orbit pitch is also the resting FLIGHT pitch, because forward is
## measured off this rig. At the -0.25 rad this used to sit at, a player who holds W
## and touches nothing else sinks at roughly 2.2 m/s and is scraping the corridor
## floor within a few seconds -- which reads as the creature being dragged down
## rather than as the camera being angled. Near level, with a slight look-down for
## framing.
var _pitch: float = -0.1

@onready var _yaw_node: Node3D = %Yaw as Node3D
@onready var _pitch_node: Node3D = %Pitch as Node3D
@onready var _arm: SpringArm3D = %SpringArm as SpringArm3D
@onready var _camera: Camera3D = %Camera as Camera3D


func _ready() -> void:
	_arm.collision_mask = CrawlerLayers.MASK_CAMERA_ARM
	if target != null:
		global_position = target.global_position + pivot_offset
	_apply_angles()


## The Camera3D this rig drives. The director needs it to set `current`; nothing
## else should reach inside.
func camera() -> Camera3D:
	return _camera


## The rig's world facing: -Z is where the view points, so -Z is also "away from the
## camera". MarkerPilot flies along it.
##
## Taken from the Camera3D rather than from `_yaw`/`_pitch` so it survives anything
## that displaces the shot without going through `apply_look()`. The SpringArm3D
## moves the camera's POSITION when it hits a wall and never its rotation, so a
## collapsed arm does not swing the direction the player is flying.
func look_basis() -> Basis:
	return _camera.global_basis


func _process(delta: float) -> void:
	if target == null:
		return
	var wanted: Vector3 = target.global_position + pivot_offset
	global_position = global_position.lerp(wanted, 1.0 - exp(-follow_speed * delta))


## Called by MarkerPilot when this rig is the active one. `relative` is the raw
## mouse delta in pixels.
func apply_look(relative: Vector2) -> void:
	_yaw -= relative.x * look_sensitivity
	_pitch -= relative.y * look_sensitivity
	var limit: float = deg_to_rad(pitch_limit_degrees)
	_pitch = clampf(_pitch, -limit, limit)
	_apply_angles()


## Point the orbit at a given world yaw without moving anything else.
##
## The director calls this at the moment of a toggle. Without it the orbit rig's
## yaw is still whatever it was left at -- usually 0, meaning "looking down -Z of
## the world" -- and the first switch away from the chase camera SNAPS to a
## completely unrelated view. Seeding it from where the player was already looking
## makes the toggle read as a change of camera behaviour rather than a teleport.
func seed_yaw(world_yaw: float) -> void:
	_yaw = world_yaw
	_apply_angles()


func _apply_angles() -> void:
	if _yaw_node == null or _pitch_node == null:
		return
	_yaw_node.rotation = Vector3(0.0, _yaw, 0.0)
	_pitch_node.rotation = Vector3(_pitch, 0.0, 0.0)
