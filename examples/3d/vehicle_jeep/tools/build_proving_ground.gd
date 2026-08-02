extends SceneTree

## Generates scenes/proving_ground.tscn: ground, lighting, the four test lanes, the
## jeep, the chase camera and the HUD.
##
## Generated rather than hand-authored for three reasons: ramp rotations come from
## rotate_x(deg) instead of hand-computed Transform3D matrices; the rubble field is
## 36 boxes nobody wants to place by hand; and a seeded RNG makes the output
## byte-reproducible, so regenerating produces a clean diff instead of noise.
##
## Usage:
##   Godot_v4.7.1-stable_win64_console.exe --headless \
##     --path <godot project root> --script res://examples/3d/vehicle_jeep/tools/build_proving_ground.gd

## Paths are relative to this script so the example keeps working wherever the
## folder is dropped inside a project. _res() turns them into res:// paths --
## load() and ResourceSaver do not resolve relative paths the way preload() does.
const JEEP_SCENE: String = "../actors/jeep/jeep.tscn"
const CAMERA_SCENE: String = "../components/camera/chase_camera_rig.tscn"
const HUD_SCENE: String = "../ui/jeep_hud.tscn"
const TARMAC_MATERIAL: String = "../materials/tarmac.tres"
const TEST_MATERIAL: String = "../materials/test_geometry.tres"
const RUBBLE_MATERIAL: String = "../materials/rubble.tres"
const MUD_MATERIAL: String = "../materials/mud.tres"
const ICE_MATERIAL: String = "../materials/ice.tres"
const OUT_PATH: String = "../scenes/proving_ground.tscn"

const GROUND_SIZE: float = 160.0
const GROUND_THICKNESS: float = 1.0
const KERB_HEIGHT: float = 1.2

## Lane A. Every ramp is one box rotated about +X so its -Z end rises, then sunk
## until the top face's near lip sits exactly on y=0 -- a clean wedge with no
## trigonometry in the .tscn. Crest height then works out to LENGTH * sin(angle).
const RAMP_ANGLES: PackedFloat32Array = [10.0, 20.0, 30.0, 40.0]
const RAMP_WIDTH: float = 7.0
const RAMP_THICKNESS: float = 1.2
const RAMP_LENGTH: float = 10.0
## Every ramp's near lip is placed at this world Z, so all four are approached from
## the same line and the runtime test needs one approach constant, not four.
const RAMP_LIP_Z: float = -18.0
const RAMP_X: PackedFloat32Array = [-24.0, -8.0, 8.0, 24.0]

## Lane B.
const BUMP_COUNT: int = 6
const BUMP_RADIUS: float = 0.28
const BUMP_LENGTH: float = 9.0
## Sunk so only this much stands proud -- a washboard, not a kerb.
const BUMP_PROUD: float = 0.18
const BUMP_SPACING: float = 2.2
## The tallest one is 0.75 m for a reason that is not obvious. A raycast vehicle's
## wheels have NO lateral collision -- they are rays that apply suspension force --
## so a square edge does not stop the jeep by being taller than the 0.417 m wheel.
## It stops it by fouling the HULL, and the adopted body proxy's underside sits at
## y = 0.49. Measured: the jeep drives clean over a 0.50 m step, rising only 0.22 m
## because it is across the 3 m tread before all four wheels are up. 0.75 m is
## comfortably above the clearance, so it high-centres, which is the honest
## demonstration of the limit.
const STEP_HEIGHTS: PackedFloat32Array = [0.15, 0.3, 0.45, 0.75]
const RUBBLE_COUNT: int = 36
const RUBBLE_SPREAD: float = 7.0
## Fixed so the generated scene is byte-reproducible across runs.
const RUBBLE_SEED: int = 20260730
const LANE_B_X: float = 34.0

