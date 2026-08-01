class_name TentacleTuning
extends RefCounted

## Every number and every predicate that decides how a tentacle behaves.
##
## NO ENGINE DEPENDENCIES. Same contract as cargo_tether's TetherWinch and the
## jeep's JeepSurfaces: no node lookups, no raycasts, no `get_tree()`, no input, no
## `_physics_process`. It is arithmetic on values that are handed to it.
##
## That constraint is the entire point. The solver, the ribbon renderer and the
## verifier all need to agree on what "a valid anchor" means. If the predicate
## lives here, they agree by construction. If it lives in TentacleArray, the
## verifier has to re-implement it -- and then the test asserts what the test
## thinks the rule is, which is worth nothing.
##
## `[tuning]` in the static suite calls `invariant_failures()` below, so a bad edit
## to these constants fails a check rather than producing a creature that moves
## slightly wrong in a way nobody notices for a week.

## How many strands. Six is the smallest count that can hold a 2..4 planted band
## and still keep two in the air to look busy.
const TENTACLE_COUNT: int = 6

## Closer than this and the strand is a stub with no visible curve; the creature
## reads as studded rather than tentacled.
const REACH_MIN: float = 2.5
## Full extension, metres. Also the denominator for `slack_fraction()`, so it sets
## how quickly a strand straightens as it approaches full stretch.
const REACH_MAX: float = 14.0
## `normal.dot(-ray_dir)` floor. A grazing hit at 5 degrees is geometrically a hit
## and visually a tentacle stuck to nothing, because the pad lies in the wall plane
## and vanishes. 0.25 is about 75 degrees off-perpendicular.
const GRIP_FACING_MIN: float = 0.25
## Metres AHEAD of the body, measured along the travel direction, that an anchor
## must be to be worth taking.
##
## The most important predicate in this file. Without it the cone's rear lip finds
## the wall beside and slightly behind the creature every time -- those hits are
## nearer, so they win -- and the creature spends its whole life hauling itself
## backwards by one metre and then releasing. It reads as "the tentacles do not
## work" when in fact they work perfectly and are aimed wrong.
const FORWARD_BIAS_MIN: float = 1.5
## Two anchors closer than this fuse into what looks like one thick tentacle, and
## the creature loses a limb without losing the force.
const ANCHOR_MIN_SEPARATION: float = 1.8

## Seconds a strand must stay planted before any release condition may fire.
## Without it a strand can plant and release inside three ticks, which strobes.
const MIN_GRIP_TIME: float = 0.30
## Seconds after which a strand lets go regardless. Also the deadlock ceiling --
## see `invariant_failures()`.
const MAX_GRIP_TIME: float = 2.2
## Metres behind the body (negative is behind) at which a planted anchor is dead
## weight and should be released.
const RELEASE_BEHIND: float = -1.0
## The same test, further back, and this one OVERRIDES the `MIN_PLANTED` floor.
##
## Not optional. With only the soft test, two strands can both drift behind the
## body and both be held by the floor rule, at which case neither can release and
## neither can be replaced -- the creature stops dead in an open corridor with no
## error anywhere. The hard test is the escape hatch.
const RELEASE_BEHIND_HARD: float = -3.5
## Multiplier on REACH_MAX past which a strand is overstretched and lets go.
const OVERSTRETCH_FACTOR: float = 1.25
## Metres a confirmation ray may miss the anchor by before the wall counts as lost
## (it moved, or it was never really there).
const WALL_LOST_TOLERANCE: float = 0.35

## Seconds between strand launches, globally. One strand may enter REACHING per
## interval, no matter how many are idle. This is what stops all six firing on
## frame one and reading as a mechanism rather than an animal.
const FIRE_INTERVAL: float = 0.22
## Seconds before a failed search tries again.
const RETRY_DELAY: float = 0.25
## The drag must never have a gap, so at least this many strands stay planted.
const MIN_PLANTED: int = 2
## And no more than this many, which is what makes it look GANGLY. Six planted
## strands is a suspension bridge; four planted and two thrashing is a creature.
const MAX_PLANTED: int = 4

## Seconds a stroke takes, start to finish.
const STROKE_TIME: float = 0.34
## Base delay between planting and stroking. Scaled per strand by its phase so two
## strands that plant on the same tick still pull at different times.
const STROKE_DELAY_BASE: float = 0.28

## Cone half-angle around the travel direction that anchors are hunted in.
const CONE_HALF_ANGLE: float = 1.082
## And the inner edge. Never fire straight down the corridor axis -- in a tube that
## direction is either 200 m of nothing or the far end cap.
const CONE_MIN_ANGLE: float = 0.314
## Radians of azimuth jitter either side of a strand's assigned sector.
const SECTOR_JITTER: float = 0.45

## Ribbon half-width at the shoulder, metres.
##
## 0.13, not 0.22. The wider value gives a strand nearly as broad as the body is
## thick, and against a 2 m creature that reads as a SAIL rather than a tendril --
## the silhouette turns into a manta ray. Whatever this is set to, judge it against
## the body's own width in a capture, not against the number.
const ROOT_HALF_WIDTH: float = 0.13
## And at the tip. Not zero: a zero-width strip end is a degenerate triangle.
const TIP_HALF_WIDTH: float = 0.015
## Extra thickness right at the root, as a fraction, so the strand reads as growing
## out of the body rather than being glued to it.
const ROOT_BULGE: float = 0.5

## The golden angle. Spreads N phases over a circle more evenly than any rational
## fraction, so no two strands ever share a writhe cycle however many there are.
const GOLDEN_ANGLE: float = 2.39996


