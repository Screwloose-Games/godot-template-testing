extends Node

## Drives the sandbox for real and asserts what came out.
##
## Everything here needs a running scene tree, real physics ticks and real input.
## The static suite covers everything that can be decided by loading a file.
##
## Run it (a .tscn wrapper, not --script: a node added during
## SceneTree._initialize() never receives _ready(), so a bare script would run
## nothing, print nothing and exit 0 -- indistinguishable from a pass):
##   godot --headless --path <root> res://examples/3d/tentacle_crawler/tools/verify_tentacle_crawler_runtime.tscn

## How fast the marker is dragged along the generated corridor's centreline, m/s.
## Close to the creature's own measured crawl speed on purpose: rail it much faster
## and the leash saturates, so the test measures the leash hauling the body rather
## than the creature crawling.
const RAIL_SPEED: float = 6.0

var _world: Node
var _marker: MarkerPilot
var _crawler: CrawlerBody
var _camera: CrawlerCameraDirector
var _tentacles: TentacleArray
var _failures: int = 0


func _ready() -> void:
	await _load_world()
	await _check_static_hold()
	await _check_lag()
	await _check_pushoff_control()
	await _check_pushoff()
	await _check_tentacles()
	await _check_drag_requires_anchors()
	await _check_ratchet()
	await _check_bone_pose()
	await _check_corridor_run()
	await _check_input_owner()
	await _check_camera()

	print("")
	if _failures > 0:
		printerr("%d check(s) FAILED" % _failures)
		get_tree().quit(1)
		return
	print("all checks passed")
	get_tree().quit(0)


## Builds a fresh scene. Called again by any check that needs a clean slate --
## reusing a world that a previous check has flung 20 m down the corridor is how a
## suite starts measuring its own leftovers.
func _load_world() -> void:
	if _world != null:
		_world.queue_free()
		await get_tree().process_frame
	var packed: PackedScene = load(_res("../scenes/crawl_sandbox.tscn")) as PackedScene
	if packed == null:
		printerr("could not load crawl_sandbox.tscn")
		get_tree().quit(1)
		return
	_world = packed.instantiate()
	add_child(_world)
	_marker = _world.get_node_or_null("MarkerPilot") as MarkerPilot
	_crawler = _world.get_node_or_null("Crawler") as CrawlerBody
	_camera = _world.get_node_or_null("CameraDirector") as CrawlerCameraDirector
	# One deliberate, greppable hop into the actor to reach its tentacles. A test is
	# allowed to know more about a component than the game does.
	_tentacles = (
		_crawler.get_node_or_null("Tentacles") as TentacleArray if _crawler != null else null
	)
	if _marker != null:
		_marker.capture_mouse = false
	await _wait(0.5)


## THE POSITIVE CONTROL, and it runs first on purpose.
##
## Every other check here measures the creature moving. If it creeps on its own then
## every "it moved" assertion below passes for the wrong reason.
##
## IT SETTLES FIRST. The creature spawns a full leash-length behind the marker, so
## the first few seconds are it legitimately closing that gap -- measuring from t=0
## reports five metres of correct behaviour as a failure. What is actually being
## asserted is that it holds STATION once it has arrived, which is a claim about the
## steady state and has to be measured in one.
func _check_static_hold() -> void:
	if _crawler == null:
		_report("static-hold", false, "no Crawler in the scene")
		return
	await _wait(5.0)
	var start: Vector3 = _crawler.debug_state()["position"] as Vector3
	await _wait(3.0)
	var drift: float = start.distance_to(_crawler.debug_state()["position"] as Vector3)
	var lead: float = _marker.global_position.distance_to(
		_crawler.debug_state()["position"] as Vector3
	)
	_report(
		"static-hold",
		drift < 1.0,
		(
			"settled, then drifted %.3f m in 3.0 s (need < 1.0); sits %.2f m from the marker"
			% [drift, lead]
		)
	)


## It must NOT snap to the marker, and it MUST eventually arrive. The pair is the
## assertion -- either half alone is satisfied by a creature that is broken in the
## other direction.
func _check_lag() -> void:
	await _load_world()
	if _crawler == null or _marker == null:
		_report("lag", false, "no Crawler or MarkerPilot in the scene")
		return
	var body: Vector3 = _crawler.debug_state()["position"] as Vector3
	_marker.teleport(body + Vector3.FORWARD * 20.0)

	await _wait(0.25)
	var early: float = _gap()
	await _wait(3.75)
	var late: float = _gap()
	_report(
		"lag",
		early > 12.0 and late < 6.0,
		"gap %.2f m at 0.25 s (need > 12), %.2f m at 4.0 s (need < 6)" % [early, late]
	)


