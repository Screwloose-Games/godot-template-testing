extends SceneTree

## Generates scenes/cargo_run.tscn: the real course.
##
##   godot --headless --path <godot project root> \
##     --script res://examples/3d/cargo_tether/tools/build_cargo_run.gd
##
## scenes/cargo_run.tscn IS GENERATED. Edit this file and re-run it; hand edits to
## the scene are lost. The layout is seeded (COURSE_SEED), so regenerating gives a
## clean diff rather than a page of noise.
##
## IT REFUSES TO EMIT AN IMPOSSIBLE COURSE. After the rocks are placed it walks
## the spine at two-metre intervals and measures the clearance to the nearest
## asteroid SURFACE, including the drift each rock is allowed. If any sample falls
## below the guaranteed corridor it prints the offender and exits 1. A generator
## that can quietly produce a wall across the only route will, eventually, on the
## morning of a deadline.

## load() and ResourceSaver do not resolve relative paths the way preload() does,
## so every path here goes through _res().
const SHIP_SCENE: String = "../actors/ship/ship.tscn"
const CARGO_SCENE: String = "../actors/cargo/cargo.tscn"
const TETHER_SCRIPT: String = "../components/tether/tether_link.gd"
const LINE_SCENE: String = "../components/tether/tether_line.tscn"
const RIG_SCENE: String = "../components/camera/ship_chase_rig.tscn"
const DOCK_SCENE: String = "../run/delivery_dock.tscn"
const RUN_SCRIPT: String = "../run/tether_run.gd"
const HUD_SCENE: String = "../ui/tether_hud.tscn"
const POOL_SCENE: String = "../threats/projectile_pool.tscn"
const TURRET_SCENE: String = "../threats/turret.tscn"
const FIELD_SCRIPT: String = "../threats/asteroid_field.gd"
const ASTEROID_MATERIAL: String = "../materials/asteroid.tres"
const STAR_MATERIAL: String = "../materials/star.tres"
const OUT_PATH: String = "../scenes/cargo_run.tscn"

const COURSE_SEED: int = 20260730

## Control points for the spine, in metres. Deliberately curving in ALL THREE
## axes: a course that is flat in Y wastes the entire premise, because a tether
## that only ever swings sideways is a 2D tether.
const SPINE_POINTS: Array[Vector3] = [
	Vector3(0, 0, 0),
	Vector3(40, 26, -230),
	Vector3(-70, -14, -450),
	Vector3(25, 48, -670),
	Vector3(105, 6, -890),
	Vector3(-30, -36, -1110),
	Vector3(0, 0, -1330),
]
## Metres between spine samples when placing and when checking.
const SAMPLE_STEP: float = 2.0

const ASTEROID_COUNT: int = 90
const ASTEROID_MIN_RADIUS: float = 3.0
const ASTEROID_MAX_RADIUS: float = 11.0
## Outer edge of the rock tube. Past this they are scenery nobody flies near.
const FIELD_OUTER_RADIUS: float = 92.0
## Guaranteed clear radius around the spine, in the open.
const CORRIDOR_RADIUS: float = 18.0
## And at a chokepoint, where short-tether flying stops being optional.
const CHOKE_RADIUS: float = 9.0
## Fractions along the spine where the corridor pinches.
const CHOKE_POINTS: PackedFloat32Array = [0.28, 0.55, 0.82]
## How far either side of a chokepoint centre the pinch reaches, as a fraction.
const CHOKE_SPAN: float = 0.045
## Slack allowed against the guaranteed corridor before the build fails.
const CLEARANCE_TOLERANCE: float = 0.75

## Rocks in the ring that forms each chokepoint gate.
##
## The pinch has to be BUILT, not hoped for. Scattering ninety rocks at random
## and narrowing the permitted radius near a chokepoint does not produce a gate:
## at this density the nearest rock to the spine is 20 m away almost everywhere,
## so the first build measured a minimum clearance of 19.6 m and the "chokepoints"
## did nothing at all. A gate is a ring of rocks placed deliberately.
const GATE_ROCKS: int = 9
const GATE_ROCK_RADIUS: float = 7.0
## Metres of drift each rock is allowed, matching AsteroidField.drift_amplitude.
## Gates are placed clear of it so the aperture is guaranteed, not typical.
const DRIFT_ALLOWANCE: float = 3.0