## Lane C. The mud and ice lanes are laid edge to edge on purpose: the jeep's track
## is ~1.55 m, so straddling the join puts the left wheels on mud and the right on
## ice in the SAME frame. That is the case a single Area3D on the chassis cannot
## express, and it is what verify_jeep_runtime [split-mu] asserts.
const LANE_WIDTH: float = 3.6
const LANE_LENGTH: float = 40.0
const MUD_LANE_X: float = -34.0
const ICE_LANE_X: float = -30.2
## Patches are 2 cm thick with the top face 1 cm proud rather than flush. A patch
## inset flush at y=0 would be coplanar with the ground, and which body a raycast
## reports for coplanar faces is undefined -- the surface readout would flicker
## between mud and tarmac frame to frame. 1 cm is invisible to a 0.42 m wheel.
const PATCH_THICKNESS: float = 0.02
const PATCH_PROUD: float = 0.01

var _root: Node3D = null
var _report: PackedStringArray = PackedStringArray()


func _initialize() -> void:
	_root = Node3D.new()
	_root.name = "ProvingGround"

	_add_environment()
	_add_sun()
	_add_ground()
	_add_ramps()
	_add_bumps()
	_add_steps()
	_add_rubble()
	_add_surfaces()

	var spawn := Marker3D.new()
	spawn.name = "SpawnPoint"
	# The model's contact patches sit on y=0, so a little clearance drops the jeep
	# onto its suspension rather than spawning it interpenetrating the ground.
	spawn.position = Vector3(0.0, 0.45, 0.0)
	_adopt(spawn, _root)

	var jeep: Node = _instance(JEEP_SCENE)
	var rig: Node = _instance(CAMERA_SCENE)
	var hud: Node = _instance(HUD_SCENE)
	if jeep == null or rig == null or hud == null:
		quit(1)
		return

	jeep.name = "Jeep"
	(jeep as Node3D).position = spawn.position
	_adopt(jeep, _root)
	# Exported Node references serialise as NodePaths, so these survive packing.
	jeep.set("spawn_point", spawn)

	rig.name = "CameraRig"
	_adopt(rig, _root)
	rig.set("target", jeep)

	hud.name = "Hud"
	_adopt(hud, _root)
	hud.set("vehicle", jeep)

	# CONNECT_PERSIST is load-bearing: without it PackedScene.pack() drops the
	# connection, and the only symptom is a turret that never moves.
	rig.connect(&"aim_point_changed", Callable(jeep, "set_aim_point"), Object.CONNECT_PERSIST)

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

	print("Wrote %s" % out_path)
	_report.append("paths:  %d ext_resource entries rewritten relative" % rewritten)
	for line: String in _report:
		print("  %s" % line)

	# Freed rather than left to exit cleanup, which otherwise buries this tool's
	# output under a hundred lines of leaked-RID warnings -- and a report you have
	# to scroll past is a report you stop reading.
	_root.free()
	quit(0)


## Rewrites this scene's ext_resource paths into paths relative to the scene file,
## for every reference that lives inside this example folder. Returns how many were
## changed.
##
## Self-containment rule 1 says paths are relative to the file that uses them, so
## the folder can be dropped anywhere in a project. ResourceSaver will not do it:
## FLAG_RELATIVE_PATHS is a documented flag that has NO effect on text scenes in
## 4.7.1 -- verified by saving the same PackedScene with and without it and
## diffing, both absolute. So the rewrite happens here, on the text.
##
## References OUTSIDE the example folder are left absolute on purpose: they point
## at shared project assets, and a relative path to those would break in exactly
## the case this rule exists to protect.
func _relativise_paths(scene_path: String) -> int:
	var text: String = ""
	var reader: FileAccess = FileAccess.open(scene_path, FileAccess.READ)
	if reader == null:
		push_warning("Could not reopen %s to relativise its paths." % scene_path)
		return 0
	text = reader.get_as_text()
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


## `target` expressed relative to `base_dir`, both res:// paths.
##
## Hand-rolled because GDScript's String does not expose path_to_file() -- it
## exists in the C++ String but is not bound, so calling it is a parse error rather
## than the silent no-op the FLAG_RELATIVE_PATHS attempt above turned out to be.
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


