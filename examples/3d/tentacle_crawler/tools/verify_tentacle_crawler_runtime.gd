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
	await _check_ribbon_geometry()
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
	_report(
		"pushoff-ctrl",
		clearance < 1.7,
		"probe_gain 0, no leash: clearance still %.2f m (need < 1.7, i.e. did NOT move)" % clearance
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

	var planted_min: int = strands + 1
	var planted_max: int = -1
	var off_wall: int = 0
	var backward: int = 0
	var checked_anchors: int = 0

	# Fly the marker down the corridor so the creature has a reason to reach.
	Input.action_press(&"crawler_forward")
	var ticks: int = int(6.0 * Engine.physics_ticks_per_second)
	for tick: int in ticks:
		await get_tree().physics_frame
		var planted: int = _tentacles.planted_count()
		planted_min = mini(planted_min, planted)
		planted_max = maxi(planted_max, planted)
		for i: int in strands:
			var reaching: bool = _tentacles.phase_of(i) == TentacleArray.Phase.REACHING
			if reaching and not was_reaching[i]:
				(launch_ticks[i] as Array).append(tick)
				launches[i] += 1
				if not _anchor_is_on_wall(i):
					off_wall += 1
				if not _anchor_is_ahead(i):
					backward += 1
				checked_anchors += 1
			was_reaching[i] = reaching
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
	_report(
		"planted-band",
		planted_max <= TentacleTuning.MAX_PLANTED,
		(
			"planted ranged %d..%d over 6 s (ceiling %d)"
			% [planted_min, planted_max, TentacleTuning.MAX_PLANTED]
		)
	)

	var starved: int = 0
	for i: int in strands:
		if launches[i] < 2:
			starved += 1
	var collisions: int = _same_tick_launches(launch_ticks, strands)
	_report(
		"stagger",
		starved == 0 and collisions == 0,
		(
			"launches %s, %d strand(s) fired < 2 times, %d same-tick collisions"
			% [str(launches), starved, collisions]
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
	_report(
		"drag-requires-anchors",
		without < 0.5 and with_strands > 3.0,
		(
			"no leash: %.2f m in 4 s with tentacles OFF (need < 0.5), %.2f m with them ON (need > 3.0)"
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
	_report(
		"ratchet",
		troughs >= 6 and slowest < 0.55 * fastest,
		(
			"%d troughs in 5 s (need >= 6), speed %.2f..%.2f m/s (slowest must be < %.2f)"
			% [troughs, slowest, fastest, 0.55 * fastest]
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


func _anchor_is_ahead(index: int) -> bool:
	var ahead: Vector3 = _tentacles.anchor(index) - _crawler.global_position
	return ahead.dot(_crawler.wanted_direction()) > TentacleTuning.FORWARD_BIAS_MIN * 0.9


func _gap() -> float:
	return (_crawler.debug_state()["position"] as Vector3).distance_to(_marker.global_position)


## The tentacles are hand-built geometry, and every physics assertion above passes
## against a mesh that renders as nothing at all.
##
## The AABB VOLUME CEILING is the important one. A mis-stitched triangle strip joins
## the end of one tentacle to the root of the next with a real triangle, which stays
## visually subtle -- a thin dark sliver that reads as a rendering glitch -- while
## being completely wrong. A strip that goes properly wrong spans the whole level.
## Both show up as an AABB far larger than a 14 m reach can justify.
func _check_ribbon_geometry() -> void:
	await _load_world()
	if _crawler == null:
		_report("ribbon-geometry", false, "no Crawler in the scene")
		return
	var ribbons: TentacleRibbons = _crawler.get_node_or_null("Ribbons") as TentacleRibbons
	if ribbons == null:
		_report("ribbon-geometry", false, "no TentacleRibbons under the Crawler")
		return
	await _wait(2.0)
	# The mesh is rebuilt in _process, so let a frame actually draw before reading it.
	await get_tree().process_frame

	var mesh: ImmediateMesh = ribbons.mesh as ImmediateMesh
	if mesh == null or mesh.get_surface_count() == 0:
		_report("ribbon-geometry", false, "no surfaces built")
		return
	var surfaces: int = mesh.get_surface_count()
	var vertices: PackedVector3Array = mesh.surface_get_arrays(0)[Mesh.ARRAY_VERTEX]

	var finite: bool = true
	var reach_limit: float = TentacleTuning.REACH_MAX * 1.6
	var stray: int = 0
	for vertex: Vector3 in vertices:
		if not vertex.is_finite():
			finite = false
		elif vertex.distance_to(_crawler.global_position) > reach_limit:
			stray += 1

	var box: AABB = mesh.get_aabb()
	var volume: float = box.size.x * box.size.y * box.size.z
	var expected: int = _tentacles.count() * (TentacleRibbons.SEGMENTS + 1) * 2
	var ok: bool = surfaces == 1 and finite and stray == 0
	ok = ok and vertices.size() >= expected and volume > 0.001 and volume < 4000.0
	_report(
		"ribbon-geometry",
		ok,
		(
			"%d surface(s), %d verts (need >= %d), finite %s, %d stray, AABB %.1f m^3 (need < 4000)"
			% [surfaces, vertices.size(), expected, finite, stray, volume]
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
