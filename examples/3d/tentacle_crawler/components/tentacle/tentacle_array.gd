class_name TentacleArray
extends Node3D

## Eight tentacles: where they are looking, what they are holding, and when they pull.
##
## ONE NODE OWNS EVERY STRAND, in parallel arrays indexed by strand. Eight separate
## nodes would mean eight _physics_process calls, eight copies of the launch scheduler,
## and no way to express "you two, pull NOW" without a ninth node to arbitrate -- and
## that arbitration is the entire gait.
##
## STRANDS ARE NOT INTERCHANGEABLE any more. The model's chains run from 14 links to
## 23, so each strand carries its own reach and its own search sector, both solved once
## at _ready from the geometry rather than from its index.
##
## THIS IS THE ONLY FILE THAT RAYCASTS FOR ANCHORS and the only file that owns strand
## lifecycle. It applies NO FORCE: CrawlerBody reads the anchors and does that, so
## Newton's third law is not split across two files that have to agree on a sign.
## TentacleBones reads the same state and poses the model from it, and applies no force
## either.
##
## THERE ARE TWO STATE MACHINES HERE, and keeping them apart is the whole design.
##
## `Phase` is per strand and says what one tentacle is physically doing. `Cycle` is
## per ARRAY and says what the creature's gait is doing. A strand never decides to
## stroke; the cycle decides, and moves a whole pair at once. That split is what turns
## eight independent limbs into one gait.
##
##   SEARCHING -> REACHING -> PLANTED -> PULLING -> PLANTED
##        ^                      |          |         |
##        +----- RELEASING <-----+----------+---------+
##
## Note what CHANGED from the continuous gait: PLANTED no longer walks itself to
## PULLING on a private timer. A strand strokes exactly ONCE, when its pair is told to,
## and then holds as dead weight until it has trailed about a metre behind the body.
## That single edit is the difference between "hauls steadily" and "lunges".
##
## THE CYCLE:
##
##   LEAD --(lead strand away)--> FOLLOW --(second away)--> SETTLE
##     ^                                                      |
##     |                                            (both planted, glide spent)
##     +---------------(handoff, 35% into the stroke)------ HAUL

## Phase of one strand. See the diagram above.
enum Phase { SEARCHING, REACHING, PLANTED, PULLING, RELEASING }

## Where the gait is in its lunge. See the diagram above.
enum Cycle { LEAD, FOLLOW, SETTLE, HAUL }

## How far a searching tip is pulled back off a wall it would otherwise poke through.
const FLAIL_SKIN: float = 0.15
## Distance at which a reaching tip counts as arrived.
const PLANT_EPSILON: float = 0.15

@export_group("Wiring")
## The body these grow from. Supplies the shoulders, the travel direction and the
## position that "ahead" is measured from.
@export var body: CrawlerBody
## Node holding one Node3D per strand, in strand order. Read for shoulder positions
## only. In `crawler.tscn` this is `%Limbs`, whose children ARE the model's own
## tentacle sockets -- so the point a strand is drawn from and the point force is
## applied at are the same node the geometry grows out of, by construction.
@export var shoulders: Node3D
## Supplies each chain's physical length. OPTIONAL: with no rig every strand falls back
## to the global `REACH_MAX`, which is what lets a verifier stand a bare TentacleArray
## up in an empty world with no model loaded.
@export var rig: CrawlerRig

@export_group("Behaviour")
## Master switch. `[drag-requires-anchors]` turns this off to prove that the crawl
## is actually driven by the tentacles rather than by the leash alone.
@export var enabled: bool = true
## Every random draw comes from this seed, never from global randf(). Global RNG
## makes two identical runs diverge, which breaks `[determinism]` and with it any
## hope of debugging an intermittent failure.
@export var crawler_seed: int = 20260731
@export_flags_3d_physics var query_mask: int = CrawlerLayers.MASK_TENTACLE_QUERY

@export_group("Reach")
## How fast a launched tip travels, m/s.
##
## 44, up from 26. The launch has to read as a STRIKE now that only two strands carry a
## lunge: at 26 a 6 m reach took 0.23 s and looked like the limb being extended rather
## than thrown.
##
## Raised again once idle strands began trailing BEHIND the body: a strike now starts from
## a tip streamed backwards rather than one coiled at the shoulder, so it crosses about
## 10 m instead of 5. At 32 that doubled the time to plant, which lengthened the whole
## cycle -- measured 7 lunges in 8 s against 10 before. The strike has to cover the extra
## ground in the same time, or trailing the idle limbs costs a third of the lunge rate.
@export var reach_speed: float = 44.0
## Seconds a strand takes to retract after letting go.
@export var release_time: float = 0.18
## How far a searching tip flails from its shoulder, metres. Short: a searching
## tentacle is COILED and twitching, not extended and waving, which is what makes
## the launch read as a strike.
##
## 3.6 now that idle strands STREAM BACKWARD rather than orbiting. The surplus between
## the flail point and the end of the limb is what CURLS -- see TentacleBones.COIL_TURN --
## and at 2.4 m a 7.5 m chain put five metres of itself into that curl, which is a knot of
## noodle hanging off the body rather than a limb. Trailing wants the opposite of what
## orbiting wanted: a longer span reads as slack being dragged, and it cannot be mistaken
## for a reach because it points the wrong way.
@export var flail_reach: float = 3.6

