class_name PlayerCommander
extends Node

## Everything the player does with the mouse and keyboard: selection, orders, control groups
## and production hotkeys.
##
## The example cannot add input actions to project.godot, so this reads raw InputEvents
## instead of named actions. That is less of a compromise than it sounds for an RTS — mouse
## buttons and modifier chords are what the genre uses, and none of them map cleanly onto
## Godot's ui_* actions anyway.
##
## Nothing here reads `event.position`. Screen coordinates for 3D picking all come from
## RtsScreen, for the reasons documented there.

signal selection_changed(units: Array)
signal hint_toggle_requested

const MOVE_COLOR: Color = Color(0.58, 0.87, 1.0)
const ATTACK_COLOR: Color = Color(1.0, 0.36, 0.3)
## Amber, between the blue of a plain move and the red of a target order — the ping is the
## only way to tell at a glance which of the two you actually issued.
const ATTACK_MOVE_COLOR: Color = Color(1.0, 0.72, 0.25)
## How quickly a control-group key has to be pressed twice to also recentre the camera.
const DOUBLE_TAP_MSEC: int = 400

var _world: RtsWorld
var _selected: Array[Node3D] = []
var _control_groups: Dictionary = {}
var _drag_origin: Vector2 = Vector2.ZERO
var _drag_active: bool = false
var _drag_was_double_click: bool = false
var _last_group_index: int = -1
var _last_group_msec: int = 0

@onready var rts_camera: RtsCamera = %RtsCamera
@onready var overlay: SelectionOverlay = %SelectionOverlay
@onready var effects: Node3D = %Effects


func _ready() -> void:
	_world = RtsWorld.find_in(self)
	if _world != null:
		_world.unit_died.connect(_on_unit_died)


## Polling the release instead of listening for it matters: a mouse-up over a HUD panel is
## consumed by the panel and never reaches _unhandled_input, which would leave a drag running
## forever with the selection box stuck on screen.
func _process(_delta: float) -> void:
	if _drag_active and not Input.is_mouse_button_pressed(MOUSE_BUTTON_LEFT):
		_finish_drag()


func _unhandled_input(event: InputEvent) -> void:
	if _world == null or not _world.is_running:
		return
	if event is InputEventMouseButton:
		_on_mouse_button(event)
	elif event is InputEventKey and event.pressed and not event.echo:
		_on_key(event)


func selected_units() -> Array:
	return _selected


func clear_selection() -> void:
	_set_selection([])


func focus_on_selection() -> void:
	if _selected.is_empty():
		return
	rts_camera.focus_on_average(_selected)


## Called both by the Z/X/C hotkeys and by the HUD's production buttons, so the two can never
## disagree about what a button does. The roster lives on RtsWorld so the HUD, the hotkeys and
## the enemy AI cannot drift apart about what is buildable.
func request_production(index: int) -> void:
	if _world == null or index < 0 or index >= _world.unit_roster.size():
		return
	var hq: Node3D = _world.hq_of(RtsTeam.Id.PLAYER)
	if hq != null:
		hq.request_unit(_world.unit_roster[index])


func _on_mouse_button(event: InputEventMouseButton) -> void:
	if not event.pressed:
		return
	if event.button_index == MOUSE_BUTTON_LEFT:
		_begin_drag(event.double_click)
	elif event.button_index == MOUSE_BUTTON_RIGHT:
		_issue_order()


func _on_key(event: InputEventKey) -> void:
	match event.keycode:
		KEY_Z:
			request_production(0)
		KEY_X:
			request_production(1)
		KEY_C:
			request_production(2)
		KEY_F:
			focus_on_selection()
		KEY_SPACE:
			_focus_home()
		KEY_H:
			hint_toggle_requested.emit()
		KEY_1, KEY_2, KEY_3, KEY_4:
			_use_control_group(event.keycode - KEY_1, event.ctrl_pressed or event.shift_pressed)


func _begin_drag(double_click: bool) -> void:
	_drag_origin = RtsScreen.pick_position(get_viewport())
	_drag_active = true
	_drag_was_double_click = double_click
	overlay.begin_drag()


func _finish_drag() -> void:
	_drag_active = false
	overlay.end_drag()
	var end_point: Vector2 = RtsScreen.pick_position(get_viewport())
	var additive: bool = Input.is_key_pressed(KEY_SHIFT)
	var subtractive: bool = Input.is_key_pressed(KEY_CTRL)
	if _drag_origin.distance_to(end_point) < RtsConfig.DRAG_THRESHOLD_PIXELS:
		_click_select(end_point, additive, subtractive)
		return
	var rect: Rect2 = RtsScreen.drag_rect(_drag_origin, end_point)
	_apply_selection(_units_in_rect(rect), additive, subtractive)


func _click_select(point: Vector2, additive: bool, subtractive: bool) -> void:
	var hit: Node3D = _raycast_node(point, RtsLayers.MASK_SELECTABLE)
	if hit == null:
		if not additive and not subtractive:
			_set_selection([])
		return
	if _drag_was_double_click and hit.has_method("move_to"):
		_apply_selection(_on_screen_units_of_kind(hit.stats.kind), additive, false)
		return
	_apply_selection([hit], additive, subtractive)