## THE CONTROL FOR THE WALL PUSH-OFF. Same setup as the positive below, one
## variable changed, so the difference between them is attributable to that variable
## and nothing else.
##
## THE MARKER IS DETACHED IN BOTH. The first version of this check left it wired and
## "proved" the push-off worked -- but the marker sits on the corridor axis, so what
## it actually measured was the LEASH hauling the creature back to the middle. It
## reported a working probe on a build where probe_gain was zero. A control that
## shares a mechanism with the thing it is controlling for is not a control.
func _check_pushoff_control() -> void:
	await _load_world()
	if _crawler == null:
		_report("pushoff-ctrl", false, "no Crawler in the scene")
		return
	_crawler.target_marker = null
	_tentacles.enabled = false
	_crawler.probe_gain = 0.0
	_crawler.teleport(Vector3(3.0, 0.0, -8.0))
	await _wait(2.0)
	var clearance: float = _crawler.debug_state()["clearance"]
	# Measured against body_radius rather than a literal, because with the probe off the
	# creature is still pushed out to its own shell -- and a control whose threshold is a
	# magic number stops being a control the first time the creature changes size.
	var floor_gap: float = _crawler.body_radius + 0.25
	_report(
		"pushoff-ctrl",
		clearance < floor_gap,
		(
			"probe_gain 0, no leash: clearance still %.2f m (need < %.2f, i.e. did NOT move)"
			% [clearance, floor_gap]
		)
	)


## The push-off backs the creature off a wall it was dropped next to.
##
## ASSERTED ON CLEARANCE, NOT ON DISTANCE FROM THE AXIS, because clearance is what
## this force actually controls. The probe only pushes inside `probe_comfort`, so in
## a 9 m corridor it has a 3.8 m dead band through the middle and settles the
## creature at 2.6 m off the near wall rather than on the centreline. That is the
## design -- true centring is the tentacles' job, via the anchor centroid -- and an
## axis-offset assertion here would either fail correctly-working code or have to be
## loosened until it proved nothing.
func _check_pushoff() -> void:
	await _load_world()
	if _crawler == null:
		_report("pushoff", false, "no Crawler in the scene")
		return
	# Leash AND tentacles detached, so probe_gain is the only difference between this
	# and the control above. With the strands live they haul the creature toward
	# whatever they have gripped, which is a second centring mechanism fighting the
	# one under test -- the first version of this measured both and reported a
	# push-off half as strong as it is.
	_crawler.target_marker = null
	_tentacles.enabled = false
	_crawler.teleport(Vector3(3.0, 0.0, -8.0))
	await _wait(3.0)
	var clearance: float = _crawler.debug_state()["clearance"]
	var wanted: float = _crawler.probe_comfort - 0.3
	_report(
		"pushoff",
		clearance > wanted,
		"backed off to %.2f m clearance from 1.50 (need > %.2f)" % [clearance, wanted]
	)