@export_group("Search cost")
## Rays per attempt, jittered around the chosen direction.
##
## 2 rather than 3, because `attempts` went up: the attempt loop is now a SWEEP of the
## cone rather than a set of independent draws, so resolution along the sweep is worth
## more than width at each step. See `_pick_anchor`.
@export var rays_per_attempt: int = 2
## Steps in the outward sweep, and the cap on how long it may hunt. At most
## `rays_per_attempt * attempts` rays, and only on the tick a strand actually fires.
##
## 16 rather than 4, and the resolution IS the feature: the sweep steps across the cone in
## equal angles, and near the angle where the wall first comes into range one step
## overshoots the strand's reach while the next lands well inside it. Everything between
## is reach that was available and not taken. Measured mean stretch went 75% at 7 steps to
## the figure `[full-stretch]` now prints; the angular step here is about 0.07 rad, worth
## roughly 6% of distance at the angles that matter.
##
## Still cheaper than what it replaced: the pair cycle fires about 2.5 launches a second
## against the old scheduler's 5.5, and rays are only spent on the tick a strand fires.
@export var attempts: int = 16

var _phase: PackedInt32Array = PackedInt32Array()
var _anchor: PackedVector3Array = PackedVector3Array()
var _normal: PackedVector3Array = PackedVector3Array()
var _tip: PackedVector3Array = PackedVector3Array()
var _launch: PackedVector3Array = PackedVector3Array()
var _grip_age: PackedFloat32Array = PackedFloat32Array()
var _search_age: PackedFloat32Array = PackedFloat32Array()
var _retry: PackedFloat32Array = PackedFloat32Array()
var _extend: PackedFloat32Array = PackedFloat32Array()
var _stroke: PackedFloat32Array = PackedFloat32Array()
var _sector: PackedFloat32Array = PackedFloat32Array()
var _reach: PackedFloat32Array = PackedFloat32Array()
var _misses: PackedInt32Array = PackedInt32Array()
var _starve: PackedInt32Array = PackedInt32Array()
var _cycle: Cycle = Cycle.LEAD
var _cycle_timer: float = 0.0
var _since_burst: float = 0.0
var _lead_strand: int = -1
var _follow_strand: int = -1
var _hauling: PackedInt32Array = PackedInt32Array()
var _confirm_cursor: int = 0
var _time: float = 0.0
var _rng: RandomNumberGenerator = RandomNumberGenerator.new()


func _ready() -> void:
	_rng.seed = crawler_seed
	var count: int = TentacleTuning.TENTACLE_COUNT
	_phase.resize(count)
	_anchor.resize(count)
	_normal.resize(count)
	_tip.resize(count)
	_launch.resize(count)
	_grip_age.resize(count)
	_search_age.resize(count)
	_retry.resize(count)
	_extend.resize(count)
	_stroke.resize(count)
	_sector.resize(count)
	_reach.resize(count)
	_misses.resize(count)
	_starve.resize(count)
	for i: int in count:
		_phase[i] = Phase.SEARCHING
		_tip[i] = shoulder(i)
		_reach[i] = TentacleTuning.REACH_MAX
	if rig != null:
		if rig.strand_count() != count:
			push_warning(
				"model supplies %d tentacles but TENTACLE_COUNT is %d" % [rig.strand_count(), count]
			)
		for i: int in mini(count, rig.strand_count()):
			_reach[i] = rig.chain_reach(i)
	_build_sectors()


func _physics_process(delta: float) -> void:
	if not enabled or body == null or shoulders == null or delta <= 0.0:
		return
	_time += delta
	_since_burst += delta

	# BEFORE `_release_stale`, not inside `_advance_cycle`. `_retire_surplus` refuses to
	# touch anything in this set, so on the tick a burst ends a stale entry makes the
	# strand un-retirable for that tick and the planted ceiling is breached transiently --
	# which a per-tick sampler sees even though a per-interval one would not.
	var still: PackedInt32Array = PackedInt32Array()
	for index: int in _hauling:
		if _phase[index] == Phase.PULLING:
			still.append(index)
	_hauling = still

	_age_strands(delta)
	_confirm_anchors()
	_release_stale()
	_advance_cycle(delta)
	_update_tips(delta)
	# LAST, because `_update_tips` is what turns REACHING into PLANTED. Trimming before it
	# leaves the tick's two brand-new grips uncounted, so the ceiling is enforced a tick
	# behind the thing it is bounding -- and a per-tick sampler reads the overshoot.
	_retire_surplus()


func count() -> int:
	return TentacleTuning.TENTACLE_COUNT


## World position of strand `i`'s shoulder. Read from the model's own socket node
## rather than recomputed, so the point force is applied at and the point the geometry
## grows from cannot drift apart.
func shoulder(index: int) -> Vector3:
	if shoulders == null or index >= shoulders.get_child_count():
		return body.global_position if body != null else global_position
	return (shoulders.get_child(index) as Node3D).global_position


## How far strand `index` can usefully stretch, world metres. Read by TentacleBones to
## decide how much a strand should bow: the same chord is taut on a short tentacle and
## slack on a long one, and that difference is most of what sells eight limbs of
## different lengths as one creature.
func reach_of(index: int) -> float:
	return _reach[index]


## Strand `index`'s search azimuth, radians. Exposed so `[sectors]` can assert the
## strands do not overlap without re-implementing `_build_sectors()` -- a test that
## spells the rule out a second time only ever asserts what the test thinks the rule is.
func sector_of(index: int) -> float:
	return _sector[index]


## Searches this strand has run that found nothing legal.
##
## The number that tells "the launch scheduler is starving this strand" apart from
## "this strand is too short to reach anything in its own sector" -- two failures that
## look identical from the launch counts alone, and have opposite fixes.
func search_misses(index: int) -> int:
	return _misses[index]


