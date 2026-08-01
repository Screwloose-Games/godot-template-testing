extends SceneTree

## Structural assertions on the jeep. Catches the failure modes that are silent at
## runtime: collision that was never adopted, wheel nodes at the wrong height, a
## centre of mass that will roll the vehicle, groups that did not survive packing,
## and the component boundary leaking.
##
## Two conventions borrowed from verify_wolf_static.gd, both learned the hard way:
## positive controls run BEFORE the negative assertions they depend on (otherwise
## "no static bodies remain" passes beautifully on a model that has none), and the
## boundary check greps SOURCE rather than inspecting the tree, because a literal
## get_node("...") string is invisible to any amount of node inspection.
##
## Usage:
##   Godot_v4.7.1-stable_win64_console.exe --headless \
##     --path <godot project root> --script res://examples/3d/vehicle_jeep/tools/verify_jeep_static.gd

## Paths are relative to this script -- see _res().
const JEEP_SCENE: String = "../actors/jeep/jeep.tscn"
const VISUALS_SCENE: String = "../actors/jeep/jeep_visuals.tscn"
const GROUND_SCENE: String = "../scenes/proving_ground.tscn"
const CONTROLLER_SCRIPT: String = "../actors/jeep/jeep_controller.gd"
const EXAMPLE_ROOT: String = ".."

## Measured off the wheel mesh by tools/dump_jeep_model.gd. jeep.tscn's wheel_radius
## and wheel Y both derive from it, so it is asserted rather than assumed.
const WHEEL_MESH_RADIUS: float = 0.4173
## Every hull proxy's lowest vertex sits at y >= 0.49; every wheel proxy reaches
## y = 0.00. The adopted hull union must therefore clear this.
const HULL_MIN_Y: float = 0.3
## Model pivot positions, X and Z. The wheel nodes must sit over them.
const WHEEL_XZ: Array = [
	Vector2(-0.76, -1.2),
	Vector2(0.76, -1.2),
	Vector2(-0.78, 1.15),
	Vector2(0.78, 1.15),
]
## Nodes the rig drives, and the class each must still be. Godot's importer
## reinterprets names -- a node renamed to end in `_wheel` would arrive as a
## VehicleWheel3D and every lookup here would quietly change meaning.
const REQUIRED_PIVOTS: Dictionary = {
	"jeep_turret_root/wheel_fl_steer": "Node3D",
	"jeep_turret_root/wheel_fl_steer/wheel_fl_spin": "Node3D",
	"jeep_turret_root/wheel_fr_steer": "Node3D",
	"jeep_turret_root/wheel_fr_steer/wheel_fr_spin": "Node3D",
	"jeep_turret_root/wheel_rl_spin": "Node3D",
	"jeep_turret_root/wheel_rr_spin": "Node3D",
	"jeep_turret_root/turret_yaw": "Node3D",
	"jeep_turret_root/turret_yaw/turret_pitch": "Node3D",
	"jeep_turret_root/steering_wheel_pivot": "Node3D",
	"jeep_turret_root/mk_steering_axis": "Marker3D",
	"jeep_turret_root/mk_headlight_l": "Marker3D",
	"jeep_turret_root/mk_headlight_r": "Marker3D",
	"jeep_turret_root/turret_yaw/turret_pitch/mk_muzzle": "Marker3D",
}
## Vocabulary the controller must not contain, comments included. If the controller
## should not touch a model node, it should not document one either.
const FORBIDDEN_IN_CONTROLLER: PackedStringArray = [
	"wheel_fl_steer",
	"wheel_rl_spin",
	"turret_yaw",
	"turret_pitch",
	"steering_wheel_pivot",
	"jeep_turret_root",
	"sm_jeep_turret",
]

var _failures: int = 0
var _warnings: int = 0
var _done: bool = false


## Everything runs on the first _process() tick, NOT in _initialize().
##
## _initialize() runs before the root is properly in the tree, so a node added
## there never receives NOTIFICATION_READY -- _ready() simply does not fire. That
## matters more here than in the wolf's verifier: the jeep's whole collision
## harvest happens in _ready(), so checking in _initialize() reported "adopted no
## hull collision, 8 static proxies remain" on a jeep that is completely correct.
## The check was measuring the harness, not the jeep.
func _process(_delta: float) -> bool:
	if _done:
		return true
	_done = true
	_run_checks()
	return true


