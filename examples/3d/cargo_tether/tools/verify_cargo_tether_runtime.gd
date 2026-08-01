extends Node

## Behavioural checks. Every block here MEASURES something the game does.
##
##   godot --headless --path <godot project root> \
##     res://examples/3d/cargo_tether/tools/verify_cargo_tether_runtime.tscn
##
## Note the .tscn, not the .gd. A node added during SceneTree._initialize() never
## receives _ready(), so running the script directly reports nothing and exits 0 --
## which is indistinguishable from a pass.
##
## TWO RULES, both learned the hard way in this folder:
##
##   * Assert behaviour, never a property read-back. "rest_length is now 6" passes
##     just as happily against a winch that writes the variable and moves nothing;
##     "the ship and the crate are 8 m closer than they were" does not.
##   * A negative assertion gets a positive control FIRST. "Nothing fell" passes
##     beautifully against a ship that is simply broken, so [zero-g] proves the
##     body can fall before proving it does not.
##
## It drives the real ShipController through Input.action_press() rather than
## poking its internals, so what is under test is the thing the player uses.

const SANDBOX_SCENE: String = "../scenes/tether_sandbox.tscn"
const COURSE_SCENE: String = "../scenes/cargo_run.tscn"
const TURRET_SCENE: String = "../threats/turret.tscn"

var _failures: int = 0
var _world: Node = null
var _ship: ShipController = null
var _cargo: CargoBody = null
var _tether: TetherLink = null
var _run: TetherRun = null
var _turrets: Node = null

## Signal flags are MEMBER variables with named handlers. A lambda captures the
## outer local by value, so `sig.connect(func(): fired = true)` leaves the caller's
## `fired` false forever and the check silently never fires.
var _snapped: bool = false
var _attached_again: bool = false
var _completed: Dictionary = {}
var _failed_reason: StringName = &""
## Peak sideways speed the hull reached during the most recent yank.
var _peak_sideways: float = 0.0


func _ready() -> void:
	if not await _load_world():
		get_tree().quit(1)
		return

	await _check_zero_gravity()
	await _check_thrust_and_tow_cost()
	await _check_slack_is_exactly_zero()
	await _check_third_law()
	await _check_winch_under_load()
	await _check_snap_and_reattach()
	await _check_dampener()
	await _check_impact_damage()
	await _check_projectile_damage()
	await _check_turret_lead()
	await _check_completion()
	await _check_failure()

	if _failures > 0:
		print("FAILED: %d check(s)" % _failures)
	else:
		print("all runtime checks passed")
	get_tree().quit(1 if _failures > 0 else 0)


func _fail(tag: String, message: String) -> void:
	_failures += 1
	printerr("[%s] %s" % [tag, message])


func _pass(tag: String, message: String) -> void:
	print("[%s] %s" % [tag, message])


func _load_world() -> bool:
	var packed: PackedScene = load(_res(SANDBOX_SCENE)) as PackedScene
	if packed == null:
		printerr("could not load %s" % SANDBOX_SCENE)
		return false
	_world = packed.instantiate()
	add_child(_world)
	_ship = _world.get_node("Ship") as ShipController
	_cargo = _world.get_node("Cargo") as CargoBody
	_tether = _world.get_node("Tether") as TetherLink
	_run = _world.get_node("Run") as TetherRun
	_turrets = _world.get_node("Turrets")
	if _ship == null or _cargo == null or _tether == null or _run == null:
		printerr("sandbox is missing one of Ship / Cargo / Tether / Run")
		return false
	_ship.capture_mouse = false
	# The emplacements fire during every block and would put unexplained holes in
	# the damage measurements. [turret-lead] builds its own.
	if _turrets != null:
		_turrets.process_mode = Node.PROCESS_MODE_DISABLED
	_tether.tether_snapped.connect(_on_tether_snapped)
	_tether.tether_attached.connect(_on_tether_attached)
	_run.run_completed.connect(_on_run_completed)
	_run.run_failed.connect(_on_run_failed)
	await _step(2)
	return true


