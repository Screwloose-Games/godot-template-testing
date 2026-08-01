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

## How many strands. EIGHT BECAUSE THE MODEL HAS EIGHT -- this is a property of
## `assets/models/cosmic-horror.glb`, not a taste call, and CrawlerRig will report a
## mismatch if the model is ever re-exported with a different number.
const TENTACLE_COUNT: int = 8

## Closer than this and the strand is a stub with no visible curve; the creature
## reads as studded rather than tentacled.
##
## 2.0, down from 2.5, because reach is now PHYSICAL. The model's shortest chain
## usefully reaches 3.44 m; at 2.5 that strand had barely a metre of legal band and
## spent most of its life in SEARCHING.
const REACH_MIN: float = 2.0
## Ceiling on reach, metres. This is the RAY LENGTH and the global upper bound; the
## per-strand limits from `CrawlerRig.chain_reach()` are what actually bind, because a
## 14-bone tentacle and a 23-bone one cannot reach the same distance.
##
## Was 14.0, which was fiction once the strands became real geometry: the solver would
## hand a strand an anchor 9 m away, the poser would run out of chain, and the tip
## would hang in space beside a wall pad claiming it was gripping. 7.6 clears the
## longest chain's 7.53 m and nothing more. It also normalises the polar bias in
## `TentacleArray._pick_anchor`, so setting it above the longest chain would quietly
## make every strand behave as though it were shorter than it is.
const REACH_MAX: float = 7.6
## Fraction of a chain's true length that counts as its usable reach.
##
## A chain at 100% is dead straight, and the sag IS the "this one is hauling" readout.
## Spending all of it on distance throws that away and the creature walks on stilts.
const REACH_SAFETY: float = 0.92
## `normal.dot(-ray_dir)` floor. A grazing hit at 5 degrees is geometrically a hit
## and visually a tentacle stuck to nothing, because the pad lies in the wall plane
## and vanishes. 0.25 is about 75 degrees off-perpendicular.
const GRIP_FACING_MIN: float = 0.25
## Metres AHEAD OF ITS OWN SHOULDER, measured along the travel direction, that an
## anchor must be to be worth taking.
##
## The most important predicate in this file. Without it the cone's rear lip finds
## the wall beside and slightly behind the creature every time -- those hits are
## nearer, so they win -- and the creature spends its whole life hauling itself
## backwards by one metre and then releasing. It reads as "the tentacles do not
## work" when in fact they work perfectly and are aimed wrong.
##
## MEASURED FROM THE SHOULDER, NOT THE BODY CENTRE. On a 3.6 m creature the rear
## sockets sit half a metre behind the centre, so a centre-relative rule quietly asked
## those limbs for 2.0 m of forward reach instead of 1.5 -- and the two shortest could
## only satisfy it by angling so far forward that the wall fell outside their reach.
## They missed 9 searches out of 10 and never gripped anything. The shoulder is also
## the correct origin on its own terms: `anchor - shoulder` is the exact vector the
## stroke force uses, so this now gates on the thing it is actually trying to predict.
const FORWARD_BIAS_MIN: float = 1.5
## Two anchors closer than this fuse into what looks like one thick tentacle, and
## the creature loses a limb without losing the force.
##
## 1.4, down from 1.8, and the reason is the strand count rather than the look: eight
## anchors each 1.8 m from every other will not fit on the reachable wall of a 4.5 m
## corridor, so searches fail, strands sit in SEARCHING, and the creature runs on
## three tentacles in an open tube. Separation is the first lever here; MAX_PLANTED is
## the second.
const ANCHOR_MIN_SEPARATION: float = 1.4

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
## Multiplier on the strand's OWN reach past which it is overstretched and lets go.
##
## Deliberately UNDER `TentacleBones.STRETCH_MAX` (1.12). The poser can stretch a link
## by 12% to swallow a chord longer than the chain; past that it clamps and the tip
## visibly parts company with the anchor it is supposedly holding. Releasing at 1.08
## means a strand always lets go BEFORE it reaches that point, so the detachment is
## never seen. The two numbers are a pair -- move one and move the other.
const OVERSTRETCH_FACTOR: float = 1.08
## Metres a confirmation ray may miss the anchor by before the wall counts as lost
## (it moved, or it was never really there).
const WALL_LOST_TOLERANCE: float = 0.35