func _run_checks() -> void:
	_check_1_model_dependency()
	_check_2_required_pivots()
	var proxy_count: int = _check_3_proxies_exist_before_harvest()
	var jeep: VehicleBody3D = _instance_jeep()
	if jeep == null:
		print("\n=== FATAL: could not instance the jeep ===")
		quit(1)
		return
	_check_4_collision_adopted(jeep, proxy_count)
	_check_5_visuals_identity(jeep)
	_check_6_wheel_geometry(jeep)
	_check_7_centre_of_mass(jeep)
	_check_8_proving_ground()
	_check_9_component_boundary()
	_check_10_uid_sidecars()

	print("\n=== %d failure(s), %d warning(s) ===" % [_failures, _warnings])
	quit(1 if _failures > 0 else 0)


func _fail(message: String) -> void:
	_failures += 1
	printerr("  FAIL: %s" % message)


func _warn(message: String) -> void:
	_warnings += 1
	print("  WARN: %s" % message)


## The one dependency outside this folder. Checked first so its failure is
## unambiguous rather than showing up as nine unrelated missing nodes.
func _check_1_model_dependency() -> void:
	print("\n[1] the shared model resolves")
	var packed: PackedScene = load(_res(VISUALS_SCENE))
	if packed == null:
		_fail("could not load %s" % _res(VISUALS_SCENE))
		return
	var visuals: Node = packed.instantiate()
	get_root().add_child(visuals)
	if visuals.get_node_or_null("%Model") == null:
		_fail("%Model does not resolve -- the sm_jeep_turret reference is broken")
	else:
		print("  %Model resolves OK")
	visuals.free()


func _check_2_required_pivots() -> void:
	print("\n[2] every driven pivot exists, with its expected class")
	var model: Node = _instance_model()
	if model == null:
		_fail("could not instance the visuals scene")
		return
	for path: String in REQUIRED_PIVOTS:
		var node: Node = model.get_node_or_null(NodePath(path))
		if node == null:
			_fail("missing: %s" % path)
		elif node.get_class() != REQUIRED_PIVOTS[path]:
			_fail(
				(
					"%s is a %s, expected %s -- has the importer reinterpreted its name?"
					% [path, node.get_class(), REQUIRED_PIVOTS[path]]
				)
			)
	if _failures == 0:
		print("  all %d pivots present with the right class" % REQUIRED_PIVOTS.size())
	model.get_parent().free()


## POSITIVE CONTROL for check 4. Without it, "no static bodies remain" would pass
## just as happily on a model that never had any.
func _check_3_proxies_exist_before_harvest() -> int:
	print("\n[3] positive control: the model carries collision proxies")
	var model: Node = _instance_model()
	if model == null:
		_fail("could not instance the visuals scene")
		return 0
	var container: Node = model.get_node_or_null(^"jeep_turret_root/collision")
	if container == null:
		_fail("no jeep_turret_root/collision node in the model")
		model.get_parent().free()
		return 0

	var total: int = 0
	var wheels: int = 0
	for child: Node in container.get_children():
		if child is StaticBody3D:
			total += 1
			if String(child.name).begins_with("wheel_"):
				wheels += 1
	print("  %d static proxies, %d of them wheels" % [total, wheels])
	if total != 8 or wheels != 4:
		_fail("expected 8 proxies with 4 wheels; the harvest predicate assumes it")
	model.get_parent().free()
	return total - wheels


