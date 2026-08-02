extends Node

## Drives the real proving ground and measures what happens. Everything here is a
## behaviour measurement -- distance travelled, height gained, how many wheels
## report which surface -- rather than a property read-back, because a property
## read-back passes just as happily against a stub.
##
## Signal flags are MEMBER variables, never locals captured by a lambda: a lambda
## captures locals by value, so `sig.connect(func(): fired = true)` updates the
## closure's copy and the outer variable stays false forever. That one has cost
## this repo a debug cycle before.
##
## Usage:
##   Godot_v4.7.1-stable_win64_console.exe --headless \
##     --path <godot project root> res://examples/3d/vehicle_jeep/tools/verify_jeep_runtime.tscn

## Relative to this script -- see _res().
const GROUND_SCENE: String = "../scenes/proving_ground.tscn"

## Settled wheel-centre height in body space. Equals the wheel radius, because the
## contact patch is on the ground: it is the single number that says the ride
## height, the suspension tune and the authored wheel Y all agree.
const EXPECTED_WHEEL_CENTRE_Y: float = 0.4173
const WHEEL_CENTRE_TOLERANCE: float = 0.05

## Course coordinates, from build_proving_ground.gd's printed report.
const RAMP_LIP_Z: float = -18.0
const RAMP_10_X: float = -24.0
const RAMP_20_X: float = -8.0
const RAMP_30_X: float = 8.0
const RAMP_40_X: float = 24.0
const RAMP_10_CREST: float = 1.74
const RAMP_40_CREST: float = 6.43
const STEP_X: float = 34.0
const MUD_LANE_X: float = -34.0
const ICE_LANE_X: float = -30.2
const SPLIT_MU_X: float = -32.1
const ICE_CIRCLE: Vector3 = Vector3(-34.0, 0.0, -30.0)
const MUD_PIT_X: float = -34.0
const MUD_PIT_Z: float = 34.0
const SPAWN_Y: float = 0.45

var _failures: int = 0
var _world: Node3D = null
var _jeep: JeepController = null
var _visuals: JeepVisuals = null
var _wheels: Array[VehicleWheel3D] = []
## Set by a signal handler. A member, not a captured local -- see the class note.
var _respawn_fired: bool = false


func _ready() -> void:
	var packed: PackedScene = load(_res(GROUND_SCENE))
	if packed == null:
		printerr(
			"FATAL: could not load %s -- run build_proving_ground.gd first." % _res(GROUND_SCENE)
		)
		get_tree().quit(1)
		return

	_world = packed.instantiate() as Node3D
	# The camera rig is removed before the world enters the tree. It would capture
	# the mouse, and more importantly it re-emits an aim point every physics frame,
	# which would fight the turret test. That the jeep works with no camera at all
	# is the decoupling this example claims -- so exercising it is the point.
	var rig: Node = _world.get_node_or_null(^"CameraRig")
	if rig != null:
		_world.remove_child(rig)
		rig.free()
	add_child(_world)

	_jeep = _world.get_node_or_null(^"Jeep") as JeepController
	if _jeep == null:
		printerr("FATAL: no Jeep in the proving ground.")
		get_tree().quit(1)
		return
	# One deliberate hop into the component, the way the wolf's rig verifiers do it.
	_visuals = _jeep.get_node_or_null("%Visuals") as JeepVisuals
	for child: Node in _jeep.get_children():
		if child is VehicleWheel3D:
			_wheels.append(child as VehicleWheel3D)
	_jeep.respawned.connect(_on_respawned)

	await _run_all()

	print("\n=== %d failure(s) ===" % _failures)
	get_tree().quit(1 if _failures > 0 else 0)


func _on_respawned() -> void:
	_respawn_fired = true


func _run_all() -> void:
	await _block_settle()
	await _block_drive()
	await _block_visual_rig()
	await _block_steer()
	await _block_ramps()
	await _block_steps()
	await _block_grip()
	await _block_split_mu()
	await _block_respawn()
	await _block_turret()
	_block_headlights()