## Seconds between strand launches, globally. One strand may enter REACHING per
## interval, no matter how many are idle. This is what stops all eight firing on
## frame one and reading as a mechanism rather than an animal.
##
## 0.18, down from 0.22, because the deadlock guard at the bottom of this file scales
## with the strand count: at eight strands a full round of launches took 1.76 s
## against a 2.2 s grip ceiling, which passes the assert and still leaves almost no
## margin for a strand that has to retry a failed search.
const FIRE_INTERVAL: float = 0.18
## Seconds before a failed search tries again.
const RETRY_DELAY: float = 0.25
## The drag must never have a gap, so at least this many strands stay planted.
const MIN_PLANTED: int = 3
## And no more than this many, which is what makes it look GANGLY. Eight planted
## strands is a suspension bridge; five planted and three thrashing is a creature.
const MAX_PLANTED: int = 5

## Seconds a stroke takes, start to finish.
const STROKE_TIME: float = 0.34
## Base delay between planting and stroking. Scaled per strand by its phase so two
## strands that plant on the same tick still pull at different times.
const STROKE_DELAY_BASE: float = 0.28

## Cone half-angle around the travel direction that anchors are hunted in.
##
## 1.40 (80 degrees), up from 1.082. The outer edge of the cone is the only part a
## short strand can use -- see the polar bias in `TentacleArray._pick_anchor` -- because
## the near-perpendicular ray is the SHORT path to a wall. At 1.082 the model's 14- and
## 15-bone arms missed 8 and 9 searches out of 9 while every other strand missed at most
## one: they were getting launch slots and simply could not reach what they were aimed
## at. Widening the cone is what gives them anywhere to grip.
const CONE_HALF_ANGLE: float = 1.40
## And the inner edge. Never fire straight down the corridor axis -- in a tube that
## direction is either 200 m of nothing or the far end cap.
const CONE_MIN_ANGLE: float = 0.314
## How much wider a strand's azimuth jitter grows per consecutive failed search, as a
## fraction of SECTOR_JITTER, and how many failures that keeps counting for. The escape
## hatch that stops a strand aimed at an unreachable part of the tube from sitting in
## SEARCHING forever -- see `TentacleArray._pick_anchor`.
const STARVE_WIDEN: float = 0.75
const STARVE_LIMIT: int = 4

## Fraction of its own reach a strand would rather be holding at.
##
## 0.8 leaves room to be hauled past the anchor before it has to let go, and -- more
## importantly -- it makes strands of different lengths hunt at DIFFERENT distances, so
## the long ones stop camping the near wall that the short ones cannot reach past.
const PREFERRED_REACH: float = 0.8

## Radians of azimuth jitter either side of a strand's assigned sector.
##
## 0.30, down from 0.45, because eight sectors are narrower than six and the relaxed
## ring below leaves a minimum neighbour gap of about 0.68 rad. Jitter wider than half
## that and two strands can wander into each other's cone, which is the failure the
## sectors exist to prevent.
const SECTOR_JITTER: float = 0.30
## How far each strand's search sector is pulled from where its socket actually points
## toward an evenly spaced ring. 0 hunts straight out of the socket, 1 ignores the
## model entirely.
##
## Neither end works. The model's eight sockets sit in FOUR PAIRS -- roughly plus and
## minus 50 and 130 degrees -- so raw socket azimuths put two strands in one cone and
## leave the four quadrant centres unhunted, and the creature grows a beard on four
## sides. A pure even ring is worse in the other direction: it sends the low leg
## tentacles hunting the ceiling and crosses them over each other. Relaxing most of the
## way keeps arms high and legs low and still tiles the circle.
##
## 0.85 was measured, not guessed: `[sectors]` prints the tightest neighbour gap, and
## it has to beat what SECTOR_JITTER can close. At 0.55 the gap was 0.117 rad against a
## 0.60 rad jitter span -- four pairs of strands still hunting one patch of wall each.
const SECTOR_RELAX: float = 0.85

