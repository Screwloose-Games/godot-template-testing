class_name CorridorProbe
extends RefCounted

## A 14-ray fan. THE CREATURE'S ONLY SENSE OF THE WORLD.
##
## It does not know the corridor has a centreline, a generator, a Path3D or a
## sequence of segments. It knows how far the wall is in fourteen directions, and
## everything else -- staying off the walls, finding an up vector, noticing it has
## left the level -- is derived from that.
##
## That is a deliberate design constraint, not an accident of implementation. The
## alternative is to hand the body the corridor's baked centreline, and it fails
## three ways: the creature would only work in a generated level, it would thread
## the middle like a train instead of hugging surfaces, and every disagreement
## between the generator and the solver about where "the middle" is becomes a bug.
## `[independence]` in the static suite greps actors/ and components/ for Path3D,
## Curve3D and Centerline to keep it that way.
##
## THE FAN IS WORLD-ALIGNED, NOT BODY-ALIGNED. A body-aligned fan rotates with a
## creature that writhes continuously, so every ray sweeps across the wall it is
## measuring and the "distance to the left wall" reading oscillates at the writhe
## frequency -- which the centering force then chases, and the creature wobbles for
## no reason a player could ever diagnose. World-aligned readings are stable.

## Six axes plus the eight cube diagonals. Fourteen is the cheapest fan that has no
## blind cone wider than about 55 degrees, which matters because the widest thing
## the body must not clip is a corridor corner.
const DIRECTIONS: Array[Vector3] = [
	Vector3(1, 0, 0),
	Vector3(-1, 0, 0),
	Vector3(0, 1, 0),
	Vector3(0, -1, 0),
	Vector3(0, 0, 1),
	Vector3(0, 0, -1),
	Vector3(0.5773503, 0.5773503, 0.5773503),
	Vector3(0.5773503, 0.5773503, -0.5773503),
	Vector3(0.5773503, -0.5773503, 0.5773503),
	Vector3(0.5773503, -0.5773503, -0.5773503),
	Vector3(-0.5773503, 0.5773503, 0.5773503),
	Vector3(-0.5773503, 0.5773503, -0.5773503),
	Vector3(-0.5773503, -0.5773503, 0.5773503),
	Vector3(-0.5773503, -0.5773503, -0.5773503),
]

var _distances: PackedFloat32Array = PackedFloat32Array()
var _hits: PackedByteArray = PackedByteArray()
var _range: float = 25.0
var _nearest_index: int = -1


func _init() -> void:
	_distances.resize(DIRECTIONS.size())
	_hits.resize(DIRECTIONS.size())


## Fire the fan. Costs 14 raycasts, once per physics tick.
func sample(
	space: PhysicsDirectSpaceState3D, origin: Vector3, mask: int, probe_range: float
) -> void:
	_range = probe_range
	_nearest_index = -1
	var nearest: float = probe_range
	for i: int in DIRECTIONS.size():
		var direction: Vector3 = DIRECTIONS[i]
		var params: PhysicsRayQueryParameters3D = PhysicsRayQueryParameters3D.create(
			origin, origin + direction * probe_range, mask
		)
		var hit: Dictionary = space.intersect_ray(params)
		if hit.is_empty():
			_distances[i] = probe_range
			_hits[i] = 0
			continue
		var distance: float = origin.distance_to(hit["position"] as Vector3)
		_distances[i] = distance
		_hits[i] = 1
		if distance < nearest:
			nearest = distance
			_nearest_index = i
	return


func count() -> int:
	return DIRECTIONS.size()


func direction(index: int) -> Vector3:
	return DIRECTIONS[index]


## Distance to the wall in direction `index`, or the probe range when nothing was
## hit. Never INF: callers compare it against comfort distances and an INF would
## poison every one of those comparisons.
func distance(index: int) -> float:
	return _distances[index]


func has_hit(index: int) -> bool:
	return _hits[index] == 1


func nearest_distance() -> float:
	return _range if _nearest_index < 0 else _distances[_nearest_index]


## The direction TOWARD the closest surface. Falls back to world down so that a
## creature in open space still has a defined up rather than a zero vector.
func nearest_direction() -> Vector3:
	return Vector3.DOWN if _nearest_index < 0 else DIRECTIONS[_nearest_index]


## True when not one of the fourteen rays found anything.
##
## In a sealed corridor this is impossible, which is exactly what makes it useful:
## it means the creature is outside the level. That happens when the generator emits
## a corridor with a hole in it -- a bend tighter than its own width self-intersects
## and opens one -- and without this check the symptom is a creature that flies off
## into the void while every other assertion still passes.
func has_escaped() -> bool:
	return _nearest_index < 0