## Screen-space containment rather than a physics frustum query. Building six frustum planes
## by hand is more code and gets the edge cases wrong — a unit whose origin is inside the box
## but whose capsule is clipped by it simply would not be found.
func _units_in_rect(rect: Rect2) -> Array:
	var found: Array = []
	for unit: Node3D in _world.units_of(RtsTeam.Id.PLAYER):
		var point: Variant = _unit_screen_point(unit)
		if point != null and rect.has_point(point):
			found.append(unit)
	return found


func _on_screen_units_of_kind(kind: int) -> Array:
	var rect: Rect2 = Rect2(Vector2.ZERO, get_viewport().get_visible_rect().size)
	var found: Array = []
	for unit: Node3D in _world.units_of(RtsTeam.Id.PLAYER):
		if unit.stats.kind != kind:
			continue
		var point: Variant = _unit_screen_point(unit)
		if point != null and rect.has_point(point):
			found.append(unit)
	return found


## Projects chest height, not the origin at the feet, so a shallow drag across visible bodies
## selects them instead of sliding under everything.
func _unit_screen_point(unit: Node3D) -> Variant:
	if not is_instance_valid(unit) or not unit.is_alive():
		return null
	var chest: Vector3 = unit.global_position + Vector3.UP * unit.stats.chest_height()
	return RtsScreen.project(rts_camera.camera, chest)


func _apply_selection(nodes: Array, additive: bool, subtractive: bool) -> void:
	var next: Array[Node3D] = []
	if additive or subtractive:
		next.assign(_selected)
	if subtractive:
		for node: Node3D in nodes:
			next.erase(node)
	else:
		for node: Node3D in nodes:
			if not next.has(node):
				next.append(node)
	_set_selection(next)


func _set_selection(next: Array) -> void:
	for node: Node3D in _selected:
		if is_instance_valid(node):
			node.set_selected(false)
	_selected.clear()
	for node: Node3D in next:
		if is_instance_valid(node):
			node.set_selected(true)
			_selected.append(node)
	selection_changed.emit(_selected)


## A right-click means three different things depending on what is under it and what is
## selected: attack, move, or set the HQ rally point.
func _issue_order() -> void:
	if _selected.is_empty():
		return
	var point: Vector2 = RtsScreen.pick_position(get_viewport())
	var units: Array = []
	var buildings: Array = []
	for node: Node3D in _selected:
		if node.has_method("set_rally_point"):
			buildings.append(node)
		else:
			units.append(node)

	# Ctrl turns the move into an attack-move: go there, but stop and fight what you meet.
	# Plain right-click is always obeyed, so retreating actually retreats.
	var attack_move: bool = Input.is_key_pressed(KEY_CTRL)
	var enemy: Node3D = _raycast_node(point, RtsLayers.MASK_HOSTILE_TO_PLAYER)
	var ground: Variant = _raycast_ground(point)
	if enemy != null:
		for unit: Node3D in units:
			unit.order_attack(enemy)
		OrderMarker.ping(effects, enemy.global_position, ATTACK_COLOR, 1.5)
	elif ground != null and not units.is_empty():
		RtsFormation.order_into_formation(units, ground, attack_move)
		OrderMarker.ping(effects, ground, ATTACK_MOVE_COLOR if attack_move else MOVE_COLOR)
	if ground != null:
		for building: Node3D in buildings:
			building.set_rally_point(ground)


func _use_control_group(index: int, assign: bool) -> void:
	if assign:
		_control_groups[index] = _selected.duplicate()
		return
	var alive: Array = []
	for node: Node3D in _control_groups.get(index, []):
		if is_instance_valid(node) and node.is_alive():
			alive.append(node)
	_control_groups[index] = alive
	if alive.is_empty():
		return
	_set_selection(alive)
	var now: int = Time.get_ticks_msec()
	if _last_group_index == index and now - _last_group_msec < DOUBLE_TAP_MSEC:
		focus_on_selection()
	_last_group_index = index
	_last_group_msec = now


func _focus_home() -> void:
	var hq: Node3D = _world.hq_of(RtsTeam.Id.PLAYER)
	if hq != null:
		rts_camera.focus_on(hq.global_position)


func _raycast_node(point: Vector2, mask: int) -> Node3D:
	return _raycast(point, mask).get("collider")


func _raycast_ground(point: Vector2) -> Variant:
	var hit: Dictionary = _raycast(point, RtsLayers.MASK_GROUND)
	return hit["position"] if hit.has("position") else null


func _raycast(point: Vector2, mask: int) -> Dictionary:
	var camera: Camera3D = rts_camera.camera
	var from: Vector3 = camera.project_ray_origin(point)
	var to: Vector3 = from + camera.project_ray_normal(point) * RtsConfig.PICK_RAY_LENGTH
	var query: PhysicsRayQueryParameters3D = PhysicsRayQueryParameters3D.create(from, to, mask)
	return rts_camera.get_world_3d().direct_space_state.intersect_ray(query)


func _on_unit_died(unit: Node3D) -> void:
	if _selected.has(unit):
		_selected.erase(unit)
		selection_changed.emit(_selected)