const TURRET_COUNT: int = 7
## Perpendicular distance from the spine to an emplacement.
const TURRET_STANDOFF_MIN: float = 34.0
const TURRET_STANDOFF_MAX: float = 58.0

const STAR_COUNT: int = 400
const STAR_SPHERE_RADIUS: float = 900.0
const STAR_SIZE: float = 1.2

## Anchor-to-anchor is 4.2 m shorter than centre-to-centre: the ship's anchor sits
## 3.0 m astern of its origin and the cargo's 1.2 m forward of its own. Spawning
## the crate rest_length behind the ship would start the line 4.2 m slack, which
## is exactly zero force -- see CLAUDE.md.
const ANCHOR_SPAN: float = 4.2
const START_TETHER: float = 14.0
## What the run is scored against. Derived from the spine, not chosen.
const PAR_SPEED: float = 70.0

var _root: Node3D = null
var _rng := RandomNumberGenerator.new()
var _report: PackedStringArray = PackedStringArray()
var _rocks: Array[Dictionary] = []
var _field: Node3D = null
var _rock_mesh: SphereMesh = null
var _rock_shape: SphereShape3D = null
var _rock_material: Material = null
var _rock_index: int = 0


func _initialize() -> void:
	_rng.seed = COURSE_SEED
	_root = Node3D.new()
	_root.name = "CargoRun"

	var spine: Curve3D = _build_spine()
	var length: float = spine.get_baked_length()

	_add_environment()
	_add_lights()
	_add_starfield()
	_add_asteroids(spine, length)
	_add_gates(spine, length)
	if not _check_corridor(spine, length):
		quit(1)
		return
	_add_turrets(spine, length)
	_add_actors(spine, length)

	var packed := PackedScene.new()
	var pack_err: Error = packed.pack(_root)
	if pack_err != OK:
		printerr("PackedScene.pack() failed: %d" % pack_err)
		quit(1)
		return
	var out_path: String = _res(OUT_PATH)
	var save_err: Error = ResourceSaver.save(packed, out_path)
	if save_err != OK:
		printerr("ResourceSaver.save(%s) failed: %d" % [out_path, save_err])
		quit(1)
		return
	var rewritten: int = _relativise_paths(out_path)

	_report.append("wrote %s (%d paths relativised)" % [out_path, rewritten])
	for line: String in _report:
		print(line)
	# Freeing the built tree before quitting: SceneTree does not own _root, so
	# without this the run ends in a page of "RID allocations were leaked at exit"
	# that reads like a real problem and is not.
	_root.free()
	quit(0)


func _build_spine() -> Curve3D:
	var curve := Curve3D.new()
	for point: Vector3 in SPINE_POINTS:
		curve.add_point(point)
	return curve


## Guaranteed clear radius at a fraction along the spine: the open corridor,
## pinched to CHOKE_RADIUS near each chokepoint with a smooth shoulder either
## side so the narrowing is something you can see coming.
func _corridor_at(t: float) -> float:
	var radius: float = CORRIDOR_RADIUS
	for centre: float in CHOKE_POINTS:
		var distance: float = absf(t - centre)
		if distance >= CHOKE_SPAN:
			continue
		var blend: float = smoothstep(0.0, 1.0, distance / CHOKE_SPAN)
		radius = minf(radius, lerpf(CHOKE_RADIUS, CORRIDOR_RADIUS, blend))
	return radius


## A unit vector perpendicular to `tangent`, rotated by `angle` about it.
func _perpendicular(tangent: Vector3, angle: float) -> Vector3:
	var reference: Vector3 = Vector3.UP
	if absf(tangent.dot(reference)) > 0.95:
		reference = Vector3.RIGHT
	var first: Vector3 = tangent.cross(reference).normalized()
	var second: Vector3 = tangent.cross(first).normalized()
	return (first * cos(angle) + second * sin(angle)).normalized()


