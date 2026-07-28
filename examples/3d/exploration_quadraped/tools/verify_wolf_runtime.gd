extends Node

## End-to-end runtime test: drives the real demo world with simulated input and
## asserts the controller and its animator behave.
##
## The load-bearing assertion is NO SLIDE. Every gait clip has forward root motion
## baked in, so if the root motion track ever stops matching its node exactly, the
## mixer writes the track and the model creeps forward and snaps back once per
## cycle. WolfAnimator.root_motion_slide() reports that drift directly.
##
## This test needs the wolf in a real world, so it goes through the %Animator
## facade rather than reaching into the rig -- see "Component boundaries" in
## CLAUDE.md. The rig's internals are covered by verify_wolf_static/dynamic, which
## instantiate wolf_animator.tscn directly.
##
## Usage (headless is fine -- physics does not need a rendering device):
##   Godot_v4.7.1-stable_win64_console.exe --headless \
##     --path <godot project root> res://examples/3d/exploration_quadraped/tools/verify_wolf_runtime.tscn

const DemoWorld := preload("../scenes/demo_world.tscn")
const WolfAnimatorScript := preload("../actors/wolf/wolf_animator.gd")

## Anything beyond this counts as the baked slide leaking through.
const SLIDE_TOLERANCE: float = 0.01

var _failures: int = 0
var _wolf: CharacterBody3D = null
var _animator: WolfAnimatorScript = null

# Signal flags must be members, not locals captured by a lambda: GDScript closures
# capture local variables BY VALUE, so writing to a captured local from inside the
# handler updates the closure's copy and the outer variable never changes.
var _jump_fired: bool = false
var _landed_impact: float = -1.0


func _ready() -> void:
	var world: Node = DemoWorld.instantiate()
	add_child(world)

	_wolf = world.get_node_or_null("Wolf") as CharacterBody3D
	if _wolf == null:
		printerr("FATAL: Wolf not found")
		get_tree().quit(1)
		return

	_animator = _wolf.get_node_or_null("%Animator") as WolfAnimatorScript
	if _animator == null:
		printerr("FATAL: %Animator not found under the Wolf")
		get_tree().quit(1)
		return

	await _run()

	print("\n=== %d failure(s) ===" % _failures)
	get_tree().quit(1 if _failures > 0 else 0)


func _fail(message: String) -> void:
	_failures += 1
	printerr("  FAIL: %s" % message)


func _pass(message: String) -> void:
	print("  ok: %s" % message)


## Waits `frames` physics frames, tracking the worst slide seen on the root motion
## node and the peak horizontal speed.
func _step(frames: int) -> Dictionary:
	var worst_slide: float = 0.0
	var peak_speed: float = 0.0
	var grounded_frames: int = 0
	var peak_height: float = -INF
	for _i: int in frames:
		await get_tree().physics_frame
		worst_slide = maxf(worst_slide, _animator.root_motion_slide())
		peak_speed = maxf(peak_speed, _wolf.horizontal_speed)
		peak_height = maxf(peak_height, _wolf.global_position.y)
		if _wolf.is_on_floor():
			grounded_frames += 1
	return {
		"worst_slide": worst_slide,
		"peak_speed": peak_speed,
		"grounded_frames": grounded_frames,
		"peak_height": peak_height,
	}