func _fail(message: String) -> void:
	_failures += 1
	printerr("  FAIL: %s" % message)


## Does the jeep stand up at the height its geometry says it should?
##
## This also catches a wrong collision_mask, which would present as the jeep quietly
## falling through the floor rather than as anything mentioning masks.
func _block_settle() -> void:
	print("\n[settle]")
	await _place(Vector3(0.0, SPAWN_Y, 0.0), 0.0)
	await _step_frames(90)

	var contacts: int = 0
	for wheel: VehicleWheel3D in _wheels:
		if wheel.is_in_contact():
			contacts += 1
	print(
		(
			"  wheels in contact: %d/4   body y = %+.3f   gravity_scale = %.3f"
			% [contacts, _jeep.global_position.y, _jeep.gravity_scale]
		)
	)
	if contacts < 4:
		_fail("only %d/4 wheels settled onto the ground" % contacts)

	for wheel: VehicleWheel3D in _wheels:
		var centre_y: float = wheel.transform.origin.y
		print("    %-8s wheel centre y = %.4f" % [wheel.name, centre_y])
		if absf(centre_y - EXPECTED_WHEEL_CENTRE_Y) > WHEEL_CENTRE_TOLERANCE:
			_fail(
				(
					(
						"%s settled at y=%.4f, expected %.4f +/- %.2f -- ride height, "
						% [wheel.name, centre_y, EXPECTED_WHEEL_CENTRE_Y, WHEEL_CENTRE_TOLERANCE]
					)
					+ "suspension tune and authored wheel Y disagree"
				)
			)


func _block_drive() -> void:
	print("\n[drive]")
	await _place(Vector3(0.0, SPAWN_Y, 20.0), 0.0)
	var run: Dictionary = await _drive([&"jeep_throttle"], 4.0)
	var travel: Vector3 = run["travel"]
	var planar: float = Vector2(travel.x, travel.z).length()
	var heading_dot: float = 0.0
	if planar > 0.01:
		heading_dot = Vector3(travel.x, 0.0, travel.z).normalized().dot(Vector3.FORWARD)
	print(
		(
			"  travelled %.2f m in 4 s, peak %.2f m/s, forward alignment %.3f"
			% [planar, run["peak_speed"], heading_dot]
		)
	)
	if planar < 15.0:
		_fail("only %.2f m in 4 s of full throttle" % planar)
	if run["peak_speed"] < 7.0:
		_fail("peak speed %.2f m/s is too low to be driving" % run["peak_speed"])
	if heading_dot < 0.9:
		_fail("travelled %.3f aligned with -Z; the jeep is not going where it faces" % heading_dot)

	# [rpm-convention]: the geometric sign of wheel roll is derivable; get_rpm()'s
	# own convention is not. So this asserts the CALIBRATED product rather than the
	# raw sign -- get_rpm() is in fact negative when driving forward on 4.7.1, and a
	# test demanding otherwise would be asserting a guess rather than the contract.
	# What must hold is that rpm * RPM_SIGN agrees with the direction of travel,
	# which is what makes the wheel meshes roll the right way.
	print("  [rpm-convention]")
	var forward_speed: float = -_jeep.global_basis.z.dot(_jeep.linear_velocity)
	for wheel: VehicleWheel3D in _wheels:
		var rpm: float = wheel.get_rpm()
		var calibrated: float = rpm * JeepVisuals.RPM_SIGN
		print(
			(
				"    %-8s rpm %+8.1f  x RPM_SIGN -> %+8.1f   forward speed %+.2f m/s"
				% [wheel.name, rpm, calibrated, forward_speed]
			)
		)
		if signf(calibrated) != signf(forward_speed):
			_fail(
				(
					(
						"%s: rpm %+.1f x RPM_SIGN %+.0f = %+.1f, but the jeep is moving "
						% [wheel.name, rpm, JeepVisuals.RPM_SIGN, calibrated]
					)
					+ (
						"%+.2f m/s -- the wheel meshes are rolling backwards, so flip "
						% forward_speed
					)
					+ "JeepVisuals.RPM_SIGN"
				)
			)