func _add_environment() -> void:
	var sky_material := ProceduralSkyMaterial.new()
	sky_material.sky_top_color = Color(0.34, 0.47, 0.68)
	sky_material.sky_horizon_color = Color(0.76, 0.77, 0.74)
	sky_material.ground_bottom_color = Color(0.19, 0.18, 0.16)
	sky_material.ground_horizon_color = Color(0.58, 0.57, 0.52)

	var sky := Sky.new()
	sky.sky_material = sky_material

	var env := Environment.new()
	env.background_mode = Environment.BG_SKY
	env.sky = sky
	env.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
	env.ambient_light_sky_contribution = 1.0
	env.ambient_light_energy = 0.32
	env.tonemap_mode = Environment.TONE_MAPPER_FILMIC
	env.tonemap_exposure = 0.9
	env.fog_enabled = true
	env.fog_density = 0.0018
	env.fog_light_color = Color(0.66, 0.7, 0.72)
	# Not set on purpose: sdfgi / ssao / ssil / ssr / volumetric_fog are all
	# unsupported by the GL Compatibility renderer this project uses.

	var world_environment := WorldEnvironment.new()
	world_environment.name = "WorldEnvironment"
	world_environment.environment = env
	_adopt(world_environment, _root)


func _add_sun() -> void:
	var sun := DirectionalLight3D.new()
	sun.name = "Sun"
	sun.rotation_degrees = Vector3(-42.0, -125.0, 0.0)
	sun.light_energy = 0.9
	sun.shadow_enabled = true
	sun.shadow_bias = 0.04
	sun.shadow_normal_bias = 1.2
	sun.directional_shadow_mode = DirectionalLight3D.SHADOW_PARALLEL_4_SPLITS
	sun.directional_shadow_max_distance = 140.0
	_adopt(sun, _root)


func _add_ground() -> void:
	var tarmac: Material = load(_res(TARMAC_MATERIAL))
	var half: float = GROUND_SIZE * 0.5

	# One collider for the whole floor. Several tiled boxes would give Jolt shared
	# edges for a wheel ray to catch on.
	var ground: StaticBody3D = _make_box(
		"Ground",
		Vector3(GROUND_SIZE, GROUND_THICKNESS, GROUND_SIZE),
		Vector3(0.0, -GROUND_THICKNESS * 0.5, 0.0),
		tarmac
	)
	_adopt_tree(ground, _root)

	# Kerbs. You will drive off the edge otherwise, and a 160 m fall is a dull way
	# to end a test run.
	var kerbs := Node3D.new()
	kerbs.name = "Kerbs"
	_adopt(kerbs, _root)
	var material: Material = load(_res(TEST_MATERIAL))
	var edge: float = half - 0.5
	var spans: Array = [
		["KerbNorth", Vector3(GROUND_SIZE, KERB_HEIGHT, 1.0), Vector3(0.0, 0.0, -edge)],
		["KerbSouth", Vector3(GROUND_SIZE, KERB_HEIGHT, 1.0), Vector3(0.0, 0.0, edge)],
		["KerbWest", Vector3(1.0, KERB_HEIGHT, GROUND_SIZE), Vector3(-edge, 0.0, 0.0)],
		["KerbEast", Vector3(1.0, KERB_HEIGHT, GROUND_SIZE), Vector3(edge, 0.0, 0.0)],
	]
	for span: Array in spans:
		var size: Vector3 = span[1]
		var origin: Vector3 = span[2]
		origin.y = KERB_HEIGHT * 0.5
		_adopt_tree(_make_box(span[0] as String, size, origin, material), kerbs)