## Watches every strand on every physics tick for six seconds and reports four
## things at once: anchors land on real walls, they land AHEAD, no two strands launch
## on the same tick, and every strand gets a turn.
##
## Sampled per TICK rather than per interval on purpose. The stagger is a property of
## exactly which tick each launch happened on, and any coarser sample cannot tell
## "six strands launched 0.22 s apart" from "six strands launched together".
func _check_tentacles() -> void:
	await _load_world()
	if _tentacles == null or _crawler == null or _marker == null:
		_report("tentacles", false, "no TentacleArray in the scene")
		return

	var strands: int = _tentacles.count()
	var launch_ticks: Array[Array] = []
	var launches: PackedInt32Array = PackedInt32Array()
	launches.resize(strands)
	for i: int in strands:
		launch_ticks.append([])
	var was_reaching: Array[bool] = []
	for i: int in strands:
		was_reaching.append(false)

	var was_pulling: Array[bool] = []
	var was_gripping: Array[bool] = []
	for i: int in strands:
		was_pulling.append(false)
		was_gripping.append(false)

	var planted_min: int = strands + 1
	var planted_max: int = -1
	var ungripped: int = 0
	var longest_ungripped: int = 0
	var off_wall: int = 0
	var backward: int = 0
	var checked_anchors: int = 0
	# [pair-lunge]: the tick each PULLING onset happened on, and which strand it was.
	var burst_ticks: Array[int] = []
	var burst_strands: Array[int] = []
	# [full-stretch]: shoulder-to-anchor against that strand's own reach, at plant time.
	var stretched: int = 0
	var plants: int = 0
	var stretch_ratios: Array[float] = []
	var forward_ratios: Array[float] = []
	var stroked: Array[bool] = []
	for i: int in strands:
		stroked.append(false)
	# [release-behind]: how far behind the body an anchor was when it was let go.
	var release_depths: Array[float] = []

	# Fly the marker down the corridor so the creature has a reason to reach.
	Input.action_press(&"crawler_forward")
	# A ONE-SECOND WARM-UP, excluded from the planted floor. The creature starts with
	# every strand SEARCHING and nothing gripping, so tick zero is legitimately 0 planted
	# and a floor asserted from it can only ever be 0 -- which asserts nothing.
	var warmup: int = Engine.physics_ticks_per_second
	var ticks: int = int(8.0 * Engine.physics_ticks_per_second)
	for tick: int in ticks:
		await get_tree().physics_frame
		var planted: int = _tentacles.planted_count()
		if tick >= warmup:
			planted_min = mini(planted_min, planted)
			planted_max = maxi(planted_max, planted)
			if planted == 0:
				ungripped += 1
				longest_ungripped = maxi(longest_ungripped, ungripped)
			else:
				ungripped = 0
		for i: int in strands:
			var phase: int = _tentacles.phase_of(i)
			var reaching: bool = phase == TentacleArray.Phase.REACHING
			if reaching and not was_reaching[i]:
				(launch_ticks[i] as Array).append(tick)
				launches[i] += 1
				if not _anchor_is_on_wall(i):
					off_wall += 1
				if not _anchor_is_ahead(i):
					backward += 1
				checked_anchors += 1
			was_reaching[i] = reaching

			var pulling: bool = phase == TentacleArray.Phase.PULLING
			if pulling and not was_pulling[i]:
				burst_ticks.append(tick)
				burst_strands.append(i)
			was_pulling[i] = pulling

			if pulling:
				stroked[i] = true

			var gripping: bool = _tentacles.is_planted(i)
			if gripping and not was_gripping[i]:
				plants += 1
				stroked[i] = false
				var reach: float = maxf(_tentacles.reach_of(i), 0.001)
				var arm: Vector3 = _tentacles.anchor(i) - _tentacles.shoulder(i)
				stretch_ratios.append(arm.length() / reach)
				# The forward component, which is what the solver now maximises and what
				# "reach forward and grab the wall" actually means to look at.
				var forward: float = arm.dot(_crawler.wanted_direction()) / reach
				forward_ratios.append(forward)
				if forward >= 0.45:
					stretched += 1
			elif was_gripping[i] and phase == TentacleArray.Phase.RELEASING:
				# ONLY THE STRANDS THAT ACTUALLY PROPELLED. The brief is about the pair
				# that hauls: it stays stuck to the wall until it is about a metre behind.
				# Strands that gripped and were retired without ever stroking -- surplus
				# trims, overstretch on a limb the body swung wide of, a team recalled for
				# its turn -- release wherever they happen to be, and averaging them in
				# measures the exceptions rather than the gait.
				if stroked[i]:
					var travel: Vector3 = _crawler.wanted_direction()
					var offset: Vector3 = _tentacles.anchor(i) - _crawler.global_position
					release_depths.append(offset.dot(travel))
			was_gripping[i] = gripping
	Input.action_release(&"crawler_forward")

	_report(
		"anchors-on-walls",
		checked_anchors > 0 and off_wall == 0,
		(
			"%d anchors taken, %d not on a corridor surface (need 0, and > 0 taken)"
			% [checked_anchors, off_wall]
		)
	)
	_report(
		"forward-progress",
		checked_anchors > 0 and backward == 0,
		"%d anchors behind the body at plant time (need 0)" % backward
	)
	# A CEILING, AND A TIME LIMIT RATHER THAN A FLOOR.
	#
	# A hard floor of one grip is the obvious assertion and it is wrong for this gait: the
	# spent pair deliberately hangs on until it has trailed a metre behind, and the fresh
	# pair is still in flight when it lets go, so there is a real and intended moment mid
	# lunge with nothing attached at all. That is the creature being ballistic, which is
	# the whole point of the glide.
	#
	# What must NOT happen is free-falling for an appreciable time -- that is the failure
	# where the cycle has stalled and the leash is quietly doing the work. So: bound how
	# LONG it may hold nothing, not whether it ever does.
	var ungripped_seconds: float = float(longest_ungripped) / float(Engine.physics_ticks_per_second)
	_report(
		"planted-band",
		planted_max <= TentacleTuning.MAX_PLANTED and ungripped_seconds < 0.35,
		(
			"planted ranged %d..%d after warm-up (ceiling %d), longest with nothing gripping %.2f s (need < 0.35)"
			% [planted_min, planted_max, TentacleTuning.MAX_PLANTED, ungripped_seconds]
		)
	)

	# The spread bar is 3 rather than 2 because the two shortest chains genuinely fail the
	# odd search -- a 4.4 m limb in a 4 m-clear tube has a very narrow band of angles that
	# reach a wall at all -- and a failed search costs its team that turn. Measured at 1,
	# 2 and 3 across runs where the rotation was demonstrably working.
	#
	# ASSERTED AS A BALANCE, NOT AS A QUOTA. "Every strand launched at least twice in six
	# seconds" was the right test for a scheduler that picked the oldest idle strand; it
	# is the wrong one for fixed teams in fixed rotation. Four teams at roughly a 0.8 s
	# cycle get about 1.9 turns each in the window, so whether a given strand lands on 1
	# or 2 is which side of the quantisation it fell on, not whether the gait is fair.
	# Measured [2, 2, 3, 2, 2, 2, 1, 1] on a run where the rotation was working perfectly.
	#
	# What the design actually guarantees is that no strand is SKIPPED and no strand
	# hogs: the cursor visits every team in order, so counts may differ by the window
	# quantisation plus one failed search, and no more.
	var starved: int = 0
	var most: int = 0
	var fewest: int = strands + 1
	for i: int in strands:
		if launches[i] < 1:
			starved += 1
		most = maxi(most, launches[i])
		fewest = mini(fewest, launches[i])
	var spread: int = most - fewest
	var collisions: int = _same_tick_launches(launch_ticks, strands)
	# Misses alongside launches, because "never got a launch slot" and "got the slot and
	# could not reach anything" look identical from the launch counts and want opposite
	# fixes -- one is the scheduler, the other is reach or sector geometry.
	var misses: Array[int] = []
	var reaches: Array[String] = []
	for i: int in strands:
		misses.append(_tentacles.search_misses(i))
		reaches.append("%.1f" % _tentacles.reach_of(i))
	_report(
		"stagger",
		starved == 0 and spread <= 3 and collisions == 0,
		(
			"launches %s, misses %s, reach %s, %d never fired, spread %d (need <= 3), %d same-tick collisions"
			% [str(launches), str(misses), str(reaches), starved, spread, collisions]
		)
	)
	_report_pair_lunge(burst_ticks, burst_strands)
	# ASSERTED ON THE MEAN, NOT ON A HEADCOUNT CLEARING REACH_TOLERANCE.
	#
	# REACH_TOLERANCE is a SEARCH parameter -- it tells the sweep when it may stop hunting
	# and settle -- and it makes a poor pass mark, because whether a given strand can hit
	# 85% of its own reach is a fact about the wall in front of it rather than about the
	# solver. Each strand hunts a fixed azimuth sector, so one aimed at a flat face has
	# less distance available than one aimed into a corner; ANCHOR_MIN_SEPARATION then
	# vetoes the far candidates that sit too near an existing grip; and FORWARD_BIAS_MIN
	# rules out the widest angles, which are where the short strands' longest rays live.
	# 79% was measured with the sweep running to exhaustion and taking the farthest hit it
	# could find -- that IS the geometry's ceiling here, not a solver leaving reach unused.
	#
	# The mean is the honest statement of "it uses the full length of the tentacle", and
	# it still separates cleanly from the failure worth catching: a regression to
	# nearest-wins, or to the old fixed 0.8-of-reach target, lands near 0.4-0.5.
	var mean_ratio: float = 0.0
	for ratio: float in stretch_ratios:
		mean_ratio += ratio
	mean_ratio /= maxf(float(stretch_ratios.size()), 1.0)
	var mean_forward: float = 0.0
	for ratio: float in forward_ratios:
		mean_forward += ratio
	mean_forward /= maxf(float(forward_ratios.size()), 1.0)
	# ASSERTED ON THE FORWARD COMPONENT, with total stretch reported alongside.
	#
	# Total reach is the wrong bar now, and it was the wrong bar all along -- a strand
	# gripping 7 m out to the side scores beautifully on it and is precisely the failure
	# this is supposed to catch. The two numbers together also localise a regression: a
	# high total with a low forward share means the search went back to preferring
	# whatever is farthest, which is the near-perpendicular ray every time.
	_report(
		"full-stretch",
		plants > 0 and mean_forward >= 0.45,
		(
			"mean %.0f%% of reach spent FORWARD over %d anchors (need >= 45%%), %d cleared it; total stretch %.0f%%"
			% [mean_forward * 100.0, plants, stretched, mean_ratio * 100.0]
		)
	)
	_report_release_behind(release_depths)