## The sharp one. After _ready(), the jeep must carry the model's hull collision and
## none of the static bodies it came from -- and none of the four wheel proxies,
## which would fight the VehicleWheel3D raycasts.
func _check_4_collision_adopted(jeep: VehicleBody3D, expected_hulls: int) -> void:
	print("\n[4] hull collision adopted, static proxies destroyed")
	var leftovers: Array = _find_all(jeep, "StaticBody3D")
	if leftovers.size() > 0:
		_fail(
			(
				(
					"%d StaticBody3D still under the jeep -- static bodies inside a moving "
					% leftovers.size()
				)
				+ "rigid body"
			)
		)
	else:
		print("  no StaticBody3D remains OK")

	var colliders: Array[CollisionShape3D] = []
	for child: Node in jeep.get_children():
		if child is CollisionShape3D:
			colliders.append(child as CollisionShape3D)
	print("  %d CollisionShape3D adopted as direct children" % colliders.size())
	if colliders.size() != expected_hulls:
		_fail("expected %d hulls, adopted %d" % [expected_hulls, colliders.size()])

	var union: AABB = AABB()
	var first: bool = true
	for collider: CollisionShape3D in colliders:
		if not collider.shape is ConvexPolygonShape3D:
			_fail(
				(
					"%s is a %s, not a ConvexPolygonShape3D"
					% [collider.name, collider.shape.get_class()]
				)
			)
			continue
		for point: Vector3 in (collider.shape as ConvexPolygonShape3D).points:
			var placed: Vector3 = collider.transform * point
			if first:
				union = AABB(placed, Vector3.ZERO)
				first = false
			else:
				union = union.expand(placed)
	print("  adopted hull union: %s -> %s" % [str(union.position), str(union.end)])
	# Only possible if all four wheel proxies were excluded: they reach y = 0.
	if union.position.y < HULL_MIN_Y:
		_fail(
			(
				"hull union reaches y=%.3f, below %.2f -- a wheel proxy was adopted"
				% [union.position.y, HULL_MIN_Y]
			)
		)


## %Visuals must be at identity. Wheel poses are written in body space; a pitch,
## roll or scale here would tilt every wheel by a constant nothing would report.
func _check_5_visuals_identity(jeep: VehicleBody3D) -> void:
	print("\n[5] %Visuals sits at identity")
	var visuals: Node3D = jeep.get_node_or_null("%Visuals") as Node3D
	if visuals == null:
		_fail("%Visuals not found under the jeep")
		return
	if visuals.transform.is_equal_approx(Transform3D.IDENTITY):
		print("  identity OK")
	else:
		_fail("%%Visuals.transform is %s, not identity" % str(visuals.transform))


## Wheel geometry is derived, not chosen, so it is recomputed here rather than
## compared against a copy of the literal in jeep.tscn.
func _check_6_wheel_geometry(jeep: VehicleBody3D) -> void:
	print("\n[6] wheel nodes agree with the model and the suspension tune")
	var wheels: Array[VehicleWheel3D] = []
	for child: Node in jeep.get_children():
		if child is VehicleWheel3D:
			wheels.append(child as VehicleWheel3D)
	if wheels.size() != 4:
		_fail("expected 4 VehicleWheel3D direct children, found %d" % wheels.size())
		return

	var gravity: float = jeep.get("target_gravity")
	for index: int in wheels.size():
		var wheel: VehicleWheel3D = wheels[index]
		var wanted_xz: Vector2 = WHEEL_XZ[index]
		if (
			absf(wheel.position.x - wanted_xz.x) > 0.001
			or absf(wheel.position.z - wanted_xz.y) > 0.001
		):
			_fail(
				(
					"%s at x=%.3f z=%.3f, model pivot is x=%.3f z=%.3f"
					% [wheel.name, wheel.position.x, wheel.position.z, wanted_xz.x, wanted_xz.y]
				)
			)

		if absf(wheel.wheel_radius - WHEEL_MESH_RADIUS) > 0.001:
			_fail(
				(
					"%s wheel_radius %.4f != measured mesh radius %.4f"
					% [wheel.name, wheel.wheel_radius, WHEEL_MESH_RADIUS]
				)
			)

		# The engine hangs the wheel centre below the node by the suspension
		# length, which at rest is rest_length - g/(4k). Getting this wrong makes
		# the art float above the ground or sink into it.
		var sag: float = gravity / (4.0 * wheel.suspension_stiffness)
		var wanted_y: float = WHEEL_MESH_RADIUS + wheel.wheel_rest_length - sag
		if absf(wheel.position.y - wanted_y) > 0.001:
			_fail(
				(
					"%s at y=%.4f, derived value is %.4f (radius %.4f + rest %.3f - sag %.3f)"
					% [
						wheel.name,
						wheel.position.y,
						wanted_y,
						WHEEL_MESH_RADIUS,
						wheel.wheel_rest_length,
						sag
					]
				)
			)

		if not wheel.use_as_traction:
			_fail("%s is not use_as_traction; this jeep is 4WD" % wheel.name)
		var should_steer: bool = index < 2
		if wheel.use_as_steering != should_steer:
			_fail(
				(
					"%s use_as_steering is %s, expected %s"
					% [wheel.name, wheel.use_as_steering, should_steer]
				)
			)
	print("  4 wheels, positions and radius derived correctly")


