class_name TetherWinch
extends RefCounted

## The winch: how fast the tether's rest length is allowed to change, and how much
## the current load slows reeling in.
##
## Pure maths with no engine dependencies, for the same reason JeepSurfaces is:
## the solver, the HUD and the verifier all need this curve, and two files
## spelling 0.12 independently is how a readout stops describing the game.
##
## The winch is a KINEMATIC ACTUATOR ON THE SPRING'S REST LENGTH. It applies no
## force of its own. Shortening the rest length under load raises the spring's
## overshoot, which raises tension, which pulls the cargo in and pulls the ship
## back -- the spring already is the motor, so a separate winch force term would
## be double-counting.
##
## THE RATE LIMIT IS THE STABILITY GUARANTEE, not a comfort feature. A rest length
## that jumps is a step input into a stiff spring, and that is exactly how these
## detonate. At REEL_IN_RATE and 60 Hz the most rest_length can move in one step
## is 0.10 m, which at the shipped spring constant is a 680 N change -- 1.7% of
## break tension. It is a ramp with a small stair, not a step. Nothing may write
## rest length directly; everything goes through step().

## Shortest the tether can be reeled. The ship's tail anchor sits ~3 m behind its
## centre and the crate is ~1.5 m across, so below this the crate is inside the
## hull rather than merely close to it. Riding in the exhaust is the intent of
## short-tether play; interpenetrating is not.
const MIN_LENGTH: float = 6.0
## Longest the tether can be paid out. Past this the cargo is off-screen more
## often than not even with the camera's separation dolly, and the HUD's
## off-screen marker is carrying the whole readout.
const MAX_LENGTH: float = 30.0
## Where a run starts. Deliberately mid-band and slightly long, so the first thing
## a new player discovers is that reeling in helps.
const START_LENGTH: float = 14.0
## Metres per second, paying out. Fast and unconditional: slack costs nothing, so
## there is no load to fight. This also makes reel-out a panic button -- it drops
## tension to exactly zero the moment rest length passes the current separation --
## which is a genuinely good player verb obtained for free from the slack branch.
const REEL_OUT_RATE: float = 14.0
## Metres per second, reeling in, with no load. Slower than paying out; a full
## MAX -> MIN pull takes 4 s of held key.
const REEL_IN_RATE: float = 6.0
## Tension at which reel-in has slowed to STALL_FRACTION of its free rate. About
## 22% of break tension, so the rate is already halved by 4.5 kN.
const STALL_TENSION: float = 9000.0
## Floor on the reel-in rate multiplier. At or above STALL_TENSION you reel at
## 0.72 m/s: you cannot cheat a taut line, but you are never fully stopped, so
## reeling against a snagged cargo will eventually snap it. That outcome is
## correct and dramatic, and the ~1 s of visible strain first is the warning.
const STALL_FRACTION: float = 0.12
## How far one mouse-wheel click moves the target length. The wheel cannot express
## a held input, so it sets a target the rate limiter then chases -- see
## ship_input_actions.gd MOUSE_ACTIONS.
const WHEEL_STEP: float = 1.5


## Metres per second the winch can shorten the tether at, given the tension it is
## pulling against. Public because the HUD draws this as the winch's "strain".
static func reel_in_rate(tension: float) -> float:
	var load: float = clampf(tension / STALL_TENSION, 0.0, 1.0)
	return REEL_IN_RATE * lerpf(1.0, STALL_FRACTION, load)


## Moves `current` toward `target` by at most one step's worth of travel, and
## clamps the result into the legal band.
##
## `tension` only matters when shortening. Paying out against a taut line is still
## free: the line goes slack the instant rest length passes separation, so there
## is nothing to pull against.
static func step(current: float, target: float, tension: float, delta: float) -> float:
	var wanted: float = clampf(target, MIN_LENGTH, MAX_LENGTH)
	var rate: float = REEL_OUT_RATE if wanted > current else reel_in_rate(tension)
	return clampf(move_toward(current, wanted, rate * delta), MIN_LENGTH, MAX_LENGTH)


## Where in the band a length sits, 0 at MIN and 1 at MAX. The HUD's length bar.
static func band_fraction(length: float) -> float:
	return clampf((length - MIN_LENGTH) / (MAX_LENGTH - MIN_LENGTH), 0.0, 1.0)
