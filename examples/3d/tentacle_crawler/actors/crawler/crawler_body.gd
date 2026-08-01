class_name CrawlerBody
extends Node3D

## The creature's position and orientation, solved from the marker every tick.
##
## KINEMATIC ON PURPOSE. Not a RigidBody3D, not a CharacterBody3D -- a plain Node3D
## with a hand-written integrator. Four reasons, strongest first:
##
##   1. The brief is "solved by algorithms". A physics solver means two things
##      believe they own the velocity, and the one that loses is whichever ran last.
##   2. A tentacle stroke is an AUTHORED ENVELOPE, not a force. Laundering it through
##      apply_impulse means contact resolution can eat it at a wall, and the lurch
##      that is the entire feel of this creature silently stops happening.
##   3. Determinism. `[determinism]` asserts two identical runs land within 1e-3 m.
##      That is free with a fixed-dt integrator and impossible with six Jolt contacts.
##   4. No collision RESPONSE is wanted. This thing must smear along a wall, not
##      bounce off it, so depenetration is a position fix-up rather than restitution.
##
## The creature therefore has NO COLLIDER AT ALL, which is also why the camera
## SpringArm3D can never catch on it and why no exclusion bookkeeping exists anywhere.
##
## THIS IS THE ONLY FILE THAT WRITES THE BODY'S TRANSFORM. One integrator, one
## owner, one `global_transform =` at the end of the tick.

@export_group("Wiring")
## The player's intent. With none, the creature sits still -- which is a legitimate
## configuration: the capture tool and several checks run with no pilot at all.
@export var target_marker: Node3D
## The strands. With none, the creature is a ball on a spring -- which is exactly
## what `[drag-requires-anchors]` measures against.
@export var tentacles: TentacleArray

@export_group("Anchors")
## Steady pull from every gripping strand, m/s^2. The SUSPENSION: it acts in
## whatever direction the strand happens to lie, which is what holds the creature
## off the walls and, summed over a splayed set of anchors, what centres it.
##
## 2.5, and its RETROGRADE COMPONENT IS NOW STRIPPED -- see `_anchor_accel`. Under the
## pair-lunge gait a spent pair deliberately trails behind the body, so `anchor - shoulder`
## points backwards by construction and an ungated hold term brakes the glide it is
## supposed to be gliding through. The obvious fix, halving the gain, treats the symptom
## and costs the bracing that is hold's actual job -- which matters MORE now, not less,
## because only two strands are ever holding.
@export var hold_gain: float = 2.5
## Peak pull from a stroking strand, m/s^2. The PROPULSION.
##
## One stroke delivers `PAIR_SIZE * stroke_gain * STROKE_TIME * 0.5 * along^2` m/s of
## delta-v, because the raised-cosine envelope integrates to exactly half its peak.
## Tune this FIRST; it is the loudest number in the example.
##
## THE SHARE ALONG TRAVEL IS `along` SQUARED, NOT `along`. The acceleration is
## `direction * stroke_gain * envelope * maxf(along, 0)` and its useful component is that
## vector dotted back onto travel, so the angle is paid for twice. It is an easy factor
## to drop and it overstates the lunge by a third: at a typical `along` of 0.78 the naive
## reading is 22% optimistic. Here, 2 * 38 * 0.30 * 0.5 * 0.6 = 6.8 m/s per lunge.
##
## 38, up from 22, because a PAIR now does what up to five strands used to share. Not
## higher, and the ceiling is geometric rather than aesthetic: the corridor is 4.5 x 4.0 m
## against a body_radius of 2.15, so the creature has about 0.1 m of margin, and a
## ballistic lunge through the course's 12 m-radius yaw departs the tangent by roughly
## `lunge^2 / (2 * radius)`. At a 3.6 m coast that is 0.27 m and `[corridor-run]` holds;
## at the 6.5 m coast a 60 gain would buy, it is 0.9 m and the creature leaves the shell.
@export var stroke_gain: float = 38.0
## Pull toward the anchor centroid, 1/s^2 per metre of lateral offset. Applied
## perpendicular to travel only: the along-travel part is already the drag, and
## counting it twice just makes the creature faster for no reason anyone can see.
@export var center_gain: float = 2.2
## Radians of roll per m/s^2 of sideways haul. Makes the body visibly twist toward
## whichever side is currently pulling hardest.
@export var roll_from_pull: float = 0.06
## Metres of lead PAST `leash_slack` at which the creature hauls at full power.
##
## Without this gate the tentacles hunt forward and pull forward unconditionally, so
## a player who stops still watches the creature crawl straight past the marker and
## park a leash-length AHEAD of it -- the marker stops being an intent and becomes
## something the creature tows.
##
## MEASURED FROM `leash_slack`, NOT FROM ZERO, and that detail is the whole
## behaviour. The creature's natural resting place is exactly `leash_slack` behind
## the marker, where the leash is slack and pulls nothing. A ramp measured from zero
## commands FULL DRIVE at that resting distance, so the creature hauls forward,
## overshoots, gets pulled back, falls behind, and hauls again -- a limit cycle that
## never settles, on a player who is not touching the controls. Anchoring the ramp to
## the same distance the leash rests at makes "at rest" mean one thing to both.
##
## 6.0, up from 3.0, and this is where the pair-lunge gait's anti-overshoot lives.
## A lunge covers about 3.6 m, which used to be more than the whole ramp -- the creature
## crossed from full drive to none inside a single burst and hunted. At 6.0 full drive
## sits at a 10 m lead, so a lunge from there lands at 6.4 m and the next urge is already
## most of the way down. It self-limits.
##
## NOT `leash_slack`, which is the obvious other lever and the wrong one: `[lag]` asserts
## the marker gap is under 6.0 m at four seconds, and the resting gap IS `leash_slack`.
## Raising it to 6.0 puts that check on a knife edge and silently invalidates the
## README's "idle separation settles to exactly 4.00 m".
@export var drive_distance: float = 6.0

