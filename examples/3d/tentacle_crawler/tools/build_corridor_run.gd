extends SceneTree

## Generates scenes/corridor_run.tscn. EDIT THIS, NEVER THE OUTPUT.
##
##   godot --headless --path <root> --script res://examples/3d/tentacle_crawler/tools/build_corridor_run.gd
##
## RINGS, NOT BOXES. The corridor is built by walking a frame along a polyline and
## emitting a four-corner cross-section every RING_STEP metres, then filling the four
## wall quads between consecutive rings. Adjacent quads share the next ring's corner
## points EXACTLY, so there is no seam anywhere -- through bends, through pitches, or
## through a section that changes width -- because there is no place where two
## independently-positioned pieces have to meet.
##
## The whole corridor is ONE ArrayMesh with one material: 1 draw call for 260 m.
##
## WINDING FACES INWARD, AND THIS MATTERS MORE THAN IT LOOKS.
## ConcavePolygonShape3D.backface_collision defaults to false, so a wall whose
## triangles face outward is INVISIBLE TO EVERY RAYCAST. Half the corridor silently
## stops being grippable and the only symptom is a creature that always climbs the
## same side. `[anchors-on-walls]` in the runtime suite is the check that catches it.
## backface_collision is deliberately left off, so that a ray which escapes the shell
## cannot come back in through it and pretend everything is fine.

## Metres between cross-sections. Fine enough that a 12 m-radius bend reads as a
## curve rather than as a series of flats.
const RING_STEP: float = 2.0
## The layout skeleton is FIXED and only the jitter is seeded, so regenerating gives
## a clean diff rather than a completely different corridor.
const CORRIDOR_SEED: int = 20260731
## Metres of per-ring wobble on the half-extents, applied after smoothing. A
## perfectly machined tube gives every anchor the same character and makes the walls
## read as a texture-mapped cylinder rather than as something grown.
const JITTER: float = 0.22
## How many neighbours each side the half-extents are averaged over. At RING_STEP 2
## this makes every width change a ~12 m taper, with no explicit taper segments.
const SMOOTH_RADIUS: int = 3
## Refuse to emit anything the creature cannot fit down. A HALF-EXTENT, like `w` and
## `h` below, so 2.2 is a 4.4 m-wide corridor against a body_radius of 1.5.
const MIN_CLEARANCE: float = 2.2
## Below this, a bend's inner wall self-intersects at these widths and opens a HOLE
## in the shell. The creature then rays straight through the gap, anchors outside the
## level and hauls itself into the void -- with every other assertion still passing.
const MIN_BEND_RADIUS: float = 9.0
## Two non-adjacent rings closer than this means the corridor has touched itself.
const MIN_SELF_DISTANCE: float = 2.0
## Metres between structural ribs.
const RIB_SPACING: float = 8.0
## How far a rib protrudes into the corridor, and how long it is.
const RIB_INSET: float = 0.3
const RIB_LENGTH: float = 0.5
## Ribs are optional -- deleting them leaves a sealed, playable tube.
const RIBS_ENABLED: bool = true

## The course. Half-extents, so `w` 4.5 is a 9 m-wide corridor.
##
## Pitch segments are not decoration: a corridor that only ever bends in yaw wastes
## the zero-g premise entirely, and the creature never has to reason about a wall
## that used to be a floor.
const SEGMENTS: Array[Dictionary] = [
	{"kind": "straight", "length": 24.0, "w": 4.5, "h": 4.0},
	{"kind": "yaw", "angle": -90.0, "radius": 14.0, "w": 4.5, "h": 4.0},
	{"kind": "straight", "length": 20.0, "w": 4.5, "h": 4.0},
	{"kind": "straight", "length": 16.0, "w": 3.0, "h": 3.0},
	{"kind": "straight", "length": 12.0, "w": 4.5, "h": 4.0},
	{"kind": "pitch", "angle": 45.0, "radius": 18.0, "w": 4.5, "h": 4.0},
	{"kind": "straight", "length": 18.0, "w": 4.5, "h": 4.0},
	{"kind": "yaw", "angle": 90.0, "radius": 12.0, "w": 4.5, "h": 4.0},
	{"kind": "straight", "length": 26.0, "w": 7.0, "h": 6.0},
	{"kind": "yaw", "angle": 60.0, "radius": 16.0, "w": 4.5, "h": 4.0},
	{"kind": "straight", "length": 16.0, "w": 4.5, "h": 4.0},
	{"kind": "pitch", "angle": -30.0, "radius": 20.0, "w": 4.5, "h": 4.0},
	{"kind": "straight", "length": 30.0, "w": 4.5, "h": 4.0},
]