## Guarded statically because the symptom -- "it rolls over in corners" -- reads as
## a steering tuning problem and sends you off to retune the wrong thing.
func _check_7_centre_of_mass(jeep: VehicleBody3D) -> void:
	print("\n[7] centre of mass is pinned low")
	if jeep.center_of_mass_mode != RigidBody3D.CENTER_OF_MASS_MODE_CUSTOM:
		_fail(
			(
				"center_of_mass_mode is AUTO. The adopted hulls span y 0.49 -> 2.14, "
				+ "which puts the automatic centre near y=1.1 on a 1.55 m track."
			)
		)
		return
	print("  custom, at %s" % str(jeep.center_of_mass))
	if jeep.center_of_mass.y >= 0.6:
		_fail("center_of_mass.y = %.2f is too high to corner on" % jeep.center_of_mass.y)


## The generated scene, after a pack/load round trip -- which is where a
## non-persistent group or a non-persistent connection disappears.
func _check_8_proving_ground() -> void:
	print("\n[8] proving_ground.tscn survived packing")
	var packed: PackedScene = load(_res(GROUND_SCENE))
	if packed == null:
		_fail("could not load %s -- has build_proving_ground.gd been run?" % _res(GROUND_SCENE))
		return
	# Not added to the tree on purpose: groups and connections are readable without
	# it, and instancing the whole world would capture the mouse and start physics.
	var world: Node = packed.instantiate()

	var expected_groups: Dictionary = {
		"Surfaces/MudLane": &"surface_mud",
		"Surfaces/MudPit": &"surface_mud",
		"Surfaces/MudApron": &"surface_mud",
		"Surfaces/IceLane": &"surface_ice",
		"Surfaces/IceCircle": &"surface_ice",
	}
	for path: String in expected_groups:
		var node: Node = world.get_node_or_null(NodePath(path))
		if node == null:
			_fail("missing %s" % path)
		elif not node.is_in_group(expected_groups[path]):
			_fail(
				(
					(
						"%s is not in %s -- add_to_group() needs persistent=true or the "
						% [path, expected_groups[path]]
					)
					+ "group never reaches the .tscn"
				)
			)
	print("  %d surface patches carry their groups" % expected_groups.size())

	var jeep: Node = world.get_node_or_null(^"Jeep")
	var rig: Node = world.get_node_or_null(^"CameraRig")
	if jeep == null or rig == null:
		_fail("Jeep or CameraRig missing from the generated scene")
		world.free()
		return
	if rig.is_connected(&"aim_point_changed", Callable(jeep, "set_aim_point")):
		print("  aim_point_changed -> set_aim_point survived packing OK")
	else:
		_fail(
			(
				"the aim connection did not survive packing -- connect() needs "
				+ "Object.CONNECT_PERSIST. The turret would silently never move."
			)
		)

	var ground: CollisionObject3D = world.get_node_or_null(^"Ground") as CollisionObject3D
	if ground != null and ground.collision_layer != 1:
		_fail("Ground is on layer %d, expected 1 (world)" % ground.collision_layer)
	var jeep_body: CollisionObject3D = jeep as CollisionObject3D
	if jeep_body.collision_layer != 2:
		_fail("Jeep is on layer %d, expected 2" % jeep_body.collision_layer)
	if jeep_body.collision_mask & 1 == 0:
		_fail("Jeep does not mask layer 1 -- the wheel rays would find nothing")
	var arm: SpringArm3D = rig.get_node_or_null("%SpringArm") as SpringArm3D
	if arm == null:
		_fail("no %SpringArm in the camera rig")
	elif arm.collision_mask & 2 != 0:
		_fail("the spring arm masks layer 2, so it collides with the jeep it follows")
	else:
		print("  layers OK: world 1, jeep 2, arm sees 1 only")
	world.free()