## Bounds on a posed link's length, as a multiple of the model's own 0.24 m.
##
## DELIBERATELY NARROW. The poser spreads a chain along its curve, and where the curve
## is shorter than the chain the surplus is meant to COIL at the tip -- that is what a
## tentacle does with slack. Letting the links absorb it instead, which a wide band
## does, makes the whole limb shorten and lengthen as it reaches and reads as rubber.
## Bone SCALE is never touched, only this spacing, so the voxel cubes stay cubes; they
## overlap about five deep at rest, so 12% of spacing opens no visible gap.
const STRETCH_MIN: float = 0.90
const STRETCH_MAX: float = 1.12

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
## `reach_max` is THIS STRAND's limit, not the global one -- the model's chains run
## from 14 links to 23, so a single ceiling either starves the short ones or hands the
## long ones anchors they cannot touch.
static func is_anchor_valid(
	distance: float, facing: float, ahead: float, nearest_other: float, reach_max: float
) -> bool:
	if distance < REACH_MIN or distance > minf(reach_max, REACH_MAX):
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
	behind: float, stretch: float, age: float, lost: bool, planted_count: int, reach_max: float
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
		behind < RELEASE_BEHIND or stretch > reach_max * OVERSTRETCH_FACTOR or age > MAX_GRIP_TIME
	)


## How much a strand of this length should bow, as a fraction of its own length.
##
## Solved from the reach rather than picked, exactly as cargo_tether's TetherLine
## solves its sagitta from the slack: a strand at full stretch goes dead straight
## and a short one coils. The straightening is then a free readout of "this one is
## hauling hard", and it costs nothing because it is just the geometry being honest.
## Measured against THIS STRAND's reach, so a 14-link tentacle at 2.6 m reads as taut
## and a 23-link one at the same distance reads as slack -- which is exactly what a
## creature with limbs of different lengths should look like.
static func slack_fraction(chord: float, reach_max: float) -> float:
	return 0.12 + 0.55 * clampf(1.0 - chord / maxf(reach_max, 0.001), 0.0, 1.0)


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
	if REACH_SAFETY <= 0.0 or REACH_SAFETY >= 1.0:
		bad.append("REACH_SAFETY must leave a chain some sag: 0 < REACH_SAFETY < 1")
	if SECTOR_RELAX < 0.0 or SECTOR_RELAX > 1.0:
		bad.append("SECTOR_RELAX must be a 0..1 blend")
	# Jitter wider than half the narrowest sector gap lets two strands hunt the same
	# patch of wall, which is the whole thing sectors exist to stop.
	if SECTOR_JITTER * 2.0 >= TAU / float(TENTACLE_COUNT):
		bad.append("SECTOR_JITTER lets a strand wander a whole sector wide")
	# A link may stretch and it may bunch, but the nominal length has to sit inside the
	# band or every strand is clamped in one direction at all times.
	if STRETCH_MIN >= 1.0 or STRETCH_MAX <= 1.0:
		bad.append("need STRETCH_MIN < 1.0 < STRETCH_MAX")
	# The pairing described on OVERSTRETCH_FACTOR. If a strand can hold on past the
	# point the poser stops being able to reach the anchor, the tip detaches from the
	# wall in plain sight and no assertion in this folder notices.
	if OVERSTRETCH_FACTOR >= STRETCH_MAX:
		bad.append("OVERSTRETCH_FACTOR must release before the link stretch clamps")
	# The starvation deadlock. If a full round of launches takes longer than a grip
	# lasts, the earliest strands time out before the last one has ever fired, and
	# the creature permanently runs on two tentacles. The only symptom is "only two
	# of them ever move", which looks like a rendering bug.
	if FIRE_INTERVAL * float(TENTACLE_COUNT) >= MAX_GRIP_TIME:
		bad.append("FIRE_INTERVAL * TENTACLE_COUNT must stay under MAX_GRIP_TIME")
	return bad
