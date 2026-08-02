extends Node

## Photographs the crawl, so the things no headless test can see get looked at.
##
## Every physics assertion in verify_tentacle_crawler_runtime passes against a
## creature that renders as NOTHING AT ALL. The tentacles are hand-built
## ImmediateMesh geometry: wrong winding, a degenerate side vector, a material that
## culls, a strip built inside a node that still has a transform on it -- none of
## those are visible to an assertion about anchor positions, and all of them ship
## an invisible creature.
##
## MUST RUN WITH A REAL RENDERER. --headless uses the dummy driver and every shot
## comes back blank, which looks exactly like a bug in the thing being photographed:
##   godot --path <project root> res://examples/3d/tentacle_crawler/tools/capture_crawler.tscn
##
## Pass another scene after `--` to photograph that instead:
##   ... capture_crawler.tscn -- res://examples/3d/tentacle_crawler/scenes/corridor_run.tscn
##
## Shots are skipped, with a printed reason, when the thing they photograph does
## not exist yet. This tool is written to be usable from the FIRST step of the build
## (an empty corridor) rather than only once everything works -- "run it and look at
## it" is worth nothing as advice if the tool only starts working at the end.

## Where the shots go. Gitignored -- these are for looking at, not for keeping.
const OUT_DIR: String = "res://examples/3d/tentacle_crawler/tools/_shots"

var _world: Node
var _crawler: Node3D
var _marker: Node3D
var _shot: int = 0


func _ready() -> void:
	var target: String = _res("../scenes/crawl_sandbox.tscn")
	var user_args: PackedStringArray = OS.get_cmdline_user_args()
	if user_args.size() > 0:
		target = user_args[0]
	print("capturing %s" % target)

	var packed: PackedScene = load(target) as PackedScene
	if packed == null:
		printerr("could not load %s" % target)
		get_tree().quit(1)
		return
	_world = packed.instantiate()
	add_child(_world)

	_crawler = _world.find_child("Crawler", true, false) as Node3D
	_marker = _world.find_child("MarkerPilot", true, false) as Node3D
	# Never grab the mouse from a capture run: it steals the pointer from whoever
	# launched it and there is no player here to give it back.
	if _marker != null and "capture_mouse" in _marker:
		_marker.set("capture_mouse", false)
	print("present: crawler %s  marker %s" % [_crawler != null, _marker != null])

	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(OUT_DIR))
	await _run_shots()
	get_tree().quit(0)


## The shot list. Each entry photographs one thing that could be silently broken.
##
## In the generated corridor the marker is railed along the baked centreline and the
## shots are triggered by how far the CREATURE has got, not by a timer -- a timed
## shot photographs wherever the creature happened to be, which on a slow run is the
## previous section and looks like the wrong scene was loaded.
func _run_shots() -> void:
	await _wait(1.5)
	if _crawler == null:
		await _shoot("geometry")
		print("no Crawler in this scene yet -- creature shots skipped")
		return

	await _shoot("at_rest")

	var centerline: Path3D = _world.find_child("Centerline", true, false) as Path3D
	if centerline == null:
		await _sandbox_shots()
	else:
		await _corridor_shots(centerline)

	await _chase_shot()
	await _creature_solo_shot()


## Straight sandbox: drive forward and catch the creature mid-haul.
func _sandbox_shots() -> void:
	Input.action_press(&"crawler_forward")
	await _wait(1.2)
	await _shoot("reaching")
	await _wait(1.0)
	await _shoot("stroke_lurch")
	await _wait(2.6)
	await _shoot("narrow")
	Input.action_release(&"crawler_forward")


## Generated corridor: rail the marker and shoot at the sections worth seeing.
func _corridor_shots(centerline: Path3D) -> void:
	var curve: Curve3D = centerline.curve
	var total: float = curve.get_baked_length()
	# Offsets derived from the generator's own segment table.
	var stations: Array[Array] = [
		[35.0, "bend"],
		[74.0, "narrow"],
		[158.0, "chamber"],
	]
	var rail: float = curve.get_closest_offset(_marker.global_position)
	var delta: float = 1.0 / float(Engine.physics_ticks_per_second)
	var next: int = 0
	for _tick: int in int(70.0 * Engine.physics_ticks_per_second):
		await get_tree().physics_frame
		rail = minf(rail + 7.0 * delta, total)
		_marker.global_position = curve.sample_baked(rail)
		if next >= stations.size():
			break
		if curve.get_closest_offset(_crawler.global_position) >= (stations[next][0] as float):
			await _shoot(stations[next][1] as String)
			next += 1


## The other camera. Every shot above is already through the orbit rig, since that is
## the one the game starts on and drives with; this catches the chase rig.
##
## It asks for the rig it wants rather than calling `toggle()` twice. A blind toggle
## captures whichever camera happens not to be live, which is how you end up with a
## file called `orbit_view` containing a chase shot the day the default flips.
func _chase_shot() -> void:
	var director: CrawlerCameraDirector = (
		_world.find_child("CameraDirector", true, false) as CrawlerCameraDirector
	)
	if director == null:
		return
	director.set_orbit_active(false)
	await _wait(0.6)
	await _shoot("chase_view")
	director.set_orbit_active(true)
	await _wait(0.4)