## Lane A, straight ahead (-Z): gradeability.
func _add_ramps() -> void:
	var group := Node3D.new()
	group.name = "Ramps"
	_adopt(group, _root)

	var material: Material = load(_res(TEST_MATERIAL))
	_report.append("ramps (approach from +Z, all near lips at z=%.1f):" % RAMP_LIP_Z)

	for index: int in RAMP_ANGLES.size():
		var degrees: float = RAMP_ANGLES[index]
		var angle: float = deg_to_rad(degrees)
		# Rotating about +X by a POSITIVE angle sends local +Z down and -Z up, so
		# the far end is the crest and the jeep climbs driving -Z.
		#
		# Sinking by (L/2)sin(a) - (T/2)cos(a) puts the top face's near lip exactly
		# on y=0: no lip to trip over, no floating edge, and crest = L*sin(a).
		var sink: float = (RAMP_LENGTH * 0.5) * sin(angle) - (RAMP_THICKNESS * 0.5) * cos(angle)
		var lip_offset: float = (
			(RAMP_THICKNESS * 0.5) * sin(angle) + (RAMP_LENGTH * 0.5) * cos(angle)
		)
		var centre_z: float = RAMP_LIP_Z - lip_offset
		var ramp: StaticBody3D = _make_box(
			"Ramp%02d" % int(degrees),
			Vector3(RAMP_WIDTH, RAMP_THICKNESS, RAMP_LENGTH),
			Vector3(RAMP_X[index], sink, centre_z),
			material
		)
		ramp.rotate_x(angle)
		_adopt_tree(ramp, group)

		var crest_height: float = RAMP_LENGTH * sin(angle)
		var crest_z: float = (
			centre_z + (RAMP_THICKNESS * 0.5) * sin(angle) - (RAMP_LENGTH * 0.5) * cos(angle)
		)
		_report.append(
			(
				"  %2d deg  x=%+6.1f  lip_z=%.1f  crest_z=%+7.2f  crest_height=%.2f m"
				% [int(degrees), RAMP_X[index], RAMP_LIP_Z, crest_z, crest_height]
			)
		)


## Lane B part 1: a washboard. Cylinders laid along X so the whole axle hits at
## once and the suspension, not the steering, is what is being read.
func _add_bumps() -> void:
	var group := Node3D.new()
	group.name = "Bumps"
	_adopt(group, _root)

	var material: Material = load(_res(TEST_MATERIAL))
	for index: int in BUMP_COUNT:
		var body := StaticBody3D.new()
		body.name = "Bump%02d" % index
		body.collision_layer = 1
		body.collision_mask = 0
		body.position = Vector3(
			LANE_B_X, BUMP_PROUD - BUMP_RADIUS, 6.0 + float(index) * BUMP_SPACING
		)
		# A CylinderShape3D's axis is +Y; this lays it along X.
		body.rotate_z(PI * 0.5)

		var shape := CylinderShape3D.new()
		shape.radius = BUMP_RADIUS
		shape.height = BUMP_LENGTH
		var collider := CollisionShape3D.new()
		collider.name = "CollisionShape3D"
		collider.shape = shape
		body.add_child(collider)

		var mesh := CylinderMesh.new()
		mesh.top_radius = BUMP_RADIUS
		mesh.bottom_radius = BUMP_RADIUS
		mesh.height = BUMP_LENGTH
		mesh.radial_segments = 12
		mesh.rings = 1
		mesh.material = material
		var visual := MeshInstance3D.new()
		visual.name = "MeshInstance3D"
		visual.mesh = mesh
		body.add_child(visual)

		_adopt_tree(body, group)
	_report.append(
		(
			"bumps:  %d cylinders r=%.2f at x=%.0f, %.2f m proud, %.1f m apart"
			% [BUMP_COUNT, BUMP_RADIUS, LANE_B_X, BUMP_PROUD, BUMP_SPACING]
		)
	)