@export_group("Leash")
## Metres of dead zone before the leash pulls at all.
##
## This is why the creature visibly TRAILS the marker rather than wearing it. At
## zero the body sits on the marker and there is no creature, just a cursor.
@export var leash_slack: float = 4.0
## Spring rate, 1/s^2 per metre of stretch.
@export var leash_stiffness: float = 9.0
## Damping on the rate of stretch, 1/s. 0.9x critical (2*sqrt(9) = 6.0), so it is
## deliberately UNDER-damped: a critically damped body gliding smoothly to its
## target is precisely the motion this creature is not supposed to have.
@export var leash_damping: float = 5.4
## Ceiling on leash acceleration, m/s^2, so a teleported marker cannot launch it.
##
## Raised with the marker's speed. Terminal velocity under the leash alone is this
## over `body_drag`, so at 26 the creature topped out near 16 m/s however fast the
## marker flew -- tripling the marker just stretched the leash and changed nothing you
## could see.
@export var leash_max_accel: float = 60.0

@export_group("Probe")
## Metres of wall clearance the body tries to keep.
##
## 4.2, up from 2.6, and this is a GAIT change rather than a comfort tweak. The body
## rolls so its up-axis points away from the nearest wall, so a strand's sector is
## fixed relative to whichever wall the creature is hugging -- and the four raised arms
## end up permanently aimed across the tube. At 2.6 the creature crawled along one wall
## with the far side 6.4 m away, which is past every arm's reach, so all four starved
## in SEARCHING while the four legs did the work. Set above the corridor's half-height
## the push comes from all sides at once, the creature runs down the MIDDLE, and every
## strand faces wall at about the same distance. An eight-limbed creature in a tube
## should be using the whole tube.
@export var probe_comfort: float = 4.2
## How hard it pushes off a wall inside that distance, 1/s^2 per metre.
@export var probe_gain: float = 6.0
## Hard shell radius, metres. Inside this the body is pushed out positionally.
##
## 2.15, up from 1.2, because the greybox sphere became a 3.1 x 3.6 x 3.6 m creature.
## The invariant it has to preserve is that the VISUAL never pokes through a wall the
## solver believes it is clear of, so this has to clear the torso's largest half-extent
## (1.82 m) with the same margin the sphere had. `[rig]` in the static suite MEASURES
## the torso rather than trusting this comment, and fails if the two ever part company.
@export var body_radius: float = 2.15
## How far the fan looks. Past this a direction reads as "open".
@export var probe_range: float = 25.0
@export_flags_3d_physics var probe_mask: int = CrawlerLayers.MASK_BODY_PROBE
## How far ahead to look when deciding which way "forward" is. See `_travel_direction`.
@export var peek_distance: float = 5.0