## THE MOST IMPORTANT SHOT IN THE LIST, and the reason this tool exists.
##
## A dark creature against a grey wall can hide a completely broken pose -- a chain
## still at its rest angles, a limb sheared by the squash, a NaN control point -- while
## every other photograph still looks perfectly fine. With the corridor hidden there is
## nothing left to mistake for the creature.
func _creature_solo_shot() -> void:
	for node: Node in _descendants(_world):
		if node is GeometryInstance3D and not _crawler.is_ancestor_of(node):
			(node as GeometryInstance3D).visible = false
	await _wait(0.2)
	await _shoot("creature_solo")


func _descendants(node: Node) -> Array[Node]:
	var found: Array[Node] = [node]
	for child: Node in node.get_children():
		found.append_array(_descendants(child))
	return found


## Saves one PNG and prints the state that produced it.
##
## The telemetry line matters as much as the image: "the creature looks wrong" and
## "the creature is fine and the camera is pointed at a wall" are the same
## photograph, and only the numbers tell them apart.
func _shoot(label: String) -> void:
	# The texture is only valid once the frame has actually been drawn.
	await RenderingServer.frame_post_draw
	var image: Image = get_viewport().get_texture().get_image()
	_shot += 1
	var path: String = "%s/%02d_%s.png" % [OUT_DIR, _shot, label]
	var err: Error = image.save_png(path)
	if err != OK:
		printerr("save_png(%s) failed: %d" % [path, err])
		return
	print("%-24s  %s" % [path.get_file(), _telemetry()])


## One line of "what was true when the shutter opened". Degrades to a note rather
## than failing when the creature does not exist yet.
func _telemetry() -> String:
	if _crawler == null or not _crawler.has_method("debug_state"):
		var lit: float = _average_luma()
		return "no creature  ·  mean luma %.3f" % lit
	var state: Dictionary = _crawler.call("debug_state")
	var phases: String = "------"
	var tentacles: Node = _crawler.get_node_or_null("Tentacles")
	if tentacles != null:
		phases = tentacles.call("debug_state")["phases"]
	return (
		"planted %d/%d · speed %5.2f m/s · clearance %5.2f m · bones %3d · draws %4d · %s · %s"
		% [
			state.get("planted_count", 0),
			state.get("tentacle_count", 0),
			state.get("speed", 0.0),
			state.get("clearance", 0.0),
			_posed_bone_count(),
			_draw_call_count(),
			_arm_report(),
			phases,
		]
	)


## Bones actually posed this frame. Zero here and a photograph of an empty corridor are
## the same image, and only this number tells them apart.
func _posed_bone_count() -> int:
	var rig: CrawlerRig = _crawler.get_node_or_null("Rig") as CrawlerRig
	if rig == null:
		return 0
	var total: int = 0
	for strand: int in rig.strand_count():
		total += rig.link_count(strand)
	return total


## Draw calls in the frame just drawn.
##
## The creature is 470 separate MeshInstance3D nodes on a GL Compatibility web target,
## which is the one real performance risk in this example. Printing it next to every
## shot turns that from a worry into a number somebody can act on.
## Requested arm length against what the SpringArm actually gave us.
##
## "The creature fills the whole frame" has two completely different causes -- the arm
## is too short, or the arm is fine and a WALL is shortening it -- and they look
## identical in a screenshot. CLAUDE.md already records that trap costing a debug cycle
## once; printing both numbers is what stops it costing another.
func _arm_report() -> String:
	var director: Node = _world.get_node_or_null("CameraDirector")
	if director == null:
		return "arm n/a"
	for node: Node in _descendants(director):
		var arm: SpringArm3D = node as SpringArm3D
		if arm == null or not arm.is_visible_in_tree():
			continue
		return "arm %4.1f/%4.1f" % [arm.get_hit_length(), arm.spring_length]
	return "arm n/a"


func _draw_call_count() -> int:
	return RenderingServer.get_rendering_info(
		RenderingServer.RENDERING_INFO_TOTAL_DRAW_CALLS_IN_FRAME
	)


## Mean brightness of the frame just drawn.
##
## A completely black shot and a correctly-lit shot are indistinguishable in a log,
## and a corridor lit only by ambient (the sealed-tube shadow trap) looks fine in a
## thumbnail. This is the cheapest possible "did anything render" signal.
func _average_luma() -> float:
	var image: Image = get_viewport().get_texture().get_image()
	image.resize(16, 16, Image.INTERPOLATE_BILINEAR)
	var total: float = 0.0
	for y: int in 16:
		for x: int in 16:
			var c: Color = image.get_pixel(x, y)
			total += c.r * 0.2126 + c.g * 0.7152 + c.b * 0.0722
	return total / 256.0


func _wait(seconds: float) -> void:
	for _i: int in int(seconds * Engine.physics_ticks_per_second):
		await get_tree().physics_frame


## load() and ResourceSaver need real res:// paths, so relative paths in a tool
## script are resolved against the script's own location.
func _res(relative_path: String) -> String:
	var dir: String = (get_script() as Script).resource_path.get_base_dir()
	return dir.path_join(relative_path).simplify_path()
