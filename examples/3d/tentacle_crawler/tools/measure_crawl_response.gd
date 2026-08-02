extends Node

## Prints what the crawl actually does, as numbers.
##
## The README quotes these, so they are not allowed to drift silently: retune
## anything in the anchor block or the leash and re-run this, then update the README
## or delete the numbers from it. A quoted number that no longer holds is worse than
## no number.
##
##   godot --headless --path <root> res://examples/3d/tentacle_crawler/tools/measure_crawl_response.tscn
##
## Pass `--` then `trace` to get the per-sample time series instead of the summary,
## which is what you want when the creature is doing something and you do not yet
## know what.

## Seconds of settling before the idle trace starts.
const SETTLE: float = 6.0
## Seconds each measured phase runs for.
const WINDOW: float = 8.0

var _world: Node
var _crawler: CrawlerBody
var _marker: MarkerPilot
var _tentacles: TentacleArray


func _ready() -> void:
	var packed: PackedScene = load(_res("../scenes/crawl_sandbox.tscn")) as PackedScene
	_world = packed.instantiate()
	add_child(_world)
	_crawler = _world.get_node("Crawler") as CrawlerBody
	_marker = _world.get_node("MarkerPilot") as MarkerPilot
	_tentacles = _crawler.get_node("Tentacles") as TentacleArray
	_marker.capture_mouse = false
	# UNWIRE THE CAMERA. In play, forward is measured off the orbit rig, so the path
	# a held W flies depends on the angle that rig happens to rest at -- and these
	# numbers are about the leash, the drag and the stroke ratchet, not about camera
	# framing. Left wired, a purely cosmetic change to the resting pitch tilts the
	# drive into the floor and rewrites the table in the README. With no director the
	# marker flies its own frame, dead level down the box, every run.
	_marker.camera = null

	var tracing: bool = OS.get_cmdline_user_args().has("trace")
	print("physics %d Hz" % Engine.physics_ticks_per_second)

	print("\n--- IDLE (marker parked, %.0f s settle) ---" % SETTLE)
	await _wait(SETTLE)
	await _run("idle", tracing)

	print("\n--- DRIVEN (marker held forward) ---")
	Input.action_press(&"crawler_forward")
	await _wait(1.0)
	await _run("driven", tracing)
	Input.action_release(&"crawler_forward")

	get_tree().quit(0)


func _run(label: String, tracing: bool) -> void:
	var start: Vector3 = _crawler.global_position
	var speeds: PackedFloat32Array = PackedFloat32Array()
	var planted: PackedInt32Array = PackedInt32Array()
	planted.resize(_tentacles.count() + 1)
	var separations: PackedFloat32Array = PackedFloat32Array()
	var strokes: int = 0
	var was_pulling: bool = false
	var sample: int = 0

	for _tick: int in int(WINDOW * Engine.physics_ticks_per_second):
		await get_tree().physics_frame
		var state: Dictionary = _crawler.debug_state()
		speeds.append(state["speed"])
		planted[state["planted_count"] as int] += 1
		var separation: float = _marker.global_position.distance_to(state["position"] as Vector3)
		separations.append(separation)
		var pulling: bool = state["pulling"]
		if pulling and not was_pulling:
			strokes += 1
		was_pulling = pulling
		sample += 1
		if tracing and sample % 15 == 0:
			print(
				(
					"  t %5.2f  z %7.2f  sep %5.2f  speed %5.2f  planted %d  %s"
					% [
						float(sample) / float(Engine.physics_ticks_per_second),
						(state["position"] as Vector3).z,
						separation,
						state["speed"],
						state["planted_count"],
						_tentacles.debug_state()["phases"] as String,
					]
				)
			)

	var travelled: float = start.distance_to(_crawler.global_position)
	print(
		(
			"%s: travelled %.2f m in %.0f s (mean %.2f m/s)"
			% [label, travelled, WINDOW, travelled / WINDOW]
		)
	)
	print(
		(
			"%s: speed %.2f .. %.2f m/s, mean %.2f"
			% [label, _min_of(speeds), _max_of(speeds), _mean_of(speeds)]
		)
	)
	print(
		(
			"%s: marker separation %.2f .. %.2f m, mean %.2f"
			% [label, _min_of(separations), _max_of(separations), _mean_of(separations)]
		)
	)
	print(
		(
			"%s: %d strokes in %.0f s (mean period %.2f s)"
			% [label, strokes, WINDOW, WINDOW / maxf(float(strokes), 1.0)]
		)
	)
	var histogram: String = ""
	for i: int in planted.size():
		histogram += "%d:%d%%  " % [i, roundi(100.0 * float(planted[i]) / float(sample))]
	print("%s: planted histogram  %s" % [label, histogram])


func _min_of(values: PackedFloat32Array) -> float:
	var lowest: float = INF
	for value: float in values:
		lowest = minf(lowest, value)
	return lowest


func _max_of(values: PackedFloat32Array) -> float:
	var highest: float = -INF
	for value: float in values:
		highest = maxf(highest, value)
	return highest


func _mean_of(values: PackedFloat32Array) -> float:
	if values.is_empty():
		return 0.0
	var total: float = 0.0
	for value: float in values:
		total += value
	return total / float(values.size())


func _wait(seconds: float) -> void:
	for _i: int in int(seconds * Engine.physics_ticks_per_second):
		await get_tree().physics_frame


func _res(relative_path: String) -> String:
	var dir: String = (get_script() as Script).resource_path.get_base_dir()
	return dir.path_join(relative_path).simplify_path()