@export_group("Motion")
## Medium drag, 1/s.
##
## 1.2, down from 1.6. Terminal speed under the leash is `leash_max_accel / body_drag`,
## so drag is the other half of how fast this thing can ever go -- raising the ceiling
## without touching it just made the creature lurch harder into the same wall of drag
## and cover slightly LESS ground.
##
## This is now the ONLY thing shaping the glide, so it sets how far a lunge carries:
## `dv / body_drag * (1 - exp(-body_drag * t))`, about 3.6 m per cycle at these values.
## It is the second lever to reach for after `stroke_gain`.
@export var body_drag: float = 1.2
## Extra drag while gripping but not pulling. DISABLED AT 1.0 -- see `_drag_accel`.
##
## Under the old continuous gait this was the entire "drags itself" read, and dropping it
## to 1.0 made the creature glide everywhere and stop being a creature. The pair-lunge
## gait inverts that: the pulse now comes from a synchronised burst followed by a
## deliberate ballistic coast, and braking through the coast destroys it. Kept as a knob
## rather than deleted because it is exactly the lever for a heavier, more laboured
## variant of the same gait.
@export var brake_multiplier: float = 1.0
## Soft ceiling on speed, m/s. Raised alongside `leash_max_accel`; with the marker at
## 27 m/s the creature was sitting on the old 14 for most of a driven run.
@export var max_speed: float = 30.0

@export_group("Orientation")
## How fast the up reference swings toward the nearest wall, 1/s.
@export var orient_speed: float = 4.0
## How fast the body turns to face where it is going, 1/s.
@export var turn_speed: float = 5.0
## Radians of idle roll. The creature is never quite still.
@export var writhe_amplitude: float = 0.22
## Radians per second of that roll.
@export var writhe_rate: float = 1.3

var _position: Vector3 = Vector3.ZERO
var _velocity: Vector3 = Vector3.ZERO
var _orientation: Quaternion = Quaternion.IDENTITY
var _forward: Vector3 = Vector3.FORWARD
var _up: Vector3 = Vector3.UP
var _travel: Vector3 = Vector3.FORWARD
var _time: float = 0.0
var _pull_lateral: Vector3 = Vector3.ZERO
var _stroke_urge: float = -1.0
var _probe: CorridorProbe = CorridorProbe.new()

@onready var _hull: Node3D = %Hull as Node3D


func _ready() -> void:
	_position = global_position
	_orientation = global_basis.get_rotation_quaternion()
	_forward = -global_basis.z.normalized()
	_up = global_basis.y.normalized()
	_travel = _forward


func _physics_process(delta: float) -> void:
	if delta <= 0.0:
		return
	_time += delta
	_probe.sample(get_world_3d().direct_space_state, _position, probe_mask, probe_range)
	_travel = _travel_direction()

	var accel: Vector3 = _leash_accel() + _anchor_accel() + _probe_accel() + _drag_accel()
	_velocity += accel * delta
	_velocity = _capped(_velocity)
	_position += _velocity * delta
	_depenetrate()

	_solve_orientation(delta)
	_apply_squash()
	# The ONE place the transform is written. Built from a unit quaternion, so the
	# body node can never accumulate scale -- squash lives on %Hull, because scaling
	# this node would also scale the shoulder offsets and the probe fan.
	global_transform = Transform3D(Basis(_orientation), _position)


## Where the creature is trying to go. Not simply "toward the marker".
##
## THE CORNER PEEK. At a 90-degree bend the marker is round the corner, so the
## straight line to it points into the outer wall. Every candidate anchor then fails
## the forward-bias test, no tentacle can plant, and the creature stops dead in an
## open corridor with nothing logged anywhere. It is the single most likely way for
## this example to look broken on a first run.
##
## So the intent direction is cast forward one ray, and on a hit it is projected onto
## the wall plane -- it SLIDES along the wall rather than pressing into it, which is
## what a real animal following a scent round a corner does. One extra raycast per
## tick, and it is the difference between a creature that turns corners and one that
## grinds its face into a wall.
func _travel_direction() -> Vector3:
	if target_marker == null:
		return _travel
	var raw: Vector3 = CrawlerMath.direction_or(target_marker.global_position - _position, _travel)
	var space: PhysicsDirectSpaceState3D = get_world_3d().direct_space_state
	var params: PhysicsRayQueryParameters3D = PhysicsRayQueryParameters3D.create(
		_position, _position + raw * peek_distance, probe_mask
	)
	var hit: Dictionary = space.intersect_ray(params)
	if hit.is_empty():
		return raw
	var normal: Vector3 = hit["normal"]
	# Head-on into a dead end leaves nothing to slide along; keep the old heading
	# rather than normalising a zero and flipping the creature inside out.
	return CrawlerMath.direction_or(raw - normal * raw.dot(normal), _travel)