func _add_asteroids(spine: Curve3D, length: float) -> void:
	_field = Node3D.new()
	_field.name = "Asteroids"
	_field.set_script(load(_res(FIELD_SCRIPT)))
	_field.set("field_seed", COURSE_SEED)
	_field.set("drift_amplitude", DRIFT_ALLOWANCE)
	_adopt(_field, _root)

	_rock_material = load(_res(ASTEROID_MATERIAL))
	_rock_mesh = SphereMesh.new()
	_rock_mesh.radius = 1.0
	_rock_mesh.height = 2.0
	# 8 x 4 is 64 triangles. At ninety instances that is 5760 triangles for the
	# entire field, which is the whole point of a greybox.
	_rock_mesh.radial_segments = 8
	_rock_mesh.rings = 4
	_rock_shape = SphereShape3D.new()
	_rock_shape.radius = 1.0

	var histogram: Dictionary = {}
	for _i: int in ASTEROID_COUNT:
		var t: float = _rng.randf()
		var centre: Vector3 = spine.sample_baked(t * length)
		var tangent: Vector3 = _spine_tangent(spine, length, t)
		var radius: float = _rng.randf_range(ASTEROID_MIN_RADIUS, ASTEROID_MAX_RADIUS)
		# Clear of the guaranteed corridor by its own radius plus the drift it is
		# allowed, so the promise holds for the whole run and not just at t = 0.
		var inner: float = _corridor_at(t) + radius + DRIFT_ALLOWANCE + 1.0
		if inner >= FIELD_OUTER_RADIUS:
			continue
		var offset: float = _rng.randf_range(inner, FIELD_OUTER_RADIUS)
		_spawn_rock(centre + _perpendicular(tangent, _rng.randf() * TAU) * offset, radius)
		var bucket: int = int(radius)
		histogram[bucket] = int(histogram.get(bucket, 0)) + 1

	_report.append("asteroids: %d" % _rocks.size())
	var buckets: Array = histogram.keys()
	buckets.sort()
	for bucket: int in buckets:
		_report.append("  r %2d-%2d m  %d" % [bucket, bucket + 1, histogram[bucket]])


## One rock, added to the field and recorded for the clearance check.
func _spawn_rock(position: Vector3, radius: float) -> void:
	var body := AnimatableBody3D.new()
	body.name = "Asteroid%02d" % _rock_index
	_rock_index += 1
	body.collision_layer = TetherLayers.OBSTACLE
	body.collision_mask = 0
	body.sync_to_physics = false
	# A random basis plus a UNIFORM scale is what stops ninety spheres reading as
	# ninety spheres. Uniform, because a non-uniform scale on a physics body
	# warns and distorts the collision sphere.
	var basis: Basis = Basis.from_euler(
		Vector3(_rng.randf() * TAU, _rng.randf() * TAU, _rng.randf() * TAU)
	)
	body.transform = Transform3D(basis.scaled(Vector3.ONE * radius), position)
	_adopt(body, _field)

	var visual := MeshInstance3D.new()
	visual.name = "Mesh"
	visual.mesh = _rock_mesh
	visual.material_override = _rock_material
	visual.visibility_range_end = 600.0
	_adopt(visual, body)

	var collision := CollisionShape3D.new()
	collision.name = "Collision"
	collision.shape = _rock_shape
	_adopt(collision, body)

	_rocks.append({"position": position, "radius": radius})


## Builds the three chokepoint gates: a ring of rocks around the spine leaving a
## CHOKE_RADIUS aperture, guaranteed rather than typical.
##
## This is where short-tether flying stops being optional. A crate on 26 m of line
## swings 30 m off the axis of travel; the aperture is 9 m of guaranteed clear
## radius. You reel in or you lose paint.
func _add_gates(spine: Curve3D, length: float) -> void:
	for gate: int in CHOKE_POINTS.size():
		var t: float = CHOKE_POINTS[gate]
		var centre: Vector3 = spine.sample_baked(t * length)
		var tangent: Vector3 = _spine_tangent(spine, length, t)
		# Ring radius = the guaranteed aperture, plus the rock's own radius, plus
		# the drift it is allowed to wander inward.
		var ring: float = CHOKE_RADIUS + GATE_ROCK_RADIUS + DRIFT_ALLOWANCE
		var twist: float = _rng.randf() * TAU
		for i: int in GATE_ROCKS:
			var angle: float = twist + TAU * float(i) / float(GATE_ROCKS)
			_spawn_rock(
				centre + _perpendicular(tangent, angle) * ring,
				GATE_ROCK_RADIUS * _rng.randf_range(0.9, 1.1)
			)
		_report.append(
			"gate %d at t=%.2f: %d rocks, %.0f m aperture" % [gate, t, GATE_ROCKS, CHOKE_RADIUS]
		)


