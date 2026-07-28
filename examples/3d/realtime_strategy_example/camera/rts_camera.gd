class_name RtsCamera
extends Node3D

## Standard RTS camera rig: WASD / arrows / screen-edge / middle-drag to pan, wheel to zoom.
##
## The rig is a plain Node3D sitting on the ground plane; the Camera3D child hangs above and
## behind it at a fixed pitch and never rotates. Fixed pitch removes a whole class of "which
## way is north" confusion and, more usefully, keeps unproject_position() stable so box
## select stays predictable.
##
## Shake is applied to the Camera3D's local offset, never to the rig. The rig's position has
## to stay the clean logical value for bounds clamping and for "centre on selection" to work.

const PITCH_RADIANS: float = deg_to_rad(RtsConfig.CAMERA_PITCH_DEGREES)

## Set by the HUD while the cursor is over a panel. Edge scrolling from behind a UI panel
## feels like the camera has a mind of its own.
var edge_scroll_blocked: bool = false

var _target_position: Vector3 = Vector3.ZERO
var _zoom_distance: float = RtsConfig.CAMERA_START_ZOOM
var _target_zoom: float = RtsConfig.CAMERA_START_ZOOM
var _shake_strength: float = 0.0
var _middle_drag_active: bool = false

@onready var camera: Camera3D = %Camera


func _ready() -> void:
	_target_position = global_position
	camera.rotation = Vector3(PITCH_RADIANS, 0.0, 0.0)
	_apply_camera_offset()


func _process(delta: float) -> void:
	_apply_keyboard_pan(delta)
	_apply_edge_pan(delta)
	_clamp_target()
	var follow: float = clampf(RtsConfig.CAMERA_SMOOTHING * delta, 0.0, 1.0)
	global_position = global_position.lerp(_target_position, follow)
	_zoom_distance = lerpf(_zoom_distance, _target_zoom, follow)
	_shake_strength = move_toward(_shake_strength, 0.0, RtsConfig.CAMERA_SHAKE_DECAY * delta)
	_apply_camera_offset()


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		_handle_mouse_button(event)
	elif event is InputEventMouseMotion and _middle_drag_active:
		_pan_by_screen_delta((event as InputEventMouseMotion).relative)


## Snap the camera's destination to a world point. Used by "centre on HQ" and control-group
## double-taps; the smoothing in _process turns the jump into a glide.
func focus_on(world_position: Vector3) -> void:
	_target_position = Vector3(world_position.x, 0.0, world_position.z)
	_clamp_target()


## Frames a group of units. Ignores Y so the rig stays on the ground plane.
func focus_on_average(nodes: Array) -> void:
	var total: Vector3 = Vector3.ZERO
	var count: int = 0
	for node: Node3D in nodes:
		if not is_instance_valid(node):
			continue
		total += node.global_position
		count += 1
	if count > 0:
		focus_on(total / float(count))


func shake(strength: float) -> void:
	_shake_strength = maxf(_shake_strength, strength)


func _handle_mouse_button(event: InputEventMouseButton) -> void:
	match event.button_index:
		MOUSE_BUTTON_WHEEL_UP:
			_zoom_by(-RtsConfig.CAMERA_ZOOM_STEP)
		MOUSE_BUTTON_WHEEL_DOWN:
			_zoom_by(RtsConfig.CAMERA_ZOOM_STEP)
		MOUSE_BUTTON_MIDDLE:
			_middle_drag_active = event.pressed


func _zoom_by(amount: float) -> void:
	_target_zoom = clampf(
		_target_zoom + amount, RtsConfig.CAMERA_MIN_ZOOM, RtsConfig.CAMERA_MAX_ZOOM
	)


func _apply_keyboard_pan(delta: float) -> void:
	var direction: Vector2 = Vector2.ZERO
	if Input.is_key_pressed(KEY_W) or Input.is_key_pressed(KEY_UP):
		direction.y -= 1.0
	if Input.is_key_pressed(KEY_S) or Input.is_key_pressed(KEY_DOWN):
		direction.y += 1.0
	if Input.is_key_pressed(KEY_A) or Input.is_key_pressed(KEY_LEFT):
		direction.x -= 1.0
	if Input.is_key_pressed(KEY_D) or Input.is_key_pressed(KEY_RIGHT):
		direction.x += 1.0
	_pan(direction, delta)


## Edge scrolling is suppressed when the window is unfocused — otherwise alt-tabbing away
## with the cursor near an edge sends the camera off across the map while you are not looking.
func _apply_edge_pan(delta: float) -> void:
	if edge_scroll_blocked or not DisplayServer.window_is_focused():
		return
	var viewport: Viewport = get_viewport()
	var mouse: Vector2 = RtsScreen.pick_position(viewport)
	var bounds: Vector2 = viewport.get_visible_rect().size
	if mouse.x < 0.0 or mouse.y < 0.0 or mouse.x > bounds.x or mouse.y > bounds.y:
		return
	var margin: float = RtsConfig.CAMERA_EDGE_MARGIN
	var direction: Vector2 = Vector2.ZERO
	if mouse.x < margin:
		direction.x -= 1.0
	elif mouse.x > bounds.x - margin:
		direction.x += 1.0
	if mouse.y < margin:
		direction.y -= 1.0
	elif mouse.y > bounds.y - margin:
		direction.y += 1.0
	_pan(direction, delta)


## Pan speed scales with zoom distance so a zoomed-out view still crosses the map in a
## comparable number of seconds to a zoomed-in one.
func _pan(direction: Vector2, delta: float) -> void:
	if direction == Vector2.ZERO:
		return
	var speed: float = RtsConfig.CAMERA_PAN_SPEED * _zoom_distance
	var step: Vector2 = direction.normalized() * speed * delta
	_target_position += Vector3(step.x, 0.0, step.y)


func _pan_by_screen_delta(relative: Vector2) -> void:
	var scale: float = _zoom_distance * 0.0025
	_target_position += Vector3(-relative.x * scale, 0.0, -relative.y * scale)


func _clamp_target() -> void:
	_target_position.x = clampf(
		_target_position.x, -RtsConfig.MAP_HALF_WIDTH, RtsConfig.MAP_HALF_WIDTH
	)
	_target_position.z = clampf(
		_target_position.z, -RtsConfig.MAP_HALF_DEPTH, RtsConfig.MAP_HALF_DEPTH
	)
	_target_position.y = 0.0


func _apply_camera_offset() -> void:
	var back: float = cos(-PITCH_RADIANS) * _zoom_distance
	var up: float = sin(-PITCH_RADIANS) * _zoom_distance
	var jitter: Vector3 = Vector3.ZERO
	if _shake_strength > 0.0:
		jitter = Vector3(
			randf_range(-_shake_strength, _shake_strength),
			randf_range(-_shake_strength, _shake_strength),
			0.0
		)
	camera.position = Vector3(0.0, up, back) + jitter