var _positions: PackedVector3Array = PackedVector3Array()
var _forwards: PackedVector3Array = PackedVector3Array()
var _ups: PackedVector3Array = PackedVector3Array()
var _half_w: PackedFloat32Array = PackedFloat32Array()
var _half_h: PackedFloat32Array = PackedFloat32Array()
var _rng: RandomNumberGenerator = RandomNumberGenerator.new()


func _initialize() -> void:
	_rng.seed = CORRIDOR_SEED
	_walk()
	_smooth_extents()
	_apply_jitter()

	var complaints: PackedStringArray = _validate()
	if not complaints.is_empty():
		for line: String in complaints:
			printerr("REFUSING TO EMIT: %s" % line)
		quit(1)
		return

	var root: Node3D = _build_scene()
	var packed: PackedScene = PackedScene.new()
	if packed.pack(root) != OK:
		printerr("pack() failed")
		quit(1)
		return
	var path: String = _res("../scenes/corridor_run.tscn")
	if ResourceSaver.save(packed, path) != OK:
		printerr("save(%s) failed" % path)
		quit(1)
		return
	_relativise(path)
	print(
		(
			"wrote %s: %d rings, %.1f m, clearance %.2f..%.2f m"
			% [path, _positions.size(), _length(), _min_clearance(), _max_clearance()]
		)
	)
	quit(0)


## Walk a frame along the course, one sample every RING_STEP.
func _walk() -> void:
	var position: Vector3 = Vector3.ZERO
	var forward: Vector3 = Vector3.FORWARD
	var up: Vector3 = Vector3.UP

	for segment: Dictionary in SEGMENTS:
		var kind: String = segment["kind"]
		var length: float = 0.0
		if kind == "straight":
			length = segment["length"]
		else:
			length = absf(deg_to_rad(segment["angle"] as float)) * (segment["radius"] as float)
		var steps: int = maxi(int(round(length / RING_STEP)), 1)
		var step: float = length / float(steps)

		for _i: int in steps:
			_positions.append(position)
			_forwards.append(forward)
			_ups.append(up)
			_half_w.append(segment["w"])
			_half_h.append(segment["h"])

			position += forward * step
			if kind == "straight":
				continue
			# Turn by arc length over radius, so the segment's stated angle comes out
			# regardless of how the steps divide.
			var turn: float = signf(segment["angle"] as float) * step / (segment["radius"] as float)
			if kind == "yaw":
				forward = forward.rotated(up, turn).normalized()
			else:
				var right: Vector3 = forward.cross(up).normalized()
				forward = forward.rotated(right, turn).normalized()
				# Carry `up` through the pitch by parallel transport about the same
				# axis. Leaving it at world +Y instead lets the frame roll as the
				# tube climbs, and the walls trade places with the floor halfway up.
				up = right.cross(forward).normalized()

	# Final ring, so the last segment has something to close against.
	_positions.append(position)
	_forwards.append(forward)
	_ups.append(up)
	_half_w.append(SEGMENTS[SEGMENTS.size() - 1]["w"])
	_half_h.append(SEGMENTS[SEGMENTS.size() - 1]["h"])


