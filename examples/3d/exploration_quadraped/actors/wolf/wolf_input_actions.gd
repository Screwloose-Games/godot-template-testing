extends Node

## Registers the input actions WolfController reads, from inside wolf.tscn, so the
## example runs in any host project without an edit to its project.godot.
##
## Why here and not in project settings: this folder is a self-contained example
## dropped into a bigger project. A tool that writes the bindings into
## project.godot mutates shared config that every other scene in the host project
## also lives under -- see tools/setup_project_settings.gd, which is now optional.
##
## Two rules keep it non-destructive:
##   * An action the host project already defines is left completely alone. A game
##     with its own "jump" binding keeps it, bindings and deadzone included.
##   * Only actions this script created are erased again on the way out, so
##     nothing leaks into the host's InputMap after the example is unloaded.

## action -> physical keycodes. Physical rather than keycode so AZERTY and Dvorak
## users get WASD by position instead of by letter.
const ACTIONS: Dictionary = {
	&"move_forward": [KEY_W, KEY_UP],
	&"move_back": [KEY_S, KEY_DOWN],
	&"move_left": [KEY_A, KEY_LEFT],
	&"move_right": [KEY_D, KEY_RIGHT],
	&"jump": [KEY_SPACE],
	&"sprint": [KEY_SHIFT],
	&"walk": [KEY_ALT],
}
## The InputMap default has moved between 4.x releases, so it is pinned here.
const DEADZONE: float = 0.2

## action -> how many live instances registered it. Shared across every wolf in
## the scene: with two of them, the first to leave the tree must not erase the
## bindings the second is still reading.
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