func phase_of(index: int) -> int:
	return _phase[index]


## Planted or pulling. The distinction matters to the stroke but not to the force:
## a pulling strand is still gripping.
func is_planted(index: int) -> bool:
	return _phase[index] == Phase.PLANTED or _phase[index] == Phase.PULLING


func anchor(index: int) -> Vector3:
	return _anchor[index]


func anchor_normal(index: int) -> Vector3:
	return _normal[index]


func tip(index: int) -> Vector3:
	return _tip[index]


## 0 while coiled, 1 at full extension. Used to thin the ribbon while a strand flies.
func extend_fraction(index: int) -> float:
	return _extend[index]


## The stroke's force envelope for this strand right now, 0 when it is not pulling.
func envelope(index: int) -> float:
	if _phase[index] != Phase.PULLING:
		return 0.0
	return TentacleTuning.stroke_envelope(_stroke[index] / TentacleTuning.STROKE_TIME)


func planted_count() -> int:
	var total: int = 0
	for i: int in count():
		if is_planted(i):
			total += 1
	return total


## Strands on their way to an anchor. Read by `_release_stale` to answer "is anything
## inbound?" before it lets the last grips go.
func _reaching_count() -> int:
	var total: int = 0
	for i: int in count():
		if _phase[i] == Phase.REACHING:
			total += 1
	return total


func any_pulling() -> bool:
	for i: int in count():
		if _phase[i] == Phase.PULLING:
			return true
	return false


func debug_state() -> Dictionary:
	var letters: String = ""
	for i: int in count():
		letters += "SRPUL".substr(_phase[i], 1)
	return {
		"planted_count": planted_count(),
		"any_pulling": any_pulling(),
		"phases": letters,
	}


## Each strand's search sector, solved once from where its socket actually sits.
##
## THE MODEL'S SOCKETS DO NOT TILE A CIRCLE. Eight of them sit in four pairs -- roughly
## plus and minus 50 and 130 degrees around the forward axis, four low "legs" and four
## raised "arms" -- separated inside each pair only by depth. Hunting straight out of
## each socket therefore puts two strands in one cone, leaves the four quadrant centres
## unhunted, and the creature grows a beard on four sides. Handing out an even ring
## instead is worse the other way: leg tentacles get sent hunting the ceiling and cross
## over each other to get there.
##
## So: measure, rank by azimuth, and relax each strand most of the way toward the even
## ring it would have had. Arms stay high, legs stay low, and the circle still tiles.
## Solved from the REST POSE at _ready and then fixed -- a sector that moved with the
## body would make the search direction depend on the writhe.
func _build_sectors() -> void:
	var total: int = count()
	var measured: PackedFloat32Array = PackedFloat32Array()
	measured.resize(total)
	var frame: Basis = Basis.IDENTITY
	var origin: Vector3 = global_position
	if body != null:
		frame = body.global_basis.orthonormalized()
		origin = body.global_position
	for i: int in total:
		var offset: Vector3 = frame.inverse() * (shoulder(i) - origin)
		# Azimuth about the body's forward axis, so x is right and y is up.
		measured[i] = atan2(offset.y, offset.x)

	var order: Array[int] = []
	order.assign(range(total))
	order.sort_custom(func(a: int, b: int) -> bool: return measured[a] < measured[b])

	# THE RING IS PINNED TO WHERE THE SOCKETS ACTUALLY ARE, by the CIRCULAR mean of each
	# socket's offset from its own slot. A ring nailed to a fixed angle instead leaves
	# every strand a long way from its slot, so blending toward it barely moves anything
	# and the pairs stay collided -- which is exactly what the first run of `[sectors]`
	# reported, at 0.117 rad between neighbours. A plain arithmetic mean is wrong the
	# moment one offset straddles zero, and this set does straddle it.
	var sum_x: float = 0.0
	var sum_y: float = 0.0
	for rank: int in order.size():
		var offset: float = measured[order[rank]] - TAU * float(rank) / float(total)
		sum_x += cos(offset)
		sum_y += sin(offset)
	var base: float = atan2(sum_y, sum_x)

	for rank: int in order.size():
		var strand: int = order[rank]
		var slot: float = base + TAU * float(rank) / float(total)
		var shift: float = angle_difference(measured[strand], slot)
		_sector[strand] = measured[strand] + shift * TentacleTuning.SECTOR_RELAX


func _age_strands(delta: float) -> void:
	for i: int in count():
		match _phase[i]:
			Phase.SEARCHING:
				_search_age[i] += delta
				_retry[i] = maxf(_retry[i] - delta, 0.0)
			Phase.PLANTED:
				# NO STROKE TRIGGER HERE ANY MORE. A planted strand waits to be told.
				# The old code walked itself to PULLING on a private per-strand delay,
				# which is precisely what smeared eight limbs into a continuous haul --
				# the strokes overlapped and averaged out. `_advance_cycle` now grants
				# PULLING to a whole pair on one tick, and only once per grip.
				_grip_age[i] += delta
			Phase.PULLING:
				_grip_age[i] += delta
				_stroke[i] += delta
				if _stroke[i] >= TentacleTuning.STROKE_TIME:
					# Spent. Back to PLANTED as dead weight -- it will never stroke
					# again on this anchor, it just holds on until it has trailed about
					# a metre behind and `_release_stale` lets it go.
					_phase[i] = Phase.PLANTED