## Average each ring's extents with its neighbours.
##
## This is what produces the tapers, and it means the SEGMENTS table above can state
## flat widths with hard edges between them and still emit a corridor that opens and
## closes smoothly. Explicit taper segments would be a second set of numbers to keep
## consistent with the first.
func _smooth_extents() -> void:
	var smoothed_w: PackedFloat32Array = _half_w.duplicate()
	var smoothed_h: PackedFloat32Array = _half_h.duplicate()
	for i: int in _half_w.size():
		var total_w: float = 0.0
		var total_h: float = 0.0
		var samples: int = 0
		for offset: int in range(-SMOOTH_RADIUS, SMOOTH_RADIUS + 1):
			var j: int = clampi(i + offset, 0, _half_w.size() - 1)
			total_w += _half_w[j]
			total_h += _half_h[j]
			samples += 1
		smoothed_w[i] = total_w / float(samples)
		smoothed_h[i] = total_h / float(samples)
	_half_w = smoothed_w
	_half_h = smoothed_h


## Applied AFTER smoothing, or the smoothing would erase it.
func _apply_jitter() -> void:
	for i: int in _half_w.size():
		_half_w[i] += _rng.randf_range(-JITTER, JITTER)
		_half_h[i] += _rng.randf_range(-JITTER, JITTER)


## Everything that would make an unplayable or physically broken corridor. Mirrors
## build_cargo_run's clearance walk: refuse to emit rather than emit and hope.
func _validate() -> PackedStringArray:
	var complaints: PackedStringArray = PackedStringArray()
	for i: int in _half_w.size():
		var clearance: float = minf(_half_w[i], _half_h[i])
		if clearance < MIN_CLEARANCE:
			complaints.append(
				"ring %d has %.2f m clearance, below %.2f" % [i, clearance, MIN_CLEARANCE]
			)
			break

	for segment: Dictionary in SEGMENTS:
		if segment["kind"] == "straight":
			continue
		if (segment["radius"] as float) < MIN_BEND_RADIUS:
			complaints.append(
				(
					"a %s of radius %.1f is below the %.1f m self-intersection limit"
					% [segment["kind"], segment["radius"], MIN_BEND_RADIUS]
				)
			)

	for i: int in _positions.size():
		for j: int in range(i + 3, _positions.size()):
			if _positions[i].distance_to(_positions[j]) < MIN_SELF_DISTANCE:
				complaints.append(
					(
						"rings %d and %d are %.2f m apart -- the corridor touches itself"
						% [i, j, _positions[i].distance_to(_positions[j])]
					)
				)
				return complaints
	return complaints


func _build_scene() -> Node3D:
	var root: Node3D = Node3D.new()
	root.name = "CorridorRun"

	var shell: MeshInstance3D = MeshInstance3D.new()
	shell.name = "Mesh"
	shell.mesh = _build_shell_mesh()
	shell.material_override = load(_res("../materials/corridor_wall.tres"))

	var body: StaticBody3D = StaticBody3D.new()
	body.name = "Shell"
	body.collision_layer = CrawlerLayers.CORRIDOR
	body.collision_mask = 0
	_adopt(body, root, root)
	_adopt(shell, body, root)

	var collision: CollisionShape3D = CollisionShape3D.new()
	collision.name = "Collision"
	collision.shape = (shell.mesh as ArrayMesh).create_trimesh_shape()
	_adopt(collision, body, root)

	if RIBS_ENABLED:
		_build_ribs(root)

	# BAKED FOR THE TOOLS ONLY. The creature never reads this -- it knows the world
	# exclusively through raycasts, and `[independence]` in the static suite greps
	# actors/ and components/ for Path3D, Curve3D and Centerline to keep it that way.
	# The capture tool rails the marker along it and the verifier measures progress
	# against it; both are allowed to know things the game does not.
	var path: Path3D = Path3D.new()
	path.name = "Centerline"
	var curve: Curve3D = Curve3D.new()
	for i: int in _positions.size():
		curve.add_point(_positions[i])
	path.curve = curve
	_adopt(path, root, root)

	_build_lighting(root)
	_build_actors(root)
	return root