## Did the rig actually MOVE, or did the code merely run? A pose write that lands
## on the wrong node compiles, executes and reports nothing.
func _block_visual_rig() -> void:
	print("\n[visual-rig]")
	var before: Dictionary = _visuals.debug_state()
	var before_spin: Array = before["spin_angles"]
	await _drive([&"jeep_throttle", &"jeep_steer_left"], 1.5)
	var after: Dictionary = _visuals.debug_state()
	var after_spin: Array = after["spin_angles"]

	var moved: int = 0
	for index: int in after_spin.size():
		if not is_equal_approx(before_spin[index], after_spin[index]):
			moved += 1
	print("  %d/4 wheel spin angles advanced" % moved)
	if moved < 4:
		_fail("only %d wheel meshes are rolling" % moved)

	# The front steer pivots must carry exactly what the physics wheel carries.
	var steer_rotations: Array = after["steer_rotations"]
	for index: int in 2:
		var wheel_steer: float = _wheels[index].steering
		if absf(steer_rotations[index] - wheel_steer) > 0.001:
			_fail(
				(
					"%s steer pivot at %.4f rad, wheel says %.4f"
					% [_wheels[index].name, steer_rotations[index], wheel_steer]
				)
			)
	print("  front steer pivots track wheel.steering (%.4f rad)" % _wheels[0].steering)

	# DIRECTION, not just movement. A wheel that rolls backwards or a rim that turns
	# the wrong way both animate perfectly and look wrong, and neither shows up in
	# "did the value change". Both are derivable, so both are asserted rather than
	# left as something to confirm by eye once and hope nobody re-tunes.
	var deltas: Array = after["spin_deltas"]
	for index: int in deltas.size():
		# Driving forward must DECREASE the roll angle: a positive rotation about +X
		# carries the contact patch toward -Z, which is a wheel rolling backwards.
		if deltas[index] >= 0.0:
			_fail(
				(
					(
						"%s rolled %+.5f rad on the last forward frame; the wheel meshes are "
						% [_wheels[index].name, deltas[index]]
					)
					+ "spinning backwards"
				)
			)
	print("  all 4 wheels rolling forward (last delta %+.5f rad)" % deltas[0])

	# Proves the raked-axis path executed, not merely compiled. The axis is read off
	# mk_steering_axis at runtime; a wrong basis would leave the rim at rest.
	print(
		(
			"  steering axis %s, rim moved: %s"
			% [str(after["steering_wheel_axis"]), after["steering_wheel_moved"]]
		)
	)
	if not after["steering_wheel_moved"]:
		_fail("the steering wheel never left its rest pose")

	# Half lock, not full: at full lock the rim has turned 180 degrees and the top of
	# it is back on the centre line, so the X component is zero and says nothing.
	_visuals.set_steering_normalized(0.5)
	var rim_up: Vector3 = _visuals.debug_state()["steering_wheel_up"]
	print("  at half lock left, the top of the rim points %s" % str(rim_up))
	if rim_up.x > -0.5:
		_fail(
			(
				(
					"steering left turns the rim the wrong way: its top went to x=%+.3f, and "
					% rim_up.x
				)
				+ "left is -X"
			)
		)
	_visuals.set_steering_normalized(0.0)


func _block_steer() -> void:
	print("\n[steer]")
	await _place(Vector3(0.0, SPAWN_Y, 30.0), 0.0)
	var start_heading: float = _jeep.global_rotation.y
	await _drive([&"jeep_throttle", &"jeep_steer_left"], 3.0)
	var turned: float = rad_to_deg(absf(angle_difference(start_heading, _jeep.global_rotation.y)))
	print("  heading changed %.1f deg" % turned)
	if turned < 30.0:
		_fail("only %.1f deg of turn in 3 s of full lock" % turned)


