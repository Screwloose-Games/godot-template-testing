extends SceneTree

## Structural checks. Nothing here runs the game; it inspects what the scenes and
## the source actually say.
##
##   godot --headless --path <godot project root> \
##     --script res://examples/3d/cargo_tether/tools/verify_cargo_tether_static.gd
##
## Everything runs on the first _process() tick rather than in _initialize().
## Nodes added during SceneTree._initialize() never receive _ready(), so a check
## written there measures the harness rather than the example -- and reports a
## perfectly correct scene as broken.

const SHIP_SCENE: String = "../actors/ship/ship.tscn"
const CARGO_SCENE: String = "../actors/cargo/cargo.tscn"
const RIG_SCENE: String = "../components/camera/ship_chase_rig.tscn"
const TURRET_SCENE: String = "../threats/turret.tscn"
const POOL_SCENE: String = "../threats/projectile_pool.tscn"
const COURSE_SCENE: String = "../scenes/cargo_run.tscn"
const SANDBOX_SCENE: String = "../scenes/tether_sandbox.tscn"
const CONTROLLER_SOURCE: String = "../actors/ship/ship_controller.gd"
const LINK_SOURCE: String = "../components/tether/tether_link.gd"
const WINCH_SOURCE: String = "../components/tether/tether_winch.gd"

## The mass ratio band. Outside this the cargo is either scenery or an anchor --
## see the derivation in cargo.tscn.
const RATIO_MIN: float = 0.45
const RATIO_MAX: float = 0.75

var _failures: int = 0
var _done: bool = false


func _process(_delta: float) -> bool:
	if _done:
		return true
	_done = true

	_check_scenes_load()
	_check_mass_ratio()
	_check_body_settings()
	_check_layer_matrix()
	_check_wiring_survived_packing()
	_check_winch_band()
	_check_paths_are_relative()
	_check_component_boundaries()
	_check_uid_sidecars()

	if _failures > 0:
		print("FAILED: %d check(s)" % _failures)
	else:
		print("all checks passed")
	quit(1 if _failures > 0 else 0)
	return true


func _fail(tag: String, message: String) -> void:
	_failures += 1
	printerr("[%s] %s" % [tag, message])


func _pass(tag: String, message: String) -> void:
	print("[%s] %s" % [tag, message])


## 1. Every scene in the folder resolves and instantiates.
func _check_scenes_load() -> void:
	var scenes: Array[String] = [
		SHIP_SCENE, CARGO_SCENE, RIG_SCENE, TURRET_SCENE, POOL_SCENE, SANDBOX_SCENE, COURSE_SCENE
	]
	for path: String in scenes:
		var packed: PackedScene = load(_res(path)) as PackedScene
		if packed == null:
			_fail("scenes", "%s did not load" % path)
			continue
		var node: Node = packed.instantiate()
		if node == null:
			_fail("scenes", "%s did not instantiate" % path)
			continue
		node.free()
	_pass("scenes", "%d scenes load and instantiate" % scenes.size())


## 2. THE most important number in the example, asserted structurally. The
## behavioural half of this is the tow-cost measurement in
## measure_tether_response.tscn -- 0.630 of the free run.
func _check_mass_ratio() -> void:
	var ship: RigidBody3D = _instantiate(SHIP_SCENE) as RigidBody3D
	var cargo: RigidBody3D = _instantiate(CARGO_SCENE) as RigidBody3D
	if ship == null or cargo == null:
		_fail("mass", "could not instantiate the bodies")
		return
	var ratio: float = cargo.mass / maxf(ship.mass, 0.001)
	if ratio < RATIO_MIN or ratio > RATIO_MAX:
		_fail("mass", "cargo:ship is %.3f, outside [%.2f, %.2f]" % [ratio, RATIO_MIN, RATIO_MAX])
	else:
		_pass("mass", "cargo:ship %.3f (%.0f / %.0f kg)" % [ratio, cargo.mass, ship.mass])
	ship.free()
	cargo.free()


## 3. The zero-gravity settings that are silently wrong by default, including the
## can_sleep flag whose failure mode is "the tether works sometimes".
func _check_body_settings() -> void:
	for path: String in [SHIP_SCENE, CARGO_SCENE]:
		var body: RigidBody3D = _instantiate(path) as RigidBody3D
		if body == null:
			continue
		if not is_zero_approx(body.gravity_scale):
			_fail("bodies", "%s has gravity_scale %.2f" % [path, body.gravity_scale])
		if body.can_sleep:
			_fail("bodies", "%s can sleep; apply_force() will be silently ignored" % path)
		if body.linear_damp_mode != RigidBody3D.DAMP_MODE_REPLACE:
			_fail("bodies", "%s linear_damp_mode is not REPLACE" % path)
		if body.angular_damp_mode != RigidBody3D.DAMP_MODE_REPLACE:
			_fail("bodies", "%s angular_damp_mode is not REPLACE" % path)
		body.free()
	_pass("bodies", "zero-g, no sleep, damping REPLACE on ship and cargo")