## The same flat-colour environment and shadowless light pair as the hand-authored
## sandbox, for the same reasons: a ProceduralSkyMaterial draws a sun disk per
## DirectionalLight3D, sky ambient against a near-black background lights nothing,
## and a sealed tube with shadows on renders its entire interior at ambient only.
func _build_lighting(root: Node3D) -> void:
	var environment: Environment = Environment.new()
	environment.background_mode = Environment.BG_COLOR
	environment.background_color = Color(0.02, 0.021, 0.026)
	environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	environment.ambient_light_color = Color(0.46, 0.48, 0.55)
	environment.ambient_light_energy = 0.34
	environment.tonemap_mode = Environment.TONE_MAPPER_FILMIC

	var world: WorldEnvironment = WorldEnvironment.new()
	world.name = "WorldEnvironment"
	world.environment = environment
	_adopt(world, root, root)

	# LOCAL basis, not global_basis. Nothing here is in the SceneTree yet, and the
	# global_* setters read the parent chain to solve for a local value -- which
	# prints `Condition "!is_inside_tree()" is true` and silently writes identity.
	# Every node below is a direct child of a root that sits at identity, so the two
	# are the same value anyway.
	var sun: DirectionalLight3D = DirectionalLight3D.new()
	sun.name = "Sun"
	sun.basis = Basis.looking_at(Vector3(-0.814, -0.458, -0.356), Vector3.UP)
	sun.light_energy = 1.0
	sun.shadow_enabled = false
	_adopt(sun, root, root)

	var fill: DirectionalLight3D = DirectionalLight3D.new()
	fill.name = "Fill"
	fill.basis = Basis.looking_at(Vector3(0.789, 0.526, -0.316), Vector3.UP)
	fill.light_energy = 0.75
	fill.shadow_enabled = false
	_adopt(fill, root, root)


## The creature, the marker it chases, and the cameras.
##
## Node-typed exports are assigned as OBJECT REFERENCES here, not as NodePaths.
## PackedScene.pack() converts them and writes the `node_paths=` header itself, which
## is the one reliable way to get that attribute right -- hand-writing it is where
## the silent-null trap lives, and a generator that gets it wrong produces a scene
## that loads clean and does nothing.
func _build_actors(root: Node3D) -> void:
	var marker_scene: PackedScene = load(_res("../components/marker_pilot/marker_pilot.tscn"))
	var crawler_scene: PackedScene = load(_res("../actors/crawler/crawler.tscn"))
	var camera_scene: PackedScene = load(_res("../components/camera/crawler_camera_director.tscn"))

	var marker: MarkerPilot = marker_scene.instantiate() as MarkerPilot
	marker.name = "MarkerPilot"
	_adopt(marker, root, root)
	marker.transform = Transform3D(_frame_basis(6), _positions[6])

	var crawler: CrawlerBody = crawler_scene.instantiate() as CrawlerBody
	crawler.name = "Crawler"
	_adopt(crawler, root, root)
	# Two rings back is 4 m, which is exactly the leash slack -- so the creature
	# starts in the pose it spends its life in instead of lunging on the first tick.
	crawler.transform = Transform3D(_frame_basis(4), _positions[4])
	crawler.target_marker = marker

	var camera: CrawlerCameraDirector = camera_scene.instantiate() as CrawlerCameraDirector
	camera.name = "CameraDirector"
	_adopt(camera, root, root)
	camera.target = crawler
	camera.marker = marker
	marker.camera = camera


## A basis facing along the corridor at ring `index`. Basis.looking_at points -Z at
## its argument, and -Z is the creature's forward, so this needs no correction.
func _frame_basis(index: int) -> Basis:
	return Basis.looking_at(_forwards[index], _ups[index])


