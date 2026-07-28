class_name RtsFormation
extends RefCounted

## Turns one right-click into N distinct destinations.
##
## Giving every selected unit the same target point is the single biggest cause of an RTS
## feeling broken: the squad arrives, cannot all occupy one spot, and spends the rest of the
## match shoving each other. Spreading the order into a ring formation fixes it at the source,
## before RVO avoidance is ever asked to referee an unsolvable problem.


## Destinations laid out in concentric rings around `center`: one in the middle, then 6 per
## ring at increasing radius. Returns exactly `count` of them.
static func slots(
	center: Vector3, count: int, spacing: float = RtsConfig.FORMATION_SPACING
) -> Array[Vector3]:
	var result: Array[Vector3] = []
	if count <= 0:
		return result
	result.append(center)
	var ring: int = 1
	while result.size() < count:
		var slots_in_ring: int = 6 * ring
		var radius: float = float(ring) * spacing
		for index: int in slots_in_ring:
			if result.size() >= count:
				break
			var angle: float = TAU * float(index) / float(slots_in_ring)
			result.append(center + Vector3(cos(angle) * radius, 0.0, sin(angle) * radius))
		ring += 1
	return result


## Hands out the slots so each goes to the closest unit that has not been given one yet.
## Without this the formation is correct but the squad crosses over itself getting into it,
## which looks worse than not having a formation at all. O(n^2), but it runs once per order
## with n capped at the population limit.
static func order_into_formation(units: Array, center: Vector3, engage: bool = false) -> void:
	var destinations: Array[Vector3] = slots(center, units.size())
	var remaining: Array = units.duplicate()
	for destination: Vector3 in destinations:
		if remaining.is_empty():
			return
		var best_index: int = 0
		var best_distance: float = INF
		for index: int in remaining.size():
			var unit: Node3D = remaining[index]
			var distance: float = unit.global_position.distance_squared_to(destination)
			if distance < best_distance:
				best_distance = distance
				best_index = index
		remaining[best_index].move_to(destination, engage)
		remaining.remove_at(best_index)
