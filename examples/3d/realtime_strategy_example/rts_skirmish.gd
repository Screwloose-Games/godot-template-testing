extends Node3D

## Root of the realtime-strategy prototype: a capture-point skirmish.
##
## Run this scene directly with F6 (Run Current Scene). It is deliberately not registered in
## globals/scene_manager.gd and is not the project's main scene, because this example has to
## stay entirely inside its own folder.
##
## The match rules live in RtsWorld; this node owns the wiring, the opening camera, and the
## restart path.

@onready var world: RtsWorld = %RtsWorld
@onready var rts_camera: RtsCamera = %RtsCamera
@onready var commander: PlayerCommander = %PlayerCommander
@onready var hud: RtsHud = %RtsHud


func _ready() -> void:
	GlobalSignalBus.level_started.emit()
	hud.bind(world, commander, rts_camera)
	world.match_ended.connect(_on_match_ended)
	world.hq_damaged.connect(_on_hq_damaged)
	await _wait_for_navigation_map()
	var hq: Node3D = world.hq_of(RtsTeam.Id.PLAYER)
	if hq != null:
		# Offset toward the middle so the opening view shows the base *and* the ground you
		# are about to fight over, rather than a wall of your own buildings.
		rts_camera.focus_on(hq.global_position + Vector3(0.0, 0.0, -9.0))


func _unhandled_input(event: InputEvent) -> void:
	if world.is_running or not (event is InputEventKey):
		return
	var key_event: InputEventKey = event
	if key_event.pressed and not key_event.echo and key_event.keycode == KEY_R:
		restart()


func restart() -> void:
	# Unpausing first is not optional: reload_current_scene() keeps the tree's paused state,
	# so restarting from a paused match would load a fresh scene that is already frozen with
	# no pause menu open to unfreeze it.
	get_tree().paused = false
	get_tree().reload_current_scene()


## NavigationServer3D does not finish building its map until after the first physics frames
## have run. Anything that requests a path before then silently gets an empty one and stands
## still forever, so nothing that needs to move may start until this returns.
func _wait_for_navigation_map() -> void:
	await get_tree().physics_frame
	await get_tree().physics_frame


func _on_match_ended(winning_team: int, reason: String) -> void:
	commander.clear_selection()
	hud.show_result(winning_team, reason, world.elapsed_seconds)


func _on_hq_damaged(team: int, _health_fraction: float) -> void:
	if team == RtsTeam.Id.PLAYER:
		rts_camera.shake(0.16)