func _build_shell_mesh() -> ArrayMesh:
	var surface: SurfaceTool = SurfaceTool.new()
	surface.begin(Mesh.PRIMITIVE_TRIANGLES)
	for i: int in _positions.size() - 1:
		_emit_ring_walls(surface, _ring(i, 0.0), _ring(i + 1, 0.0))
	_emit_cap(surface, _ring(0, 0.0), true)
	_emit_cap(surface, _ring(_positions.size() - 1, 0.0), false)
	surface.generate_normals()
	return surface.commit()


## Ribs: a short section of tube inset into the corridor, with an annular shoulder at
## each end joining it back to the wall.
##
## Their real job is PARALLAX. A perfectly smooth tube gives the eye nothing to
## measure speed against, and a 5 m/s crawl reads as a slow drift. They are also
## extra grip surface, which is why they are on their own layer -- the camera arm
## ignores them, because a rib every 8 m would stutter the camera the whole way down.
func _build_ribs(root: Node3D) -> void:
	var surface: SurfaceTool = SurfaceTool.new()
	surface.begin(Mesh.PRIMITIVE_TRIANGLES)
	var emitted: int = 0
	var stride: int = maxi(int(round(RIB_SPACING / RING_STEP)), 1)
	var span: int = maxi(int(round(RIB_LENGTH / RING_STEP)), 1)
	for i: int in range(stride, _positions.size() - span - 1, stride):
		var outer_a: PackedVector3Array = _ring(i, 0.0)
		var inner_a: PackedVector3Array = _ring(i, RIB_INSET)
		var inner_b: PackedVector3Array = _ring(i + span, RIB_INSET)
		var outer_b: PackedVector3Array = _ring(i + span, 0.0)
		_emit_annulus(surface, outer_a, inner_a, true)
		_emit_ring_walls(surface, inner_a, inner_b)
		_emit_annulus(surface, outer_b, inner_b, false)
		emitted += 1
	if emitted == 0:
		return
	surface.generate_normals()

	var body: StaticBody3D = StaticBody3D.new()
	body.name = "Ribs"
	body.collision_layer = CrawlerLayers.PROP
	body.collision_mask = 0
	_adopt(body, root, root)

	var mesh_node: MeshInstance3D = MeshInstance3D.new()
	mesh_node.name = "Mesh"
	mesh_node.mesh = surface.commit()
	mesh_node.material_override = load(_res("../materials/corridor_rib.tres"))
	_adopt(mesh_node, body, root)

	var collision: CollisionShape3D = CollisionShape3D.new()
	collision.name = "Collision"
	collision.shape = (mesh_node.mesh as ArrayMesh).create_trimesh_shape()
	_adopt(collision, body, root)


## The four corners of ring `index`, inset by `inset` metres, in a consistent order
## around the tube: bottom-left, bottom-right, top-right, top-left.
##
## The ORDER is what makes the winding come out inward. Walking the corners this way
## and emitting each quad as (a[k], a[k+1], b[k+1], b[k]) puts every face normal
## toward the axis. Reverse the corner order and the entire corridor becomes
## invisible to raycasts while still looking perfectly fine on screen.
func _ring(index: int, inset: float) -> PackedVector3Array:
	var origin: Vector3 = _positions[index]
	var forward: Vector3 = _forwards[index]
	var up: Vector3 = _ups[index]
	var right: Vector3 = forward.cross(up).normalized()
	var half_w: float = maxf(_half_w[index] - inset, 0.2)
	var half_h: float = maxf(_half_h[index] - inset, 0.2)
	return PackedVector3Array(
		[
			origin - right * half_w - up * half_h,
			origin + right * half_w - up * half_h,
			origin + right * half_w + up * half_h,
			origin - right * half_w + up * half_h,
		]
	)


func _emit_ring_walls(
	surface: SurfaceTool, from: PackedVector3Array, to: PackedVector3Array
) -> void:
	for corner: int in 4:
		var next: int = (corner + 1) % 4
		_emit_quad(surface, from[corner], from[next], to[next], to[corner])


