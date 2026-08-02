extends Node

## Registers the input actions MarkerPilot reads, from inside marker_pilot.tscn, so
## the example runs in any host project without an edit to its project.godot.
##
## Port of examples/3d/cargo_tether/actors/ship/ship_input_actions.gd. Same
## contract: skip anything the host already defines, erase only what we created,
## refcount so two pilots in one scene do not erase each other's bindings.
##
## Every action name is prefixed `crawler_`. This repo already contains a wolf that
## owns bare `move_forward` and a jeep that owns `jeep_*`; a host project whose own
## `jump` silently became a marker thruster is an hour of debugging for whoever
## dropped this folder in.
##
## `ui_cancel` (release the mouse) is deliberately NOT registered: it is a Godot
## built-in present in every project, so registering it would mean erasing a host
## binding on the way out.

## action -> physical keycodes. PHYSICAL rather than keycode so AZERTY and Dvorak
## users get WASD by position instead of by letter.
##
## V, not C, for the camera toggle. C is "look back" in cargo_tether and that muscle
## memory is worth more than the mnemonic.
##
## Every action here is READ BY SOMETHING. An earlier version also registered
## `crawler_debug` and `crawler_restart`, which nothing looked at -- and an action
## that exists but does nothing is worse than a missing one, because it survives a
## grep for its own name and reads as a feature that is merely broken.
const ACTIONS: Dictionary = {
	&"crawler_forward": [KEY_W, KEY_UP],
	&"crawler_back": [KEY_S, KEY_DOWN],
	&"crawler_left": [KEY_A, KEY_LEFT],
	&"crawler_right": [KEY_D, KEY_RIGHT],
	&"crawler_rise": [KEY_SPACE],
	&"crawler_sink": [KEY_CTRL],
	&"crawler_boost": [KEY_SHIFT],
	&"crawler_roll_left": [KEY_Q],
	&"crawler_roll_right": [KEY_E],
	&"crawler_camera": [KEY_V],
}
## The InputMap deadzone default has moved between 4.x releases, so it is pinned.
const DEADZONE: float = 0.2

## action -> how many live instances registered it. Shared across every pilot in the
## scene: with two of them, the first to leave the tree must not erase the bindings
## the second is still reading.
static var _registrations: Dictionary = {}


func _enter_tree() -> void:
	for action: StringName in ACTIONS:
		if not _claim(action):
			continue
		for keycode: int in ACTIONS[action]:
			var event := InputEventKey.new()
			event.physical_keycode = keycode
			InputMap.action_add_event(action, event)


func _exit_tree() -> void:
	for action: StringName in ACTIONS:
		if not _registrations.has(action):
			continue
		_registrations[action] -= 1
		if _registrations[action] <= 0:
			_registrations.erase(action)
			InputMap.erase_action(action)


## Takes ownership of `action`, creating it if this is the first instance to ask.
## Returns true when the caller should go on to add its events -- false means either
## the host project owns this action or another instance already built it.
func _claim(action: StringName) -> bool:
	if _registrations.has(action):
		_registrations[action] += 1
		return false
	if InputMap.has_action(action):
		return false  # The host project owns this one. Do not touch it.
	InputMap.add_action(action, DEADZONE)
	_registrations[action] = 1
	return true