func _run() -> void:
	# Let the wolf settle onto the ground.
	var settle: Dictionary = await _step(30)
	print("\n[settle]")
	if settle["grounded_frames"] > 20:
		_pass("landed on the ground (%d/30 frames grounded)" % settle["grounded_frames"])
	else:
		_fail("never settled on the floor (%d/30 frames grounded)"
				% settle["grounded_frames"])
	print("  wolf position: %s" % str(_wolf.global_position))

	# --- Sprint forward -------------------------------------------------------
	print("\n[sprint forward, 2.5 s]")
	var start_position: Vector3 = _wolf.global_position
	Input.action_press(&"move_forward")
	Input.action_press(&"sprint")
	var sprint: Dictionary = await _step(150)
	Input.action_release(&"move_forward")
	Input.action_release(&"sprint")

	var travelled: Vector3 = _wolf.global_position - start_position
	var planar_travel: float = Vector2(travelled.x, travelled.z).length()
	print("  travelled %.3f m, peak speed %.3f m/s" % [planar_travel, sprint["peak_speed"]])
	print("  worst root motion offset: %.6f m" % sprint["worst_slide"])

	if planar_travel > 5.0:
		_pass("the wolf actually moved (%.2f m)" % planar_travel)
	else:
		_fail("barely moved: %.3f m in 2.5 s of held sprint" % planar_travel)

	if absf(sprint["peak_speed"] - _wolf.sprint_speed) <= _wolf.sprint_speed * 0.1:
		_pass("reached sprint_speed (%.3f vs %.3f)"
				% [sprint["peak_speed"], _wolf.sprint_speed])
	else:
		_fail("peak speed %.3f is not within 10%% of sprint_speed %.3f"
				% [sprint["peak_speed"], _wolf.sprint_speed])

	# THE critical assertion.
	if sprint["worst_slide"] <= SLIDE_TOLERANCE:
		_pass("NO SLIDE -- the model held its rest position (max %.6f m)"
				% sprint["worst_slide"])
	else:
		_fail("SLIDE DETECTED: the model drifted %.4f m from rest -- the baked "
				% sprint["worst_slide"]
				+ "forward motion is not being cancelled. %s" % _animator.debug_report())

	# Moved forward means -Z in the wolf's own frame; confirm it did not reverse.
	var forward: Vector3 = -_wolf.global_transform.basis.z
	var alignment: float = travelled.normalized().dot(forward)
	print("  travel/forward alignment: %.3f" % alignment)
	if alignment > 0.9:
		_pass("moved nose-first, not tail-first")
	else:
		_fail("travel direction does not match facing (dot %.3f). Either the yaw "
				% alignment
				+ "formula or the 180-degree ModelPivot has the wrong sign.")

	# --- Deceleration ---------------------------------------------------------
	print("\n[release input, 1 s]")
	var coast: Dictionary = await _step(60)
	print("  speed now %.4f m/s, worst slide %.6f" % [
			_wolf.horizontal_speed, coast["worst_slide"]])
	if _wolf.horizontal_speed < 0.05:
		_pass("braked to a stop")
	else:
		_fail("still moving at %.4f m/s a second after input released"
				% _wolf.horizontal_speed)

	# --- Jump ----------------------------------------------------------------
	print("\n[jump]")
	_wolf.jumped.connect(_on_wolf_jumped)
	_wolf.landed.connect(_on_wolf_landed)

	Input.action_press(&"jump")
	await get_tree().physics_frame
	await get_tree().physics_frame
	Input.action_release(&"jump")

	var airborne_seen: bool = false
	var air_state_seen: bool = false
	var peak_height: float = _wolf.global_position.y
	for _i: int in 90:
		await get_tree().physics_frame
		if not _wolf.is_on_floor():
			airborne_seen = true
		if _animator.is_air_state_active():
			air_state_seen = true
		peak_height = maxf(peak_height, _wolf.global_position.y)

	print("  jumped signal: %s, left the ground: %s, Airborne state: %s" % [
			str(_jump_fired), str(airborne_seen), str(air_state_seen)])
	print("  peak height %.3f m, landed impact %.3f" % [peak_height, _landed_impact])

	if _jump_fired:
		_pass("jump fired")
	else:
		_fail("jump input did not produce a jump")
	if airborne_seen:
		_pass("left the ground")
	else:
		_fail("never left the ground")
	if air_state_seen:
		_pass("state machine travelled to Airborne")
	else:
		_fail("state machine never entered Airborne")
	if _landed_impact >= 0.0:
		_pass("landed signal fired (impact %.2f m/s)" % _landed_impact)
	else:
		_fail("never landed again")
	if _animator.is_ground_state_active():
		_pass("back in the Ground state after landing")
	else:
		_fail("not back on the ground after landing -- %s" % _animator.debug_report())

	await _test_slopes()
	await _test_step()