## THE DIRECT ASSERTION OF THE GAIT: two tentacles, together, over and over.
##
## Every other check here would still pass on the old continuous haul -- anchors would
## land on walls, ahead, staggered, and drag the creature along. Only this one can tell
## "two strands lunge in unison" from "eight strands pull out of phase".
##
## Onsets are grouped by proximity in TICKS rather than sampled per interval, for the
## same reason the launch stagger is: the whole property is which tick each strand
## started on, and any coarser sample cannot tell a synchronised pair from two strands
## that happened to fall in the same window.
func _report_pair_lunge(burst_ticks: Array[int], burst_strands: Array[int]) -> void:
	if _tentacles == null:
		_report("pair-lunge", false, "no TentacleArray in the scene")
		return
	# PAIR_STAGGER is the launch gap, not the stroke gap -- a pair is granted PULLING on
	# one tick. Three ticks of slack covers nothing worse than rounding.
	var window: int = int(TentacleTuning.PAIR_STAGGER * Engine.physics_ticks_per_second) + 3
	var lunges: int = 0
	var full_pairs: int = 0
	var same_side: int = 0
	var i: int = 0
	while i < burst_ticks.size():
		var j: int = i
		while j + 1 < burst_ticks.size() and burst_ticks[j + 1] - burst_ticks[i] <= window:
			j += 1
		var size: int = j - i + 1
		lunges += 1
		if size == TentacleTuning.PAIR_SIZE:
			full_pairs += 1
			# OPPOSED, not merely simultaneous. The pair exists so the two pulls cancel
			# laterally and sum forward; two limbs hauling from the same side of the ring
			# throw the creature at that wall instead. Half the ring apart is the ideal, so
			# require at least a right angle of separation.
			var apart: float = absf(
				angle_difference(
					_tentacles.sector_of(burst_strands[i]), _tentacles.sector_of(burst_strands[j])
				)
			)
			if apart < PI * 0.5:
				same_side += 1
		i = j + 1
	_report(
		"pair-lunge",
		# Same-side pairs are bounded rather than banned. The pair is chosen from whichever
		# strands are FREE, and occasionally the free set holds nothing a right angle away
		# from the longest-waiting one. Lunging with a less-than-ideal pair beats not
		# lunging -- the alternative is stalling the gait to wait for a better partner --
		# so allow a small tail and fail if it becomes the rule.
		lunges >= 5 and full_pairs == lunges and same_side * 5 <= lunges,
		(
			"%d lunges in 8 s (need >= 5), %d were a full pair of %d, %d pulled from the same side (allow 1 in 5)"
			% [lunges, full_pairs, TentacleTuning.PAIR_SIZE, same_side]
		)
	)


