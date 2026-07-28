class_name WolfGaitLadder
extends RefCounted

## Speed <-> blend_position mapping for a cyclic-synced quadruped gait ladder.
##
## Each gait clip in grey-wolf-gaits-and-jump.glb has forward root motion baked
## into its "wolf_rig/grey_wolf" position track: stride D metres over clip length
## L seconds. That makes every gait a known ground speed v = D / L, so the six
## clips form a strictly monotonic speed ladder and the blend space can simply be
## indexed by metres per second.
##
## The catch: under AnimationNodeBlendSpace1D.SYNC_MODE_CYCLIC_MUTABLE the engine
## scales each blend point's delta by L_i / T, where T = sum(w_i * L_i). That is
## what phase-locks the clips (every point's normalised phase then advances at
## delta / T, identically), but it means the ground speed the tree produces is
##
##     s = sum(w_i * D_i) / sum(w_i * L_i)
##
## -- blended stride over blended cycle length. Physically exact, but a ratio of
## blends rather than a blend of ratios, so it is NOT equal to sum(w_i * v_i),
## which is what blend_position would naively be. Ignoring the difference costs
## up to 4.5% foot slip mid-blend (worst on walk->amble and canter->gallop).
##
## `blend_position_for_speed()` inverts the relation in closed form, so the ladder
## is phase-locked AND speed-exact at the same time.

## Blend point names, ordered by ascending speed. These are also the animation
## names in the imported GLB -- the glTF importer strips the "-loop" suffix, so
## "walk-loop" in the source file arrives as "walk".
const GAIT_NAMES: PackedStringArray = [
	"walk", "amble", "pace", "trot", "canter", "gallop",
]

## Clip length in seconds (L). Verified against the imported AnimationPlayer.
const GAIT_LENGTHS: PackedFloat32Array = [1.00, 0.72, 0.58, 0.54, 0.56, 0.42]

## Baked forward root motion per cycle in metres (D). Verified against the
## "wolf_rig/grey_wolf" position track of each clip.
const GAIT_STRIDES: PackedFloat32Array = [0.55, 0.70, 0.85, 0.95, 1.40, 1.95]


## Ground speed a single gait produces when played at its native rate.
static func gait_speed(index: int) -> float:
	return GAIT_STRIDES[index] / GAIT_LENGTHS[index]


## Speed of the slowest gait (walk, 0.55 m/s). Below this the walk cycle is
## played back slower rather than blended with anything.
static func slowest_speed() -> float:
	return gait_speed(0)


## Speed of the fastest gait (gallop, ~4.64 m/s). Above this the whole ladder is
## time-scaled up via the GaitRate node.
static func fastest_speed() -> float:
	return gait_speed(GAIT_NAMES.size() - 1)


static func gait_count() -> int:
	return GAIT_NAMES.size()


## The three Ground-state AnimationTree parameters for a given ground speed,
## packed as (idle_mix, gait_rate, blend_position). Returned as a Vector3 rather
## than a Dictionary because this runs every physics frame and a Vector3 is a
## stack value with no allocation.
##
## Four continuous bands, every one of them exactly speed-matched. Both mix and
## rate scale the animated root motion linearly, so:
##
##   v <= creep       walk pinned at `gait_rate_min`, crossfading toward idle
##                    -> (v/creep) * 0.55 * 0.35            == v
##   creep < v < walk walk at full weight, rate v / walk_speed
##                    -> 1 * 0.55 * (v/0.55)                == v
##   walk <= v <= top full weight, native rate, exact Mobius inverse
##                    -> blended_speed(inverse(v))          == v
##   v > top          gallop pinned, rate scales past 1.0
##                    -> 4.643 * (v/4.643)                  == v
##
## Continuous across every band join, so there is no pop at the thresholds.
## `tools/verify_wolf_dynamic.gd` drives this exact function and measures the
## resulting root motion, so the identities above are tested, not just asserted.
static func ground_animation_params(speed: float, gait_rate_min: float) -> Vector3:
	var walk_gait_speed: float = slowest_speed()
	var top_gait_speed: float = fastest_speed()
	var creep_speed: float = walk_gait_speed * gait_rate_min

	if speed <= creep_speed:
		var mix: float = 0.0
		if not is_zero_approx(creep_speed):
			mix = clampf(speed / creep_speed, 0.0, 1.0)
		return Vector3(mix, gait_rate_min, walk_gait_speed)

	if speed < walk_gait_speed:
		return Vector3(1.0, speed / walk_gait_speed, walk_gait_speed)

	var rate: float = 1.0
	if speed > top_gait_speed:
		rate = speed / top_gait_speed
	return Vector3(1.0, rate, blend_position_for_speed(speed))


## Index of the gait carrying the most weight at `speed`, i.e. the nearest blend
## point. Purely informational -- used for the `gait_changed` signal and debug
## readouts, never for driving the blend.
static func dominant_gait_index(speed: float) -> int:
	var best: int = 0
	var best_distance: float = absf(speed - gait_speed(0))
	for i: int in range(1, GAIT_NAMES.size()):
		var distance: float = absf(speed - gait_speed(i))
		if distance < best_distance:
			best_distance = distance
			best = i
	return best


static func dominant_gait_name(speed: float) -> StringName:
	return StringName(GAIT_NAMES[dominant_gait_index(speed)])


## Ground speed the tree actually produces when blending `index` -> `index + 1`
## with linear weight `t`. This is the forward direction of the relation that
## `blend_position_for_speed()` inverts; the calibration test uses it directly.
static func blended_speed(index: int, t: float) -> float:
	var stride: float = lerpf(GAIT_STRIDES[index], GAIT_STRIDES[index + 1], t)
	var length: float = lerpf(GAIT_LENGTHS[index], GAIT_LENGTHS[index + 1], t)
	return stride / length


## Exact inverse of `blended_speed()`. Returns the blend_position that makes the
## tree's root motion equal `speed`.
##
## Within a segment only two points carry weight, so solving
##     (1 - t) * D_i + t * D_j = s * [(1 - t) * L_i + t * L_j]
## for t gives
##     t = (s * L_i - D_i) / [(D_j - s * L_j) - (D_i - s * L_i)]
## which is a monotonic Mobius function of t and therefore uniquely invertible.
## Sanity: s == v_i gives t == 0; s == v_j makes numerator == denominator, t == 1.
##
## Because the blend points sit at their own implied speeds, the returned value
## still reads as "roughly metres per second" when inspected in the debugger.
static func blend_position_for_speed(speed: float) -> float:
	var last: int = GAIT_NAMES.size() - 1
	var clamped: float = clampf(speed, gait_speed(0), gait_speed(last))

	# Find the segment [i, i + 1] containing `clamped`.
	var i: int = 0
	while i < last - 1 and clamped > gait_speed(i + 1):
		i += 1

	var length_lo: float = GAIT_LENGTHS[i]
	var length_hi: float = GAIT_LENGTHS[i + 1]
	var stride_lo: float = GAIT_STRIDES[i]
	var stride_hi: float = GAIT_STRIDES[i + 1]

	var denominator: float = (stride_hi - clamped * length_hi) \
			- (stride_lo - clamped * length_lo)
	var t: float = 0.0
	if not is_zero_approx(denominator):
		t = clampf((clamped * length_lo - stride_lo) / denominator, 0.0, 1.0)

	return lerpf(gait_speed(i), gait_speed(i + 1), t)