## The flat shoulder joining a rib's inset ring to the corridor wall.
func _emit_annulus(
	surface: SurfaceTool, outer: PackedVector3Array, inner: PackedVector3Array, facing: bool
) -> void:
	for corner: int in 4:
		var next: int = (corner + 1) % 4
		if facing:
			_emit_quad(surface, outer[corner], outer[next], inner[next], inner[corner])
		else:
			_emit_quad(surface, inner[corner], inner[next], outer[next], outer[corner])


## An end cap. `start` flips the winding, because the two ends of a tube face
## opposite ways along the axis and both must face INTO it.
func _emit_cap(surface: SurfaceTool, ring: PackedVector3Array, start: bool) -> void:
	if start:
		_emit_quad(surface, ring[0], ring[3], ring[2], ring[1])
	else:
		_emit_quad(surface, ring[0], ring[1], ring[2], ring[3])


## Two triangles, wound so the quad faces the side the corner order implies.
##
## THE ORDER IS REVERSED FROM THE OBVIOUS ONE, and it has to be: GODOT TREATS
## CLOCKWISE WINDING AS FRONT-FACING. Emitting (a,b,c),(a,c,d) -- which the
## right-hand rule says produces an inward normal -- gives Godot an outward one, and
## the result is a corridor that is invisible from inside AND, far worse, invisible
## to every raycast, because ConcavePolygonShape3D.backface_collision is false.
##
## That failure is nasty precisely because it does not look like a winding bug: the
## corridor renders fine from outside, the creature still finds a few anchors on rib
## geometry, and nothing errors. The tell was the body probe reporting its full 25 m
## range in all fourteen directions inside a 9 m tube.
##
## The hand-authored sandbox never hit this because BoxShape3D is a solid convex
## primitive with no winding to get wrong.
func _emit_quad(surface: SurfaceTool, a: Vector3, b: Vector3, c: Vector3, d: Vector3) -> void:
	surface.add_vertex(a)
	surface.add_vertex(c)
	surface.add_vertex(b)
	surface.add_vertex(a)
	surface.add_vertex(d)
	surface.add_vertex(c)


func _length() -> float:
	var total: float = 0.0
	for i: int in _positions.size() - 1:
		total += _positions[i].distance_to(_positions[i + 1])
	return total


func _min_clearance() -> float:
	var lowest: float = INF
	for i: int in _half_w.size():
		lowest = minf(lowest, minf(_half_w[i], _half_h[i]))
	return lowest


func _max_clearance() -> float:
	var highest: float = 0.0
	for i: int in _half_w.size():
		highest = maxf(highest, minf(_half_w[i], _half_h[i]))
	return highest


## add_child THEN set owner. Setting owner on a node that is not yet a descendant of
## the owner fails silently, and PackedScene.pack() then drops it -- producing a
## scene that saves without error and contains almost nothing.
func _adopt(node: Node, parent: Node, root: Node) -> void:
	parent.add_child(node)
	node.owner = root


## ResourceSaver writes absolute res:// paths, and FLAG_RELATIVE_PATHS still does
## nothing to text scenes in 4.7.1, so the ext_resource lines are rewritten by hand.
## `[paths]` in the static suite greps for the absolute form.
func _relativise(path: String) -> void:
	var file: FileAccess = FileAccess.open(path, FileAccess.READ)
	if file == null:
		printerr("could not reopen %s to relativise its paths" % path)
		return
	var text: String = file.get_as_text()
	file.close()
	# One replacement covers materials/, components/ and actors/ alike: the scene is
	# saved into scenes/, so every sibling folder is exactly one level up.
	text = text.replace("res://examples/3d/tentacle_crawler/", "../")
	var out: FileAccess = FileAccess.open(path, FileAccess.WRITE)
	out.store_string(text)
	out.close()


func _res(relative_path: String) -> String:
	var dir: String = (get_script() as Script).resource_path.get_base_dir()
	return dir.path_join(relative_path).simplify_path()
