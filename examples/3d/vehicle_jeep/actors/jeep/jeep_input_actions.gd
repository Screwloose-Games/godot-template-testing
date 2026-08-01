extends Node

## Registers the input actions JeepController reads, from inside jeep.tscn, so the
## example runs in any host project without an edit to its project.godot.
##
## Structurally this is examples/3d/exploration_quadraped/actors/wolf/
## wolf_input_actions.gd, with one deliberate difference: every action name is
## prefixed `jeep_`.
##
## The wolf registers bare names (`move_forward`, `jump`) and relies on "skip
## anything the host already defines" to stay non-destructive. That is safe for one
## example and stops being safe with two: this repo now contains a wolf that owns
## `move_forward`, so an unprefixed vehicle would silently inherit the wolf's
## bindings and never register its own. Worse in the other direction -- a host whose
## `jump` is bound to something meaningful would find it acting as a handbrake, and
## nothing anywhere reports it. Prefixing makes the collision impossible and makes
## the erase on the way out unambiguous.
##
## `ui_cancel` (release the mouse) is deliberately NOT registered: it is a Godot
## built-in present in every project, so registering it would mean erasing a host
## binding on exit.

## action -> physical keycodes. Physical rather than keycode so AZERTY and Dvorak
## users get WASD by position instead of by letter.
const ACTIONS: Dictionary = {
	&"jeep_throttle": [KEY_W, KEY_UP],
	&"jeep_reverse": [KEY_S, KEY_DOWN],
	&"jeep_steer_left": [KEY_A, KEY_LEFT],
	&"jeep_steer_right": [KEY_D, KEY_RIGHT],
	&"jeep_handbrake": [KEY_SPACE],
	&"jeep_headlights": [KEY_L],
	&"jeep_reset": [KEY_R],
	&"jeep_respawn": [KEY_T],
	&"jeep_hud": [KEY_H],
}
## The InputMap default has moved between 4.x releases, so it is pinned here.
const DEADZONE: float = 0.2

## action -> how many live instances registered it. Shared across every jeep in the
## scene: with two of them, the first to leave the tree must not erase the bindings
## the second is still reading.
static var _registrations: Dictionary = {}


func _enter_tree() -> void:
	for action: StringName in ACTIONS:
		if _registrations.has(action):
			_registrations[action] += 1
			continue
		if InputMap.has_action(action):
			continue  # The host project owns this one. Do not touch it.
		InputMap.add_action(action, DEADZONE)
		for keycode: int in ACTIONS[action]:
			var event := InputEventKey.new()
			event.physical_keycode = keycode
			InputMap.action_add_event(action, event)
		_registrations[action] = 1


func _exit_tree() -> void:
	for action: StringName in ACTIONS:
		if not _registrations.has(action):
			continue
		_registrations[action] -= 1
		if _registrations[action] <= 0:
			_registrations.erase(action)
			InputMap.erase_action(action)
