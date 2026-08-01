extends Node

## Measures what the tether actually does, so the numbers in TetherLink and
## cargo.tscn are chosen against evidence instead of against a feeling.
##
## This is NOT a verifier -- it asserts nothing and always exits 0. It is the
## tuning instrument: it prints period, decay, tow cost, steady stretch, swing
## amplitude and winch stall, and you read those off before deciding whether to
## move spring_k or the mass ratio. Tuning a spring by feel at 60 Hz is where jam
## hours go to die.
##
## It builds its own bodies rather than instancing ship.tscn, on purpose. There is
## no controller, no camera, no input and no HUD in here, so what it reports is
## the spring's behaviour and nothing else. Whether ShipController flies well is a
## separate question, measured by verify_cargo_tether_runtime.
##
## Run it (note: the .tscn, not the .gd -- a node added during
## SceneTree._initialize() never receives _ready()):
##   godot --headless --path <project root> \
##     res://examples/3d/cargo_tether/tools/measure_tether_response.tscn

## Matches ShipController.thrust_main, so tow cost is measured against the force
## the ship actually produces.
const THRUST_MAIN: float = 28000.0
## Matches ShipController.thrust_lateral. The corner in [swing-amplitude] is
## strafed rather than flown round, because this harness has no attitude
## controller -- so it must use the force the strafe thrusters actually have.
const THRUST_LATERAL: float = 12000.0
const BOOST_MULTIPLIER: float = 1.9
## The ship's anchor sits 3.0 m behind its centre and the cargo's 1.2 m ahead of
## its own, so anchor-to-anchor is 4.2 m SHORTER than centre-to-centre.
##
## rest_length is an anchor-to-anchor distance. Spawning the cargo rest_length
## behind the ship therefore starts the line 4.2 m slack, which is not a small
## error: it is the difference between a tether and a piece of string lying on
## the floor. The first version of this harness did exactly that and reported
## overshoot pinned at -1.20 m for fourteen straight seconds.
const ANCHOR_SPAN: float = 4.2
## Long enough to catch several taut episodes, which are seconds apart because
## the line spends most of its time slack. See _measure_axial.
const SETTLE_SECONDS: float = 14.0

var _ship: RigidBody3D
var _cargo: RigidBody3D
var _tether: TetherLink
var _rig: Node3D
var _ship_force: Vector3 = Vector3.ZERO


func _ready() -> void:
	print("=== tether response, %d Hz ===" % Engine.physics_ticks_per_second)
	await _measure_axial()
	await _measure_tow_cost()
	await _measure_steady_stretch()
	await _measure_swing_amplitude()
	await _measure_winch_stall()
	await _measure_winch_stability()
	print("=== done ===")
	get_tree().quit(0)


func _physics_process(_delta: float) -> void:
	if _ship != null and not _ship_force.is_zero_approx():
		_ship.apply_central_force(_ship.global_basis * _ship_force)