## Gradeability. Measured as PEAK height, not final: drive over a crest and the
## final height is ground level again, which reads as failure on a success.
func _block_ramps() -> void:
	print("\n[ramp]")
	var ten: float = await _climb(RAMP_10_X, "Ramp10")
	var thirty: float = await _climb(RAMP_30_X, "Ramp30")
	var forty: float = await _climb(RAMP_40_X, "Ramp40")
	print(
		(
			"  10 deg peak %.2f m (crest %.2f)   30 deg peak %.2f m   40 deg peak %.2f m (crest %.2f)"
			% [ten, RAMP_10_CREST, thirty, forty, RAMP_40_CREST]
		)
	)
	# Framed as "did it summit", because the approach is 12 m long and the jeep
	# arrives carrying real momentum -- which is honest, since that is how a player
	# meets these ramps. Sustained gradeability is engine-limited at about 30 deg
	# (8.8 kN of drive against 12.6 kN of gravity on the 40), and what momentum
	# cannot do is get it over the top.
	if ten < RAMP_10_CREST * 0.9:
		_fail(
			(
				(
					"only %.2f m up a 10 degree ramp whose crest is %.2f m -- it should "
					% [ten, RAMP_10_CREST]
				)
				+ "summit this one comfortably"
			)
		)
	if forty > RAMP_40_CREST * 0.8:
		_fail(
			(
				(
					"reached %.2f m of the 40 degree ramp's %.2f m crest; that grade is "
					% [forty, RAMP_40_CREST]
				)
				+ "meant to defeat the jeep"
			)
		)
	print("  30 degrees is genuinely marginal, so it is reported, not asserted")


## Square edges. The wheel radius is 0.417, so the 0.50 step is taller than the
## wheel and must stop the jeep -- which makes this two-directional rather than a
## one-way "it climbed something".
func _block_steps() -> void:
	print("\n[step]")
	# Measured as "did it get past", not "how high did the body rise".
	#
	# Body height is a bad proxy at this scale: the steps are 3 m deep and the
	# wheelbase is 2.35 m, so the jeep is across the tread before all four wheels
	# are up and the origin never reaches the step height. A 0.12 m step measured
	# 0.094 m and a 0.50 m step measured 0.219 -- the number does not separate
	# "climbed it" from "did not".
	#
	# What blocks the jeep is HULL CLEARANCE, not wheel radius: VehicleWheel3D
	# wheels are raycasts with no lateral collision, so a square edge below the
	# adopted body proxy's underside (y = 0.49) is simply absorbed by the
	# suspension. 0.75 m is above that, so it high-centres.
	var low: Dictionary = await _cross_step(-6.0, "Step15")
	var mid: Dictionary = await _cross_step(-13.0, "Step30")
	var high: Dictionary = await _cross_step(-20.0, "Step45")
	var blocked: Dictionary = await _cross_step(-27.0, "Step75")
	if not low["crossed"]:
		_fail(
			(
				"the 0.15 m step stopped the jeep (%.2f m of %.2f m travelled)"
				% [low["travelled"], low["needed"]]
			)
		)
	if not mid["crossed"]:
		_fail(
			(
				"the 0.30 m step stopped the jeep (%.2f m of %.2f m travelled)"
				% [mid["travelled"], mid["needed"]]
			)
		)
	if blocked["crossed"]:
		_fail(
			(
				"the jeep got over the 0.75 m step; that is well above its 0.49 m hull "
				+ "clearance, so it should have high-centred on it"
			)
		)
	print(
		(
			"  0.45 m sits just under the 0.49 m clearance and is marginal "
			+ "(crossed: %s), so it is reported, not asserted" % high["crossed"]
		)
	)


