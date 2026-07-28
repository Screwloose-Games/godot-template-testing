class_name RtsConfig
extends RefCounted

## Every tuning knob for the skirmish, in one file.
##
## This is a prototype whose whole job is to answer "is the loop fun?", which means the
## numbers below are going to be wrong on the first pass and get changed a lot. They live
## here — rather than scattered across scenes — so a balance session is one file open in one
## editor, not a scavenger hunt. Per-unit-type numbers are the exception: those are in
## data/unit_*.tres so they can be edited with the game running.

# --- Economy -------------------------------------------------------------------------

## Buys three Grunts, or a Grunt plus a Tank, immediately. The point is that the very first
## decision happens on frame one instead of after a build-up.
const STARTING_GOLD: int = 150
## What an HQ produces on its own, and the single most important number in the file.
##
## It used to be 3/s against 18/s of point income, which meant whoever touched a point first
## tripled their economy inside eleven seconds and the match was over before the first fight.
## At 8/s a player holding nothing still fields a Grunt every six seconds, so losing the
## opening is a setback rather than a death sentence. Points are now worth roughly 2.5x, not
## 7x, which makes them about tempo and position instead of being the whole economy.
const HQ_TRICKLE_INCOME: float = 8.0
const CENTER_POINT_INCOME: float = 4.0
const FLANK_POINT_INCOME: float = 2.0
## Extra income per capture point you are behind by. A losing player needs to be able to
## rebuild an army or the game is decided long before it ends.
const CATCHUP_INCOME_PER_POINT: float = 1.5
## Owning everything is 8 + 4 + 4x2 = 20/s. Forces composition choices rather than mass.
const POPULATION_CAP: int = 20

# --- Capture points ------------------------------------------------------------------

const CAPTURE_RADIUS: float = 8.0
const CAPTURE_SECONDS: float = 6.0
## More bodies capture faster, but with sharply diminishing returns — otherwise the correct
## play is always "send everything", which is not a decision.
const CAPTURE_MAX_CONTRIBUTORS: int = 3
## Progress runs -1 (enemy) through 0 (neutral) to +1 (player). Flipping an enemy point means
## crossing the whole range, which is what makes a contested point feel worth fighting over
## instead of worth trading.
const CAPTURE_PROGRESS_EPSILON: float = 0.001

# --- Headquarters --------------------------------------------------------------------

const HQ_MAX_HEALTH: float = 2000.0
const HQ_ATTACK_RANGE: float = 14.0
const HQ_DAMAGE_PER_HIT: float = 25.0
const HQ_ATTACK_INTERVAL: float = 1.0
## How far in front of the HQ freshly built units walk to. Keeps the spawn pad clear.
const HQ_RALLY_OFFSET: float = 8.0
## One queue per HQ. You cannot dump 400 banked gold at once, so the buy *order* matters.
const PRODUCTION_QUEUE_LIMIT: int = 5

# --- Match: the ticket race -------------------------------------------------------------

## The match is won by draining the enemy's tickets, not by sieging their base.
##
## Killing an HQ is still an instant win, but it is now the risky alternative rather than the
## only route: committing an army to a base push means giving up the points that are actually
## draining them. That tension is the game. It also means the score is legible from second
## one — you can see who is winning and by how fast, instead of guessing from unit counts.
const STARTING_TICKETS: float = 400.0
## Per second, per capture point held beyond the enemy's count. A one-point lead takes about
## 160s to close out; a three-point lead about 55s. Being level drains nobody, so a stalemate
## pushes both sides to break the tie rather than to turtle.
const TICKET_DRAIN_PER_POINT: float = 2.5
## Losing a unit costs a little on top, so trading badly has a price even while you hold
## ground. Small on purpose — position should stay the dominant term.
const TICKET_COST_PER_UNIT: float = 2.0
## Safety net so a playtest always terminates. On expiry the higher ticket count wins.
const MATCH_TIME_LIMIT: float = 300.0