## The spent pair must let go at about a metre behind, not at the escape hatch.
##
## `RELEASE_BEHIND_HARD` (-3.5) deliberately overrides the planted floor so two strands
## can never deadlock each other. That makes it a perfectly good way for the gait to
## LOOK like it works while the soft rule never fires at all -- the creature would still
## crawl, still lunge, still pass every other check, and drag its spent limbs three and a
## half metres before letting go. Asserting the mean depth is what separates the two.
##
## SANDBOX ONLY, and deliberately so: `behind` is measured against
## `CrawlerBody.wanted_direction()`, which is the corner-peeked bearing to the marker. At
## a bend that vector swings, so `behind` steps by whole metres for reasons that have
## nothing to do with when a strand let go.
func _report_release_behind(depths: Array[float]) -> void:
	if depths.is_empty():
		_report("release-behind", false, "no strand released its grip in 8 s")
		return
	# MEASURED OVER THE RELEASES THAT TRAILED, AND ON THE MEDIAN.
	#
	# Not every propelling limb can reach a metre behind the body, and that is geometry
	# rather than a fault. A grip is also given up on OVERSTRETCH, deliberately, at 1.08 of
	# the strand's reach -- paired with the poser's STRETCH_MAX so a tip never visibly
	# parts company with the wall it claims to hold. A 4.4 m chain gripping a wall 4 m to
	# the side is already at its limit by the time the body draws level with the anchor, so
	# it lets go slightly ahead every time. Demanding otherwise asserts against the shape
	# of the corridor.
	#
	# So: require that a real share of grips DO trail, and that when they do, the soft
	# RELEASE_BEHIND rule is what fired rather than the -3.5 m deadlock escape hatch. That
	# second half is the one worth having -- the creature crawls perfectly well with the
	# soft rule dead and the hatch doing all the work, and nothing else here would notice.
	# The median resists the long tail from a limb force-released far behind.
	var trailed: Array[float] = []
	var deepest: float = INF
	for depth: float in depths:
		deepest = minf(deepest, depth)
		if depth < 0.0:
			trailed.append(depth)
	trailed.sort()
	var share: float = float(trailed.size()) / float(depths.size())
	var median: float = trailed[trailed.size() / 2] if not trailed.is_empty() else 0.0
	var low: float = TentacleTuning.RELEASE_BEHIND_HARD + 0.5
	var high: float = TentacleTuning.RELEASE_BEHIND + 0.7
	_report(
		"release-behind",
		share >= 0.30 and median >= low and median <= high,
		(
			"%d propelling releases, %.0f%% trailed behind (need >= 30%%), median of those %.2f m (need %.2f..%.2f), deepest %.2f"
			% [depths.size(), share * 100.0, median, low, high, deepest]
		)
	)


