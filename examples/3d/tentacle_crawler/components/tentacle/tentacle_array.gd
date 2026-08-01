class_name TentacleArray
extends Node3D

## Six tentacles: where they are looking, what they are holding, and when they pull.
##
## ONE NODE OWNS ALL SIX STRANDS, in parallel arrays indexed by strand. Six separate
## nodes would mean six _physics_process calls, six copies of the launch scheduler,
## and no way to express "at most four of you may be planted" without a seventh node
## to arbitrate -- and that band is most of what makes the creature look gangly.
##
## THIS IS THE ONLY FILE THAT RAYCASTS FOR ANCHORS and the only file that owns strand
## lifecycle. It applies NO FORCE: CrawlerBody reads the anchors and does that, so
## Newton's third law is not split across two files that have to agree on a sign.
## TentacleRibbons reads the same state and draws it, and applies no force either.
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
## Node holding one Marker3D per strand. Read for shoulder positions only.
@export var shoulders: Node3D

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
@export var flail_reach: float = 3.2

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
	for i: int in count:
		_phase[i] = Phase.SEARCHING
		_tip[i] = shoulder(i)


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


## World position of strand `i`'s shoulder. Read from the authored Marker3D rather
## than recomputed, so moving a shoulder in crawler.tscn moves both the force
## application point and the drawn root together.
func shoulder(index: int) -> Vector3:
	if shoulders == null or index >= shoulders.get_child_count():
		return body.global_position if body != null else global_position
	return (shoulders.get_child(index) as Node3D).global_position


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
## ROUND-ROBIN, not all six. Six confirmation rays every tick is six times the cost
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
		if TentacleTuning.should_release(behind, stretch, _grip_age[i], false, planted):
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
## Both halves are load-bearing. Without the gate all six fire on the first frame,
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
		_retry[best] = TentacleTuning.RETRY_DELAY
		return
	_anchor[best] = found["position"]
	_normal[best] = found["normal"]
	_launch[best] = _tip[best]
	_extend[best] = 0.0
	_phase[best] = Phase.REACHING
	_search_age[best] = 0.0
	_fire_timer = TentacleTuning.FIRE_INTERVAL


## Hunt for something worth gripping in this strand's own sector.
##
## THE AZIMUTH IS SECTORED, NOT RANDOM. A uniformly random azimuth clumps all six
## strands onto whichever wall panel happens to be nearest and the creature grows a
## beard on one side. Giving each strand a sector of the circle plus a little jitter
## is what makes it splay.
##
## THE CONE OPENS AROUND THE BODY'S TRAVEL DIRECTION, NOT ITS NOSE. Those differ at
## a bend -- the nose still points at the outer wall while travel has already slid
## round the corner -- and hunting around the nose is exactly how a creature ends up
## grinding its face into a corner with every candidate anchor rejected.
func _pick_anchor(index: int) -> Dictionary:
	var space: PhysicsDirectSpaceState3D = get_world_3d().direct_space_state
	var origin: Vector3 = shoulder(index)
	var travel: Vector3 = body.wanted_direction()
	var sector: float = TAU * float(index) / float(count()) + TAU / float(2 * count())
	var best: Dictionary = {}
	var best_distance: float = INF

	for _attempt: int in attempts:
		var azimuth: float = (
			sector + _rng.randf_range(-TentacleTuning.SECTOR_JITTER, TentacleTuning.SECTOR_JITTER)
		)
		var polar: float = lerpf(
			TentacleTuning.CONE_MIN_ANGLE, TentacleTuning.CONE_HALF_ANGLE, _rng.randf()
		)
		for _ray: int in rays_per_attempt:
			var jittered: float = azimuth + _rng.randf_range(-0.12, 0.12)
			var direction: Vector3 = _cone_direction(travel, jittered, polar)
			var params: PhysicsRayQueryParameters3D = PhysicsRayQueryParameters3D.create(
				origin, origin + direction * TentacleTuning.REACH_MAX, query_mask
			)
			var hit: Dictionary = space.intersect_ray(params)
			if hit.is_empty():
				continue
			var point: Vector3 = hit["position"]
			var distance: float = origin.distance_to(point)
			if distance >= best_distance:
				continue
			var facing: float = (hit["normal"] as Vector3).dot(-direction)
			var ahead: float = (point - body.global_position).dot(travel)
			if not TentacleTuning.is_anchor_valid(
				distance, facing, ahead, _nearest_live(point, index)
			):
				continue
			best_distance = distance
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
	var space: PhysicsDirectSpaceState3D = get_world_3d().direct_space_state
	var params: PhysicsRayQueryParameters3D = PhysicsRayQueryParameters3D.create(
		origin, origin + direction * flail_reach, query_mask
	)
	var hit: Dictionary = space.intersect_ray(params)
	if hit.is_empty():
		return origin + direction * flail_reach
	return (hit["position"] as Vector3) - direction * FLAIL_SKIN