## The leash. Shaped exactly like cargo_tether's TetherLink, including the clamp.
##
## `maxf(tension, 0.0)` is load-bearing: closing on the marker fast makes the damping
## term exceed the spring term, and an unclamped leash then PUSHES the creature away
## from where the player is steering. Ropes pull. The dead zone means a slack leash
## contributes exactly nothing, which is what lets the tentacles own the motion
## whenever the player is not yanking the creature somewhere.
func _leash_accel() -> Vector3:
	if target_marker == null:
		return Vector3.ZERO
	var to_marker: Vector3 = target_marker.global_position - _position
	var separation: float = to_marker.length()
	var stretch: float = separation - leash_slack
	if stretch <= 0.0 or separation < 0.0001:
		return Vector3.ZERO
	var direction: Vector3 = to_marker / separation
	var closing_rate: float = _velocity.dot(direction)
	var tension: float = maxf(stretch * leash_stiffness - closing_rate * leash_damping, 0.0)
	return (direction * tension).limit_length(leash_max_accel)


## What the tentacles are doing to the body: a steady hold from every gripping
## strand, a stroke impulse from the ones currently hauling, and a sideways nudge
## toward the middle of whatever they are all holding on to.
##
## `maxf(along, 0.0)` ON THE STROKE TERM IS LOAD-BEARING. Without it, two strands
## gripping opposite walls and stroking together produce a net force of zero while
## both visibly heave -- and the creature sits vibrating in place, which every player
## and every reviewer reads as a physics bug rather than as a tuning problem. This is
## the same clamp, for the same reason, as `maxf(tension, 0.0)` in the leash and in
## cargo_tether's TetherLink: these things pull, they never push.
##
## The hold term is deliberately NOT gated that way. A strand bracing sideways is
## doing real work -- it is what stops the creature falling into the wall it is
## climbing -- so it acts along whatever direction it actually lies.
func _anchor_accel() -> Vector3:
	_pull_lateral = Vector3.ZERO
	if tentacles == null or not tentacles.enabled:
		return Vector3.ZERO

	var urge: float = _latched_urge()
	var accel: Vector3 = Vector3.ZERO
	var centroid: Vector3 = Vector3.ZERO
	var planted: int = 0
	for i: int in tentacles.count():
		if not tentacles.is_planted(i):
			continue
		var anchor: Vector3 = tentacles.anchor(i)
		centroid += anchor
		planted += 1
		var direction: Vector3 = CrawlerMath.direction_or(
			anchor - tentacles.shoulder(i), Vector3.ZERO
		)
		if direction.is_zero_approx():
			continue
		var along: float = direction.dot(_travel)
		# The hold term keeps its sideways bracing and loses its backward haul. A spent
		# pair TRAILS on purpose under this gait, so `direction` points behind the body
		# for most of its grip; without this the suspension quietly becomes an anchor in
		# the nautical sense and eats the glide the lunge just bought.
		var hold: Vector3 = direction * hold_gain
		var backward: float = hold.dot(_travel)
		if backward < 0.0:
			hold -= _travel * backward
		accel += hold + direction * stroke_gain * tentacles.envelope(i) * maxf(along, 0.0)

	if planted == 0:
		return Vector3.ZERO

	# Centre on what the strands are holding, sideways only.
	#
	# TWO ANCHORS MINIMUM. The centroid of a single anchor IS that anchor, so with one
	# strand planted this stops being a centring force and becomes a pull straight at
	# whichever wall that strand happens to be gripping -- at exactly the moment there is
	# no opposing limb to cancel it. The gait already declines to haul on a lone strand;
	# this is the same rule applied to the passive term.
	if planted >= TentacleTuning.PAIR_SIZE:
		var to_centroid: Vector3 = centroid / float(planted) - _position
		var lateral: Vector3 = to_centroid - _travel * to_centroid.dot(_travel)
		accel += lateral * center_gain

	# THE URGE GATES THE WHOLE ANCHOR FORCE, not just its forward part.
	#
	# The previous version projected out only the component along `_travel`, which is
	# correct arithmetic and completely useless in practice: `_travel` is the
	# direction to the marker, and once the creature has ARRIVED that direction is
	# the bearing to a point two metres away, so it swings through large angles every
	# tick. The projection then removed almost none of a 10 m/s^2 pull, and the
	# creature thrashed back and forth past a stationary marker at a mean speed of
	# 5.6 m/s while the player held nothing. Measured, in measure_crawl_response.
	#
	# Gating everything costs the anchors' idle bracing, which turns out not to
	# matter: the probe fan already keeps the body off walls, and it does so without
	# reference to any direction that can become degenerate.
	accel *= urge
	_pull_lateral = accel - _travel * accel.dot(_travel)
	return accel