## The measurement that matters: how far the jeep gets on mud versus on tarmac from
## a standing start. A property read-back would pass against a stub; this cannot.
func _block_grip() -> void:
	print("\n[mud]")
	await _place(Vector3(0.0, SPAWN_Y, 40.0), 0.0)
	var tarmac_run: Dictionary = await _drive([&"jeep_throttle"], 3.0)
	var tarmac: float = (tarmac_run["travel"] as Vector3).length()

	# Run along the 40 m mud LANE, not across the 12 m pit. The pit is only 12 m
	# deep and a 3 s run covers 25 m, so two thirds of the "mud" run happened on
	# tarmac and the comparison came out at 100% -- the measurement was wrong, not
	# the vehicle. The lane is 3.6 m wide against a 1.56 m track, so a straight run
	# keeps all four wheels on it.
	await _place(Vector3(MUD_LANE_X, SPAWN_Y, 18.0), 0.0)
	await _step_frames(30)
	var surfaces: Dictionary = _surface_counts()
	print("  standing on the mud lane, wheels report: %s" % str(surfaces))
	if surfaces.get(&"mud", 0) < 4:
		_fail("expected all 4 wheels on mud, got %s" % str(surfaces))
	# Only the wheels that actually REPORT mud, so a placement error shows up as a
	# surface-count failure above rather than as a misleading friction failure here.
	for wheel_state: Dictionary in _jeep.debug_state()["wheels"] as Array:
		if wheel_state["surface"] != &"mud":
			continue
		if wheel_state["friction_slip"] >= wheel_state["base_friction_slip"]:
			_fail(
				(
					"%s reports mud but is still at friction_slip %.2f"
					% [wheel_state["label"], wheel_state["friction_slip"]]
				)
			)

	var mud_run: Dictionary = await _drive([&"jeep_throttle"], 3.0)
	var mud: float = (mud_run["travel"] as Vector3).length()
	var ratio: float = mud / maxf(tarmac, 0.001)
	var ended_on: Dictionary = _surface_counts()
	print(
		(
			"  tarmac %.2f m, mud %.2f m -> %.0f%% of the tarmac run (ended on %s)"
			% [tarmac, mud, ratio * 100.0, str(ended_on)]
		)
	)
	# Guards the measurement itself: if the jeep wandered off the lane mid-run, the
	# comparison silently becomes tarmac-vs-tarmac and reports a clean pass.
	if ended_on.get(&"mud", 0) < 3:
		_fail(
			(
				"the jeep left the mud lane during the run (%s), so the comparison " % str(ended_on)
				+ "is not measuring mud"
			)
		)
	if ratio > 0.75:
		_fail(
			(
				"mud cost only %.0f%% of the distance; grip loss is not reaching the solver"
				% ((1.0 - ratio) * 100.0)
			)
		)

	print("\n[ice]")
	await _place(ICE_CIRCLE + Vector3(0.0, SPAWN_Y, 6.0), 0.0)
	await _step_frames(30)
	var ice_run: Dictionary = await _drive([&"jeep_throttle"], 1.5)
	print("  mean skid on ice %.3f (1.0 = full grip)" % ice_run["mean_skid"])
	if ice_run["mean_skid"] > 0.95:
		_fail("tyres are not slipping on ice (mean skid %.3f)" % ice_run["mean_skid"])

	# [restore]: float-equal, not approximate. The base is captured from the
	# authored value, so anything but an exact match means the restore path is
	# reconstructing a number rather than putting one back.
	print("\n[restore]")
	await _place(Vector3(0.0, SPAWN_Y, 0.0), 0.0)
	await _step_frames(60)
	var state: Dictionary = _jeep.debug_state()
	for wheel_state: Dictionary in state["wheels"]:
		if wheel_state["friction_slip"] != wheel_state["base_friction_slip"]:
			_fail(
				(
					"%s back on tarmac at friction_slip %.6f, authored value is %.6f"
					% [
						wheel_state["label"],
						wheel_state["friction_slip"],
						wheel_state["base_friction_slip"]
					]
				)
			)
	print("  every wheel restored to its authored friction_slip exactly")


## Two wheels on mud and two on ice IN THE SAME FRAME. This is the assertion that
## per-wheel detection buys and a chassis-mounted Area3D cannot express at all.
func _block_split_mu() -> void:
	print("\n[split-mu]")
	await _place(Vector3(SPLIT_MU_X, SPAWN_Y, 0.0), 0.0)
	await _step_frames(60)
	var counts: Dictionary = _surface_counts()
	print(
		(
			"  straddling x=%.2f (mud lane %.1f | ice lane %.1f): %s"
			% [SPLIT_MU_X, MUD_LANE_X, ICE_LANE_X, str(counts)]
		)
	)
	if counts.get(&"mud", 0) < 2 or counts.get(&"ice", 0) < 2:
		_fail("expected 2 wheels on mud and 2 on ice at once, got %s" % str(counts))