## Walks the spine and measures the worst clearance to a rock surface.
##
## The drift amplitude is subtracted because the rocks move: a corridor that is
## only clear at t = 0 is not a corridor, it is a coincidence.
func _check_corridor(spine: Curve3D, length: float) -> bool:
	var samples: int = int(length / SAMPLE_STEP)
	var worst: float = 1e9
	var worst_t: float = 0.0
	var failures: int = 0
	var total: float = 0.0
	for i: int in samples:
		var t: float = float(i) / float(samples)
		var point: Vector3 = spine.sample_baked(t * length)
		var clearance: float = 1e9
		for rock: Dictionary in _rocks:
			# Surface, not centre, and minus the drift each rock is allowed: a
			# corridor that is only clear at t = 0 is not a corridor, it is a
			# coincidence.
			var gap: float = (
				point.distance_to(rock["position"]) - float(rock["radius"]) - DRIFT_ALLOWANCE
			)
			clearance = minf(clearance, gap)
		total += clearance
		if clearance < worst:
			worst = clearance
			worst_t = t
		if clearance < _corridor_at(t) * CLEARANCE_TOLERANCE:
			failures += 1

	_report.append("spine: %.0f m, %d samples" % [length, samples])
	_report.append(
		"clearance: min %.1f m at t = %.3f, mean %.1f m" % [worst, worst_t, total / float(samples)]
	)
	if failures > 0:
		printerr(
			(
				"%d spine samples are inside the guaranteed corridor (worst %.1f m at t=%.3f)."
				% [failures, worst, worst_t]
			)
		)
		return false
	return true


func _add_turrets(spine: Curve3D, length: float) -> void:
	var holder := Node3D.new()
	holder.name = "Turrets"
	_adopt(holder, _root)
	var packed: PackedScene = load(_res(TURRET_SCENE))

	# Sit them just before each chokepoint and spread the rest along the run, so
	# the pressure lands where the corridor is already tight.
	var fractions: PackedFloat32Array = PackedFloat32Array()
	for centre: float in CHOKE_POINTS:
		fractions.append(maxf(centre - 0.035, 0.05))
	while fractions.size() < TURRET_COUNT:
		fractions.append(_rng.randf_range(0.12, 0.94))

	for i: int in TURRET_COUNT:
		var t: float = fractions[i]
		var centre: Vector3 = spine.sample_baked(t * length)
		var tangent: Vector3 = _spine_tangent(spine, length, t)
		var standoff: float = _rng.randf_range(TURRET_STANDOFF_MIN, TURRET_STANDOFF_MAX)
		var position: Vector3 = centre + _perpendicular(tangent, _rng.randf() * TAU) * standoff
		var turret: Node3D = packed.instantiate() as Node3D
		turret.name = "Turret%02d" % i
		turret.position = position
		# A distinct seed per emplacement, or their spread rolls correlate and
		# seven turrets land the same miss.
		turret.set("seed_index", i + 1)
		holder.add_child(turret)
		# Instance roots only: setting owner on the children of an instanced
		# scene is what breaks the instance link.
		turret.owner = _root
		_report.append("turret %d at t=%.2f, standoff %.0f m" % [i, t, standoff])