## 4. The layer matrix from data/tether_layers.gd, against the scenes that carry
## it as bare integers -- plus the assertion that nothing occupies the reserved
## PROJECTILE bit, which is what would mean somebody had turned the raycast shots
## back into bodies and reintroduced tunnelling.
func _check_layer_matrix() -> void:
	var expected: Dictionary = {
		SHIP_SCENE: [TetherLayers.SHIP, TetherLayers.MASK_SHIP_BODY],
		CARGO_SCENE: [TetherLayers.CARGO, TetherLayers.MASK_CARGO_BODY],
		TURRET_SCENE: [TetherLayers.TURRET, 0],
	}
	for path: String in expected:
		var body: CollisionObject3D = _instantiate(path) as CollisionObject3D
		if body == null:
			continue
		var want: Array = expected[path]
		if body.collision_layer != want[0]:
			_fail("layers", "%s layer is %d, expected %d" % [path, body.collision_layer, want[0]])
		if body.collision_mask != want[1]:
			_fail("layers", "%s mask is %d, expected %d" % [path, body.collision_mask, want[1]])
		body.free()

	var rig: Node = _instantiate(RIG_SCENE)
	if rig != null:
		var arm: SpringArm3D = rig.get_node_or_null("SpringArm") as SpringArm3D
		if arm == null:
			_fail("layers", "camera rig has no SpringArm")
		elif arm.collision_mask & (TetherLayers.SHIP | TetherLayers.CARGO) != 0:
			_fail("layers", "the camera arm masks the ship or the cargo; it will catch on them")
		rig.free()

	var course: Node = _instantiate(COURSE_SCENE)
	if course != null:
		var offenders: int = _count_projectile_layer(course)
		if offenders > 0:
			_fail(
				"layers",
				(
					"%d bodies occupy the reserved PROJECTILE bit -- shots are supposed to be raycasts"
					% offenders
				)
			)
		course.free()
	_pass("layers", "layer/mask matrix matches TetherLayers, PROJECTILE bit unoccupied")


func _count_projectile_layer(node: Node) -> int:
	var count: int = 0
	var body: CollisionObject3D = node as CollisionObject3D
	if body != null and (body.collision_layer & TetherLayers.PROJECTILE) != 0:
		count += 1
	for child: Node in node.get_children():
		count += _count_projectile_layer(child)
	return count


## 5. The node_paths trap, in both directions.
##
## A Node-typed @export assigned in a .tscn resolves to NULL unless the node
## header carries node_paths=PackedStringArray(...). There is no error when it
## fails: TetherLink simply bails out of _physics_process forever and the only
## symptom is a separation of exactly 0.00. This is the single most valuable
## check in the file, because it caught exactly that.
func _check_wiring_survived_packing() -> void:
	for path: String in [SANDBOX_SCENE, COURSE_SCENE]:
		var world: Node = _instantiate(path)
		if world == null:
			continue
		var tether: Node = world.get_node_or_null("Tether")
		var ship: Node = world.get_node_or_null("Ship")
		var run: Node = world.get_node_or_null("Run")
		if tether == null or ship == null or run == null:
			_fail("wiring", "%s is missing Tether, Ship or Run" % path)
			world.free()
			continue
		var wires: Dictionary = {
			"tether.ship": tether.get("ship"),
			"tether.cargo": tether.get("cargo"),
			"tether.ship_anchor": tether.get("ship_anchor"),
			"tether.cargo_anchor": tether.get("cargo_anchor"),
			"ship.tether": ship.get("tether"),
			"run.ship": run.get("ship"),
			"run.dock": run.get("dock"),
			"run.projectiles": run.get("projectiles"),
		}
		for name: String in wires:
			if wires[name] == null:
				_fail(
					"wiring",
					"%s: %s is null -- missing node_paths= on the node header" % [path, name]
				)
		world.free()
	_pass("wiring", "every Node-typed export resolves in both scenes")


## 6. The winch band has to leave room for both bodies, or the minimum setting is
## interpenetration rather than merely close.
func _check_winch_band() -> void:
	if TetherWinch.MIN_LENGTH >= TetherWinch.MAX_LENGTH:
		_fail("winch", "MIN_LENGTH is not below MAX_LENGTH")
	if (
		TetherWinch.START_LENGTH < TetherWinch.MIN_LENGTH
		or TetherWinch.START_LENGTH > TetherWinch.MAX_LENGTH
	):
		_fail("winch", "START_LENGTH sits outside the band")
	if TetherWinch.STALL_FRACTION <= 0.0:
		_fail("winch", "STALL_FRACTION of 0 means reeling in against load stops dead")
	_pass(
		"winch",
		(
			"band %.0f-%.0f m, start %.0f, stall floor %.2f"
			% [
				TetherWinch.MIN_LENGTH,
				TetherWinch.MAX_LENGTH,
				TetherWinch.START_LENGTH,
				TetherWinch.STALL_FRACTION
			]
		)
	)