## Positive control first: prove the body CAN fall, then prove it does not.
## Without the control this passes against a ship whose physics never ran at all.
func _check_zero_gravity() -> void:
	await _reset()
	_ship.gravity_scale = 1.0
	var from: float = _ship.global_position.y
	await _step(60)
	var fell: float = from - _ship.global_position.y
	_ship.gravity_scale = 0.0
	if fell < 1.0:
		_fail("zero-g", "control failed: with gravity on the ship only fell %.2f m" % fell)
		return

	await _reset()
	var start: Vector3 = _ship.global_position
	await _step(120)
	var drifted: float = start.distance_to(_ship.global_position)
	if drifted > 0.05:
		_fail("zero-g", "ship drifted %.3f m with no input" % drifted)
	else:
		_pass("zero-g", "control fell %.2f m; unpowered drift %.4f m" % [fell, drifted])


## Distance under thrust, free and towing. The ratio IS the mass ratio made
## visible -- set the cargo to 1 kg and this block fails.
func _check_thrust_and_tow_cost() -> void:
	await _reset()
	_tether.release()
	var free_travel: float = await _thrust_for(3.0)
	var heading: float = (-_ship.global_basis.z).dot(_ship.linear_velocity.normalized())
	if free_travel < 100.0:
		_fail("thrust", "3 s of thrust covered only %.1f m" % free_travel)
	elif heading < 0.98:
		_fail("thrust", "travel is not aligned with -Z (dot %.3f)" % heading)
	else:
		_pass("thrust", "%.1f m in 3 s, alignment %.3f" % [free_travel, heading])

	await _reset()
	var towed_travel: float = await _thrust_for(3.0)
	var ratio: float = towed_travel / maxf(free_travel, 0.001)
	if ratio < 0.55 or ratio > 0.80:
		_fail("tow-cost", "towed/free is %.3f, outside [0.55, 0.80]" % ratio)
	else:
		_pass(
			"tow-cost", "%.1f m towed of %.1f m free -> %.3f" % [towed_travel, free_travel, ratio]
		)


## Below the rest length the force must be EXACTLY zero, not merely small. A
## spring that leaks below its rest length shows up as the crate creeping toward
## the ship whenever you coast, and it is invisible until you look for it.
func _check_slack_is_exactly_zero() -> void:
	await _reset()
	var anchor_span: float = 4.2
	_cargo.place_at(
		Transform3D(Basis.IDENTITY, _ship.global_position + Vector3(0.0, 0.0, 6.0 + anchor_span))
	)
	await _step(2)
	var start: Vector3 = _cargo.global_position
	await _step(60)
	var moved: float = start.distance_to(_cargo.global_position)
	if not is_zero_approx(_tether.tension()):
		_fail("slack", "slack line carries %.3f N" % _tether.tension())
	elif moved > 0.05:
		_fail("slack", "cargo moved %.3f m on a slack line" % moved)
	else:
		_pass("slack", "tension 0.000 N, cargo moved %.4f m" % moved)