## THE LOAD-BEARING CHECK OF THE WHOLE SUITE.
##
## A creature whose tentacles contribute exactly nothing is a ball on a spring, and
## it still satisfies every other assertion here: it lags the marker, it stays off
## walls, its strands still reach and plant and stagger beautifully while moving it
## not at all. Only this check can tell the difference.
##
## THE LEASH IS DETACHED IN BOTH RUNS. Driving the marker and comparing distances
## would mostly measure the leash hauling the body along, and the tentacles' share
## would be a small difference between two large numbers. With no marker, the
## tentacles are the only thing in the scene that can produce motion at all.
func _check_drag_requires_anchors() -> void:
	var without: float = await _crawl_distance(false)
	var with_strands: float = await _crawl_distance(true)
	# 8.0 rather than 3.0, and the number is measured rather than chosen: the pair-lunge
	# gait covers 15.98 m in this window where the continuous haul managed a little over
	# three. Half the measured figure is a threshold that still fails loudly if the
	# tentacles stop contributing, without being so tight it fails on a slow first lunge.
	_report(
		"drag-requires-anchors",
		without < 0.5 and with_strands > 8.0,
		(
			"no leash: %.2f m in 4 s with tentacles OFF (need < 0.5), %.2f m with them ON (need > 8.0)"
			% [without, with_strands]
		)
	)


func _crawl_distance(strands_enabled: bool) -> float:
	await _load_world()
	if _crawler == null or _tentacles == null:
		return 0.0
	_crawler.target_marker = null
	_tentacles.enabled = strands_enabled
	# Zero the momentum the world already built during its half-second settle. The
	# strands are live while the scene loads, so the "tentacles OFF" run inherited a
	# few m/s and coasted 1.7 m on drag alone -- which is most of the way to the
	# threshold it was supposed to prove it could not reach.
	_crawler.teleport(_crawler.global_position)
	var start: Vector3 = _crawler.global_position
	await _wait(4.0)
	return start.distance_to(_crawler.global_position)


## It must PULSE, not glide.
##
## Two assertions, because either alone is cheap to satisfy accidentally: enough
## local minima that the motion is genuinely rhythmic, AND a deep enough trough that
## the rhythm is a real stop-start rather than a ripple on a constant speed.
func _check_ratchet() -> void:
	await _load_world()
	if _crawler == null:
		_report("ratchet", false, "no Crawler in the scene")
		return
	_crawler.target_marker = null

	var speeds: PackedFloat32Array = PackedFloat32Array()
	for _tick: int in int(5.0 * Engine.physics_ticks_per_second):
		await get_tree().physics_frame
		speeds.append(_crawler.current_speed())

	var fastest: float = 0.0
	var slowest: float = INF
	for speed: float in speeds:
		fastest = maxf(fastest, speed)
		slowest = minf(slowest, speed)
	var troughs: int = 0
	for i: int in range(1, speeds.size() - 1):
		if speeds[i] < speeds[i - 1] and speeds[i] <= speeds[i + 1]:
			troughs += 1
	# TROUGH COUNT DOWN, TROUGH DEPTH UP. The pulse used to come from tripling the drag
	# between strokes, which produced many shallow dips; it now comes from a synchronised
	# burst followed by a ballistic coast, which produces fewer and far deeper ones. A
	# lunge cycle is about 0.85 s, so five seconds holds roughly six -- asserting six
	# would be asserting the quantisation. Measured 0.06..8.04 m/s, a ratio of 0.007.
	_report(
		"ratchet",
		troughs >= 4 and slowest < 0.35 * fastest,
		(
			"%d troughs in 5 s (need >= 4), speed %.2f..%.2f m/s (slowest must be < %.2f)"
			% [troughs, slowest, fastest, 0.35 * fastest]
		)
	)


func _same_tick_launches(launch_ticks: Array[Array], strands: int) -> int:
	var seen: Dictionary = {}
	var collisions: int = 0
	for i: int in strands:
		for tick: int in launch_ticks[i]:
			if seen.has(tick):
				collisions += 1
			seen[tick] = true
	return collisions


## Re-cast from the shoulder and confirm the anchor sits on something solid.
##
## This is also the winding check: a trimesh corridor whose triangles face outward is
## invisible to every ray, so half the walls silently stop being grippable and the
## only symptom is a creature that always climbs the same side.
func _anchor_is_on_wall(index: int) -> bool:
	var from: Vector3 = _tentacles.shoulder(index)
	var to: Vector3 = _tentacles.anchor(index)
	var space: PhysicsDirectSpaceState3D = _crawler.get_world_3d().direct_space_state
	var params: PhysicsRayQueryParameters3D = PhysicsRayQueryParameters3D.create(
		from, from + (to - from) * 1.05, _tentacles.query_mask
	)
	var hit: Dictionary = space.intersect_ray(params)
	if hit.is_empty():
		return false
	return (hit["position"] as Vector3).distance_to(to) <= TentacleTuning.WALL_LOST_TOLERANCE