## Re-cast anchors to check the wall is still there: the hauling pair every tick, plus
## one more strand round-robin.
##
## ROUND-ROBIN FOR THE IDLE ONES. Eight confirmation rays every tick is eight times the
## cost for a check whose whole job is to notice a rare event; one per tick gives each
## strand a look about ten times a second, which is far faster than a wall can go
## missing without the creature already being somewhere impossible.
##
## BUT THE HAULING PAIR IS CHECKED EVERY TICK, because for them the rare event is no
## longer rare-in-consequence. A stroke is 0.30 s and the round-robin takes up to 0.13 s
## to come back round, so a strand could spend nearly half a burst hauling the creature
## on a wall that is not there -- and a burst is now the entire propulsion, not one
## contribution among five. Two extra rays, and only while a stroke is running.
##
## Losing a member mid-burst SILENTLY HALVES THE LUNGE: `_begin_release` zeroes `_stroke`
## and `envelope()` reports 0 for anything that is not PULLING, so no state anywhere says
## "this lunge came out at half strength". It self-heals because HAUL exits on its own
## timer rather than on the pair still existing, but a short lunge with no explanation is
## exactly what this comment is here to explain.
func _confirm_anchors() -> void:
	for index: int in _hauling:
		if is_planted(index):
			_confirm_anchor(index)

	var checked: int = 0
	while checked < count():
		_confirm_cursor = (_confirm_cursor + 1) % count()
		checked += 1
		if not is_planted(_confirm_cursor) or _confirm_cursor in _hauling:
			continue
		_confirm_anchor(_confirm_cursor)
		return


## CAST ACROSS THE WALL, NOT FROM THE SHOULDER.
##
## This used to ray from the shoulder to the anchor, and that test degrades exactly as the
## gait improved. Once the search began maximising how far AHEAD an anchor is, grips are
## taken much further forward, so the shoulder-to-anchor line meets the wall at a shallow
## angle -- and it gets shallower every tick as the body lunges past. A grazing ray is the
## one case a raycast is worst at: it skims the surface, misses or returns a point some way
## along it, and the strand is told the wall it is holding has ceased to exist. Measured,
## the propelling pair was being released a median of 3.05 m AHEAD of the body, which is
## the exact opposite of the trailing read the gait is built on.
##
## Probing along the stored normal instead makes the test independent of where the body
## has got to. It also asks a better question: not "can this strand still see its anchor"
## but "is that piece of wall still there".
func _confirm_anchor(index: int) -> void:
	var normal: Vector3 = _normal[index]
	var anchor: Vector3 = _anchor[index]
	var reach: float = TentacleTuning.WALL_LOST_TOLERANCE
	var space: PhysicsDirectSpaceState3D = get_world_3d().direct_space_state
	var params: PhysicsRayQueryParameters3D = PhysicsRayQueryParameters3D.create(
		anchor + normal * reach, anchor - normal * reach, query_mask
	)
	var hit: Dictionary = space.intersect_ray(params)
	var lost: bool = hit.is_empty()
	if not lost:
		lost = (hit["position"] as Vector3).distance_to(anchor) > reach
	if lost:
		_begin_release(index)


## Let go of anchors that have done their work -- but NEVER of the last ones while
## nothing is on its way to replace them.
##
## THE INBOUND GUARD IS NOT THE SAME RULE AS `MIN_PLANTED`, which is why it lives here
## rather than in the predicate. `RELEASE_BEHIND_HARD` deliberately overrides the
## MIN_PLANTED floor -- it is the escape hatch that stops two strands deadlocking each
## other -- and at lunge speeds a spent pair crosses -3.5 m in about a third of a second.
## If the cycle happens to be between teams at that moment, both let go, nothing is
## reaching, and the creature free-falls on the leash and the wall probe alone until the
## next pair plants. A count cannot express "something is on its way"; this can.
##
## Safe to skip the release here because this function only ever reports `lost = false`.
## A wall that has genuinely stopped existing is released by `_confirm_anchors`, which
## does not consult this guard -- holding onto nothing is not a grip worth protecting.
func _release_stale() -> void:
	var travel: Vector3 = body.wanted_direction()
	var origin: Vector3 = body.global_position
	var planted: int = planted_count()
	var inbound: int = _reaching_count()
	for i: int in count():
		if not is_planted(i):
			continue
		var behind: float = (_anchor[i] - origin).dot(travel)
		# HOLD THE LAST PAIR UNTIL A REPLACEMENT IS ACTUALLY GRIPPING -- not until one is
		# merely on its way, and not regardless.
		#
		# Both of the obvious rules are wrong, in opposite directions, and both were
		# measured. Gating on "nothing inbound" blocks the release for most of the cycle,
		# because a strand is only REACHING for a couple of tenths: the soft RELEASE_BEHIND
		# rule then never fires and limbs trail until the -3.5 m deadlock hatch catches
		# them, measured at a -3.77 m median. Dropping the guard entirely goes the other
		# way -- the spent pair lets go a metre back before the fresh pair has landed, and
		# the creature free-falls with nothing attached for 0.77 s.
		#
		# `planted > PAIR_SIZE` is the honest test for "someone else has it now", and it is
		# the brief's own wording: the propelling limbs stay against the surface WHILE two
		# others take hold. The hard escape hatch is still reachable underneath, so a
		# replacement that never lands cannot strand a limb out at the back forever.
		# Gated on ONE remaining grip, not on the pair size. Holding while `planted <= 2`
		# releases the first of the spent pair on time and then strands its partner: the
		# count drops to one, the guard latches, and that limb trails until the -3.5 m
		# hatch collects it. The release depths came out bimodal, one near a metre and one
		# far back, for a median of -2.89 m. Both members of a spent pair should let go
		# within a moment of each other, because they were outrun together.
		if planted <= 1:
			if behind > TentacleTuning.RELEASE_BEHIND_HARD:
				continue
		var stretch: float = shoulder(i).distance_to(_anchor[i])
		if TentacleTuning.should_release(behind, stretch, _grip_age[i], false, planted, _reach[i]):
			_begin_release(i)
			planted -= 1