# --- Units ---------------------------------------------------------------------------

## Units re-scan for targets on this interval with a randomised initial phase, so the cost is
## spread across frames instead of spiking on one. At a 20-unit cap this is free.
const TARGET_SCAN_INTERVAL: float = 0.25
## Units start walking toward a target slightly before they can shoot it, so they close the
## last metre instead of standing still at the edge of range.
const ACQUIRE_RANGE_MULTIPLIER: float = 1.5
## Floor under the above. Without it a Grunt's acquire radius is attack_range x 1.5 = 3m,
## which is barely wider than the unit itself — armies walked straight past each other, fights
## only happened where paths happened to collide, and Archers (18m) were quietly the correct
## buy no matter what the counter triangle said.
const MIN_ACQUIRE_RANGE: float = 9.0
const FORMATION_SPACING: float = 1.7
const ARRIVE_DISTANCE: float = 1.0
const DEATH_FADE_SECONDS: float = 0.3

# --- Map ------------------------------------------------------------------------------

const MAP_HALF_WIDTH: float = 40.0
const MAP_HALF_DEPTH: float = 34.0

# --- Camera ---------------------------------------------------------------------------

const CAMERA_PITCH_DEGREES: float = -55.0
## Wide enough on match start to see your base, the near capture points and the ground between
## them. Starting tight reads as "where am I?" for the first ten seconds.
const CAMERA_START_ZOOM: float = 36.0
const CAMERA_MIN_ZOOM: float = 14.0
const CAMERA_MAX_ZOOM: float = 52.0
const CAMERA_ZOOM_STEP: float = 3.5
## Pan speed scales with zoom distance, so a zoomed-out view crosses the map at a sane rate.
const CAMERA_PAN_SPEED: float = 1.1
const CAMERA_EDGE_MARGIN: float = 14.0
const CAMERA_SMOOTHING: float = 12.0
const CAMERA_SHAKE_DECAY: float = 6.0

# --- Input / selection -----------------------------------------------------------------

## Drags shorter than this are treated as clicks, not box selections.
const DRAG_THRESHOLD_PIXELS: float = 6.0
const PICK_RAY_LENGTH: float = 600.0
const CONTROL_GROUP_COUNT: int = 4

# --- Counter triangle --------------------------------------------------------------------

## Grunt beats Archer, Archer beats Tank, Tank beats Grunt. Both a bonus and a penalty are
## applied, giving a 3x swing between mirrored matchups — loud on purpose, so a playtester
## learns the triangle from one engagement instead of from a spreadsheet. Anything not listed
## (including every attack against a building) is 1.0.
const COUNTER_BONUS: float = 1.8
const COUNTER_PENALTY: float = 0.6
const COUNTER_MULTIPLIERS: Dictionary = {
	UnitStats.Kind.GRUNT:
	{
		UnitStats.Kind.ARCHER: COUNTER_BONUS,
		UnitStats.Kind.TANK: COUNTER_PENALTY,
	},
	UnitStats.Kind.ARCHER:
	{
		UnitStats.Kind.TANK: COUNTER_BONUS,
		UnitStats.Kind.GRUNT: COUNTER_PENALTY,
	},
	UnitStats.Kind.TANK:
	{
		UnitStats.Kind.GRUNT: COUNTER_BONUS,
		UnitStats.Kind.ARCHER: COUNTER_PENALTY,
	},
}


## Damage scaling for an attack of `attacker_kind` landing on `defender_kind`. Buildings pass
## a negative defender kind and always take 1.0.
static func counter_multiplier(attacker_kind: int, defender_kind: int) -> float:
	if not COUNTER_MULTIPLIERS.has(attacker_kind):
		return 1.0
	var row: Dictionary = COUNTER_MULTIPLIERS[attacker_kind]
	return row.get(defender_kind, 1.0)
