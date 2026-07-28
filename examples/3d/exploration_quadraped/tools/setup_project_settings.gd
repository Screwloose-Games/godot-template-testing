extends SceneTree

## OPTIONAL. Bakes this example's settings into the HOST project.godot.
##
## Nothing needs it any more, and running it edits config that every other scene
## in the host project also lives under:
##   * The input map is registered at runtime from inside wolf.tscn instead --
##     see actors/wolf/wolf_input_actions.gd, which is the source of ACTIONS
##     below. Run this only to make the bindings permanent and editable in
##     Project Settings.
##   * main_scene repoints the whole project's startup scene at the wolf world.
##   * default_gravity is cosmetic here: WolfController applies its own `gravity`
##     export rather than reading the project setting.
##   * The Jolt edge-removal mitigation has been on by default since 4.5.
##
## Usage:
##   Godot_v4.7.1-stable_win64_console.exe --headless \
##     --path <godot project root> --script res://examples/3d/exploration_quadraped/tools/setup_project_settings.gd

## One source of truth with the runtime registration, so the two cannot drift.
const WolfInputActions := preload("../actors/wolf/wolf_input_actions.gd")

## Relative to this script -- see _res(). Kept out of SETTINGS because a const
## dictionary cannot call _res() to resolve it.
const MAIN_SCENE: String = "../scenes/demo_world.tscn"

const SETTINGS: Dictionary = {
	# Matches WolfController.gravity so the jump clip's 0.75 s arc lines up.
	"physics/3d/default_gravity": 20.0,
	"layer_names/3d_physics/layer_1": "world",
	"layer_names/3d_physics/layer_2": "player",
	# Jolt can catch a capsule on the shared edge between adjacent static bodies
	# and hand back a bad slide normal (godot-jolt#952). This mitigates it.
	"physics/jolt_physics_3d/motion_queries/use_enhanced_internal_edge_removal": true,
}


func _initialize() -> void:
	for action: StringName in WolfInputActions.ACTIONS:
		var events: Array[InputEvent] = []
		for keycode: int in WolfInputActions.ACTIONS[action]:
			var event := InputEventKey.new()
			event.physical_keycode = keycode
			events.append(event)
		ProjectSettings.set_setting("input/%s" % action, {
			"deadzone": WolfInputActions.DEADZONE,
			"events": events,
		})
		print("input/%s  <- %d binding(s)" % [action, events.size()])

	ProjectSettings.set_setting("application/run/main_scene", _res(MAIN_SCENE))
	print("application/run/main_scene = %s" % _res(MAIN_SCENE))

	for key: String in SETTINGS:
		ProjectSettings.set_setting(key, SETTINGS[key])
		print("%s = %s" % [key, str(SETTINGS[key])])

	var err: Error = ProjectSettings.save()
	if err != OK:
		printerr("ProjectSettings.save() failed: %d" % err)
		quit(1)
		return
	print("\nSaved project.godot")
	quit(0)


## Turns a path relative to this script into an absolute res:// path. load(),
## FileAccess and ResourceSaver do not resolve relative paths the way preload()
## does, so every path that reaches them goes through here.
func _res(relative_path: String) -> String:
	var dir: String = (get_script() as Script).resource_path.get_base_dir()
	return dir.path_join(relative_path).simplify_path()
