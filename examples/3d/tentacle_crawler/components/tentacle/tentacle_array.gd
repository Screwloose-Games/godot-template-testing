class_name TentacleArray
extends Node3D

## Eight tentacles: where they are looking, what they are holding, and when they pull.
##
## ONE NODE OWNS EVERY STRAND, in parallel arrays indexed by strand. Eight separate
## nodes would mean eight _physics_process calls, eight copies of the launch scheduler,
## and no way to express "at most five of you may be planted" without a ninth node
## to arbitrate -- and that band is most of what makes the creature look gangly.
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
## The phase machine is NOT a strict progression -- PULLING returns to PLANTED, so a
## strand hauls repeatedly on one anchor rather than letting go after every stroke:
##
##   SEARCHING -> REACHING -> PLANTED <-> PULLING
##        ^                     |            |
##        +----- RELEASING <----+------------+

## Phase of one strand. See the diagram above; note the PULLING -> PLANTED back edge.
enum Phase { SEARCHING, REACHING, PLANTED, PULLING, RELEASING }

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
## How fast a launched tip travels, m/s. A 12 m reach takes about 0.46 s at 26.
@export var reach_speed: float = 26.0
## Seconds a strand takes to retract after letting go.
@export var release_time: float = 0.18
## How far a searching tip flails from its shoulder, metres. Short: a searching
## tentacle is COILED and twitching, not extended and waving, which is what makes
## the launch read as a strike.
##
## 2.4 rather than 3.2 now that the strands are real chains. The surplus between the
## flail point and the end of the limb is what CURLS -- see TentacleBones.COIL_TURN --
## so a shorter flail puts more of the tentacle into the coil, which is the read.
@export var flail_reach: float = 2.4

@export_group("Search cost")
## Rays per attempt, jittered around the chosen direction.
@export var rays_per_attempt: int = 3
## Attempts before giving up for this launch slot. At most
## `rays_per_attempt * attempts` rays, and only on the tick a strand actually fires.
@export var attempts: int = 4

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
var _since_stroke: PackedFloat32Array = PackedFloat32Array()
var _sector: PackedFloat32Array = PackedFloat32Array()
var _reach: PackedFloat32Array = PackedFloat32Array()
var _misses: PackedInt32Array = PackedInt32Array()
var _starve: PackedInt32Array = PackedInt32Array()
var _fire_timer: float = 0.0
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
	_since_stroke.resize(count)
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
	_fire_timer = maxf(_fire_timer - delta, 0.0)

	_age_strands(delta)
	_confirm_one_anchor()
	_release_stale()
	_try_launch()
	_update_tips(delta)


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


## Strands that are gripping or about to be. This, not `planted_count()`, is what
## the launch ceiling must be measured against.
func _committed_count() -> int:
	var total: int = 0
	for i: int in count():
		if is_planted(i) or _phase[i] == Phase.REACHING:
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
				_grip_age[i] += delta
				_since_stroke[i] += delta
				if _since_stroke[i] >= TentacleTuning.stroke_delay_for(i):
					_phase[i] = Phase.PULLING
					_stroke[i] = 0.0
			Phase.PULLING:
				_grip_age[i] += delta
				_stroke[i] += delta
				if _stroke[i] >= TentacleTuning.STROKE_TIME:
					# The back edge. Same anchor, haul again after the delay.
					_phase[i] = Phase.PLANTED
					_since_stroke[i] = 0.0


## Re-cast one anchor per tick to check the wall is still there.
##
## ROUND-ROBIN, not all of them. Eight confirmation rays every tick is eight times the cost
## for a check whose whole job is to notice a rare event; one per tick gives each
## strand a look about ten times a second, which is far faster than a wall can go
## missing without the creature already being somewhere impossible.
func _confirm_one_anchor() -> void:
	var checked: int = 0
	while checked < count():
		_confirm_cursor = (_confirm_cursor + 1) % count()
		checked += 1
		if not is_planted(_confirm_cursor):
			continue
		var index: int = _confirm_cursor
		var from: Vector3 = shoulder(index)
		var to: Vector3 = _anchor[index]
		var space: PhysicsDirectSpaceState3D = get_world_3d().direct_space_state
		var params: PhysicsRayQueryParameters3D = PhysicsRayQueryParameters3D.create(
			from, from + (to - from) * 1.05, query_mask
		)
		var hit: Dictionary = space.intersect_ray(params)
		var lost: bool = hit.is_empty()
		if not lost:
			lost = (hit["position"] as Vector3).distance_to(to) > TentacleTuning.WALL_LOST_TOLERANCE
		if lost:
			_begin_release(index)
		return


func _release_stale() -> void:
	var travel: Vector3 = body.wanted_direction()
	var origin: Vector3 = body.global_position
	var planted: int = planted_count()
	for i: int in count():
		if not is_planted(i):
			continue
		var behind: float = (_anchor[i] - origin).dot(travel)
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
	_since_stroke[index] = 0.0