## Two bars, because the rule and the property it protects are not the same thing.
## `is_anchor_valid` gates on distance ahead of the STRAND'S OWN SHOULDER, so that is
## what gets the real threshold; the creature as a whole must still never anchor behind
## itself, and that is the second, weaker test.
func _anchor_is_ahead(index: int) -> bool:
	var travel: Vector3 = _crawler.wanted_direction()
	var anchor: Vector3 = _tentacles.anchor(index)
	var from_shoulder: float = (anchor - _tentacles.shoulder(index)).dot(travel)
	var from_body: float = (anchor - _crawler.global_position).dot(travel)
	return from_shoulder > TentacleTuning.FORWARD_BIAS_MIN * 0.9 and from_body > 0.0


func _gap() -> float:
	return (_crawler.debug_state()["position"] as Vector3).distance_to(_marker.global_position)


## The bones are the whole creature now, and every physics assertion above passes
## against a chain that never moved at all -- nothing in the solver ever reads a bone.
##
## THE LINK-LENGTH BAND IS THE IMPORTANT ONE. The poser carries a running frame down a
## nested chain by hand; if that recurrence is wrong the error COMPOUNDS, so joints
## either bunch at the shoulder or fly apart down the limb. Both look, from a single
## screenshot, like a slightly odd pose. Measured against the model's own 0.24 m link
## and the stretch clamp that is allowed to move it, the difference is unmissable.
func _check_bone_pose() -> void:
	await _load_world()
	if _crawler == null:
		_report("bone-pose", false, "no Crawler in the scene")
		return
	var bones: TentacleBones = _crawler.get_node_or_null("Bones") as TentacleBones
	var rig: CrawlerRig = _crawler.get_node_or_null("Rig") as CrawlerRig
	if bones == null or rig == null:
		_report("bone-pose", false, "no TentacleBones or CrawlerRig under the Crawler")
		return
	await _wait(2.0)
	await get_tree().process_frame

	var nominal: float = rig.link_step()
	var low: float = nominal * TentacleTuning.STRETCH_MIN - 0.01
	var high: float = nominal * TentacleTuning.STRETCH_MAX + 0.01
	var posed: int = 0
	var finite: bool = true
	var out_of_band: int = 0
	var far_tips: int = 0
	var worst: float = 0.0

	for strand: int in rig.strand_count():
		var previous: Vector3 = rig.socket(strand).global_position
		for link: int in rig.link_count(strand):
			var bone: Node3D = rig.bone(strand, link)
			var here: Vector3 = bone.global_position
			if not here.is_finite():
				finite = false
				continue
			if link > 0:
				var span: float = previous.distance_to(here)
				if span < low or span > high:
					out_of_band += 1
				worst = maxf(worst, absf(span - nominal))
			previous = here
			posed += 1
		# A planted strand whose chain ends nowhere near its tip is the failure the whole
		# per-strand reach system exists to prevent.
		if _tentacles.is_planted(strand):
			if bones.chain_tip(strand).distance_to(_tentacles.tip(strand)) > 1.5:
				far_tips += 1

	var expected: int = 141
	var ok: bool = finite and out_of_band == 0 and far_tips == 0 and posed >= expected
	_report(
		"bone-pose",
		ok,
		(
			"%d bones posed (need >= %d), finite %s, %d links off the %.2f-%.2f m band (worst %.3f), %d planted tips adrift"
			% [posed, expected, finite, out_of_band, low, high, worst, far_tips]
		)
	)