func _begin_release(index: int) -> void:
	_phase[index] = Phase.RELEASING
	_launch[index] = _tip[index]
	_extend[index] = 1.0
	_grip_age[index] = 0.0
	_stroke[index] = 0.0


## The gait. One pair per lunge, in fixed rotation.
##
## THIS REPLACED A LAUNCH SCHEDULER, and the difference is the whole feature. The old
## code fired the oldest idle strand every FIRE_INTERVAL and let each one stroke on a
## private timer -- eight limbs doing the same thing out of phase, which averages to a
## steady haul no matter how the numbers are tuned. Averaging is exactly what a lunge
## must not do. Here one pair goes out together, plants together, and hauls on a single
## tick, and nothing else may stroke while they do.
func _advance_cycle(delta: float) -> void:
	_cycle_timer = maxf(_cycle_timer - delta, 0.0)
	match _cycle:
		Cycle.LEAD:
			_begin_lead()
		Cycle.FOLLOW:
			if _cycle_timer <= 0.0:
				_fire(_follow_strand)
				_cycle = Cycle.SETTLE
				_cycle_timer = TentacleTuning.PAIR_SETTLE_TIMEOUT
		Cycle.SETTLE:
			_settle()
		Cycle.HAUL:
			if _cycle_timer <= 0.0:
				# THE HANDOFF. Still mid-stroke -- the creature is shooting forward right
				# now -- and the next pair is already being thrown. That overlap is what
				# makes the gait continuous while every individual pull stays discrete.
				_rotate()


## Choose this lunge's pair from whatever is FREE, opposed across the sector ring.
##
## FIXED TEAMS DEADLOCK, and it took measuring to see why. Pairing the eight strands into
## four permanent couples is tidy, deterministic and easy to assert -- and it means a
## couple can only fire when BOTH its members are idle. Up to four strands are gripping at
## any moment, and nothing stops those four landing one in each couple, at which point
## every couple is blocked by a partner that is busy and the gait stops dead until a grip
## happens to expire. Measured: the lunge rate fell from 10 in 8 s to 6, and the creature
## hung with nothing attached for 0.78 s at a stretch.
##
## Pairing dynamically cannot deadlock while any two strands are free, which with eight
## strands and a ceiling of four grips is always. OPPOSITION is what actually mattered
## about the teams -- two anchors on the same side throw the creature at that wall, two
## across from each other cancel laterally and sum forward -- and that is a property of
## the pair chosen, not of it having been chosen in advance.
func _begin_lead() -> void:
	var lead: int = _pick_free_strand(-1)
	if lead < 0:
		return
	var follow: int = _pick_free_strand(lead)
	if follow < 0:
		return
	_lead_strand = lead
	_follow_strand = follow
	if not _fire(_lead_strand):
		return
	_cycle = Cycle.FOLLOW
	_cycle_timer = TentacleTuning.PAIR_STAGGER


## The lead is whichever idle strand has waited longest, so none is starved. The follow is
## whichever idle strand sits furthest around the ring from it.
##
## ONLY SEARCHING STRANDS ARE ELIGIBLE, and that single rule deleted every force-release
## path in this file. Recalling a busy strand to make up a pair let go of limbs that were
## still reaching forward -- and calling `_begin_release` on one already retracting reset
## its extension every tick, so it never reached SEARCHING and the cycle livelocked behind
## it. A strand that is not free simply is not picked.
func _pick_free_strand(partner: int) -> int:
	var best: int = -1
	var best_score: float = -INF
	var opposed: int = -1
	var opposed_age: float = -INF
	for i: int in count():
		if i == partner or _phase[i] != Phase.SEARCHING or _retry[i] > 0.0:
			continue
		if partner < 0:
			if _search_age[i] > best_score:
				best_score = _search_age[i]
				best = i
			continue
		# OPPOSITION IS A THRESHOLD, NOT A RANKING, and the difference is fairness.
		# Ranking strictly by angular separation makes the follow slot a fixed function of
		# the lead, so the same few strands win it forever: measured launch counts ran
		# [3, 4, 6, 6, 5, 5, 8, 7] across the eight. Anything at least a right angle away
		# cancels the lateral perfectly well, so take the longest-waiting of those and let
		# separation decide only when nothing clears the bar.
		var apart: float = absf(angle_difference(_sector[i], _sector[partner]))
		if apart >= PI * 0.5 and _search_age[i] > opposed_age:
			opposed_age = _search_age[i]
			opposed = i
		if apart > best_score:
			best_score = apart
			best = i
	return opposed if opposed >= 0 else best