## Walks the wolf up each ramp. Beyond checking floor_max_angle this is the real
## test for Jolt catching a capsule on the seam where the ramp emerges from the
## ground (godot-jolt#952) -- a catch shows up as zero height gain.
func _test_slopes() -> void:
	print("\n[slopes] driving up each ramp at cruise speed")
	# Ramps are 4 x 1 x 9 boxes rotated -angle about X, centred at z = 8, so their
	# top face breaks the ground plane between z = 6.0 (10 deg) and z = 7.5 (55 deg).
	# Approaching from z = 3.5 clears all of them.
	var ramps: Array = [
		["Ramp10", -14.0, 10.0, true],
		["Ramp25", -8.0, 25.0, true],
		["Ramp40", -2.0, 40.0, true],
		# 55 degrees sits exactly on floor_max_angle, so the outcome is genuinely
		# ambiguous -- reported, not asserted.
		["Ramp55", 4.0, 55.0, false],
	]

	for ramp: Array in ramps:
		var ramp_name: String = ramp[0]
		var x: float = ramp[1]
		var angle: float = ramp[2]
		var must_climb: bool = ramp[3]

		_wolf.velocity = Vector3.ZERO
		_wolf.global_position = Vector3(x, 0.2, 3.5)
		_wolf.rotation.y = 0.0
		await _step(20)
		var base_height: float = _wolf.global_position.y

		# move_back drives +Z, which is uphill (the ramps rise toward +Z).
		Input.action_press(&"move_back")
		var result: Dictionary = await _step(210)
		Input.action_release(&"move_back")
		await _step(15)

		var gain: float = maxf(result["peak_height"], _wolf.global_position.y) - base_height
		var climbed: bool = gain > 0.35
		print("  %-8s %2.0f deg  height gain %+6.3f m  z=%.2f  slide %.6f  %s" % [
				ramp_name, angle, gain, _wolf.global_position.z,
				result["worst_slide"], "CLIMBED" if climbed else "blocked"])

		if result["worst_slide"] > SLIDE_TOLERANCE:
			_fail("%s: the model slid %.4f m while climbing"
					% [ramp_name, result["worst_slide"]])
		if must_climb and not climbed:
			_fail("%s (%.0f deg) should be climbable but gained only %+.3f m. If the "
					% [ramp_name, angle, gain]
					+ "wolf stopped dead at the ramp's base, suspect Jolt catching the "
					+ "capsule on the ground/ramp seam.")
		elif must_climb:
			_pass("%s climbed" % ramp_name)


## max_step_height is 0.3, so the 0.2 m step must be climbable and the 0.4 m step
## must not be. Asserting both directions proves the probe is selective rather
## than teleporting the wolf over anything it touches.
func _test_step() -> void:
	print("\n[steps] max_step_height = %.2f m" % _wolf.max_step_height)
	# Step20 is 4 x 0.2 x 2 centred at (10, 0.1, -4); Step40 is 4 x 0.4 x 2 at
	# (15, 0.2, -4). Both are approached from z = -1 travelling -Z.
	var steps: Array = [
		["Step20", 10.0, 0.2, true],
		["Step40", 15.0, 0.4, false],
	]

	for step_case: Array in steps:
		var step_name: String = step_case[0]
		var x: float = step_case[1]
		var height: float = step_case[2]
		var must_climb: bool = step_case[3]

		_wolf.velocity = Vector3.ZERO
		_wolf.global_position = Vector3(x, 0.2, -1.0)
		_wolf.rotation.y = 0.0
		await _step(20)
		var base_height: float = _wolf.global_position.y

		Input.action_press(&"move_forward")
		var result: Dictionary = await _step(150)
		Input.action_release(&"move_forward")
		await _step(15)

		# Measure PEAK height, not final: the platform is only 2 m deep, so the wolf
		# climbs it and walks straight off the far side back down to ground level,
		# leaving the final height at 0 even on a successful climb.
		var gain: float = result["peak_height"] - base_height
		var climbed: bool = gain > height * 0.6
		print("  %-7s %.1f m  peak gain %+.3f m  final z=%.2f  slide %.6f  %s" % [
				step_name, height, gain, _wolf.global_position.z,
				result["worst_slide"], "CLIMBED" if climbed else "blocked"])

		if result["worst_slide"] > SLIDE_TOLERANCE:
			_fail("%s: the model slid %.4f m" % [step_name, result["worst_slide"]])
		if must_climb and not climbed:
			_fail("%s (%.1f m) is under max_step_height %.2f but was not climbed"
					% [step_name, height, _wolf.max_step_height])
		elif not must_climb and climbed:
			_fail("%s (%.1f m) is above max_step_height %.2f and should have blocked "
					% [step_name, height, _wolf.max_step_height]
					+ "the wolf, but it climbed anyway")
		else:
			_pass("%s behaved as expected (%s)"
					% [step_name, "climbed" if climbed else "blocked"])


func _on_wolf_jumped() -> void:
	_jump_fired = true


func _on_wolf_landed(impact_speed: float) -> void:
	_landed_impact = impact_speed
