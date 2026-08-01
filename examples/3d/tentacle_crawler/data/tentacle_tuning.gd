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
## A REACH-AHEAD RULE BELONGS IN THE OBJECTIVE, NOT IN THE PREDICATE, and that is why
## there is no `FORWARD_BIAS_FRACTION` here.
##
## The flat floor above is weak for a long limb: 1.5 m ahead is a real constraint on a
## 4.4 m chain and almost none on a 7.5 m one, which can satisfy it while gripping
## something 7 m out to the SIDE -- geometrically ahead, visually a limb thrown sideways,
## and reported as the tentacles flailing rather than grabbing. The obvious fix is to
## scale the floor by the strand's own reach, and it is a trap: a limb gripping a wall `c`
## to the side at polar angle `t` reaches `c / sin(t)` and lands only `c / tan(t)` ahead,
## so demanding more distance ahead forces a narrower angle, which demands MORE reach than
## the strand has. Measured at a 0.45 fraction, the shortest chain needed 4.46 m against
## the 4.4 m it owns, had no legal band left at all, and took 0 anchors in 8 seconds;
## total anchors across every strand fell from 23 to 8 and the lunge rate more than halved.
## At 0.35 it still cost half the anchors.
##
## `TentacleArray._pick_anchor` maximises how far AHEAD an anchor is instead of how far
## away. That reaches for the same read and rejects nothing, so it cannot starve a limb --
## it only changes which of the hits a strand already accepts it prefers.
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

## Seconds before a failed search tries again.
const RETRY_DELAY: float = 0.25
## How many strands make up one lunge.
##
## THE GAIT IS BUILT ON PAIRS, not on a population. Two strands shoot forward one after
## the other, both plant, both haul on the same tick, and the creature shoots forward.
## Everything else in this file that mentions a count is derived from this.
const PAIR_SIZE: int = 2
## Floor on planted strands.
##
## ONE, not two, and the reason is `should_release` below rather than the look. That
## predicate kills the soft release rule whenever `planted_count <= MIN_PLANTED`, so at
## two the ONLY way a spent pair can ever let go is the -3.5 m hard escape hatch -- and
## the whole point of this gait is that the propelling pair releases at about a metre
## behind. The real floor is enforced where it belongs, in `TentacleArray._release_stale`,
## which refuses to drop the last grips while nothing is inbound. A count cannot express
## "inbound"; that guard can.
const MIN_PLANTED: int = 1
## And no more than this many: one spent pair still trailing plus one fresh pair that has
## just planted. Anything above that is a strand the cycle has lost track of.
const MAX_PLANTED: int = 4

## Seconds a stroke takes, start to finish.
const STROKE_TIME: float = 0.30
## Seconds between the two launches of a pair -- "one after the other", not together.
const PAIR_STAGGER: float = 0.10
## Longest the cycle waits for both members of a pair to plant before giving up on them
## and choosing a fresh pair.
##
## 0.45, down from 0.9, and it is a hang time rather than a comfort margin. A strike
## crosses its span in about a quarter of a second, so any pair that is going to arrive
## has arrived well before this. What the extra half-second bought was the WORST case: a
## pair that will never plant, with the previous pair already released, and the creature
## hanging on nothing for the whole timeout. Measured as 0.75 s with nothing gripping,
## against a 0.35 s bound.
const PAIR_SETTLE_TIMEOUT: float = 0.45
## Minimum seconds from one burst starting to the next one starting. THE GLIDE.
##
## Without this the cycle hauls the instant both strands plant, so the cadence is set by
## how quickly a search happens to succeed -- which is search luck, not a design. The
## creature then lunges at an unstable rate somewhere between 0.4 and 0.9 s and the
## ballistic phase never reads as deliberate. `[ratchet]`'s trough-depth assertion is a
## coin flip without it: at a 0.85 s cycle the speed floor is about 0.26 of the peak and
## passes, at 0.45 s it is about 0.40 and fails.
const GLIDE_MIN: float = 0.55
## Fraction of a stroke at which the NEXT pair launches, so the new limbs are already
## flying forward while the creature is still shooting forward on the current burst.
const PULL_HANDOFF: float = 0.35

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

