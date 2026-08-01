extends SceneTree

## Structural checks. Nothing here runs the game; it inspects what the scenes and the
## source actually say.
##
##   godot --headless --path <root> \
##     --script res://examples/3d/tentacle_crawler/tools/verify_tentacle_crawler_static.gd
##
## Everything runs on the first _process() tick rather than in _initialize(). Nodes
## added during SceneTree._initialize() never receive _ready(), so a check written
## there measures the harness rather than the example -- and reports a perfectly
## correct scene as broken.
##
## Anything that needs real physics (corridor cross-sections, anchors landing on
## walls, the creature getting round a bend) lives in the runtime suite instead. A
## check that cannot raycast should not pretend to measure geometry.

const EXAMPLE_ROOT: String = "res://examples/3d/tentacle_crawler"
const SANDBOX: String = "../scenes/crawl_sandbox.tscn"
const CORRIDOR: String = "../scenes/corridor_run.tscn"

## Effects that are silently unsupported on the GL Compatibility renderer this
## project targets. They do not error -- they just never appear, so a scene that uses
## one looks correct in the editor and ships without it.
const FORBIDDEN_RENDER: Array[String] = ["sdfgi_", "ssao_", "ssil_", "ssr_", "volumetric_fog_"]
## The creature must know the world only through raycasts, so nothing under actors/
## or components/ may name the generator's baked centreline or its type.
const FORBIDDEN_INDEPENDENCE: Array[String] = [
	"Centerline", "Path3D", "Curve3D", "corridor_run", "build_corridor_run"
]

var _failures: int = 0
var _done: bool = false


func _process(_delta: float) -> bool:
	if _done:
		return true
	_done = true

	_check_scenes_load()
	_check_wiring_survived_packing()
	_check_layer_matrix()
	_check_kinematic()
	_check_single_input_owner()
	_check_actions()
	_check_independence()
	_check_paths_are_relative()
	_check_uid_sidecars()
	_check_render_settings()
	_check_tuning_invariants()

	if _failures > 0:
		print("FAILED: %d check(s)" % _failures)
	else:
		print("all checks passed")
	quit(1 if _failures > 0 else 0)
	return true


func _check_scenes_load() -> void:
	var before: int = _failures
	var scenes: PackedStringArray = _files_under("", ".tscn")
	var loaded: int = 0
	for path: String in scenes:
		var packed: PackedScene = load(path) as PackedScene
		if packed == null:
			_fail("scenes", "%s did not load" % path)
			continue
		# Loading and INSTANTIATING are different failures. A scene referencing a
		# script that no longer compiles loads fine and explodes on instantiate.
		var node: Node = packed.instantiate()
		if node == null:
			_fail("scenes", "%s loaded but did not instantiate" % path)
			continue
		node.free()
		loaded += 1
	if loaded < 8:
		_fail("scenes", "only %d scenes found; expected at least 8" % loaded)
	_pass_if("scenes", before, "%d scenes load and instantiate" % loaded)


## THE HIGHEST-VALUE CHECK IN THIS FILE.
##
## A .tscn that assigns a Node-typed @export needs `node_paths=PackedStringArray(...)`
## on the node header. Without it Godot stores the NodePath, cannot resolve it because
## the target is not in the tree yet, and leaves the property NULL WITH NO ERROR
## ANYWHERE. The creature then renders perfectly, reports perfectly, and never moves.
func _check_wiring_survived_packing() -> void:
	var before: int = _failures
	for scene: String in [SANDBOX, CORRIDOR]:
		var world: Node = (load(_res(scene)) as PackedScene).instantiate()
		var expected: Array = [
			["MarkerPilot", "camera"],
			["Crawler", "target_marker"],
			["Crawler", "tentacles"],
			["Crawler/Tentacles", "body"],
			["Crawler/Tentacles", "shoulders"],
			["Crawler/Ribbons", "tentacles"],
			["CameraDirector", "target"],
			["CameraDirector", "marker"],
		]
		for entry: Array in expected:
			var node: Node = world.get_node_or_null(entry[0] as String)
			if node == null:
				_fail("wiring", "%s has no node %s" % [scene.get_file(), entry[0]])
				continue
			if node.get(entry[1] as String) == null:
				_fail(
					"wiring",
					(
						"%s: %s.%s is null -- missing node_paths= on its node header?"
						% [scene.get_file(), entry[0], entry[1]]
					)
				)
		world.free()
	_pass_if("wiring", before, "every Node-typed export resolves in both scenes")


