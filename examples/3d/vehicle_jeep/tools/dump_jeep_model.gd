extends SceneTree

## Prints everything the jeep rig depends on, read off the *imported* scene rather
## than off the .gltf source: node paths, the class Godot's importer decided each
## node is, local transforms, and every collision shape's type, point count and
## root-space AABB.
##
## Run this BEFORE writing any of the rig. Three things downstream encode its
## output and none of them can be guessed:
##
##   1. The collision harvester's reject predicate (jeep_visuals.gd) depends on the
##      wheel proxies reaching y=0 while every hull proxy starts well above it.
##   2. The wheel pivot names and their local positions become jeep.tscn's
##      VehicleWheel3D positions.
##   3. Godot's importer reinterprets node names -- `_wheel`/`-wheel`/`$wheel`
##      silently change a node's class (see .claude/rules/3d-assets.md). The class
##      column is the check: steering_wheel_pivot must be a Node3D, not a
##      VehicleWheel3D.
##
## Usage:
##   Godot_v4.7.1-stable_win64_console.exe --headless \
##     --path <godot project root> --script res://examples/3d/vehicle_jeep/tools/dump_jeep_model.gd

## Relative to this script -- see _res(). The shared asset, outside this example;
## the one external dependency the demo has.
const MODEL_SCENE: String = "../../../../assets/3d/vehicles/jeep_turret/sm_jeep_turret.tscn"
## Nodes the rig drives by name. Absence here is a hard failure downstream, so they
## are called out rather than left to be spotted in the tree dump.
const REQUIRED_NODES: Array[String] = [
	"jeep_turret_root",
	"jeep_turret_root/collision",
	"jeep_turret_root/wheel_fl_steer",
	"jeep_turret_root/wheel_fl_steer/wheel_fl_spin",
	"jeep_turret_root/wheel_fr_steer",
	"jeep_turret_root/wheel_fr_steer/wheel_fr_spin",
	"jeep_turret_root/wheel_rl_spin",
	"jeep_turret_root/wheel_rr_spin",
	"jeep_turret_root/turret_yaw",
	"jeep_turret_root/turret_yaw/turret_pitch",
	"jeep_turret_root/steering_wheel_pivot",
	"jeep_turret_root/mk_steering_axis",
	"jeep_turret_root/mk_headlight_l",
	"jeep_turret_root/mk_headlight_r",
	"jeep_turret_root/turret_yaw/turret_pitch/mk_muzzle",
]
## By path rather than by name: the collision proxies carry the same names as the
## wheel meshes, because Godot's importer strips the -convcolonly suffix.
const WHEEL_MESH_PATHS: Array[String] = [
	"jeep_turret_root/wheel_fl_steer/wheel_fl_spin/wheel_fl",
	"jeep_turret_root/wheel_fr_steer/wheel_fr_spin/wheel_fr",
	"jeep_turret_root/wheel_rl_spin/wheel_rl",
	"jeep_turret_root/wheel_rr_spin/wheel_rr",
]