## Wait for the pair to arrive, then haul -- but not before the glide is spent.
##
## A ONE-MEMBER LUNGE IS ABANDONED, NOT HAULED. It is tempting to pull with whatever
## planted, and it is wrong: a single burst is about 30 m/s^2 with nothing opposing its
## lateral, aimed at a wall two metres away, and `CrawlerBody`'s centroid term then pulls
## toward that same single anchor. Rotating instead costs one cycle of glide.
func _settle() -> void:
	var ready_count: int = 0
	for index: int in [_lead_strand, _follow_strand]:
		if is_planted(index):
			ready_count += 1
		elif _phase[index] != Phase.REACHING:
			# DEAD BEFORE ARRIVAL -- the strand lost its wall, or was released out from
			# under this cycle. Waiting out the rest of the timer for a limb that is no
			# longer on its way is the single largest source of the creature hanging with
			# nothing gripping, so abandon the moment the pair stops being a pair.
			_rotate()
			return
	if ready_count < TentacleTuning.PAIR_SIZE:
		if _cycle_timer <= 0.0:
			_rotate()
		return
	# GLIDE_MIN is what makes the ballistic phase a DESIGN rather than a side effect of
	# how quickly the search happened to succeed. Without it the cadence wanders with
	# search luck and the lunge stops reading as deliberate.
	#
	# WAIVED WHEN NOTHING ELSE IS HOLDING ON. A glide is a choice to coast on momentum
	# while gripping something; with no other grip it is just falling, and sitting on the
	# timer makes that worse for no gain.
	if _since_burst < TentacleTuning.GLIDE_MIN and planted_count() > TentacleTuning.PAIR_SIZE:
		return

	_hauling = PackedInt32Array([_lead_strand, _follow_strand])
	for index: int in _hauling:
		_phase[index] = Phase.PULLING
		_stroke[index] = 0.0
	# THE SPENT PAIR IS NOT RELEASED HERE. Retiring it the moment a fresh pair takes over
	# is the obvious way to bound the planted count, and it deletes the gait's whole back
	# half: the propelling limbs are supposed to stay stuck to the wall and TRAIL, paying
	# out behind the body as it shoots past them, until they are about a metre back.
	# Measured with the eager version, releases averaged 0.05 m behind -- the limbs let go
	# level with the body, which reads as them popping off rather than being outrun.
	# `_release_stale` owns that decision, on RELEASE_BEHIND. See `_retire_surplus` for
	# the ceiling.
	_since_burst = 0.0
	_cycle = Cycle.HAUL
	_cycle_timer = TentacleTuning.PULL_HANDOFF * TentacleTuning.STROKE_TIME


## The ceiling, and the only thing that enforces MAX_PLANTED.
##
## Normally nothing to do: a spent pair lets go on RELEASE_BEHIND about when the next one
## plants, so planted sits between two and four on its own. This is for the pathological
## path -- repeated search failures rotate the cursor without ever reaching HAUL, so grips
## from two or three cycles ago pile up while nothing retires them. Planted was measured
## reaching five that way, over a ceiling of four.
##
## FURTHEST BEHIND FIRST, not oldest first.
##
## Age is a bad proxy for "done with". A strand that gripped early and is still well ahead
## of the body has not finished its job -- it is the one about to take the creature's
## weight -- while one planted a moment ago on a wall the body has already shot past is
## dead weight whatever its age says. Retiring by age let go of limbs that were still 3 m
## in front: `[release-behind]` measured a median release depth of +3.05 m, i.e. the
## propelling pair being cut loose while it was still reaching forward, which is precisely
## the read the gait is supposed to deliver and precisely what was reported missing.
##
## Trimming only the surplus, rather than clearing everything, leaves RELEASE_BEHIND in
## charge of the normal case -- which is where the gait's read actually lives.
func _retire_surplus() -> void:
	var travel: Vector3 = body.wanted_direction()
	var origin: Vector3 = body.global_position
	var planted: int = planted_count()
	while planted > TentacleTuning.PAIR_SIZE * 2:
		var worst: int = -1
		var worst_behind: float = INF
		for i: int in count():
			if _phase[i] != Phase.PLANTED or i in _hauling:
				continue
			var behind: float = (_anchor[i] - origin).dot(travel)
			if behind < worst_behind:
				worst_behind = behind
				worst = i
		if worst < 0:
			return
		_begin_release(worst)
		planted -= 1


## Abandon this lunge and go back to choosing a pair. No cursor to advance any more --
## `_begin_lead` picks from whoever is free, so "try again" is the whole of it.
func _rotate() -> void:
	_cycle = Cycle.LEAD
	_cycle_timer = 0.0


## Throw one strand at whatever `_pick_anchor` found. False if it found nothing.
func _fire(index: int) -> bool:
	var found: Dictionary = _pick_anchor(index)
	if found.is_empty():
		_misses[index] += 1
		_starve[index] += 1
		_retry[index] = TentacleTuning.RETRY_DELAY
		return false
	_starve[index] = 0
	_anchor[index] = found["position"]
	_normal[index] = found["normal"]
	_launch[index] = _tip[index]
	_extend[index] = 0.0
	_phase[index] = Phase.REACHING
	_search_age[index] = 0.0
	return true