func _check_layer_matrix() -> void:
	var before: int = _failures
	for scene: String in [SANDBOX, CORRIDOR]:
		var world: Node = (load(_res(scene)) as PackedScene).instantiate()
		for body: Node in _descendants(world):
			if body is CollisionObject3D:
				var collider: CollisionObject3D = body as CollisionObject3D
				var layer: int = collider.collision_layer
				if layer != CrawlerLayers.CORRIDOR and layer != CrawlerLayers.PROP:
					_fail(
						"layers",
						(
							"%s/%s is on layer %d, not CORRIDOR or PROP"
							% [scene.get_file(), collider.name, layer]
						)
					)
				if collider.collision_mask != 0:
					_fail(
						"layers",
						(
							"%s/%s has mask %d; static geometry detects nothing"
							% [scene.get_file(), collider.name, collider.collision_mask]
						)
					)
				# The CREATURE bit is reserved and must stay empty -- see the comment
				# on the constant. Anything occupying it means someone gave the body
				# a collider, which changes how the whole solver behaves.
				if (layer & CrawlerLayers.CREATURE) != 0:
					_fail("layers", "%s occupies the reserved CREATURE bit" % collider.name)
			if body is SpringArm3D:
				var arm: SpringArm3D = body as SpringArm3D
				if arm.collision_mask != CrawlerLayers.MASK_CAMERA_ARM:
					_fail(
						"layers", "a SpringArm3D masks %d, not MASK_CAMERA_ARM" % arm.collision_mask
					)
		world.free()
	_pass_if("layers", before, "collision layers and masks are as designed")


## The design, asserted. The body is kinematic so that one integrator owns the
## velocity and the stroke envelope cannot be eaten by contact resolution.
func _check_kinematic() -> void:
	var before: int = _failures
	var crawler: Node = (load(_res("../actors/crawler/crawler.tscn")) as PackedScene).instantiate()
	for node: Node in _descendants(crawler):
		if node is RigidBody3D or node is CharacterBody3D:
			_fail("kinematic", "%s is a physics body; the creature must stay kinematic" % node.name)
	crawler.free()
	_pass_if("kinematic", before, "no physics bodies inside the creature")


## Exactly one file may read input, which is what lets the creature be driven by a
## verifier with no player, no camera and no HUD in the scene.
func _check_single_input_owner() -> void:
	var before: int = _failures
	var readers: PackedStringArray = PackedStringArray()
	for path: String in _files_under("", ".gd"):
		if path.contains("/tools/"):
			continue
		var code: String = _read_code(path)
		if code.contains("Input.") or code.contains("InputEventMouse"):
			readers.append(path.get_file())
	if readers.size() != 1 or readers[0] != "marker_pilot.gd":
		_fail("input", "expected only marker_pilot.gd to read input, found %s" % str(readers))

	# The renderer reads state and writes geometry. Nothing else.
	var ribbons: String = _read_code(_res("../components/tentacle/tentacle_ribbons.gd"))
	for banned: String in ["apply_", "Input.", "intersect_ray"]:
		if ribbons.contains(banned):
			_fail("input", "tentacle_ribbons.gd mentions %s; it must only draw" % banned)
	_pass_if("input", before, "marker_pilot.gd is the only input reader")


## Every action prefixed, no built-ins touched, and the registration refcount
## round-trips -- the pilot must leave the host's InputMap exactly as it found it.
func _check_actions() -> void:
	var before: int = _failures
	var actions: Dictionary = load(_res("../components/marker_pilot/crawler_input_actions.gd")).get(
		"ACTIONS"
	)
	for action: StringName in actions:
		if not String(action).begins_with("crawler_"):
			_fail("actions", "%s is not prefixed crawler_" % action)
	if actions.has(&"ui_cancel"):
		_fail("actions", "ui_cancel is a Godot built-in and must not be registered")

	var probe: StringName = &"crawler_forward"
	if InputMap.has_action(probe):
		_fail("actions", "%s already exists before the pilot is instantiated" % probe)
	var pilot: Node = (
		(load(_res("../components/marker_pilot/marker_pilot.tscn")) as PackedScene).instantiate()
	)
	root.add_child(pilot)
	if not InputMap.has_action(probe):
		_fail("actions", "%s was not registered on entering the tree" % probe)
	pilot.free()
	if InputMap.has_action(probe):
		_fail("actions", "%s survived the pilot leaving the tree" % probe)
	_pass_if("actions", before, "%d actions register and erase cleanly" % actions.size())


## Turns "the creature is generator-agnostic" from an intention into a rule.
##
## Checked against source WITH COMMENTS STRIPPED, because a file that should not know
## about the centreline should not document it either -- but the docstrings here
## legitimately discuss why it must not, so the raw text would always match.
func _check_independence() -> void:
	var before: int = _failures
	for folder: String in ["actors", "components"]:
		for path: String in _files_under(folder, ".gd"):
			var code: String = _read_code(path)
			for banned: String in FORBIDDEN_INDEPENDENCE:
				if code.contains(banned):
					_fail(
						"independence",
						(
							"%s mentions %s; the creature must read the world only through raycasts"
							% [path.get_file(), banned]
						)
					)
	_pass_if("independence", before, "nothing in actors/ or components/ knows the generator exists")