func _block_respawn() -> void:
	print("\n[respawn]")
	_respawn_fired = false
	var upside_down := Transform3D(Basis(Vector3.FORWARD, PI), Vector3(12.0, 20.0, 12.0))
	_jeep.place_at(upside_down)
	await _step_frames(4)
	_jeep.respawn()
	await _step_frames(4)

	var spawn: Node3D = _world.get_node_or_null(^"SpawnPoint") as Node3D
	var offset: float = _jeep.global_position.distance_to(spawn.global_position)
	var upright: float = _jeep.global_basis.y.dot(Vector3.UP)
	print(
		(
			"  %.3f m from spawn, up-vector dot %.3f, speed %.3f m/s, signal %s"
			% [offset, upright, _jeep.linear_velocity.length(), _respawn_fired]
		)
	)
	if offset > 1.0:
		_fail("respawned %.2f m from the spawn point" % offset)
	if upright < 0.9:
		_fail("still on its roof after respawn (up dot %.3f)" % upright)
	# Generous on purpose. The spawn marker is 0.45 m up, so a few frames of free
	# fall at g=14 legitimately reads ~0.9 m/s. What this rules out is the jeep
	# ARRIVING with the ~20 m/s it had while falling, which is what a teleport that
	# does not reset velocity looks like.
	if _jeep.linear_velocity.length() > 2.0:
		_fail(
			(
				"respawned carrying %.2f m/s -- the teleport did not clear velocity"
				% _jeep.linear_velocity.length()
			)
		)
	if not _respawn_fired:
		_fail("respawn() did not emit `respawned`")


func _block_turret() -> void:
	print("\n[turret]")
	await _place(Vector3(0.0, SPAWN_Y, 0.0), 0.0)
	await _step_frames(30)

	# 45 degrees to the right of the hull, level. Hull forward is -Z, right is +X.
	var target: Vector3 = _jeep.global_position + Vector3(20.0, 0.6, -20.0)
	_jeep.set_aim_point(target)
	await _step_frames(90)
	var yaw: float = rad_to_deg(_visuals.debug_state()["turret_yaw"])
	print("  aimed 45 deg right, turret yaw %.2f deg" % yaw)
	if absf(yaw - (-45.0)) > 3.0:
		_fail(
			"turret yaw %.2f deg, expected about -45 (yawing right is negative " % yaw + "about +Y)"
		)

	_jeep.set_aim_point(_jeep.global_position + Vector3(0.0, 60.0, -6.0))
	await _step_frames(120)
	var pitch: float = rad_to_deg(_visuals.debug_state()["turret_pitch"])
	var pitch_max: float = _visuals.turret_pitch_max_degrees
	print("  aimed steeply up, turret pitch %.2f deg (clamp %.1f)" % [pitch, pitch_max])
	if absf(pitch - pitch_max) > 1.0:
		_fail("pitch %.2f did not clamp at %.1f" % [pitch, pitch_max])


func _block_headlights() -> void:
	print("\n[headlights]")
	_visuals.set_headlights(true)
	var on: bool = _visuals.debug_state()["headlights"]
	_visuals.set_headlights(false)
	var off: bool = _visuals.debug_state()["headlights"]
	print("  on -> %s, off -> %s" % [on, off])
	if not on or off:
		_fail("headlight toggle did not take")


## Peak height gained driving into a ramp from the common approach line.
func _climb(ramp_x: float, label: String) -> float:
	await _place(Vector3(ramp_x, SPAWN_Y, RAMP_LIP_Z + 12.0), 0.0)
	var base_y: float = _jeep.global_position.y
	var run: Dictionary = await _drive([&"jeep_throttle"], 5.0)
	var gained: float = (run["peak_y"] as float) - base_y
	print("    %-8s peak height gain %.2f m" % [label, gained])
	return gained