## Greps the controller's SOURCE, comments included. A node-shape check is trivially
## bypassed by a literal get_node("...") string, and no tree inspection sees one.
func _check_9_component_boundary() -> void:
	print("\n[9] the controller names no node inside the model")
	var source: String = _read_text(_res(CONTROLLER_SCRIPT))
	if source.is_empty():
		_fail("could not read %s" % _res(CONTROLLER_SCRIPT))
		return
	var leaked: PackedStringArray = PackedStringArray()
	for term: String in FORBIDDEN_IN_CONTROLLER:
		if source.contains(term):
			leaked.append(term)
	if leaked.size() > 0:
		_fail(
			(
				"jeep_controller.gd mentions %s -- that vocabulary belongs to " % str(leaked)
				+ "jeep_visuals.gd"
			)
		)
	else:
		print("  controller is clean of all %d terms" % FORBIDDEN_IN_CONTROLLER.size())

	var jeep_scene: String = _read_text(_res(JEEP_SCENE))
	if jeep_scene.contains("sm_jeep_turret"):
		_fail("jeep.tscn references the model directly; only jeep_visuals.tscn may")
	else:
		print("  jeep.tscn reaches the model only through jeep_visuals.tscn OK")


## Godot generates a .gd.uid per script, and a missing one means a reference by uid
## breaks the next time the file moves. The repo commits them.
func _check_10_uid_sidecars() -> void:
	print("\n[10] every .gd has a committed .gd.uid")
	var scripts: PackedStringArray = PackedStringArray()
	_collect_scripts(_res(EXAMPLE_ROOT), scripts)
	var missing: PackedStringArray = PackedStringArray()
	for path: String in scripts:
		if not FileAccess.file_exists(path + ".uid"):
			missing.append(path)
	if missing.size() > 0:
		_fail("%d script(s) without a .uid sidecar: %s" % [missing.size(), str(missing)])
	else:
		print("  %d scripts, all with sidecars OK" % scripts.size())


func _instance_jeep() -> VehicleBody3D:
	var packed: PackedScene = load(_res(JEEP_SCENE))
	if packed == null:
		_fail("could not load %s" % _res(JEEP_SCENE))
		return null
	var jeep: Node = packed.instantiate()
	# Added to the tree so _ready() runs -- the collision harvest happens there.
	get_root().add_child(jeep)
	return jeep as VehicleBody3D


## The model subtree, inside a live JeepVisuals. Returned node is
## `<visuals>/Model`; free the PARENT to clean up.
func _instance_model() -> Node:
	var packed: PackedScene = load(_res(VISUALS_SCENE))
	if packed == null:
		return null
	var visuals: Node = packed.instantiate()
	get_root().add_child(visuals)
	return visuals.get_node_or_null("%Model")


func _collect_scripts(dir_path: String, out: PackedStringArray) -> void:
	var dir: DirAccess = DirAccess.open(dir_path)
	if dir == null:
		return
	for file_name: String in dir.get_files():
		if file_name.ends_with(".gd"):
			out.append(dir_path.path_join(file_name))
	for sub: String in dir.get_directories():
		_collect_scripts(dir_path.path_join(sub), out)


func _read_text(path: String) -> String:
	var file: FileAccess = FileAccess.open(path, FileAccess.READ)
	if file == null:
		return ""
	var text: String = file.get_as_text()
	file.close()
	return text


func _find_all(node: Node, class_wanted: String) -> Array:
	var found: Array = []
	if node.is_class(class_wanted):
		found.append(node)
	for child: Node in node.get_children():
		found.append_array(_find_all(child, class_wanted))
	return found


## Turns a path relative to this script into an absolute res:// path. load(),
## FileAccess and DirAccess do not resolve relative paths the way preload() does.
func _res(relative_path: String) -> String:
	var dir: String = (get_script() as Script).resource_path.get_base_dir()
	return dir.path_join(relative_path).simplify_path()