## Displace the cargo along the tether axis, let go, and watch it ring down.
##
## THIS IS A ONE-SIDED SPRING AND IT HAS NO CLASSICAL PERIOD. Below the rest
## length the force is exactly zero, so the system is not a mass on a spring --
## it is a mass on a rope. Each time the line comes taut it gets HALF a cycle of
## spring behaviour and is then thrown back into a free coast that lasts however
## long it takes to run the slack out again.
##
## So the two numbers worth reading are the length of a taut episode (which is
## the half period of the underlying spring, predicted 1.47 / 2 = 0.73 s) and how
## much the peak overshoot decays between episodes, which is damping_c.
##
## The first version of this measurement looked for successive peaks of overshoot
## inside 6 s, found none, and reported "damping_c is too high to read a period".
## That was the harness describing itself, not the tether.
func _measure_axial() -> void:
	_build(14.0)
	# Three metres of stretch to ring down from.
	_cargo.global_position = Vector3(0.0, 0.0, 14.0 + ANCHOR_SPAN + 3.0)
	await _step(1)

	var episode_peaks: PackedFloat64Array = PackedFloat64Array()
	var episode_lengths: PackedFloat64Array = PackedFloat64Array()
	var taut: bool = false
	var peak: float = 0.0
	var began: float = 0.0
	var elapsed: float = 0.0
	var taut_frames: int = 0
	var lowest: float = 1e9
	var highest: float = -1e9
	var step: float = 1.0 / float(Engine.physics_ticks_per_second)
	for _i: int in int(SETTLE_SECONDS / step):
		await _step(1)
		elapsed += step
		var value: float = _tether.overshoot()
		lowest = minf(lowest, value)
		highest = maxf(highest, value)
		if value > 0.0:
			taut_frames += 1
			if not taut:
				taut = true
				began = elapsed
				peak = 0.0
			peak = maxf(peak, value)
		elif taut:
			taut = false
			episode_peaks.append(peak)
			episode_lengths.append(elapsed - began)

	print("[axial]  one-sided spring: taut episodes, not cycles")
	print("  overshoot ranged %.2f .. %.2f m" % [lowest, highest])
	print(
		"  taut for %.0f%% of the window" % (100.0 * float(taut_frames) / (SETTLE_SECONDS / step))
	)
	print("  episodes in %.0f s: %d" % [SETTLE_SECONDS, episode_peaks.size()])
	for i: int in mini(episode_peaks.size(), 3):
		print("    %d  peak %.3f m  lasted %.3f s" % [i + 1, episode_peaks[i], episode_lengths[i]])
	if episode_lengths.size() >= 1:
		print("  first episode %.3f s  (predicted half period 0.73)" % episode_lengths[0])
	if episode_peaks.size() >= 2:
		print("  peak decay    %.3f" % (episode_peaks[1] / maxf(episode_peaks[0], 0.0001)))
	_teardown()


## Constant thrust for three seconds, with and without the cargo. The ratio is the
## mass ratio made visible: 1000 / (1000 + 600) = 0.625.
func _measure_tow_cost() -> void:
	var free_distance: float = await _thrust_run(false, 3.0, 1.0)
	var towed_distance: float = await _thrust_run(true, 3.0, 1.0)
	print("[tow-cost]")
	print("  free   %.2f m" % free_distance)
	print("  towed  %.2f m" % towed_distance)
	print("  ratio  %.3f  (predicted 0.625)" % (towed_distance / maxf(free_distance, 0.0001)))


## How far the line stretches under sustained acceleration. This is the number
## that has to stay well clear of max_overshoot, or ordinary flight snaps the
## tether and the break stops meaning anything.
func _measure_steady_stretch() -> void:
	print("[steady-stretch]")
	for boost: bool in [false, true]:
		_build(14.0)
		_ship_force = Vector3(0.0, 0.0, -THRUST_MAIN * (BOOST_MULTIPLIER if boost else 1.0))
		await _step(int(4.0 * Engine.physics_ticks_per_second))
		var label: String = "boost " if boost else "cruise"
		print(
			(
				"  %s  stretch %.2f of %.1f m allowed   tension %.1f kN   accel %.1f m/s^2"
				% [
					label,
					_tether.overshoot(),
					_tether.max_overshoot,
					_tether.tension() / 1000.0,
					_ship_force.length() / (_ship.mass + _cargo.mass),
				]
			)
		)
		_teardown()