## 7. Self-containment rule 1. The Godot editor rewrites relative ext_resource
## paths to absolute res:// ones every time it re-saves a scene, which breaks the
## folder silently -- it keeps working right up until somebody moves it. This is
## the highest-frequency way this example rots.
func _check_paths_are_relative() -> void:
	var root: String = _res("..")
	var offenders: PackedStringArray = PackedStringArray()
	for file: String in _walk(root):
		if not (file.ends_with(".tscn") or file.ends_with(".tres")):
			continue
		var reader: FileAccess = FileAccess.open(file, FileAccess.READ)
		if reader == null:
			continue
		var text: String = reader.get_as_text()
		reader.close()
		# ONLY ext_resource lines. Scanning the whole file flags the "how to run"
		# line in a scene's own header comment, which is a res:// path that is
		# supposed to be absolute -- it is an instruction to a human, not a
		# dependency. The first version of this check failed the sandbox for
		# documenting itself.
		for line: String in text.split("\n"):
			if line.begins_with("[ext_resource ") and line.contains(root):
				offenders.append(file.trim_prefix(root + "/"))
				break
	if offenders.size() > 0:
		_fail("paths", "absolute self-references in: %s" % ", ".join(offenders))
	else:
		_pass("paths", "no scene or resource references this folder absolutely")


## 8. Component boundaries, asserted by grepping SOURCE rather than by inspecting
## the tree. A literal Input.is_action_pressed() buried in the tether is invisible
## to any amount of node inspection.
##
## COMMENTS ARE STRIPPED FIRST, unlike the jeep's equivalent check. These are
## assertions about what a file DOES, and the most valuable comment in any of
## these files is the one explaining why a coupling is deliberately absent --
## ship_controller.gd says it does not call reload_current_scene() and why. A
## check that cannot tell that apart from actually calling it teaches people to
## delete the explanation, which is the opposite of the point.
func _check_component_boundaries() -> void:
	if _read_code(LINK_SOURCE).contains("Input."):
		_fail("boundary", "tether_link.gd reads input; ShipController owns every ship_* action")
	var winch: String = _read_code(WINCH_SOURCE)
	for forbidden: String in ["Input.", "get_tree", "global_position", "_physics_process"]:
		if winch.contains(forbidden):
			_fail("boundary", "tether_winch.gd uses '%s'; it is meant to be pure maths" % forbidden)
	if _read_code(CONTROLLER_SOURCE).contains("reload_current_scene"):
		_fail("boundary", "ship_controller.gd restarts the run; TetherRun owns that")
	_pass("boundary", "tether stays out of input, winch stays out of the engine")


## 9. Every .gd carries its .gd.uid sidecar, matching the repo convention.
func _check_uid_sidecars() -> void:
	var missing: PackedStringArray = PackedStringArray()
	for file: String in _walk(_res("..")):
		if not file.ends_with(".gd"):
			continue
		if not FileAccess.file_exists(file + ".uid"):
			missing.append(file.get_file())
	if missing.size() > 0:
		_fail("uid", "missing .gd.uid for: %s" % ", ".join(missing))
	else:
		_pass("uid", "every .gd has its .uid sidecar")


func _walk(dir_path: String) -> PackedStringArray:
	var found: PackedStringArray = PackedStringArray()
	var dir: DirAccess = DirAccess.open(dir_path)
	if dir == null:
		return found
	dir.list_dir_begin()
	var entry: String = dir.get_next()
	while entry != "":
		if not entry.begins_with("."):
			var full: String = dir_path.path_join(entry)
			if dir.current_is_dir():
				found.append_array(_walk(full))
			else:
				found.append(full)
		entry = dir.get_next()
	dir.list_dir_end()
	return found


func _read(relative_path: String) -> String:
	var reader: FileAccess = FileAccess.open(_res(relative_path), FileAccess.READ)
	if reader == null:
		_fail("read", "could not open %s" % relative_path)
		return ""
	var text: String = reader.get_as_text()
	reader.close()
	return text


## Source with every comment line removed, so a boundary check reads what the
## file does rather than what it explains about itself.
func _read_code(relative_path: String) -> String:
	var kept: PackedStringArray = PackedStringArray()
	for line: String in _read(relative_path).split("\n"):
		if not line.strip_edges().begins_with("#"):
			kept.append(line)
	return "\n".join(kept)


func _instantiate(relative_path: String) -> Node:
	var packed: PackedScene = load(_res(relative_path)) as PackedScene
	if packed == null:
		return null
	return packed.instantiate()


func _res(relative_path: String) -> String:
	var dir: String = (get_script() as Script).resource_path.get_base_dir()
	return dir.path_join(relative_path).simplify_path()