## Hunt for something worth gripping in this strand's own sector.
##
## THE AZIMUTH IS SECTORED, NOT RANDOM. A uniformly random azimuth clumps every
## strand onto whichever wall panel happens to be nearest and the creature grows a
## beard on one side. Giving each strand a sector of the circle plus a little jitter
## is what makes it splay. The sectors come from `_build_sectors()`, which solves them
## from where the model's sockets actually are -- see the note there for why neither
## the raw socket direction nor an even ring works on its own.
##
## THE CONE OPENS AROUND THE BODY'S TRAVEL DIRECTION, NOT ITS NOSE. Those differ at
## a bend -- the nose still points at the outer wall while travel has already slid
## round the corner -- and hunting around the nose is exactly how a creature ends up
## grinding its face into a corner with every candidate anchor rejected.
func _pick_anchor(index: int) -> Dictionary:
	var space: PhysicsDirectSpaceState3D = get_world_3d().direct_space_state
	var origin: Vector3 = shoulder(index)
	var travel: Vector3 = body.wanted_direction()
	var sector: float = _sector[index]
	var reach: float = _reach[index]
	# A STARVING STRAND IS ALLOWED TO POACH. Sectors keep the strands splayed, which is
	# the right default -- but a sector is a fixed direction in a body frame that rolls
	# with the nearest wall, so a short strand can end up permanently aimed at the one
	# part of the tube nothing is reachable in, and it will sit in SEARCHING for the
	# whole run rather than grip anything at all. Widening the jitter after consecutive
	# failures lets it look outside its own wedge instead of starving politely. It
	# collapses back the moment it lands one, so the splay survives.
	var desperation: int = mini(_starve[index], TentacleTuning.STARVE_LIMIT)
	var jitter: float = (
		TentacleTuning.SECTOR_JITTER * (1.0 + TentacleTuning.STARVE_WIDEN * float(desperation))
	)
	# And it searches HARDER as well as wider. Rays are only spent on the tick a strand
	# actually fires, and this multiplier only ever applies to a strand that has already
	# failed repeatedly, so the cost lands exactly where the information is missing. The
	# loop returns the moment it finds anything, so a strand that is merely unlucky pays
	# nothing extra.
	var tries: int = attempts * (1 + mini(desperation, 2))
	var best: Dictionary = {}
	# MAXIMISE HOW FAR AHEAD, NOT HOW FAR AWAY.
	#
	# Both read as "full stretch" in a number and they are completely different limbs to
	# look at. A strand taking the farthest hit it can find will happily grip 7 m out to
	# the SIDE, because a near-perpendicular ray is much the cheapest way to a lot of
	# distance. That passes every assertion in this folder, hauls the creature along
	# perfectly well, and looks like the tentacle is waving rather than grabbing something
	# in front of it -- which is exactly how it was reported.
	#
	# Done in the OBJECTIVE rather than as a stricter `is_anchor_valid` -- see the note on
	# FORWARD_BIAS_MIN in TentacleTuning. A tighter predicate REJECTS, and what it rejects
	# first is the short limbs, which cannot afford a narrow angle at all. This rejects
	# nothing: it only reorders the candidates a strand was already willing to take.
	var best_ahead: float = 0.0
	# How far ahead is worth stopping the sweep for. Relaxed by starvation, for the same
	# reason the jitter is: a strand aimed somewhere it can never get far in front of
	# itself must eventually settle for what it can reach rather than hunt forever.
	var enough: float = reach * lerpf(0.55, 0.3, float(desperation) / 4.0)

	for attempt: int in tries:
		# A MONOTONE OUTWARD SWEEP, NOT A DRAW -- this is what makes "full stretch" happen.
		#
		# In a tube a ray at polar angle t off the travel axis meets the wall at about
		# `clearance / sin(t)`, which is strictly DECREASING in t. So sweeping the cone
		# open from its inner edge and taking the first hit yields the FARTHEST anchor
		# this strand can physically reach, and the early return below already stops
		# there. No scoring, no second pass.
		#
		# The predecessor biased a random draw toward the narrow end and did not work,
		# for two reasons worth writing down. A biased draw SAMPLES; it does not
		# maximise -- with the cone 80 degrees wide most samples still land on the near
		# wall. And the value it biased toward was itself scaled by the strand's length,
		# so for a SHORT strand it collapsed to the wide edge and did nothing at all,
		# which is exactly the strand that has the hardest time reaching anything.
		#
		# The sweep needs no such correction because it self-calibrates: the ray is
		# capped at this strand's own reach, so near-axis steps simply miss for a short
		# strand and it picks up further out. That also drops the old dependence on
		# REACH_MAX as a normaliser -- see the warning on that constant.
		var sweep: float = float(attempt) / maxf(float(tries - 1), 1.0)
		var polar: float = lerpf(
			TentacleTuning.CONE_MIN_ANGLE, TentacleTuning.CONE_HALF_ANGLE, sweep
		)
		polar = clampf(
			polar + _rng.randf_range(-0.05, 0.05),
			TentacleTuning.CONE_MIN_ANGLE,
			TentacleTuning.CONE_HALF_ANGLE
		)
		var azimuth: float = sector + _rng.randf_range(-jitter, jitter)
		for _ray: int in rays_per_attempt:
			var jittered: float = azimuth + _rng.randf_range(-0.12, 0.12)
			var direction: Vector3 = _cone_direction(travel, jittered, polar)
			# Ray no longer than the strand can actually reach: a hit past that is not a
			# near miss, it is an anchor this tentacle would be posed pointing at while
			# visibly falling short of.
			#
			# 0.995 RATHER THAN 1.0, and it is not cosmetic. `is_anchor_valid` rejects
			# anything past `reach`, and a hit at the very tip of the ray measures a
			# float hair over it. That never mattered while strands aimed at 80% of
			# their reach; now EVERY good candidate sits on that edge, and the rejection
			# would show up as a strand that intermittently cannot find anything with no
			# indication why.
			var params: PhysicsRayQueryParameters3D = PhysicsRayQueryParameters3D.create(
				origin, origin + direction * reach * 0.995, query_mask
			)
			var hit: Dictionary = space.intersect_ray(params)
			if hit.is_empty():
				continue
			var point: Vector3 = hit["position"]
			var distance: float = origin.distance_to(point)
			var facing: float = (hit["normal"] as Vector3).dot(-direction)
			# From the shoulder: the same vector the stroke force is built from.
			var ahead: float = (point - origin).dot(travel)
			if not TentacleTuning.is_anchor_valid(
				distance, facing, ahead, _nearest_live(point, index), reach
			):
				continue
			if ahead <= best_ahead:
				continue
			best_ahead = ahead
			best = {"position": point, "normal": hit["normal"]}
		# KEEP SWEEPING UNTIL THE HIT IS ACTUALLY WELL FORWARD, not merely until there is
		# one. Stopping at the first valid hit is correct in the continuous limit and
		# wrong at this resolution: the sweep steps in finite jumps, so the step before
		# the wall comes into range overshoots the strand's reach and misses, and the
		# step after it lands well inside. Measured, that quantisation cost up to 15% of
		# reach and only 5 of 24 anchors came out at full stretch. Carrying the best hit
		# and continuing until one clears the band fixes it without a second pass.
		if best_ahead >= enough:
			return best
	return best