## The cargo has to yank the SHIP. This is the whole feel of the prototype, and a
## sign error here produces a crate that trails perfectly while the ship flies as
## if it were empty -- which reads as "the tether works".
func _check_third_law() -> void:
	# With the attitude controller NEUTRALISED. ShipController holds a commanded
	# body rate of zero with up to 110 kN.m of authority, which is more than the
	# tether's ~89 kN.m -- so on a live ship the yank is suppressed almost
	# entirely and a naive "did it spin" check measures 0.019 rad/s and calls the
	# third law broken. It was measuring the autopilot.
	var free_spin: float = await _yank(0.0)
	# And with it restored, which is the design claim: the pilot wins that fight.
	var held_spin: float = await _yank(3.0)

	# 2.0 m/s, against a measured 2.85 from a 4.5 m stretch. Not a guess: the
	# undamped energy in that stretch is worth 7.2 m/s of hull, a damping ratio of
	# 0.38 takes it to roughly 4, and the line going slack partway through the
	# pull accounts for the rest. The threshold exists to catch a sign error or a
	# force applied only to the crate, both of which read as ~0.
	if _peak_sideways < 2.0:
		_fail("third-law", "ship only reached %.2f m/s toward the cargo" % _peak_sideways)
	else:
		_pass("third-law", "cargo pulled the ship to %.2f m/s sideways" % _peak_sideways)

	# A central force produces translation and no spin at all, so any real yaw is
	# proof the force lands on the tail anchor.
	if free_spin < 0.15:
		_fail(
			"torque-yank",
			"no yaw (%.3f rad/s) even with the autopilot off; force is central" % free_spin
		)
	elif held_spin > free_spin * 0.5:
		_fail(
			"torque-yank",
			(
				"autopilot only cut the yank from %.2f to %.2f rad/s; authority is too low"
				% [free_spin, held_spin]
			)
		)
	else:
		_pass(
			"torque-yank",
			(
				"tether yaws the hull to %.2f rad/s; the autopilot holds it to %.2f"
				% [free_spin, held_spin]
			)
		)


## Stretches the line sideways and returns the peak yaw rate the hull reaches,
## with the attitude controller's gain set to `gain` (0 disables it).
##
## Also records the peak sideways speed, which is what the third law is really
## about and which the autopilot does not touch.
func _yank(gain: float) -> float:
	await _reset()
	var original: float = _ship.rate_gain
	_ship.rate_gain = gain
	# Stretched but NOT past breaking. The offset is anchor-to-anchor once the
	# 4.2 m anchor span is folded in, so rest_length + 8 puts the line 8.5 m over
	# and it snaps on the first frame.
	_cargo.place_at(
		Transform3D(
			Basis.IDENTITY, _ship.global_position + Vector3(_tether.rest_length + 4.0, 0.0, 0.0)
		)
	)
	var peak_spin: float = 0.0
	_peak_sideways = 0.0
	for _i: int in 45:
		await _step(1)
		peak_spin = maxf(peak_spin, absf(_ship.angular_velocity.y))
		_peak_sideways = maxf(_peak_sideways, _ship.linear_velocity.x)
	_ship.rate_gain = original
	return peak_spin


## Reeling in has to pull the crate closer WHILE LOADED, and it has to be much
## slower than reeling in against nothing.
##
## Measured as ship-to-cargo separation, not as rest_length: writing rest_length
## is a property write and would pass against a winch that moves nothing.
##
## THE PAIR IS THE ASSERTION. Either number alone says nothing -- 1.94 m in three
## seconds looks broken until you know the free rate is 12 m, at which point it is
## the stall curve doing exactly its job.
func _check_winch_under_load() -> void:
	var free_closed: float = await _reel_in(false)
	var loaded_closed: float = await _reel_in(true)
	if loaded_closed < 0.5:
		_fail(
			"winch", "reeling in under load closed only %.2f m; the stall is total" % loaded_closed
		)
	elif free_closed < 6.0:
		_fail("winch", "reeling in unloaded closed only %.2f m" % free_closed)
	elif loaded_closed > free_closed * 0.35:
		_fail(
			"winch",
			(
				"loaded reel is %.0f%% of free; a taut line is being cheated"
				% (100.0 * loaded_closed / free_closed)
			)
		)
	else:
		_pass(
			"winch",
			(
				"closed %.2f m free, %.2f m loaded (%.0f%%) -- stall curve holds"
				% [free_closed, loaded_closed, 100.0 * loaded_closed / free_closed]
			)
		)


