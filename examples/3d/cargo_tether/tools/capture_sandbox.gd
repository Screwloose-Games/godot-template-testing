extends Node

## Flies the sandbox on rails and saves PNGs, so the things no headless test can
## see get looked at.
##
## The tether ribbon is hand-built ImmediateMesh geometry. Every measurement in
## measure_tether_response.tscn can pass while that mesh renders as nothing at
## all -- wrong winding, a degenerate side vector, a material that culls, a strip
## built inside a node with a transform on it. None of those are visible to a
## physics assertion, and all of them ship a game with an invisible tether.
##
## MUST RUN WITH A REAL RENDERER. --headless uses the dummy driver and every
## capture comes back blank, which looks exactly like a rendering bug:
##   godot --path <project root> res://examples/3d/cargo_tether/tools/capture_sandbox.tscn

## Where the shots go. Gitignored -- these are for looking at, not for keeping.
const OUT_DIR: String = "res://examples/3d/cargo_tether/tools/_shots"
## Force used to fly the canned manoeuvre, matching ShipController's exports.
const THRUST_MAIN: float = 28000.0
const THRUST_LATERAL: float = 12000.0

var _ship: RigidBody3D
var _cargo: CargoBody
var _tether: TetherLink
var _run: TetherRun
var _force: Vector3 = Vector3.ZERO
var _shot: int = 0


func _ready() -> void:
	# Defaults to the sandbox; pass another scene after `--` to photograph it
	# instead. Both scenes use the same node names, so the canned flight works on
	# either:
	#   godot --path <root> res://.../capture_sandbox.tscn -- res://.../cargo_run.tscn
	var target: String = _res("../scenes/tether_sandbox.tscn")
	var user_args: PackedStringArray = OS.get_cmdline_user_args()
	if user_args.size() > 0:
		target = user_args[0]
	print("capturing %s" % target)
	var packed: PackedScene = load(target) as PackedScene
	if packed == null:
		printerr("could not load the sandbox scene")
		get_tree().quit(1)
		return
	var world: Node = packed.instantiate()
	add_child(world)

	_ship = world.get_node("Ship") as RigidBody3D
	_cargo = world.get_node("Cargo") as CargoBody
	_tether = world.get_node("Tether") as TetherLink
	_run = world.get_node("Run") as TetherRun
	# Never grab the mouse from a capture run.
	(_ship as ShipController).capture_mouse = false

	# TetherLink._physics_process bails silently when any of its four references
	# is null, and the only symptom is a separation of exactly 0.00 forever. Say
	# so out loud rather than photographing a tether that was never running.
	print(
		(
			"wiring: ship %s  cargo %s  ship_anchor %s  cargo_anchor %s  ship.tether %s"
			% [
				_tether.ship != null,
				_tether.cargo != null,
				_tether.ship_anchor != null,
				_tether.cargo_anchor != null,
				(_ship as ShipController).tether != null,
			]
		)
	)
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(OUT_DIR))

	await _fly()
	get_tree().quit(0)


func _physics_process(_delta: float) -> void:
	if _ship != null and not _force.is_zero_approx():
		_ship.apply_central_force(_ship.global_basis * _force)


func _fly() -> void:
	# Rest. The line should hang with a visible bow: it is slack, and the bow is
	# how much rope is spare.
	await _wait(0.6)
	await _shoot("01_at_rest")

	# Under way. Steady stretch is 1.55 m, so the bow should be nearly gone.
	_force = Vector3(0.0, 0.0, -THRUST_MAIN)
	await _wait(2.5)
	await _shoot("02_under_thrust")

	# Corner. The crate swings wide and the line should be dead straight and
	# tinted toward the warning colour. Kept to 1.0 s: a longer strafe at this
	# force snaps the line, and a snapped tether photographs as no tether.
	_force = Vector3(THRUST_LATERAL, 0.0, -THRUST_MAIN * 0.3)
	await _wait(1.0)
	await _shoot("03_cornering")

	# Reeled in short. The crate should be tucked up close behind the hull.
	_force = Vector3(0.0, 0.0, -THRUST_MAIN)
	_tether.target_length = TetherWinch.MIN_LENGTH
	await _wait(3.0)
	await _shoot("04_reeled_in")

	# Paid out long, still under power.
	_tether.target_length = TetherWinch.MAX_LENGTH
	await _wait(3.0)
	await _shoot("05_paid_out")

	await _fly_the_run()