## The stroke's force envelope, over `u` in 0..1. A raised cosine: zero force and
## zero SLOPE at both ends, so a stroke neither starts nor stops with a jerk.
##
## Its integral over 0..1 is exactly 0.5, which is the useful part -- it means one
## stroke delivers `stroke_gain * STROKE_TIME * 0.5` metres per second of delta-v,
## and that is a number you can reason about instead of tune blindly.
static func stroke_envelope(u: float) -> float:
	if u <= 0.0 or u >= 1.0:
		return 0.0
	return 0.5 - 0.5 * cos(TAU * u)


## Is this candidate hit worth planting on? All four tests, in the order that
## rejects fastest. `ahead` is the hit's distance along the travel direction from
## the body; `facing` is `normal.dot(-ray_dir)`; `nearest_other` is the distance to
## the closest live anchor, or a large number when there are none.
static func is_anchor_valid(
	distance: float, facing: float, ahead: float, nearest_other: float
) -> bool:
	if distance < REACH_MIN or distance > REACH_MAX:
		return false
	if ahead <= FORWARD_BIAS_MIN:
		return false
	if facing <= GRIP_FACING_MIN:
		return false
	return nearest_other > ANCHOR_MIN_SEPARATION


## Should a planted strand let go? `behind` is metres along the travel direction
## (negative is behind the body), `stretch` is shoulder-to-anchor distance, `age`
## is seconds held, `lost` is whether the confirmation ray missed.
##
## The MIN_GRIP_TIME guard is checked FIRST and beats everything except a lost
## wall -- a wall that stopped existing is not a strand we may keep holding.
static func should_release(
	behind: float, stretch: float, age: float, lost: bool, planted_count: int
) -> bool:
	if lost:
		return true
	if age < MIN_GRIP_TIME:
		return false
	if behind < RELEASE_BEHIND_HARD:
		return true  # Overrides the MIN_PLANTED floor. See the const's comment.
	if planted_count <= MIN_PLANTED:
		return false
	return (
		behind < RELEASE_BEHIND or stretch > REACH_MAX * OVERSTRETCH_FACTOR or age > MAX_GRIP_TIME
	)


## How much a strand of this length should bow, as a fraction of its own length.
##
## Solved from the reach rather than picked, exactly as cargo_tether's TetherLine
## solves its sagitta from the slack: a strand at full stretch goes dead straight
## and a short one coils. The straightening is then a free readout of "this one is
## hauling hard", and it costs nothing because it is just the geometry being honest.
static func slack_fraction(chord: float) -> float:
	return 0.12 + 0.55 * clampf(1.0 - chord / REACH_MAX, 0.0, 1.0)


## Ribbon half-width at parameter `t` (0 at the shoulder, 1 at the tip), thinned
## while the strand is still extending so a flying tentacle reads as thinner and
## faster than a planted one hauling.
static func taper_half_width(t: float, extend_fraction: float) -> float:
	var base: float = lerpf(ROOT_HALF_WIDTH, TIP_HALF_WIDTH, smoothstep(0.0, 1.0, t))
	var bulge: float = 1.0 + ROOT_BULGE * (1.0 - t) * (1.0 - t)
	return base * bulge * (0.55 + 0.45 * clampf(extend_fraction, 0.0, 1.0))


## Each strand's fixed phase, spread by the golden angle.
static func phase_for(index: int) -> float:
	return fmod(float(index) * GOLDEN_ANGLE, TAU)


## Seconds between planting and stroking, for this strand. Scaled by its phase, so
## the stagger survives two strands planting on the same tick.
static func stroke_delay_for(index: int) -> float:
	return STROKE_DELAY_BASE * (0.4 + 0.6 * phase_for(index) / TAU)


## Every constraint these constants must satisfy. Returns the failures as strings
## so `[tuning]` can print WHICH one broke rather than just refusing to run.
static func invariant_failures() -> PackedStringArray:
	var bad: PackedStringArray = PackedStringArray()
	if REACH_MIN >= REACH_MAX:
		bad.append("REACH_MIN must be below REACH_MAX")
	if MIN_PLANTED >= MAX_PLANTED or MAX_PLANTED > TENTACLE_COUNT:
		bad.append("need MIN_PLANTED < MAX_PLANTED <= TENTACLE_COUNT")
	if MIN_GRIP_TIME >= MAX_GRIP_TIME:
		bad.append("MIN_GRIP_TIME must be below MAX_GRIP_TIME")
	if STROKE_TIME <= 0.0 or STROKE_DELAY_BASE < 0.0:
		bad.append("STROKE_TIME must be positive and STROKE_DELAY_BASE non-negative")
	if RELEASE_BEHIND_HARD >= RELEASE_BEHIND:
		bad.append("RELEASE_BEHIND_HARD must be further back than RELEASE_BEHIND")
	if CONE_MIN_ANGLE >= CONE_HALF_ANGLE:
		bad.append("CONE_MIN_ANGLE must be inside CONE_HALF_ANGLE")
	# The starvation deadlock. If a full round of launches takes longer than a grip
	# lasts, the earliest strands time out before the last one has ever fired, and
	# the creature permanently runs on two tentacles. The only symptom is "only two
	# of them ever move", which looks like a rendering bug.
	if FIRE_INTERVAL * float(TENTACLE_COUNT) >= MAX_GRIP_TIME:
		bad.append("FIRE_INTERVAL * TENTACLE_COUNT must stay under MAX_GRIP_TIME")
	return bad
