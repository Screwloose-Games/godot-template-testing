extends SceneTree

## Generates scenes/demo_world.tscn: ground, lighting, slope/step test geometry,
## the wolf, and the orbit camera rig.
##
## Generated rather than hand-authored so the ramp rotations come from
## rotate_x(deg) instead of hand-computed Transform3D matrices.
##
## Usage:
##   Godot_v4.7.1-stable_win64_console.exe --headless \
##     --path <godot project root> --script res://examples/3d/exploration_quadraped/tools/build_demo_world.gd

## Paths are relative to this script so the example keeps working wherever the
## folder is dropped inside a project. _res() turns them into res:// paths --
## load() and ResourceSaver do not resolve relative paths the way preload() does.
const WOLF_SCENE: String = "../actors/wolf/wolf.tscn"
const CAMERA_SCENE: String = "../components/camera/orbit_camera_rig.tscn"
const GROUND_MATERIAL: String = "../materials/ground.tres"
const TEST_MATERIAL: String = "../materials/test_geometry.tres"
const OUT_PATH: String = "../scenes/demo_world.tscn"

const GROUND_SIZE: float = 60.0
const GROUND_THICKNESS: float = 1.0

## Ramp angles in degrees. floor_max_angle on the wolf is 55 degrees, so the
## first three should be climbable and the last should not.
const RAMP_ANGLES: PackedFloat32Array = [10.0, 25.0, 40.0, 55.0]
const STEP_HEIGHTS: PackedFloat32Array = [0.2, 0.4]

var _root: Node3D = null


func _initialize() -> void:
	_root = Node3D.new()
	_root.name = "DemoWorld"

	_add_environment()
	_add_sun()
	_add_ground()
	_add_test_geometry()

	var wolf: Node = _instance(WOLF_SCENE)
	if wolf == null:
		quit(1)
		return
	wolf.name = "Wolf"
	(wolf as Node3D).position = Vector3(0.0, 0.05, 0.0)
	_adopt(wolf, _root)

	var rig: Node = _instance(CAMERA_SCENE)
	if rig == null:
		quit(1)
		return
	rig.name = "CameraRig"
	_adopt(rig, _root)
	# Exported Node references serialise as NodePaths, so this survives packing.
	rig.set("target", wolf)

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

	print("Wrote %s" % out_path)
	print("  ground:  %.0f x %.0f, single collider (avoids Jolt shared-edge catching)"
			% [GROUND_SIZE, GROUND_SIZE])
	print("  ramps:   %s degrees" % str(RAMP_ANGLES))
	print("  steps:   %s m" % str(STEP_HEIGHTS))
	print("  wolf at %s, camera rig targeting it" % str((wolf as Node3D).position))
	quit(0)


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
## children were attached before the parent joined the tree (setting owner
## requires the node to already share a tree with the owner).
func _adopt_tree(node: Node, parent: Node) -> void:
	parent.add_child(node)
	node.owner = _root
	for child: Node in node.get_children():
		_claim(child)


func _claim(node: Node) -> void:
	node.owner = _root
	for child: Node in node.get_children():
		_claim(child)


func _add_environment() -> void:
	var sky_material := ProceduralSkyMaterial.new()
	sky_material.sky_top_color = Color(0.35, 0.5, 0.72)
	sky_material.sky_horizon_color = Color(0.72, 0.76, 0.78)
	sky_material.ground_bottom_color = Color(0.2, 0.21, 0.2)
	sky_material.ground_horizon_color = Color(0.6, 0.62, 0.6)

	var sky := Sky.new()
	sky.sky_material = sky_material

	var env := Environment.new()
	env.background_mode = Environment.BG_SKY
	env.sky = sky
	env.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
	env.ambient_light_sky_contribution = 1.0
	# Sky ambient at full energy on top of a 1.2-energy sun blew every upward-
	# facing surface to pure white, and the grey fur read as white. Ambient is
	# dialled back and the exposure trimmed so midtones land where the albedo
	# values actually put them.
	env.ambient_light_energy = 0.3
	env.tonemap_mode = Environment.TONE_MAPPER_FILMIC
	env.tonemap_exposure = 0.85
	env.fog_enabled = true
	env.fog_density = 0.0022
	env.fog_light_color = Color(0.62, 0.68, 0.72)
	# Not set on purpose: sdfgi / ssao / ssil / ssr / volumetric_fog are all
	# unsupported by the GL Compatibility renderer this project uses.

	var world_environment := WorldEnvironment.new()
	world_environment.name = "WorldEnvironment"
	world_environment.environment = env
	_adopt(world_environment, _root)