func _initialize() -> void:
	var packed: PackedScene = load(_res(MODEL_SCENE))
	if packed == null:
		printerr("Could not load %s -- did --import succeed?" % _res(MODEL_SCENE))
		quit(1)
		return

	var root: Node = packed.instantiate()
	print("=== SCENE ROOT: %s (%s) ===" % [root.name, root.get_class()])
	_dump_tree(root, root, 0)

	print("\n=== REQUIRED NODES ===")
	var missing: int = 0
	for path: String in REQUIRED_NODES:
		var node: Node = root.get_node_or_null(NodePath(path))
		if node == null:
			missing += 1
			print("  MISSING  %s" % path)
		else:
			print("  ok  %-24s %s" % [node.get_class(), path])

	print("\n=== COLLISION SHAPES ===")
	print("  Every hull proxy should start well above y=0; every wheel proxy should")
	print("  reach y=0. That gap is the harvester's second gate.")
	for shape_node: CollisionShape3D in _find_all(root, "CollisionShape3D"):
		_dump_shape(shape_node, root)

	print("\n=== STEERING AXIS ===")
	var axis_marker: Node3D = (
		root.get_node_or_null(NodePath("jeep_turret_root/mk_steering_axis")) as Node3D
	)
	if axis_marker != null:
		var basis: Basis = axis_marker.transform.basis
		print("  mk_steering_axis basis.x = %s" % str(basis.x))
		print("  mk_steering_axis basis.y = %s" % str(basis.y))
		print(
			"  mk_steering_axis basis.z = %s   <- the rotation axis, read at runtime" % str(basis.z)
		)
		print("  tilt from +Z: %.2f deg" % rad_to_deg(basis.z.angle_to(Vector3.BACK)))

	print("\n=== WHEEL MESH BOUNDS (radius / half-width, per instance) ===")
	print("  wheel_radius in jeep.tscn comes from here, not from the spec's rounded 0.42.")
	# By path, not find_child(): the collision proxies carry the SAME names (the
	# importer strips the -convcolonly suffix), so a name search finds the
	# StaticBody3D first and reports "no mesh" on a model that is perfectly fine.
	for path: String in WHEEL_MESH_PATHS:
		var mesh_node: MeshInstance3D = root.get_node_or_null(NodePath(path)) as MeshInstance3D
		if mesh_node == null or mesh_node.mesh == null:
			print("  %s: not a MeshInstance3D with a mesh" % path)
			continue
		var aabb: AABB = mesh_node.mesh.get_aabb()
		print(
			(
				"  %-16s aabb pos=%s size=%s  -> radius~%.4f half_width~%.4f"
				% [
					mesh_node.name,
					str(aabb.position),
					str(aabb.size),
					maxf(aabb.size.y, aabb.size.z) * 0.5,
					aabb.size.x * 0.5
				]
			)
		)

	root.free()
	quit(1 if missing > 0 else 0)


func _dump_tree(node: Node, root: Node, depth: int) -> void:
	var extra: String = ""
	if node is Node3D:
		var node_3d: Node3D = node as Node3D
		extra = "  pos=%s rot_deg=%s" % [str(node_3d.position), str(node_3d.rotation_degrees)]
	print("%s%s (%s)%s" % ["  ".repeat(depth), node.name, node.get_class(), extra])
	for child: Node in node.get_children():
		_dump_tree(child, root, depth + 1)


func _dump_shape(shape_node: CollisionShape3D, root: Node) -> void:
	var shape: Shape3D = shape_node.shape
	if shape == null:
		print("  %s  <no shape>" % root.get_path_to(shape_node))
		return

	# Root space, not local: the harvester works in the body's frame, and a proxy
	# whose vertices are already root-space reads differently from one that is not.
	#
	# Accumulated up the parent chain rather than read off global_transform,
	# because SceneTree._initialize() runs before anything is in the tree and
	# global_transform then returns identity with an error -- see the example's
	# CLAUDE.md. The harvester at runtime IS in the tree and uses the direct form.
	var to_root: Transform3D = _transform_to(shape_node, root)
	var points: PackedVector3Array = PackedVector3Array()
	if shape is ConvexPolygonShape3D:
		points = (shape as ConvexPolygonShape3D).points

	var detail: String = ""
	if points.size() > 0:
		var lo: Vector3 = to_root * points[0]
		var hi: Vector3 = lo
		for point: Vector3 in points:
			var world_point: Vector3 = to_root * point
			lo = lo.min(world_point)
			hi = hi.max(world_point)
		detail = "  points=%d  root_aabb lo=%s hi=%s" % [points.size(), str(lo), str(hi)]

	print(
		(
			"  %-44s %-24s parent=%-16s%s"
			% [
				root.get_path_to(shape_node),
				shape.get_class(),
				shape_node.get_parent().get_class(),
				detail
			]
		)
	)


## Composed local transform from `ancestor` down to `node`, tree or no tree.
func _transform_to(node: Node3D, ancestor: Node) -> Transform3D:
	var result: Transform3D = Transform3D.IDENTITY
	var walk: Node = node
	while walk != null and walk != ancestor:
		if walk is Node3D:
			result = (walk as Node3D).transform * result
		walk = walk.get_parent()
	return result


func _find_all(node: Node, class_wanted: String) -> Array:
	var found: Array = []
	if node.is_class(class_wanted):
		found.append(node)
	for child: Node in node.get_children():
		found.append_array(_find_all(child, class_wanted))
	return found


## Turns a path relative to this script into an absolute res:// path. load(),
## FileAccess and ResourceSaver do not resolve relative paths the way preload()
## does, so every path that reaches them goes through here.
func _res(relative_path: String) -> String:
	var dir: String = (get_script() as Script).resource_path.get_base_dir()
	return dir.path_join(relative_path).simplify_path()