## THE HEADLINE NUMBER. Fly the same canned manoeuvre on a short tether and a long
## one, and measure how far the cargo swings off the ship's line of travel.
##
## Measured perpendicular to the ship's own velocity, not in world axes, so it
## does not matter that the two runs take slightly different paths -- the cargo
## pulls back on the ship and it always will.
##
## Excursion for a given swing angle scales linearly with length, so a long tether
## should read several times a short one. If it does not, the winch is decoration.
func _measure_swing_amplitude() -> void:
	print("[swing-amplitude]")
	var results: Dictionary = {}
	var angles: Dictionary = {}
	for length: float in [8.0, 26.0]:
		_build(length)
		var peak: float = 0.0
		var peak_angle: float = 0.0
		var snapped: bool = false
		# Straight, then strafe hard, then straight again: a corner. The lateral
		# leg uses the STRAFE thrust, not the main engine -- there is no attitude
		# controller in here to turn the nose with, and pushing 28 kN sideways is
		# a manoeuvre the ship cannot actually perform. The first version did
		# exactly that, snapped the line on both runs, and then measured how far
		# a free-drifting crate had wandered: 99 m on the "short" tether, which
		# reported the ratio backwards.
		var legs: Array = [
			[Vector3(0.0, 0.0, -THRUST_MAIN), 3.0],
			[Vector3(THRUST_LATERAL, 0.0, -THRUST_MAIN * 0.3), 2.0],
			[Vector3(0.0, 0.0, -THRUST_MAIN), 2.0],
		]
		for leg: Array in legs:
			_ship_force = leg[0] as Vector3
			var frames: int = int((leg[1] as float) * Engine.physics_ticks_per_second)
			for _i: int in frames:
				await _step(1)
				# Only while the line exists. A detached crate is not swinging,
				# it is leaving, and its offset grows without bound.
				if not _tether.is_attached():
					snapped = true
					break
				peak = maxf(peak, _lateral_offset())
				peak_angle = maxf(peak_angle, _swing_deviation())
			if snapped:
				break
		results[length] = peak
		angles[length] = peak_angle
		var note: String = "  SNAPPED -- amplitude is not comparable" if snapped else ""
		print(
			(
				"  L = %5.1f m   peak lateral offset %6.2f m   peak swing off-stern %5.1f deg%s"
				% [length, peak, peak_angle, note]
			)
		)
		_teardown()

	# The metric SATURATES. Lateral offset can never exceed the separation, so
	# once both tethers swing to near-perpendicular the ratio collapses onto the
	# ratio of their lengths -- here (26 + 4.2) / (8 + 4.2) = 2.48. Anything at or
	# above about 2.0 means the winch is delivering most of the difference that
	# geometry allows; asking for more than 2.48 is asking for the impossible,
	# which is what the 2.5 target in the plan was doing.
	var short_peak: float = results[8.0]
	var long_peak: float = results[26.0]
	var ceiling: float = (26.0 + ANCHOR_SPAN) / (8.0 + ANCHOR_SPAN)
	print(
		(
			"  ratio long/short  %.2f  of a %.2f geometric ceiling  (want >= 2.0)"
			% [long_peak / maxf(short_peak, 0.0001), ceiling]
		)
	)
	print("  peak swing off-stern  %.0f deg short, %.0f deg long" % [angles[8.0], angles[26.0]])


## Reel in against nothing, then against a load, and compare. The pair is the
## measurement: either number alone says nothing about whether the stall works.
func _measure_winch_stall() -> void:
	print("[winch-stall]")
	var travel: Dictionary = {}
	for loaded: bool in [false, true]:
		_build(TetherWinch.MAX_LENGTH)
		if loaded:
			_ship_force = Vector3(0.0, 0.0, -THRUST_MAIN)
			# Let the line come taut before asking the winch to fight it.
			await _step(int(1.5 * Engine.physics_ticks_per_second))
		var before: float = _tether.rest_length
		_tether.target_length = TetherWinch.MIN_LENGTH
		await _step(int(2.0 * Engine.physics_ticks_per_second))
		travel[loaded] = before - _tether.rest_length
		print(
			(
				"  %s  reeled %.2f m in 2 s   (tension %.1f kN)"
				% ["loaded " if loaded else "free   ", travel[loaded], _tether.tension() / 1000.0]
			)
		)
		_teardown()
	var ratio: float = (travel[true] as float) / maxf(travel[false] as float, 0.0001)
	print("  loaded/free  %.3f  (want <= 0.25)" % ratio)


## Reel the full band while boosting, which is the worst case for the spring: the
## rest length is moving against the highest tension the game can produce. An
## unstable spring's real failure mode is NaN, after which every readout prints
## 0.00 and looks perfectly healthy, so this checks explicitly.
func _measure_winch_stability() -> void:
	_build(TetherWinch.MAX_LENGTH)
	_ship_force = Vector3(0.0, 0.0, -THRUST_MAIN * BOOST_MULTIPLIER)
	await _step(int(1.0 * Engine.physics_ticks_per_second))
	_tether.target_length = TetherWinch.MIN_LENGTH

	var finite: bool = true
	var worst_overshoot: float = 0.0
	var snapped: bool = false
	for _i: int in int(4.0 * Engine.physics_ticks_per_second):
		await _step(1)
		if not _cargo.global_position.is_finite() or not _ship.global_position.is_finite():
			finite = false
			break
		if not _tether.is_attached():
			snapped = true
			break
		worst_overshoot = maxf(worst_overshoot, _tether.overshoot())

	var allowed: float = _tether.max_overshoot
	print("[winch-stability]")
	print("  positions finite  %s" % ("yes" if finite else "NO -- THE SPRING DIVERGED"))
	print("  peak overshoot    %.2f m of %.1f allowed" % [worst_overshoot, allowed])
	print("  snapped           %s" % ("yes" if snapped else "no"))
	_teardown()