func _add_sun() -> void:
	var sun := DirectionalLight3D.new()
	sun.name = "Sun"
	sun.rotation_degrees = Vector3(-45.0, -130.0, 0.0)
	sun.light_energy = 0.85
	sun.shadow_enabled = true
	sun.shadow_bias = 0.03
	# 38 separate thin meshes with no shared skin are prime shadow-acne
	# candidates, so this matters more than usual.
	sun.shadow_normal_bias = 1.5
	sun.directional_shadow_mode = \
			DirectionalLight3D.SHADOW_PARALLEL_4_SPLITS
	sun.directional_shadow_max_distance = 60.0
	_adopt(sun, _root)


func _add_ground() -> void:
	var body := StaticBody3D.new()
	body.name = "Ground"
	body.collision_layer = 1
	body.collision_mask = 0
	_adopt(body, _root)

	var extents := Vector3(GROUND_SIZE, GROUND_THICKNESS, GROUND_SIZE)

	var shape := BoxShape3D.new()
	shape.size = extents
	var collider := CollisionShape3D.new()
	collider.name = "CollisionShape3D"
	collider.shape = shape
	collider.position = Vector3(0.0, -GROUND_THICKNESS * 0.5, 0.0)
	_adopt(collider, body)

	var mesh := BoxMesh.new()
	mesh.size = extents
	mesh.material = load(_res(GROUND_MATERIAL))
	var visual := MeshInstance3D.new()
	visual.name = "MeshInstance3D"
	visual.mesh = mesh
	visual.position = Vector3(0.0, -GROUND_THICKNESS * 0.5, 0.0)
	_adopt(visual, body)


func _add_test_geometry() -> void:
	var group := Node3D.new()
	group.name = "TestGeometry"
	_adopt(group, _root)

	var material: Material = load(_res(TEST_MATERIAL))

	# Ramps. Each is a long box rotated about X and sunk so its lower end is
	# buried in the ground, which makes a clean wedge without any trigonometry.
	for i: int in RAMP_ANGLES.size():
		var angle: float = RAMP_ANGLES[i]
		var ramp: StaticBody3D = _make_box(
				"Ramp%02d" % int(angle),
				Vector3(4.0, 1.0, 9.0),
				Vector3(-14.0 + float(i) * 6.0, -0.15, 8.0),
				material)
		ramp.rotate_x(-deg_to_rad(angle))
		_adopt_tree(ramp, group)

	# Steps.
	for i: int in STEP_HEIGHTS.size():
		var height: float = STEP_HEIGHTS[i]
		var step: StaticBody3D = _make_box(
				"Step%02d" % int(height * 100.0),
				Vector3(4.0, height, 2.0),
				Vector3(10.0 + float(i) * 5.0, height * 0.5, -4.0),
				material)
		_adopt_tree(step, group)

	# A wall, to check the capsule against something vertical.
	var wall: StaticBody3D = _make_box(
			"Wall", Vector3(10.0, 2.5, 0.5), Vector3(-8.0, 1.25, -8.0), material)
	_adopt_tree(wall, group)


## Builds a StaticBody3D with a matching BoxShape3D collider and BoxMesh visual.
## Ownership is NOT set here -- the caller passes the result to _adopt_tree()
## after applying any rotation.
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