func _add_actors(spine: Curve3D, length: float) -> void:
	var start: Vector3 = spine.sample_baked(0.0)
	var start_tangent: Vector3 = _spine_tangent(spine, length, 0.0)
	var end: Vector3 = spine.sample_baked(length)
	var end_tangent: Vector3 = _spine_tangent(spine, length, 1.0)

	var dock: Node3D = _instance(DOCK_SCENE) as Node3D
	dock.name = "Dock"
	# Ring plane perpendicular to the spine, so you fly through the hole rather
	# than at the rim.
	dock.transform = Transform3D(Basis.looking_at(end_tangent, Vector3.UP), end)
	_claim(dock)

	var pool: Node3D = _instance(POOL_SCENE) as Node3D
	pool.name = "Projectiles"
	_claim(pool)

	var spawn := Marker3D.new()
	spawn.name = "SpawnPoint"
	spawn.transform = Transform3D(Basis.looking_at(start_tangent, Vector3.UP), start)
	_adopt(spawn, _root)

	var ship: Node3D = _instance(SHIP_SCENE) as Node3D
	ship.name = "Ship"
	ship.transform = spawn.transform
	_claim(ship)

	var cargo: Node3D = _instance(CARGO_SCENE) as Node3D
	cargo.name = "Cargo"
	# Behind the ship, at the anchor-to-anchor rest length.
	cargo.position = start - start_tangent * (START_TETHER + ANCHOR_SPAN)
	_claim(cargo)

	var tether := Node.new()
	tether.name = "Tether"
	tether.set_script(load(_res(TETHER_SCRIPT)))
	_adopt(tether, _root)

	var line: Node3D = _instance(LINE_SCENE) as Node3D
	line.name = "TetherLine"
	_claim(line)

	var rig: Node3D = _instance(RIG_SCENE) as Node3D
	rig.name = "CameraRig"
	_claim(rig)

	var run := Node.new()
	run.name = "Run"
	run.set_script(load(_res(RUN_SCRIPT)))
	_adopt(run, _root)

	var hud: Node = _instance(HUD_SCENE)
	hud.name = "Hud"
	_claim(hud)

	# Wiring goes LAST, once every node is in the tree. Node-typed exports
	# serialise as NodePaths and PackedScene.pack() emits the node_paths= header
	# that makes them resolve on load -- assigning them before the targets exist
	# would store paths that resolve to null with no error anywhere.
	tether.set("ship", ship)
	tether.set("cargo", cargo)
	tether.set("ship_anchor", ship.get_node("TetherAnchor"))
	tether.set("cargo_anchor", cargo.get_node("TetherAnchor"))
	ship.set("tether", tether)
	line.set("tether", tether)
	rig.set("target", ship)
	rig.set("secondary", cargo)
	run.set("ship", ship)
	run.set("cargo", cargo)
	run.set("tether", tether)
	run.set("dock", dock)
	run.set("projectiles", pool)
	var par: float = length / PAR_SPEED
	run.set("par_time", par)
	hud.set("run", run)
	hud.set("cargo", cargo)

	_report.append("dock at %s" % end)
	_report.append("par time %.1f s (%.0f m at %.0f m/s)" % [par, length, PAR_SPEED])


func _spine_tangent(spine: Curve3D, length: float, t: float) -> Vector3:
	var here: float = clampf(t, 0.0, 1.0) * length
	var ahead: float = minf(here + 1.0, length)
	var behind: float = maxf(here - 1.0, 0.0)
	var direction: Vector3 = spine.sample_baked(ahead) - spine.sample_baked(behind)
	if direction.length_squared() < 0.000001:
		return Vector3.FORWARD
	return direction.normalized()


func _add_environment() -> void:
	var environment := Environment.new()
	# A flat colour, not a procedural sky: a sky draws a sun disk and scattering
	# halo per DirectionalLight3D, which paints a visible seam across empty space.
	environment.background_mode = Environment.BG_COLOR
	environment.background_color = Color(0.016, 0.019, 0.036)
	# Ambient from a COLOUR, not from the sky. Sampling a near-black background
	# lights nothing and every surface facing away from the sun goes pure black.
	environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	environment.ambient_light_color = Color(0.36, 0.42, 0.55)
	environment.ambient_light_energy = 0.32
	environment.tonemap_mode = Environment.TONE_MAPPER_FILMIC
	# Nothing here touches sdfgi, ssao, ssil, ssr or volumetric fog: all of them
	# are unsupported on the GL Compatibility renderer this project targets.
	var node := WorldEnvironment.new()
	node.name = "WorldEnvironment"
	node.environment = environment
	_adopt(node, _root)


func _add_lights() -> void:
	var sun := DirectionalLight3D.new()
	sun.name = "Sun"
	sun.transform = Transform3D(
		Basis.from_euler(Vector3(deg_to_rad(-42.0), deg_to_rad(34.0), 0.0)), Vector3.ZERO
	)
	sun.light_energy = 1.1
	sun.shadow_enabled = true
	sun.directional_shadow_mode = DirectionalLight3D.SHADOW_PARALLEL_2_SPLITS
	sun.directional_shadow_max_distance = 180.0
	_adopt(sun, _root)

	# Fill from the opposite side, no shadows. Without it a greybox has one
	# readable face and one black one, and you cannot tell which way a rock or a
	# turret is oriented.
	var fill := DirectionalLight3D.new()
	fill.name = "Fill"
	fill.transform = Transform3D(
		Basis.from_euler(Vector3(deg_to_rad(28.0), deg_to_rad(-150.0), 0.0)), Vector3.ZERO
	)
	fill.light_energy = 0.22
	fill.shadow_enabled = false
	_adopt(fill, _root)