## At most one strand may launch per FIRE_INTERVAL, and the oldest idle strand goes
## first.
##
## Both halves are load-bearing. Without the gate all eight fire on the first frame,
## land together, and stroke together -- which reads as a machine, not an animal.
## Without the oldest-first queue the same one or two strands win the slot every
## time and the rest never fire at all.
func _try_launch() -> void:
	if _fire_timer > 0.0:
		return
	# COMMITTED, not planted. A strand in REACHING has already chosen its anchor and
	# will be gripping within half a second, so counting only the ones currently
	# holding lets a launch go out while another is still in flight -- and the band
	# was measured overshooting to five of six that way.
	if _committed_count() >= TentacleTuning.MAX_PLANTED:
		return
	var best: int = -1
	var best_age: float = -1.0
	for i: int in count():
		if _phase[i] != Phase.SEARCHING or _retry[i] > 0.0:
			continue
		if _search_age[i] > best_age:
			best_age = _search_age[i]
			best = i
	if best < 0:
		return

	var found: Dictionary = _pick_anchor(best)
	if found.is_empty():
		_misses[best] += 1
		_starve[best] += 1
		_retry[best] = TentacleTuning.RETRY_DELAY
		return
	_starve[best] = 0
	_anchor[best] = found["position"]
	_normal[best] = found["normal"]
	_launch[best] = _tip[best]
	_extend[best] = 0.0
	_phase[best] = Phase.REACHING
	_search_age[best] = 0.0
	_fire_timer = TentacleTuning.FIRE_INTERVAL


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
	# What THIS strand would like to be holding: a comfortable fraction of its own
	# length, rather than whatever happens to be closest.
	var wanted: float = reach * TentacleTuning.PREFERRED_REACH
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
	var best_score: float = INF

	for _attempt: int in tries:
		var azimuth: float = sector + _rng.randf_range(-jitter, jitter)
		# THE INNER CONE IS USELESS TO A SHORT STRAND. Polar angle is measured off the
		# corridor axis, so a ray 18 degrees out travels about 9 m before it touches a
		# wall -- fine for a 23-bone tentacle, unreachable for a 14-bone one, which
		# then spends every launch slot casting rays it can never follow and sits in
		# SEARCHING for the whole run. Bias the draw outward in proportion to how short
		# this strand is, so each one spends its rays where its own length can land.
		var span: float = reach / maxf(TentacleTuning.REACH_MAX, 0.001)
		var polar_low: float = lerpf(
			TentacleTuning.CONE_HALF_ANGLE, TentacleTuning.CONE_MIN_ANGLE, span * span
		)
		var polar: float = lerpf(polar_low, TentacleTuning.CONE_HALF_ANGLE, _rng.randf())
		for _ray: int in rays_per_attempt:
			var jittered: float = azimuth + _rng.randf_range(-0.12, 0.12)
			var direction: Vector3 = _cone_direction(travel, jittered, polar)
			# Ray no longer than the strand can actually reach: a hit past that is not a
			# near miss, it is an anchor this tentacle would be posed pointing at while
			# visibly falling short of.
			var params: PhysicsRayQueryParameters3D = PhysicsRayQueryParameters3D.create(
				origin, origin + direction * reach, query_mask
			)
			var hit: Dictionary = space.intersect_ray(params)
			if hit.is_empty():
				continue
			var point: Vector3 = hit["position"]
			var distance: float = origin.distance_to(point)
			# SCORED AGAINST THIS STRAND'S OWN WORKING DISTANCE, not simply nearest.
			#
			# Taking the nearest hit is the obvious rule and it starves the short limbs.
			# Every strand prefers the same near wall, but a long strand can reach it
			# too -- so the long ones get there first, and ANCHOR_MIN_SEPARATION then
			# locks the short ones out of the only band they can physically reach. The
			# model's 14- and 15-bone arms missed 10 and 13 searches out of 13 that way
			# while the long strands missed none. Scoring by distance-from-preferred
			# makes long strands reach PAST the near wall and leaves it free.
			var score: float = absf(distance - wanted)
			if score >= best_score:
				continue
			var facing: float = (hit["normal"] as Vector3).dot(-direction)
			# From the shoulder: the same vector the stroke force is built from.
			var ahead: float = (point - origin).dot(travel)
			if not TentacleTuning.is_anchor_valid(
				distance, facing, ahead, _nearest_live(point, index), reach
			):
				continue
			best_score = score
			best = {"position": point, "normal": hit["normal"]}
		if not best.is_empty():
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
					_since_stroke[i] = 0.0
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


## Where a searching tip sits: coiled near the shoulder, twitching on its own phase.
##
## CLAMPED OUT OF THE WALL by one ray. Without it, a strand coiling near a wall pokes
## straight through it and the creature grows spikes out of the corridor -- which is
## both obviously wrong and completely invisible to every physics assertion, because
## a searching strand holds nothing and applies nothing.
func _flail_point(index: int) -> Vector3:
	var origin: Vector3 = shoulder(index)
	var offset: float = TentacleTuning.phase_for(index)
	var azimuth: float = offset + _time * 1.7
	var polar: float = 0.7 + 0.35 * sin(_time * 2.3 + offset)
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