## Fraction of its own reach that counts as FULL STRETCH.
##
## Not a target -- `TentacleArray._pick_anchor` maximises distance directly by sweeping
## the search cone outward and taking the first hit, so nothing needs to aim at a
## fraction. This is the threshold `[full-stretch]` asserts against, and the band a
## starving strand is allowed to fall below.
##
## The old `PREFERRED_REACH` of 0.8 was the opposite policy: hold at a comfortable
## fraction so different lengths hunt different distances. That went with a gait where
## five strands hauled steadily. A pair that has to yank the whole creature forward wants
## every centimetre of lever it has.
const REACH_TOLERANCE: float = 0.85

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
##
## ONLY TRUE WHILE SEARCHING OR REACHING, since the gait became pair-lunge. A planted
## strand is now at full stretch by construction -- `_pick_anchor` maximises distance --
## so `chord` equals the strand's own reach, `1 - chord / reach_max` is zero, and this
## pins at its 0.12 floor for every hauling limb. That is the intended read (a limb under
## load goes straight) but it does mean the sag is no longer a readout that DISTINGUISHES
## hauling limbs from each other. It distinguishes hauling from flailing.
static func slack_fraction(chord: float, reach_max: float) -> float:
	return 0.12 + 0.55 * clampf(1.0 - chord / maxf(reach_max, 0.001), 0.0, 1.0)


## Each strand's fixed phase, spread by the golden angle.
static func phase_for(index: int) -> float:
	return fmod(float(index) * GOLDEN_ANGLE, TAU)


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
	if STROKE_TIME <= 0.0:
		bad.append("STROKE_TIME must be positive")
	if TENTACLE_COUNT % PAIR_SIZE != 0:
		bad.append("PAIR_SIZE must tile TENTACLE_COUNT into whole teams")
	# One spent pair still trailing plus one fresh pair that has just planted.
	if MAX_PLANTED < PAIR_SIZE * 2:
		bad.append("MAX_PLANTED must fit the handoff overlap of two pairs")
	if PULL_HANDOFF <= 0.0 or PULL_HANDOFF >= 1.0:
		bad.append("PULL_HANDOFF must be a fraction of a stroke: 0 < PULL_HANDOFF < 1")
	# Both members have to be in the air before the stroke they belong to is over.
	if PAIR_STAGGER * 2.0 >= STROKE_TIME:
		bad.append("PAIR_STAGGER must let a pair fully launch inside one stroke")
	if GLIDE_MIN < STROKE_TIME:
		bad.append("GLIDE_MIN below STROKE_TIME lets two bursts overlap")
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
	if REACH_TOLERANCE <= 0.0 or REACH_TOLERANCE >= 1.0:
		bad.append("REACH_TOLERANCE must be a fraction of reach: 0 < REACH_TOLERANCE < 1")
	# A band no strand can be inside is a threshold that always fails.
	if REACH_MIN >= REACH_TOLERANCE * REACH_MAX:
		bad.append("REACH_TOLERANCE * REACH_MAX must leave a band above REACH_MIN")
	# THE TEAM-REUSE DEADLOCK, and the successor to the old FIRE_INTERVAL guard.
	#
	# Teams are fixed, so a team's turn comes round again after every OTHER team has
	# lunged once. If that takes less time than a grip can last, a team's own strands are
	# still holding on from last time when it is asked to fire, and the cycle spends its
	# turn force-releasing instead of reaching. The symptom is a creature that lunges
	# every other cycle for no visible reason.
	#
	# Derived from the DESIGNED cadence (`GLIDE_MIN + STROKE_TIME`), not from
	# `PAIR_SETTLE_TIMEOUT`. The timeout is the pathological path -- a team that cannot
	# find anywhere to grip -- and building the bound from it asserts against a case that
	# is already handled by rotating early.
	var rotation: float = (
		(GLIDE_MIN + STROKE_TIME) * (float(TENTACLE_COUNT) / float(PAIR_SIZE) - 1.0)
	)
	if rotation <= MAX_GRIP_TIME:
		bad.append("a team's turn returns before MAX_GRIP_TIME frees its own strands")
	return bad