## The Godot editor rewrites relative ext_resource paths to absolute res:// ones on
## every re-save, which breaks self-containment silently. This is how the folder rots.
func _check_paths_are_relative() -> void:
	var offenders: int = 0
	for extension: String in [".tscn", ".tres"]:
		for path: String in _files_under("", extension):
			var text: String = FileAccess.get_file_as_string(path)
			for line: String in text.split("\n"):
				if line.begins_with("[ext_resource") and line.contains(EXAMPLE_ROOT):
					_fail(
						"paths",
						"%s has an absolute path: %s" % [path.get_file(), line.strip_edges()]
					)
					offenders += 1
	if offenders == 0:
		_pass("paths", "every ext_resource path is relative")


func _check_uid_sidecars() -> void:
	var missing: int = 0
	for path: String in _files_under("", ".gd"):
		if not FileAccess.file_exists(path + ".uid"):
			_fail("uid", "%s has no .uid sidecar" % path.get_file())
			missing += 1
	if missing == 0:
		_pass("uid", "every .gd has its .uid sidecar")


func _check_render_settings() -> void:
	var before: int = _failures
	for extension: String in [".tscn", ".tres", ".gd"]:
		for path: String in _files_under("", extension):
			if path.ends_with("verify_tentacle_crawler_static.gd"):
				continue  # This file names them in order to ban them.
			# COMMENTS STRIPPED. crawl_sandbox.tscn carries a header explaining that
			# none of these effects may be used, and a raw text search cannot tell
			# that apart from using one -- it reported five violations against a
			# scene whose only crime was documenting the rule.
			var text: String = _read_code(path)
			for banned: String in FORBIDDEN_RENDER:
				if text.contains(banned):
					_fail(
						"render",
						"%s uses %s, unsupported on GL Compatibility" % [path.get_file(), banned]
					)

	for scene: String in [SANDBOX, CORRIDOR]:
		var world: Node = (load(_res(scene)) as PackedScene).instantiate()
		for node: Node in _descendants(world):
			if node is WorldEnvironment:
				var environment: Environment = (node as WorldEnvironment).environment
				if environment.background_mode != Environment.BG_COLOR:
					_fail("render", "%s: background is not a flat colour" % scene.get_file())
				if environment.ambient_light_source != Environment.AMBIENT_SOURCE_COLOR:
					_fail("render", "%s: ambient is not a COLOR source" % scene.get_file())
		world.free()
	_pass_if(
		"render",
		before,
		"no unsupported effects; both environments are flat colour + colour ambient"
	)


func _check_tuning_invariants() -> void:
	var failures: PackedStringArray = TentacleTuning.invariant_failures()
	for line: String in failures:
		_fail("tuning", line)
	if failures.is_empty():
		_pass("tuning", "TentacleTuning constants satisfy every invariant")


## Source with comments stripped, so a check for a banned token does not fire on the
## docstring explaining why the token is banned.
##
## Scene and resource files comment with `;`, GDScript with `#`. Getting this wrong
## is not a small matter of tidiness: these files are HEAVILY commented by house
## style, and every rule this suite enforces is also written down in prose right next
## to the code that obeys it.
func _read_code(path: String) -> String:
	var marker: String = ";" if path.ends_with(".tscn") or path.ends_with(".tres") else "#"
	var text: String = FileAccess.get_file_as_string(path)
	var stripped: String = ""
	for line: String in text.split("\n"):
		var at: int = line.find(marker)
		stripped += (line if at < 0 else line.substr(0, at)) + "\n"
	return stripped


func _files_under(folder: String, extension: String) -> PackedStringArray:
	var found: PackedStringArray = PackedStringArray()
	var base: String = EXAMPLE_ROOT if folder.is_empty() else EXAMPLE_ROOT.path_join(folder)
	_walk(base, extension, found)
	return found


func _walk(folder: String, extension: String, found: PackedStringArray) -> void:
	var dir: DirAccess = DirAccess.open(folder)
	if dir == null:
		return
	dir.list_dir_begin()
	var entry: String = dir.get_next()
	while entry != "":
		var path: String = folder.path_join(entry)
		if dir.current_is_dir():
			if not entry.begins_with("."):
				_walk(path, extension, found)
		elif entry.ends_with(extension):
			found.append(path)
		entry = dir.get_next()
	dir.list_dir_end()


func _descendants(node: Node) -> Array[Node]:
	var found: Array[Node] = [node]
	for child: Node in node.get_children():
		found.append_array(_descendants(child))
	return found


func _res(relative_path: String) -> String:
	var dir: String = (get_script() as Script).resource_path.get_base_dir()
	return dir.path_join(relative_path).simplify_path()


func _fail(tag: String, message: String) -> void:
	_failures += 1
	printerr("[%s] FAIL  %s" % [tag, message])


func _pass(tag: String, message: String) -> void:
	print("[%-13s] PASS  %s" % [tag, message])


## PASS only if this check added no failures.
##
## The unconditional version printed "[render] PASS" directly underneath five
## [render] FAIL lines, which is the kind of summary that gets skimmed and believed.
func _pass_if(tag: String, failures_before: int, message: String) -> void:
	if _failures == failures_before:
		_pass(tag, message)