## A unit vector `polar` radians off `axis`, rotated `azimuth` around it.
func _cone_direction(axis: Vector3, azimuth: float, polar: float) -> Vector3:
	var hint: Vector3 = body.global_basis.y
	var right: Vector3 = axis.cross(hint)
	if right.length_squared() < 0.0001:
		right = axis.cross(body.global_basis.x)
	right = CrawlerMath.direction_or(right, Vector3.RIGHT)
	var up: Vector3 = right.cross(axis).normalized()
	var radial: Vector3 = right * cos(azimuth) + up * sin(azimuth)
	return (axis * cos(polar) + radial * sin(polar)).normalized()


## Distance from `point` to the nearest OTHER live anchor. Two anchors closer than
## ANCHOR_MIN_SEPARATION fuse into what looks like one thick tentacle, so the
## creature silently loses a limb while keeping its force.
func _nearest_live(point: Vector3, ignore_index: int) -> float:
	var nearest: float = INF
	for i: int in count():
		if i == ignore_index or not is_planted(i):
			continue
		nearest = minf(nearest, point.distance_to(_anchor[i]))
	return nearest


func _update_tips(delta: float) -> void:
	for i: int in count():
		match _phase[i]:
			Phase.SEARCHING:
				_tip[i] = _flail_point(i)
				_extend[i] = 0.0
			Phase.REACHING:
				var span: float = maxf(_launch[i].distance_to(_anchor[i]), 0.001)
				_extend[i] = minf(_extend[i] + reach_speed * delta / span, 1.0)
				_tip[i] = _launch[i].lerp(_anchor[i], _extend[i])
				if _tip[i].distance_to(_anchor[i]) < PLANT_EPSILON:
					_phase[i] = Phase.PLANTED
					_tip[i] = _anchor[i]
					_extend[i] = 1.0
					_grip_age[i] = 0.0
			Phase.PLANTED, Phase.PULLING:
				_tip[i] = _anchor[i]
				_extend[i] = 1.0
			Phase.RELEASING:
				_extend[i] = maxf(_extend[i] - delta / maxf(release_time, 0.001), 0.0)
				_tip[i] = shoulder(i).lerp(_launch[i], _extend[i])
				if _extend[i] <= 0.0:
					_phase[i] = Phase.SEARCHING
					_search_age[i] = 0.0
					_retry[i] = 0.0


## Where a searching tip sits: STREAMED BACKWARD along the body, swaying on its own phase.
##
## THE IDLE LIMBS MUST NOT COMPETE WITH THE REACHING ONES. This used to orbit the
## shoulder at a polar angle of 0.7 +/- 0.35 radians -- measured off the TRAVEL axis, so
## six idle strands waved forward and sideways at 2.4 m while the two that matter threw
## themselves 5 to 7 m forward to grip something. Two limbs reaching and six waving in
## roughly the same direction does not read as "it grabs the wall and hauls", it reads as
## flailing, which is exactly what it was reported as. Nothing was wrong with the gait:
## the eye simply could not find it.
##
## Trailing them instead makes the creature streamline behind its own lunge, and leaves
## FORWARD as a direction that only ever means "this limb is reaching". The sway is slow
## and small for the same reason -- an idle limb should read as slack being dragged, not
## as an animation.
##
## CLAMPED OUT OF THE WALL by one ray. Without it, a strand coiling near a wall pokes
## straight through it and the creature grows spikes out of the corridor -- which is
## both obviously wrong and completely invisible to every physics assertion, because
## a searching strand holds nothing and applies nothing.
func _flail_point(index: int) -> Vector3:
	var origin: Vector3 = shoulder(index)
	var offset: float = TentacleTuning.phase_for(index)
	var azimuth: float = offset + _time * 0.6
	# Measured off the travel axis, so PI is straight back. Held well behind the beam so
	# no idle tip ever crosses into the forward half.
	var polar: float = PI - 0.5 + 0.18 * sin(_time * 1.4 + offset)
	var direction: Vector3 = _cone_direction(body.wanted_direction(), azimuth, polar)
	# Capped by the strand's own length. A 14-link tentacle flailing the full 3.2 m
	# would be posed straighter while COILED than it ever gets while hauling.
	var span: float = minf(flail_reach, _reach[index])
	var space: PhysicsDirectSpaceState3D = get_world_3d().direct_space_state
	var params: PhysicsRayQueryParameters3D = PhysicsRayQueryParameters3D.create(
		origin, origin + direction * span, query_mask
	)
	var hit: Dictionary = space.intersect_ray(params)
	if hit.is_empty():
		return origin + direction * span
	return (hit["position"] as Vector3) - direction * FLAIL_SKIN
