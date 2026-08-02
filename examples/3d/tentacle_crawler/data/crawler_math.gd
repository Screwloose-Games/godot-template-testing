class_name CrawlerMath
extends RefCounted

## Vector helpers that more than one component needs, in one place.
##
## NO ENGINE DEPENDENCIES, same contract as TentacleTuning. Three files here blend
## direction vectors -- the chase rig's up reference, the body's up reference, and
## the tentacle coil axis -- and every one of them can produce a NaN that silently
## poisons a whole transform. One copy, with the reasoning attached to it.


## Normalised lerp between two directions.
##
## NOT Vector3.slerp, and this is the entire reason the function exists. Slerp
## rotates about the cross product of its arguments and ASSERTS that axis is unit
## length. A basis that has been rebuilt from looking_at every frame drifts off unit
## length by a part in a thousand within a minute, and the caller then spams
## "The axis Vector3 (...) must be normalized" on every single frame. Normalising the
## INPUTS does not fix it -- the complaint comes from inside the rotation. An nlerp
## has no axis-angle step at all, and for a direction reference the easing
## difference is invisible.
static func blend_direction(from: Vector3, to: Vector3, weight: float) -> Vector3:
	var blended: Vector3 = from.lerp(to, clampf(weight, 0.0, 1.0))
	# Near-antipodal inputs lerp through zero, and normalising a zero vector is a
	# NaN that propagates into the transform and never comes back out.
	if blended.length_squared() < 0.000001:
		return to.normalized() if to.length_squared() > 0.000001 else from
	return blended.normalized()


## Normalise, or fall back rather than produce a NaN.
##
## Vector3.normalized() on a zero vector returns Vector3.ZERO in Godot 4 rather than
## NaN, which is worse in one specific way: it is a plausible-looking value that
## silently zeroes whatever it is multiplied into, so the failure surfaces three
## systems away from its cause.
static func direction_or(vector: Vector3, fallback: Vector3) -> Vector3:
	if vector.length_squared() < 0.000001:
		return fallback
	return vector.normalized()


## Frame-rate-independent smoothing weight for a given stiffness, 1/s.
##
## The repo standard. A bare `lerp(a, b, k * delta)` is frame-rate DEPENDENT and
## goes unstable when k * delta exceeds 1, which on a 20 fps web build is a
## stiffness of only 20.
static func smoothing(stiffness: float, delta: float) -> float:
	return 1.0 - exp(-stiffness * delta)