## Reels in for three seconds, with or without the engine loading the line.
## Returns the metres of ship-to-cargo separation actually removed.
func _reel_in(loaded: bool) -> float:
	await _reset()
	# Starting from the default rest length, NOT from a paid-out line. Paying out
	# to 30 m first only creates slack: the crate does not follow a lengthening
	# line, so the first 2.7 s of the reel is spent taking that slack back up and
	# the measurement came out as 0.43 m of travel on an unloaded winch that is
	# actually good for 12.
	if loaded:
		Input.action_press(&"ship_thrust")
		await _step(90)
	var before: float = _ship.global_position.distance_to(_cargo.global_position)
	Input.action_press(&"ship_reel_in")
	await _step(180)
	Input.action_release(&"ship_reel_in")
	Input.action_release(&"ship_thrust")
	return before - _ship.global_position.distance_to(_cargo.global_position)


func _check_snap_and_reattach() -> void:
	await _reset()
	_snapped = false
	_attached_again = false
	# Pin the crate and fly away from it: the line has to break rather than
	# stretch forever or quietly drop to zero tension.
	_cargo.freeze = true
	Input.action_press(&"ship_thrust")
	Input.action_press(&"ship_boost")
	await _step(240)
	Input.action_release(&"ship_boost")
	Input.action_release(&"ship_thrust")
	_cargo.freeze = false
	if not _snapped:
		_fail("snap", "flying away from a pinned crate under boost did not break the line")
	elif _tether.is_attached():
		_fail("snap", "tether_snapped fired but the line still reports attached")
	else:
		_pass("snap", "line broke and reports detached")

	# Close back in slowly and grab it.
	#
	# Placed ABEAM rather than astern. The reattach radius is 8 m anchor-to-anchor
	# and the ship's anchor is 3 m behind its origin, so parking 5 m astern puts
	# the anchors 9.2 m apart and the grab is refused -- the first version failed
	# here while both the geometry and the rule were correct.
	_ship.place_at(
		Transform3D(_ship.global_transform.basis, _cargo.global_position + Vector3(6.0, 0.0, 0.0))
	)
	await _step(4)
	var took: bool = _tether.try_attach()
	if not took or not _attached_again:
		_fail("reattach", "could not re-grab the crate at 5 m and rest")
	else:
		# And the fresh line has to do work, not just report attached.
		_cargo.place_at(
			Transform3D(
				Basis.IDENTITY, _ship.global_position + Vector3(0.0, 0.0, _tether.rest_length + 6.0)
			)
		)
		await _step(10)
		if _tether.tension() <= 0.0:
			_fail("reattach", "re-attached line carries no tension when stretched")
		else:
			_pass("reattach", "re-grabbed, and the new line pulls at %.0f N" % _tether.tension())


## On/off contrast. "Speed fell" alone would pass against a ship with heavy drag
## baked in, which is exactly what the dampener is NOT.
func _check_dampener() -> void:
	# The tether is released for both halves. Leaving it attached means the crate
	# stays put while the ship is shoved to 40 m/s, the line comes taut and drags
	# it back -- the first version measured 32.7 m/s and reported the drift as
	# non-Newtonian when what it had actually measured was the tether working.
	await _reset()
	_tether.release()
	_ship.dampener_on = false
	_ship.linear_velocity = Vector3(40.0, 0.0, 0.0)
	await _step(240)
	var coasting: float = _ship.linear_velocity.length()

	# Four seconds, not three. The dampener is AUTHORITY-limited, not gain-limited:
	# at 40 m/s the gain asks for 88 kN and it is clamped to the 12 kN a lateral
	# thruster actually has, so it decelerates at a flat 12 m/s^2 and needs 3.3 s
	# to stop. Measuring at 3 s catches it at 4.16 m/s and reads as a failure when
	# it is the clamp doing exactly its job.
	await _reset()
	_tether.release()
	_ship.dampener_on = true
	_ship.linear_velocity = Vector3(40.0, 0.0, 0.0)
	await _step(240)
	var damped: float = _ship.linear_velocity.length()
	_ship.dampener_on = false

	if absf(coasting - 40.0) > 0.5:
		_fail(
			"dampener-off",
			"drift is not Newtonian: 40 m/s decayed to %.2f with no input" % coasting
		)
	elif damped > 4.0:
		_fail("dampener-on", "dampener left %.2f m/s after 3 s" % damped)
	else:
		_pass("dampener", "off: %.2f m/s retained; on: %.2f m/s remaining" % [coasting, damped])