## Lane B part 2: square edges. The wheel radius is 0.417, so the 0.50 step is
## taller than the wheel and should STOP the jeep from a standing start -- which
## makes the step test two-directional instead of a one-way "it climbed something".
func _add_steps() -> void:
	var group := Node3D.new()
	group.name = "Steps"
	_adopt(group, _root)

	var material: Material = load(_res(TEST_MATERIAL))
	for index: int in STEP_HEIGHTS.size():
		var height: float = STEP_HEIGHTS[index]
		var step: StaticBody3D = _make_box(
			"Step%02d" % int(round(height * 100.0)),
			Vector3(9.0, height, 3.0),
			Vector3(LANE_B_X, height * 0.5, -6.0 - float(index) * 7.0),
			material
		)
		_adopt_tree(step, group)
	var heights: PackedStringArray = PackedStringArray()
	for height: float in STEP_HEIGHTS:
		heights.append("%.2f" % height)
	_report.append(
		(
			"steps:  %s m at x=%.0f, driving -Z; hull clearance is 0.49 m"
			% [", ".join(heights), LANE_B_X]
		)
	)


## Lane B part 3: broken ground. Half-buried, randomly tilted boxes -- the thing
## that makes four independent suspension travels visible at a glance.
func _add_rubble() -> void:
	var group := Node3D.new()
	group.name = "Rubble"
	_adopt(group, _root)

	var material: Material = load(_res(RUBBLE_MATERIAL))
	var rng := RandomNumberGenerator.new()
	rng.seed = RUBBLE_SEED
	var centre := Vector3(LANE_B_X, 0.0, 26.0)

	for index: int in RUBBLE_COUNT:
		var size := Vector3(
			rng.randf_range(0.25, 0.8), rng.randf_range(0.25, 0.8), rng.randf_range(0.25, 0.8)
		)
		var origin: Vector3 = (
			centre
			+ Vector3(
				rng.randf_range(-RUBBLE_SPREAD, RUBBLE_SPREAD),
				rng.randf_range(-0.15, 0.2),
				rng.randf_range(-RUBBLE_SPREAD, RUBBLE_SPREAD)
			)
		)
		var block: StaticBody3D = _make_box("Rubble%02d" % index, size, origin, material)
		block.rotate_y(rng.randf_range(-PI, PI))
		block.rotate_x(rng.randf_range(-0.35, 0.35))
		block.rotate_z(rng.randf_range(-0.35, 0.35))
		_adopt_tree(block, group)
	_report.append(
		(
			"rubble: %d seeded blocks (seed %d) over %.0f x %.0f m at %s"
			% [RUBBLE_COUNT, RUBBLE_SEED, RUBBLE_SPREAD * 2.0, RUBBLE_SPREAD * 2.0, str(centre)]
		)
	)


## Lane C, left (-X): where grip goes away.
func _add_surfaces() -> void:
	var group := Node3D.new()
	group.name = "Surfaces"
	_adopt(group, _root)

	var mud: Material = load(_res(MUD_MATERIAL))
	var ice: Material = load(_res(ICE_MATERIAL))

	_add_patch(
		group,
		"MudLane",
		Vector3(LANE_WIDTH, PATCH_THICKNESS, LANE_LENGTH),
		Vector3(MUD_LANE_X, 0.0, 0.0),
		mud,
		&"surface_mud"
	)
	_add_patch(
		group,
		"IceLane",
		Vector3(LANE_WIDTH, PATCH_THICKNESS, LANE_LENGTH),
		Vector3(ICE_LANE_X, 0.0, 0.0),
		ice,
		&"surface_ice"
	)
	_add_patch(
		group,
		"MudPit",
		Vector3(12.0, PATCH_THICKNESS, 12.0),
		Vector3(-34.0, 0.0, 34.0),
		mud,
		&"surface_mud"
	)

	# On the run-up to the 20 degree ramp: the "you cannot climb it on mud" demo.
	_add_patch(
		group,
		"MudApron",
		Vector3(8.0, PATCH_THICKNESS, 10.0),
		Vector3(RAMP_X[1], 0.0, RAMP_LIP_Z + 5.0),
		mud,
		&"surface_mud"
	)

	# Somewhere to hold the handbrake down and spin.
	var circle := StaticBody3D.new()
	circle.name = "IceCircle"
	circle.collision_layer = 1
	circle.collision_mask = 0
	circle.position = Vector3(-34.0, PATCH_PROUD - PATCH_THICKNESS * 0.5, -30.0)
	# `true` = persistent. Without it the group is NOT written into the .tscn and
	# every low-grip patch silently loads as tarmac, with no error anywhere.
	circle.add_to_group(&"surface_ice", true)

	var shape := CylinderShape3D.new()
	shape.radius = 9.0
	shape.height = PATCH_THICKNESS
	var collider := CollisionShape3D.new()
	collider.name = "CollisionShape3D"
	collider.shape = shape
	circle.add_child(collider)

	var mesh := CylinderMesh.new()
	mesh.top_radius = 9.0
	mesh.bottom_radius = 9.0
	mesh.height = PATCH_THICKNESS
	mesh.radial_segments = 32
	mesh.rings = 1
	mesh.material = ice
	var visual := MeshInstance3D.new()
	visual.name = "MeshInstance3D"
	visual.mesh = mesh
	circle.add_child(visual)
	_adopt_tree(circle, group)

	var join_x: float = (MUD_LANE_X + LANE_WIDTH * 0.5 + ICE_LANE_X - LANE_WIDTH * 0.5) * 0.5
	_report.append(
		(
			"grip:   mud lane centred x=%.1f, ice lane x=%.1f, join at x=%.2f"
			% [MUD_LANE_X, ICE_LANE_X, join_x]
		)
	)
	_report.append("        straddle the join for split-mu; mud apron guards Ramp20")


