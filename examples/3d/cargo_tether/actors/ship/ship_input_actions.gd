extends Node

## Registers the input actions ShipController reads, from inside ship.tscn, so the
## example runs in any host project without an edit to its project.godot.
##
## Port of examples/3d/vehicle_jeep/actors/jeep/jeep_input_actions.gd, extended
## with mouse-button actions for the winch. Same contract: skip anything the host
## already defines, erase only what we created, refcount so two ships in one scene
## do not erase each other's bindings.
##
## Every action name is prefixed `ship_`. This repo already contains a wolf that
## owns bare `move_forward` and a jeep that owns `jeep_*`; a host whose `jump`
## silently became the vertical thruster is an hour of debugging.
##
## `ui_cancel` (release the mouse) is deliberately NOT registered: it is a Godot
## built-in present in every project, so registering it would mean erasing a host
## binding on exit.

## action -> physical keycodes. Physical rather than keycode so AZERTY and Dvorak
## users get WASD by position instead of by letter.
##
## R and F for the winch rather than the mouse wheel: R sits directly above F, so
## "up shortens, down lengthens" is available to the index finger without moving
## the hand off WASD. The wheel is bound too, but as a stepped set-point -- see
## MOUSE_ACTIONS.
const ACTIONS: Dictionary = {
	&"ship_thrust": [KEY_W, KEY_UP],
	&"ship_reverse": [KEY_S, KEY_DOWN],
	&"ship_strafe_left": [KEY_A, KEY_LEFT],
	&"ship_strafe_right": [KEY_D, KEY_RIGHT],
	&"ship_rise": [KEY_SPACE],
	&"ship_sink": [KEY_CTRL],
	&"ship_roll_left": [KEY_Q],
	&"ship_roll_right": [KEY_E],
	&"ship_boost": [KEY_SHIFT],
	&"ship_reel_in": [KEY_R],
	&"ship_reel_out": [KEY_F],
	&"ship_tether_toggle": [KEY_G],
	&"ship_dampener": [KEY_Z],
	&"ship_brake": [KEY_X],
	&"ship_look_back": [KEY_C],
	&"ship_hud": [KEY_H],
	&"ship_restart": [KEY_BACKSPACE],
}
## action -> mouse buttons.
##
## A wheel CANNOT express a held input: every wheel event is a press immediately
## followed by a release, so `Input.is_action_pressed(&"ship_reel_step_in")` never
## reads true for a "held" wheel. That is why these are separate actions from the
## R/F pair and why ShipController treats them as a stepped set-point rather than
## as a reel command. The winch's rate limiter then chases that set-point, which
## is also what keeps a wheel click from becoming a step input into the spring.
const MOUSE_ACTIONS: Dictionary = {
	&"ship_reel_step_in": [MOUSE_BUTTON_WHEEL_UP],
	&"ship_reel_step_out": [MOUSE_BUTTON_WHEEL_DOWN],
}
## The InputMap default has moved between 4.x releases, so it is pinned here.
const DEADZONE: float = 0.2

## action -> how many live instances registered it. Shared across every ship in
## the scene: with two of them, the first to leave the tree must not erase the
## bindings the second is still reading.
static var _registrations: Dictionary = {}


func _enter_tree() -> void:
	for action: StringName in ACTIONS:
		if not _claim(action):
			continue
		for keycode: int in ACTIONS[action]:
			var event := InputEventKey.new()
			event.physical_keycode = keycode
			InputMap.action_add_event(action, event)

	for action: StringName in MOUSE_ACTIONS:
		if not _claim(action):
			continue
		for button: int in MOUSE_ACTIONS[action]:
			var event := InputEventMouseButton.new()
			event.button_index = button as MouseButton
			InputMap.action_add_event(action, event)


func _exit_tree() -> void:
	_release(ACTIONS)
	_release(MOUSE_ACTIONS)


## Takes ownership of `action`, creating it if this is the first instance to ask.
## Returns true when the caller should go on to add its events -- false means
## either the host project owns this action or another instance already built it.
func _claim(action: StringName) -> bool:
	if _registrations.has(action):
		_registrations[action] += 1
		return false
	if InputMap.has_action(action):
		return false  # The host project owns this one. Do not touch it.
	InputMap.add_action(action, DEADZONE)
	_registrations[action] = 1
	return true


func _release(table: Dictionary) -> void:
	for action: StringName in table:
		if not _registrations.has(action):
			continue
		_registrations[action] -= 1
		if _registrations[action] <= 0:
			_registrations.erase(action)
			InputMap.erase_action(action)