## The whole point of the damage curve: drifting into a rock is free, whipping the
## crate into one is nearly fatal. Both halves are asserted, in one block.
func _check_impact_damage() -> void:
	var rock: Node3D = _world.get_node("Rocks/Rock1") as Node3D
	if rock == null:
		_fail("impact", "sandbox has no Rocks/Rock1 to hit")
		return
	var damage: TetherDamage = _cargo.get_node_or_null("%Damage") as TetherDamage

	var gentle: float = await _ram_rock(rock, 5.0, damage)
	var hard: float = await _ram_rock(rock, 45.0, damage)
	if gentle > 0.0:
		_fail("impact", "a 5 m/s nudge cost %.1f integrity; it should be free" % gentle)
	elif hard < 30.0:
		_fail("impact", "a 45 m/s slam cost only %.1f integrity" % hard)
	else:
		_pass("impact", "5 m/s cost %.1f, 45 m/s cost %.1f" % [gentle, hard])


## Flies the crate into `rock` at `speed` and returns the integrity lost.
func _ram_rock(rock: Node3D, speed: float, damage: TetherDamage) -> float:
	await _reset()
	_tether.release()
	# Line the crate up 30 m short of the rock, pointed at it.
	var approach: Vector3 = (Vector3.UP * 0.001 + Vector3.BACK).normalized()
	_cargo.place_at(Transform3D(Basis.IDENTITY, rock.global_position + approach * 30.0))
	await _step(2)
	var before: float = damage.integrity()
	_cargo.linear_velocity = -approach * speed
	# Long enough to cover 30 m even at 5 m/s, plus the i-frame window.
	await _step(int(30.0 / maxf(speed, 1.0) * 60.0) + 40)
	return before - damage.integrity()


func _check_projectile_damage() -> void:
	await _reset()
	var damage: TetherDamage = _cargo.get_node_or_null("%Damage") as TetherDamage
	var pool: ProjectilePool = _run.projectiles
	if damage == null or pool == null:
		_fail("projectile", "no %Damage on the cargo, or no pool on the run")
		return
	var before: float = damage.integrity()
	for _i: int in 2:
		var muzzle: Vector3 = _cargo.global_position + Vector3(0.0, 0.0, 40.0)
		pool.fire(
			muzzle, (_cargo.global_position - muzzle).normalized(), 220.0, damage.projectile_damage
		)
		await _step(20)
	var lost: float = before - damage.integrity()
	var wanted: float = damage.projectile_damage * 2.0
	# Two hits must cost twice: projectiles deliberately bypass the contact
	# i-frames, or a three-round burst would land as one.
	if not is_equal_approx(lost, wanted):
		_fail("projectile", "two hits cost %.1f, expected %.1f" % [lost, wanted])
	else:
		_pass("projectile", "two hits cost %.1f; i-frames correctly bypassed" % lost)


## Measures the LEAD SOLUTION, not that a shot was fired: does the barrel point
## ahead of a crossing target rather than at it?
func _check_turret_lead() -> void:
	var packed: PackedScene = load(_res(TURRET_SCENE)) as PackedScene
	var turret: TetherTurret = packed.instantiate() as TetherTurret
	_world.add_child(turret)
	await _reset()

	# Park the turret 150 m off the ship's beam and send the ship across it.
	turret.global_position = _ship.global_position + Vector3(150.0, 0.0, -120.0)
	_ship.linear_velocity = Vector3(0.0, 0.0, -80.0)
	await _step(90)

	var to_ship: Vector3 = (_ship.global_position - turret.global_position).normalized()
	var aim: Vector3 = turret.aim_direction()
	var lead_angle: float = rad_to_deg(aim.angle_to(to_ship))
	var ahead: float = aim.dot(_ship.linear_velocity.normalized())
	turret.queue_free()
	# It must not be aimed AT the ship (that is no lead at all), and it must be
	# leaning the way the ship is going rather than trailing it.
	if lead_angle < 1.0:
		_fail(
			"turret-lead", "barrel points straight at the target: no lead (%.2f deg)" % lead_angle
		)
	elif ahead <= 0.0:
		_fail("turret-lead", "barrel leads behind the target (dot %.3f)" % ahead)
	else:
		_pass("turret-lead", "leads %.1f deg ahead of the target, into its travel" % lead_angle)