func _add_patch(
	parent: Node,
	node_name: String,
	size: Vector3,
	origin: Vector3,
	material: Material,
	group_name: StringName
) -> void:
	var placed: Vector3 = origin
	placed.y = PATCH_PROUD - size.y * 0.5
	var patch: StaticBody3D = _make_box(node_name, size, placed, material)
	# `true` = persistent, or the group never reaches the .tscn. See IceCircle.
	patch.add_to_group(group_name, true)
	_adopt_tree(patch, parent)


func _instance(relative_path: String) -> Node:
	var path: String = _res(relative_path)
	var packed: PackedScene = load(path)
	if packed == null:
		printerr("Could not load %s" % path)
		return null
	return packed.instantiate()


## Adds `node` under `parent` and sets owner so PackedScene.pack() keeps it.
## For instanced sub-scenes only the instance root gets an owner -- its internal
## children stay owned by their own scene, which is what preserves the instance
## link through packing.
func _adopt(node: Node, parent: Node) -> void:
	parent.add_child(node)
	node.owner = _root


## Same, but also claims every descendant. Needed for nodes built locally whose
## children were attached before the parent joined the tree (setting owner requires
## the node to already share a tree with the owner).
func _adopt_tree(node: Node, parent: Node) -> void:
	parent.add_child(node)
	node.owner = _root
	for child: Node in node.get_children():
		_claim(child)


func _claim(node: Node) -> void:
	node.owner = _root
	for child: Node in node.get_children():
		_claim(child)


## Builds a StaticBody3D with a matching BoxShape3D collider and BoxMesh visual.
## Ownership is NOT set here -- the caller passes the result to _adopt_tree() after
## applying any rotation.
func _make_box(
	node_name: String, size: Vector3, origin: Vector3, material: Material
) -> StaticBody3D:
	var body := StaticBody3D.new()
	body.name = node_name
	body.collision_layer = 1
	body.collision_mask = 0
	body.position = origin

	var shape := BoxShape3D.new()
	shape.size = size
	var collider := CollisionShape3D.new()
	collider.name = "CollisionShape3D"
	collider.shape = shape
	body.add_child(collider)

	var mesh := BoxMesh.new()
	mesh.size = size
	mesh.material = material
	var visual := MeshInstance3D.new()
	visual.name = "MeshInstance3D"
	visual.mesh = mesh
	body.add_child(visual)

	return body


## Turns a path relative to this script into an absolute res:// path. load(),
## FileAccess and ResourceSaver do not resolve relative paths the way preload()
## does, so every path that reaches them goes through here.
func _res(relative_path: String) -> String:
	var dir: String = (get_script() as Script).resource_path.get_base_dir()
	return dir.path_join(relative_path).simplify_path()
