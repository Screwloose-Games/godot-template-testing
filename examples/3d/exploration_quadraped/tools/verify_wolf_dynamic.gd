extends Node

## Calibration sweep: the highest-value test in the project.
##
## Drives WolfGaitLadder.ground_animation_params() at a range of commanded speeds,
## advances the AnimationTree manually, and measures the root motion it actually
## produces. Asserts the measured speed matches the commanded speed.
##
## One test catches four separate classes of bug:
##   * arithmetic errors in the ladder or its Mobius inverse;
##   * a root-motion loop-wrap spike (the accumulated delta jumping by -D once per
##     cycle when the clip wraps) -- would show as a large negative bias, most
##     visible on gallop at 0.42 s/cycle;
##   * SYNC_MODE_CYCLIC_MUTABLE not behaving as documented;
##   * discontinuities where the four speed bands join.
##
## Runs as a scene (not --script) because AnimationTree.advance() needs a real
## node in a real tree:
##   Godot_v4.7.1-stable_win64_console.exe --headless \
##     --path <godot project root> res://examples/3d/exploration_quadraped/tools/verify_wolf_dynamic.tscn
##
## Instantiates wolf_animator.tscn, NOT wolf.tscn: this measures the animation rig
## and needs no CharacterBody3D, no collision and no physics. It therefore no
## longer incidentally proves that wolf.tscn loads -- verify_wolf_static.gd check 9
## and verify_wolf_runtime.tscn cover that.

const WolfGaitLadderScript := preload("../actors/wolf/wolf_gait_ladder.gd")
const WolfAnimatorScript := preload("../actors/wolf/wolf_animator.gd")
const WolfAnimatorScene := preload("../actors/wolf/wolf_animator.tscn")

const STEP: float = 1.0 / 60.0
## Number of full gait cycles to average over. Enough that any once-per-cycle
## wrap artefact shows up several times.
const CYCLES: float = 5.0
## Tolerance on mean speed, as a fraction of commanded.
const TOLERANCE: float = 0.05

const SAMPLES: PackedFloat32Array = [
	0.05, 0.10, 0.19, 0.30, 0.55, 0.76, 0.97, 1.20,
	1.47, 1.61, 1.76, 2.14, 2.50, 3.42, 4.64, 6.00,
]

var _failures: int = 0


func _ready() -> void:
	var animator: WolfAnimatorScript = WolfAnimatorScene.instantiate()
	add_child(animator)

	# MANUAL means the tree only advances when we call advance(), so the sweep is
	# deterministic and independent of frame timing. The animator's _ready() has
	# already run (children ready before parents) and left the tree active in the
	# Ground state; nothing has ticked it yet because no physics frame has passed.
	animator.set_manual_advance(true)
	animator.enter_ground()

	# The root motion delta arrives in the animated node's parent space. With the
	# 180-degree ModelPivot that is not the animator's space, so the animator
	# caches a correction -- read the production value rather than recomputing it.
	var basis_correction: Basis = animator.root_motion_basis()
	print("root motion basis correction:\n  x=%s\n  y=%s\n  z=%s" % [
			str(basis_correction.x), str(basis_correction.y), str(basis_correction.z)])
	if basis_correction.is_equal_approx(Basis.IDENTITY):
		printerr("FAIL: basis correction is identity -- the 180-degree pivot was not found")
		_failures += 1

	# Settle the state machine into Ground before measuring.
	for _i: int in 30:
		animator.advance(STEP)

	print("\n%-9s %-9s %-9s %-7s %-9s %-9s %s" % [
			"cmd m/s", "measured", "err %", "mix", "rate", "blend_pos", "verdict"])
	print("-".repeat(76))

	for commanded: float in SAMPLES:
		_measure(animator, commanded)

	print("-".repeat(76))
	print("\n=== %d failure(s) over %d samples ===" % [_failures, SAMPLES.size()])
	_quit(1 if _failures > 0 else 0)


func _measure(animator: WolfAnimatorScript, commanded: float) -> void:
	# Drive the tree through the SAME call the game makes every physics frame.
	# `params` below is recomputed only to print what that call applied -- same
	# function, same constant, so the two cannot drift.
	animator.update_ground(commanded)
	var params: Vector3 = WolfGaitLadderScript.ground_animation_params(
			commanded, WolfAnimatorScript.GAIT_RATE_MIN)

	# Let the Blend2 crossfade and the blend space weights settle at the new
	# parameters before sampling, so we measure steady state.
	for _i: int in 20:
		animator.advance(STEP)
		animator.measured_motion()

	# Cycle length at this blend position, used to pick a sane sample window.
	var cycle: float = _blended_cycle_length(params.z) / maxf(params.y, 0.001)
	var duration: float = maxf(cycle * CYCLES, 0.5)
	var steps: int = int(round(duration / STEP))

	var travelled: Vector3 = Vector3.ZERO
	var min_instant: float = INF
	var max_instant: float = -INF
	for _i: int in steps:
		animator.advance(STEP)
		var delta: Vector3 = animator.measured_motion()
		delta.y = 0.0
		travelled += delta
		var instant: float = delta.length() / STEP
		min_instant = minf(min_instant, instant)
		max_instant = maxf(max_instant, instant)

	var measured: float = travelled.length() / (float(steps) * STEP)
	var error_pct: float = 0.0
	if commanded > 0.0:
		error_pct = (measured - commanded) / commanded * 100.0

	var ok: bool = absf(error_pct) <= TOLERANCE * 100.0
	if not ok:
		_failures += 1
	print("%-9.3f %-9.4f %-+9.2f %-7.3f %-9.4f %-9.4f %s   [inst %.2f..%.2f]" % [
			commanded, measured, error_pct, params.x, params.y, params.z,
			"OK  " if ok else "FAIL", min_instant, max_instant])


## Blended cycle length T = sum(w_i * L_i) at a given blend position, matching
## what SYNC_MODE_CYCLIC_MUTABLE computes internally.
func _blended_cycle_length(blend_position: float) -> float:
	var last: int = WolfGaitLadderScript.gait_count() - 1
	var position: float = clampf(blend_position,
			WolfGaitLadderScript.gait_speed(0), WolfGaitLadderScript.gait_speed(last))
	var i: int = 0
	while i < last - 1 and position > WolfGaitLadderScript.gait_speed(i + 1):
		i += 1
	var low: float = WolfGaitLadderScript.gait_speed(i)
	var high: float = WolfGaitLadderScript.gait_speed(i + 1)
	var t: float = 0.0
	if not is_equal_approx(low, high):
		t = clampf((position - low) / (high - low), 0.0, 1.0)
	return lerpf(WolfGaitLadderScript.GAIT_LENGTHS[i],
			WolfGaitLadderScript.GAIT_LENGTHS[i + 1], t)


func _quit(code: int) -> void:
	get_tree().quit(code)