func _check_completion() -> void:
	await _reset()
	_completed = {}
	var dock: Node3D = _world.get_node("Dock") as Node3D
	# Teleport both into the ring rather than fly the course: what is under test
	# is the trigger, the score and the grade, not the piloting.
	_ship.place_at(Transform3D(_ship.global_transform.basis, dock.global_position))
	_cargo.place_at(Transform3D(Basis.IDENTITY, dock.global_position + Vector3(0.0, 0.0, 16.0)))
	await _step(20)
	if _completed.is_empty():
		_fail("dock", "reaching the ring with the cargo attached did not complete the run")
		return
	var expected: Dictionary = _run.score_for(_completed["integrity"], _completed["elapsed"])
	if _completed["grade"] != expected["grade"]:
		_fail(
			"dock",
			"grade %s does not match the table (%s)" % [_completed["grade"], expected["grade"]]
		)
	elif not bool(_completed["cargo_delivered"]):
		_fail("dock", "a crate still on the tether was not counted as delivered")
	else:
		_pass(
			"dock",
			(
				"completed: grade %s, score %.0f, integrity %.0f%%"
				% [
					_completed["grade"],
					_completed["score"],
					(_completed["integrity"] as float) * 100.0
				]
			)
		)


func _check_failure() -> void:
	await _reset()
	_failed_reason = &""
	var damage: TetherDamage = _cargo.get_node_or_null("%Damage") as TetherDamage
	# Empty the crate's bar the way the game does, through the damage component.
	for _i: int in 40:
		damage.apply_projectile(10.0)
	await _step(10)
	if _failed_reason != &"cargo_destroyed":
		_fail("fail", "destroying the cargo raised '%s', expected cargo_destroyed" % _failed_reason)
	else:
		_pass("fail", "destroying the cargo fails the run with cargo_destroyed")


func _thrust_for(seconds: float) -> float:
	var start: Vector3 = _ship.global_position
	Input.action_press(&"ship_thrust")
	await _step(int(seconds * 60.0))
	Input.action_release(&"ship_thrust")
	return start.distance_to(_ship.global_position)


## Back to a clean run, with every action released -- a block that leaves a key
## held poisons every block after it, and the symptom is an unrelated failure.
func _reset() -> void:
	for action: StringName in [
		&"ship_thrust",
		&"ship_reverse",
		&"ship_boost",
		&"ship_reel_in",
		&"ship_reel_out",
		&"ship_brake",
		&"ship_strafe_left",
		&"ship_strafe_right"
	]:
		if InputMap.has_action(action):
			Input.action_release(action)
	_cargo.freeze = false
	_run.restart()
	await _step(6)


func _step(frames: int) -> void:
	for _i: int in frames:
		await get_tree().physics_frame


func _on_tether_snapped(_at_overshoot: float, _at_position: Vector3) -> void:
	_snapped = true


func _on_tether_attached() -> void:
	_attached_again = true


func _on_run_completed(result: Dictionary) -> void:
	_completed = result


func _on_run_failed(reason: StringName) -> void:
	_failed_reason = reason


func _res(relative_path: String) -> String:
	var dir: String = (get_script() as Script).resource_path.get_base_dir()
	return dir.path_join(relative_path).simplify_path()