## Reset and fly the whole delivery, so the run loop is exercised end to end
## rather than assumed: clock, dock trigger, score, grade and banner.
func _fly_the_run() -> void:
	# A full soft reset, not just a respawn: the canned manoeuvres above smash the
	# crate into rocks, so by this point the run has usually already failed and
	# the delivery leg would exit on the first frame.
	_run.restart()
	await _wait(0.2)

	_force = Vector3(0.0, 0.0, -THRUST_MAIN)
	var deadline: int = int(30.0 * Engine.physics_ticks_per_second)
	var peak_shots: int = 0
	var total_shots: int = 0
	var previous_live: int = 0
	for _i: int in deadline:
		await get_tree().physics_frame
		# Positive control for the turrets. Without it, "cargo arrived at 100%"
		# reads as "the player dodged well" when it may mean the emplacements
		# never fired a round.
		var live: int = _run.projectiles.live_count()
		peak_shots = maxi(peak_shots, live)
		if live > previous_live:
			total_shots += live - previous_live
		previous_live = live
		if _run.state() != TetherRun.State.RUNNING:
			break
	_force = Vector3.ZERO
	print("turrets: %d rounds fired, %d in flight at peak" % [total_shots, peak_shots])

	var state: Dictionary = _run.debug_state()
	var result: Dictionary = state["result"]
	print(
		(
			"run: state %d  elapsed %.2f s  cargo %.0f%%  hull %.0f%%  grade %s  score %.0f  %s"
			% [
				state["state"],
				state["elapsed"],
				(state["cargo_integrity"] as float) * 100.0,
				(state["ship_integrity"] as float) * 100.0,
				result.get("grade", "-"),
				result.get("score", 0.0),
				result.get("reason", &""),
			]
		)
	)
	await _wait(0.3)
	await _shoot("06_delivered")
	await _prove_shots_bite()


## Positive control for the damage path.
##
## "Cargo arrived at 100%" is the same output whether the player dodged well or
## the projectiles cannot hurt anything at all -- a raycast that resolves to the
## wrong node, a %Damage lookup that returns null, a mask with the cargo bit
## missing. So fire two rounds point-blank into the crate and check the bar moves
## by exactly twice the per-shot cost, which also confirms projectiles bypass
## i-frames the way contact damage does not.
func _prove_shots_bite() -> void:
	var damage: TetherDamage = _cargo.get_node_or_null("%Damage") as TetherDamage
	if damage == null:
		printerr("cargo has no %Damage node")
		return
	# Against a STATIONARY crate. The first version of this control fired both
	# rounds down a line computed once, while the cargo was still coasting at
	# 116 m/s -- so the second shot was aimed 29 m behind it and the control
	# reported half the expected damage as if the game were broken.
	_run.restart()
	await _wait(0.4)

	var before: float = damage.integrity()
	for _i: int in 2:
		var muzzle: Vector3 = _cargo.global_position + Vector3(0.0, 0.0, 40.0)
		_run.projectiles.fire(
			muzzle, (_cargo.global_position - muzzle).normalized(), 220.0, damage.projectile_damage
		)
		await _wait(0.25)
	# One more round, photographed in flight. The pool can route hits correctly
	# while its MultiMesh draws nothing at all -- an unresized buffer, a culled
	# material, a zero visible_instance_count -- and the console cannot tell the
	# difference.
	# Fired ACROSS the view ahead of the ship, not at the crate. The crate trails
	# astern -- behind the camera -- so a round aimed at it is photographed from
	# behind and proves nothing about whether tracers draw.
	var muzzle: Vector3 = _ship.global_position + Vector3(-70.0, -4.0, -70.0)
	for i: int in 4:
		_run.projectiles.fire(muzzle + Vector3(0.0, 0.0, float(i) * 9.0), Vector3.RIGHT, 90.0, 0.0)
	await _wait(0.35)
	await _shoot("07_tracers_in_flight")

	var lost: float = before - damage.integrity()
	print(
		(
			"projectile damage: %.1f lost, expected %.1f  %s"
			% [
				lost,
				damage.projectile_damage * 2.0,
				"OK" if is_equal_approx(lost, damage.projectile_damage * 2.0) else "MISMATCH"
			]
		)
	)


func _shoot(label: String) -> void:
	# The texture is only valid once the frame has actually been drawn.
	await RenderingServer.frame_post_draw
	var image: Image = get_viewport().get_texture().get_image()
	_shot += 1
	var path: String = "%s/%02d_%s.png" % [OUT_DIR, _shot, label]
	var err: Error = image.save_png(path)
	if err != OK:
		printerr("save_png(%s) failed: %d" % [path, err])
		return
	var state: Dictionary = _tether.debug_state()
	print(
		(
			"%-22s  %s  rest %5.2f m  sep %6.2f m  tension %6.2f kN  strain %.2f"
			% [
				path.get_file(),
				"attached" if state["attached"] else "SNAPPED ",
				state["rest_length"],
				state["separation"],
				(state["tension"] as float) / 1000.0,
				state["strain"],
			]
		)
	)


func _wait(seconds: float) -> void:
	for _i: int in int(seconds * Engine.physics_ticks_per_second):
		await get_tree().physics_frame


## load() and ResourceSaver need real res:// paths, so relative paths in a tool
## script are resolved against the script's own location.
func _res(relative_path: String) -> String:
	var dir: String = (get_script() as Script).resource_path.get_base_dir()
	return dir.path_join(relative_path).simplify_path()