## How hard the creature currently WANTS to move, 0 to 1, from how far the marker
## leads it along its travel direction.
##
## WITH NO MARKER THIS IS 1.0, i.e. crawl freely. That is not a fallback so much as
## the honest reading: with no intent node wired there is no intent to satisfy, the
## component is being driven directly by a tool or a verifier, and it should do the
## thing it does. `[drag-requires-anchors]` and `[ratchet]` both detach the marker
## precisely so the tentacles are the only thing left that can produce motion.
func _drive_urge() -> float:
	if target_marker == null:
		return 1.0
	var lead: float = (target_marker.global_position - _position).dot(_travel)
	return clampf((lead - leash_slack) / maxf(drive_distance, 0.001), 0.0, 1.0)


## The urge, held constant for the duration of a stroke.
##
## A LUNGE OUTRUNS ITS OWN REASON FOR EXISTING. The urge is a ramp on how far the marker
## leads the body, and one burst closes 3.6 m of that lead in well under a second -- so
## sampling it every tick means the creature commits to a stroke, sprints far enough to
## satisfy the gate mid-burst, and has the second half of its own pull switched off under
## it. The visible result is a lunge that dies halfway, which reads as the tentacles
## slipping rather than as a control decision.
##
## Latching it at the leading edge of the burst makes a stroke an all-or-nothing
## commitment, which is what an authored envelope is supposed to be. The gate still does
## its job -- it decides whether the NEXT lunge happens at all.
func _latched_urge() -> float:
	if not tentacles.any_pulling():
		_stroke_urge = -1.0
		return _drive_urge()
	if _stroke_urge < 0.0:
		_stroke_urge = _drive_urge()
	return _stroke_urge


## Push off any wall closer than `probe_comfort`.
##
## This is what keeps the creature off the wall in a narrow section where there may
## be no tentacle anchor on one side at all. It is a soft, distance-weighted shove
## rather than a hard limit, so it reads as the creature avoiding the wall rather
## than as an invisible barrier.
func _probe_accel() -> Vector3:
	var accel: Vector3 = Vector3.ZERO
	for i: int in _probe.count():
		if not _probe.has_hit(i):
			continue
		var gap: float = _probe.distance(i)
		if gap >= probe_comfort:
			continue
		accel -= _probe.direction(i) * (probe_comfort - gap) * probe_gain
	return accel


## Medium drag. The brake is now OFF by default -- see `brake_multiplier`.
##
## This used to be the ratchet: gripping but not hauling tripled the drag, the creature
## very nearly stopped between strokes, and the next stroke read as a lurch. It was the
## single line that made a continuous haul look like dragging.
##
## The pair-lunge gait gets its pulse from the gait itself instead. One synchronised
## burst from two strands, then a deliberate GLIDE_MIN of ballistic coast on momentum
## alone. Braking through that coast would flatten exactly the phase the gait exists to
## produce -- the creature is supposed to SHOOT forward and carry, not stop and shuffle.
func _drag_accel() -> Vector3:
	return -_velocity * body_drag * _brake_multiplier()


func _brake_multiplier() -> float:
	if tentacles == null or not tentacles.enabled:
		return 1.0
	if tentacles.planted_count() > 0 and not tentacles.any_pulling():
		return brake_multiplier
	return 1.0


## Soft quadratic ceiling rather than a hard clamp: a hard clamp on a body being
## driven by impulses produces a visible flat spot at exactly max_speed.
func _capped(velocity: Vector3) -> Vector3:
	var speed: float = velocity.length()
	if speed <= max_speed or speed < 0.0001:
		return velocity
	var excess: float = speed - max_speed
	return velocity / speed * (max_speed + excess / (1.0 + excess))


## Positional push-out, applied AFTER integration.
##
## Never as an acceleration. As an acceleration this oscillates at the physics rate
## and the creature buzzes against the wall; as a position fix-up the wall is simply
## solid. Only the INWARD velocity component is killed, never reflected -- a
## reflection makes the creature bounce, and it is supposed to smear.
func _depenetrate() -> void:
	for i: int in _probe.count():
		if not _probe.has_hit(i):
			continue
		var gap: float = _probe.distance(i)
		if gap >= body_radius:
			continue
		var toward_wall: Vector3 = _probe.direction(i)
		_position -= toward_wall * (body_radius - gap)
		var inward: float = _velocity.dot(toward_wall)
		if inward > 0.0:
			_velocity -= toward_wall * inward