## Drives at a step from 3 m out -- close enough to be near a standing start, which
## is what makes "the tall one stops it" mean anything -- and reports whether the
## jeep ended up beyond the step's far face.
##
## Steps are 3 m deep in Z, so the near face is at step_z + 1.5 and the far face at
## step_z - 1.5. Starting 3 m short of the near face, crossing means travelling
## more than 6 m in -Z.
func _cross_step(step_z: float, label: String) -> Dictionary:
	var start_z: float = step_z + 4.5
	var needed: float = start_z - (step_z - 1.5)
	await _place(Vector3(STEP_X, SPAWN_Y, start_z), 0.0)
	var base_y: float = _jeep.global_position.y
	var run: Dictionary = await _drive([&"jeep_throttle"], 3.0)
	var travelled: float = start_z - _jeep.global_position.z
	var drift: float = absf(_jeep.global_position.x - STEP_X)
	# Lateral drift is checked too, and it is not pedantry: hitting a step edge that
	# is too tall yaws the jeep, and it then slides off to the side and drives on
	# past the step's 9 m width. Z travel alone counts that as a successful climb.
	var crossed: bool = travelled > needed and drift < 3.0
	print(
		(
			"    %-8s travelled %5.2f m of %.2f needed, drift %4.2f m, peak +%.3f m -> %s"
			% [
				label,
				travelled,
				needed,
				drift,
				(run["peak_y"] as float) - base_y,
				"crossed" if crossed else "STOPPED"
			]
		)
	)
	return {"crossed": crossed, "travelled": travelled, "needed": needed, "drift": drift}


func _surface_counts() -> Dictionary:
	var counts: Dictionary = {}
	for wheel_state: Dictionary in _jeep.debug_state()["wheels"] as Array:
		if not wheel_state["contact"]:
			continue
		var surface: StringName = wheel_state["surface"]
		counts[surface] = counts.get(surface, 0) + 1
	return counts


func _place(origin: Vector3, heading_degrees: float) -> void:
	_release_all()
	_jeep.place_at(Transform3D(Basis(Vector3.UP, deg_to_rad(heading_degrees)), origin))
	await _step_frames(45)


## Holds `actions` for `seconds` and reports what happened over the run.
func _drive(actions: Array, seconds: float) -> Dictionary:
	var start: Vector3 = _jeep.global_position
	var peak_speed: float = 0.0
	var peak_y: float = start.y
	var skid_total: float = 0.0
	var skid_samples: int = 0

	for action: StringName in actions:
		Input.action_press(action)
	var frames: int = int(seconds * float(Engine.physics_ticks_per_second))
	for _frame: int in frames:
		await get_tree().physics_frame
		peak_speed = maxf(peak_speed, _jeep.linear_velocity.length())
		peak_y = maxf(peak_y, _jeep.global_position.y)
		for wheel: VehicleWheel3D in _wheels:
			if wheel.is_in_contact():
				skid_total += wheel.get_skidinfo()
				skid_samples += 1
	_release_all()

	return {
		"travel": _jeep.global_position - start,
		"peak_speed": peak_speed,
		"peak_y": peak_y,
		"mean_skid": 1.0 if skid_samples == 0 else skid_total / float(skid_samples),
	}


func _release_all() -> void:
	for action: StringName in [
		&"jeep_throttle",
		&"jeep_reverse",
		&"jeep_steer_left",
		&"jeep_steer_right",
		&"jeep_handbrake",
	]:
		if InputMap.has_action(action):
			Input.action_release(action)


func _step_frames(frames: int) -> void:
	for _frame: int in frames:
		await get_tree().physics_frame


## Turns a path relative to this script into an absolute res:// path.
func _res(relative_path: String) -> String:
	var dir: String = (get_script() as Script).resource_path.get_base_dir()
	return dir.path_join(relative_path).simplify_path()