## Rail the marker the length of the generated corridor and see whether the creature
## actually gets there.
##
## THIS IS THE CHECK THE WHOLE GENERATED SCENE EXISTS FOR. A creature that stalls at
## the first 90-degree bend passes every assertion in the sandbox, because the
## sandbox is a straight line. It is also the most likely way for the corner peek in
## CrawlerBody to be wrong without anything saying so.
##
## Three things at once: it never leaves the shell (which is also the corridor
## winding check, since an outward-wound tube is invisible to the probe and reads as
## open space in every direction), it never clips through a wall, and it turns.
func _check_corridor_run() -> void:
	if _world != null:
		_world.queue_free()
		await get_tree().process_frame
	var packed: PackedScene = load(_res("../scenes/corridor_run.tscn")) as PackedScene
	if packed == null:
		_report("corridor-run", false, "could not load corridor_run.tscn")
		return
	_world = packed.instantiate()
	add_child(_world)
	_marker = _world.get_node_or_null("MarkerPilot") as MarkerPilot
	_crawler = _world.get_node_or_null("Crawler") as CrawlerBody
	_marker.capture_mouse = false
	var curve: Curve3D = (_world.get_node("Centerline") as Path3D).curve
	await _wait(1.0)

	var total: float = curve.get_baked_length()
	var start_forward: Vector3 = _crawler.debug_state()["forward"]
	var rail: float = curve.get_closest_offset(_marker.global_position)
	var worst_clearance: float = INF
	var escapes: int = 0
	var max_turn: float = 0.0
	var delta: float = 1.0 / float(Engine.physics_ticks_per_second)

	for _tick: int in int(60.0 * Engine.physics_ticks_per_second):
		await get_tree().physics_frame
		rail = minf(rail + RAIL_SPEED * delta, total)
		_marker.global_position = curve.sample_baked(rail)
		var state: Dictionary = _crawler.debug_state()
		worst_clearance = minf(worst_clearance, state["clearance"] as float)
		if state["escaped"]:
			escapes += 1
		var turn: float = rad_to_deg((state["forward"] as Vector3).angle_to(start_forward))
		max_turn = maxf(max_turn, turn)
		if rail >= total and curve.get_closest_offset(_crawler.global_position) > total * 0.9:
			break

	var reached: float = curve.get_closest_offset(_crawler.global_position)
	var fraction: float = reached / total
	_report(
		"corridor-run",
		fraction >= 0.85 and escapes == 0 and worst_clearance > 0.05,
		(
			"travelled %.0f%% of %.0f m, min clearance %.2f m, %d ticks outside the shell"
			% [fraction * 100.0, total, worst_clearance, escapes]
		)
	)
	_report(
		"bend",
		max_turn >= 75.0,
		"heading turned %.0f degrees from its start at most (need >= 75)" % max_turn
	)


## A typo'd action name is silently `false` forever -- Input.get_action_strength on
## an action that does not exist returns 0.0 and reports nothing. So the FIRST thing
## worth proving is that pressing a key moves the thing it is supposed to move.
func _check_input_owner() -> void:
	# Reload. The tentacle check flies the marker for six seconds and parks it
	# against the far end of a 60 m corridor, where pressing forward moves it
	# exactly nothing -- and this check then reports a broken input map on a build
	# whose input map is fine.
	await _load_world()
	if _marker == null:
		_report("input-owner", false, "no MarkerPilot in the scene")
		return
	var start: Vector3 = _marker.global_position
	Input.action_press(&"crawler_forward")
	await _wait(2.0)
	Input.action_release(&"crawler_forward")
	var travelled: float = start.distance_to(_marker.global_position)
	var floor_distance: float = _marker.move_speed * 1.6
	_report(
		"input-owner",
		travelled >= floor_distance,
		"marker travelled %.2f m in 2.0 s (need >= %.2f)" % [travelled, floor_distance]
	)


## Exactly one Camera3D may be `current`, before and after, and it must change.
##
## Both halves matter. Setting `current = true` on the second camera silently
## un-`current`s the first, so "the toggle did nothing" and "the toggle worked" look
## identical unless the identity of the live camera is compared.
func _check_camera() -> void:
	if _camera == null:
		_report("camera", false, "no CameraDirector in the scene")
		return
	var before: Camera3D = _camera.active_camera()
	var before_count: int = _current_camera_count()
	_camera.toggle()
	await _wait(0.2)
	var after: Camera3D = _camera.active_camera()
	var after_count: int = _current_camera_count()
	var ok: bool = before != null and after != null and before != after
	ok = ok and before_count == 1 and after_count == 1
	# Printed as a PATH, not a name. Both rigs call their camera "Camera", so a
	# name-based line reads "before Camera -> after Camera" whether the toggle
	# worked or did nothing at all -- a diagnostic that cannot distinguish pass
	# from fail is worse than none.
	_report(
		"camera",
		ok,
		(
			"current before %s (%d live) -> after %s (%d live)"
			% [_path_of(before), before_count, _path_of(after), after_count]
		)
	)
	_camera.toggle()


func _path_of(node: Node) -> String:
	if node == null:
		return "<null>"
	return str(_world.get_path_to(node))


func _current_camera_count() -> int:
	var count: int = 0
	for camera: Camera3D in _find_cameras(_world):
		if camera.current:
			count += 1
	return count


func _find_cameras(node: Node) -> Array[Camera3D]:
	var found: Array[Camera3D] = []
	if node is Camera3D:
		found.append(node as Camera3D)
	for child: Node in node.get_children():
		found.append_array(_find_cameras(child))
	return found


func _report(tag: String, ok: bool, detail: String) -> void:
	if not ok:
		_failures += 1
	print("[%-14s] %s  %s" % [tag, "PASS" if ok else "FAIL", detail])


func _wait(seconds: float) -> void:
	for _i: int in int(seconds * Engine.physics_ticks_per_second):
		await get_tree().physics_frame


## load() needs a real res:// path, so relative paths in a tool script are resolved
## against the script's own location.
func _res(relative_path: String) -> String:
	var dir: String = (get_script() as Script).resource_path.get_base_dir()
	return dir.path_join(relative_path).simplify_path()