## Distance from the cargo to the line the ship is travelling along.
func _lateral_offset() -> float:
	var velocity: Vector3 = _ship.linear_velocity
	if velocity.length_squared() < 0.01:
		return 0.0
	var axis: Vector3 = velocity.normalized()
	var span: Vector3 = _cargo.global_position - _ship.global_position
	return (span - axis * span.dot(axis)).length()


## How far the cargo has swung OFF the trailing line, in degrees: 0 is directly
## astern, 90 is out beside the ship.
##
## Measured against the trailing direction rather than the direction of travel,
## because a cargo doing exactly what it should sits 180 degrees from the
## velocity vector -- the first version reported a peak of 180 for both tethers,
## which is just "the crate is behind me".
##
## Unlike the lateral offset this does not scale with tether length, so it
## separates "the crate swung hard" from "the crate is simply further away".
func _swing_deviation() -> float:
	var velocity: Vector3 = _ship.linear_velocity
	var span: Vector3 = _cargo.global_position - _ship.global_position
	if velocity.length_squared() < 0.01 or span.length_squared() < 0.01:
		return 0.0
	var astern: Vector3 = -velocity.normalized()
	return rad_to_deg(astern.angle_to(span.normalized()))


func _thrust_run(attached: bool, seconds: float, scale: float) -> float:
	_build(14.0)
	if not attached:
		_tether.release()
	var start: Vector3 = _ship.global_position
	_ship_force = Vector3(0.0, 0.0, -THRUST_MAIN * scale)
	await _step(int(seconds * Engine.physics_ticks_per_second))
	var travelled: float = _ship.global_position.distance_to(start)
	_teardown()
	return travelled


## Fresh ship, cargo and tether, with the cargo already at the rest length so
## nothing starts under tension.
func _build(rest_length: float) -> void:
	_rig = Node3D.new()
	add_child(_rig)

	_ship = _make_body(1000.0, Vector3(3.0, 1.6, 6.0), 3.0, 0.2)
	_cargo = _make_body(600.0, Vector3(1.8, 1.8, 2.4), -1.2, 0.35)
	_rig.add_child(_ship)
	_rig.add_child(_cargo)
	_ship.global_position = Vector3.ZERO
	# Anchor-to-anchor, not centre-to-centre. See ANCHOR_SPAN.
	_cargo.global_position = Vector3(0.0, 0.0, rest_length + ANCHOR_SPAN)

	_tether = TetherLink.new()
	_tether.ship = _ship
	_tether.cargo = _cargo
	_tether.ship_anchor = _ship.get_child(1) as Node3D
	_tether.cargo_anchor = _cargo.get_child(1) as Node3D
	_tether.rest_length = rest_length
	_rig.add_child(_tether)
	_ship_force = Vector3.ZERO


func _make_body(mass: float, size: Vector3, anchor_z: float, spin_damp: float) -> RigidBody3D:
	var body := RigidBody3D.new()
	body.mass = mass
	body.gravity_scale = 0.0
	body.can_sleep = false
	body.linear_damp_mode = RigidBody3D.DAMP_MODE_REPLACE
	body.linear_damp = 0.0
	body.angular_damp_mode = RigidBody3D.DAMP_MODE_REPLACE
	body.angular_damp = spin_damp
	var shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = size
	shape.shape = box
	body.add_child(shape)
	var anchor := Marker3D.new()
	anchor.position = Vector3(0.0, 0.0, anchor_z)
	body.add_child(anchor)
	return body


func _teardown() -> void:
	if _rig != null:
		_rig.queue_free()
		_rig = null
	_ship = null
	_cargo = null
	_tether = null
	_ship_force = Vector3.ZERO
	await _step(1)


func _step(frames: int) -> void:
	for _i: int in frames:
		await get_tree().physics_frame