func _solve_orientation(delta: float) -> void:
	# Mostly where it intends to go, partly where it is actually going. Pure travel
	# direction makes the creature face sideways whenever a stroke shoves it off
	# axis; pure intent makes it ignore its own momentum and look weightless.
	var motion: Vector3 = CrawlerMath.direction_or(_velocity, Vector3.ZERO)
	_forward = CrawlerMath.direction_or(_travel * 0.65 + motion * 0.35, _forward)

	# Up is AWAY FROM THE NEAREST WALL. This is what makes it hug surfaces and crawl
	# along a ceiling as happily as a floor, and it is the whole reason the marker
	# does not need a roll control.
	var candidate: Vector3 = CrawlerMath.blend_direction(
		_up, -_probe.nearest_direction(), CrawlerMath.smoothing(orient_speed, delta)
	)
	# Near-parallel forward and up make Basis.looking_at degenerate and spin the
	# creature. Keeping the previous up is a lean; letting it through is a snap.
	if absf(_forward.dot(candidate)) <= 0.985:
		_up = candidate

	var wanted: Basis = Basis.looking_at(_forward, _up)
	wanted = wanted.rotated(wanted.z.normalized(), _writhe_roll())
	_orientation = _orientation.slerp(
		wanted.get_rotation_quaternion(), CrawlerMath.smoothing(turn_speed, delta)
	)


## Idle roll, plus a twist toward whichever side is currently hauling.
##
## The idle term alone makes the creature look alive while doing nothing. The pull
## term is what makes it look like the tentacles are attached to it: without it the
## strands heave and the body glides along serenely, which reads as two unrelated
## animations playing at once.
func _writhe_roll() -> float:
	var idle: float = writhe_amplitude * sin(writhe_rate * _time)
	var side: float = _pull_lateral.dot(Basis(_orientation).x)
	return idle + clampf(side * roll_from_pull, -0.5, 0.5)


## Bunch up on the pull.
##
## APPLIED TO %Hull, NEVER TO THIS NODE. Scaling the body node would also scale the
## shoulder offsets and the origin of the probe fan, so the creature would gain
## tentacle reach and lose wall clearance every time it flexed -- a bug that would
## show up as the crawl speeding up slightly on every stroke and nowhere else.
func _apply_squash() -> void:
	if _hull == null:
		return
	# AVERAGED OVER THE PAIR, not summed raw. Two strands now stroke on the same tick, so
	# a raw sum peaks at 2.0 and the clamp turns every single lunge into a full-depth
	# squash -- the flex becomes a binary flash that tells you nothing about how hard the
	# creature is actually pulling. Dividing by the pair size restores the 0..1 range the
	# envelope was designed to produce, so a half-strength lunge still looks like one.
	var effort: float = 0.0
	if tentacles != null and tentacles.enabled:
		for i: int in tentacles.count():
			effort += tentacles.envelope(i)
		effort /= float(TentacleTuning.PAIR_SIZE)
	effort = clampf(effort, 0.0, 1.0)
	_hull.scale = Vector3(1.0 + 0.12 * effort, 1.0 + 0.12 * effort, 1.0 - 0.22 * effort)


func current_speed() -> float:
	return _velocity.length()


## Where the creature is trying to go, corner-peek applied. TentacleArray opens its
## search cone around this rather than around the body's nose -- aiming at the nose
## is what makes a creature grind into the outer wall of a bend.
func wanted_direction() -> Vector3:
	return _travel


## Drop the creature somewhere with no momentum. For tools and verifiers.
func teleport(to: Vector3) -> void:
	_position = to
	_velocity = Vector3.ZERO
	global_transform = Transform3D(Basis(_orientation), _position)


## One dictionary rather than eight accessors, so gdlint's max-public-methods stays
## a real constraint instead of something to be worked around one getter at a time.
func debug_state() -> Dictionary:
	return {
		"speed": _velocity.length(),
		"velocity": _velocity,
		"position": _position,
		"clearance": _probe.nearest_distance(),
		"escaped": _probe.has_escaped(),
		"travel": _travel,
		"forward": _forward,
		"up": _up,
		"planted_count": tentacles.planted_count() if tentacles != null else 0,
		"tentacle_count": tentacles.count() if tentacles != null else 0,
		"pulling": tentacles.any_pulling() if tentacles != null else false,
	}