func _add_starfield() -> void:
	var mesh := QuadMesh.new()
	mesh.size = Vector2(STAR_SIZE, STAR_SIZE)
	var multi := MultiMesh.new()
	multi.transform_format = MultiMesh.TRANSFORM_3D
	multi.mesh = mesh
	multi.instance_count = STAR_COUNT
	for i: int in STAR_COUNT:
		# Normally distributed direction, normalised: the naive "three uniform
		# randoms" clusters at the corners of a cube.
		var direction := Vector3(_rng.randfn(), _rng.randfn(), _rng.randfn())
		if direction.length_squared() < 0.0001:
			direction = Vector3.UP
		direction = direction.normalized()
		var scale: float = _rng.randf_range(0.5, 1.6)
		multi.set_instance_transform(
			i, Transform3D(Basis().scaled(Vector3.ONE * scale), direction * STAR_SPHERE_RADIUS)
		)
	var node := MultiMeshInstance3D.new()
	node.name = "Starfield"
	node.multimesh = multi
	node.material_override = load(_res(STAR_MATERIAL))
	node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	# The course is 1330 m long and the sphere is 900 m out; without this the
	# field pops out of existence whenever its origin leaves the frustum.
	node.extra_cull_margin = 16384.0
	_adopt(node, _root)
	_report.append("starfield: %d billboards on a %.0f m sphere" % [STAR_COUNT, STAR_SPHERE_RADIUS])


func _instance(relative_path: String) -> Node:
	var packed: PackedScene = load(_res(relative_path))
	return packed.instantiate()


## Adds `node` under the root and sets owner so PackedScene.pack() keeps it. For
## instanced sub-scenes only the instance root gets an owner, which is what
## preserves the instance link.
func _claim(node: Node) -> void:
	_root.add_child(node)
	node.owner = _root


## Owner can only be set once the node shares a tree with the owner, so the order
## here is add_child THEN owner -- not the other way round.
func _adopt(node: Node, parent: Node) -> void:
	parent.add_child(node)
	node.owner = _root


## See build_proving_ground.gd: ResourceSaver.FLAG_RELATIVE_PATHS has no effect on
## text scenes in 4.7.1, so the rewrite happens here, on the text.
func _relativise_paths(scene_path: String) -> int:
	var reader: FileAccess = FileAccess.open(scene_path, FileAccess.READ)
	if reader == null:
		push_warning("Could not reopen %s to relativise its paths." % scene_path)
		return 0
	var text: String = reader.get_as_text()
	reader.close()

	var example_root: String = _res("..")
	var changed: int = 0
	var lines: PackedStringArray = text.split("\n")
	for index: int in lines.size():
		var line: String = lines[index]
		if not line.begins_with("[ext_resource "):
			continue
		var marker: String = ' path="'
		var start: int = line.find(marker)
		if start < 0:
			continue
		start += marker.length()
		var end: int = line.find('"', start)
		if end < 0:
			continue
		var target: String = line.substr(start, end - start)
		if not target.begins_with(example_root):
			continue
		lines[index] = (
			line.substr(0, start)
			+ _relative_from(scene_path.get_base_dir(), target)
			+ line.substr(end)
		)
		changed += 1

	if changed == 0:
		return 0
	var writer: FileAccess = FileAccess.open(scene_path, FileAccess.WRITE)
	if writer == null:
		push_warning("Could not rewrite %s; its paths stay absolute." % scene_path)
		return 0
	writer.store_string("\n".join(lines))
	writer.close()
	return changed


## `target` expressed relative to `base_dir`, both res:// paths. Hand-rolled
## because String.path_to_file() is not bound in GDScript.
func _relative_from(base_dir: String, target: String) -> String:
	var base_parts: PackedStringArray = base_dir.trim_prefix("res://").split("/", false)
	var target_parts: PackedStringArray = target.trim_prefix("res://").split("/", false)

	var shared: int = 0
	while (
		shared < base_parts.size()
		and shared < target_parts.size() - 1
		and base_parts[shared] == target_parts[shared]
	):
		shared += 1

	var out: PackedStringArray = PackedStringArray()
	for _step: int in base_parts.size() - shared:
		out.append("..")
	for index: int in range(shared, target_parts.size()):
		out.append(target_parts[index])
	return "/".join(out)


## FileAccess, load() and ResourceSaver need real res:// paths.
func _res(relative_path: String) -> String:
	var dir: String = (get_script() as Script).resource_path.get_base_dir()
	return dir.path_join(relative_path).simplify_path()
