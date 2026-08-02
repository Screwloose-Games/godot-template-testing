class_name JeepSurfaces
extends RefCounted

## What each ground surface does to a tyre. Pure tables plus one group lookup --
## no node references, no physics, so both the controller and the HUD read it.
##
## That sharing is the point. The grip number on the debug readout has to be the
## grip number in the solver; two files spelling 0.34 independently is how a
## readout stops describing the game (the GAIT_RATE_MIN lesson from the wolf
## example's CLAUDE.md).
##
## Surfaces are declared by node group, so any StaticBody3D in the world can opt
## in with add_to_group(&"surface_mud", true) -- note the `true`, or the group is
## not written into the .tscn and everything silently reads as tarmac.

## What a wheel touching nothing declared reports. Also the fallback for a wheel
## in the air, which is harmless: an airborne wheel exerts no traction anyway.
const DEFAULT: StringName = &"tarmac"
## Multiplies the wheel's authored wheel_friction_slip. 1.0 leaves it untouched.
##
## These only mean anything read together with the authored base
## (wheel_friction_slip = 1.0) and the engine force (2200 N per traction wheel).
## A tyre only lets go once the engine asks for more than the surface can pass, and
## the threshold is much lower than physical intuition suggests -- Godon's vehicle
## solver compares a HALVED forward impulse against the limit, so a surface has to
## be very slick indeed before throttle overwhelms it.
##
## Measured, by running the same 3 s standing start on tarmac and on mud:
##   base 3.5, mud 0.34  ->  mud covered 100% of the tarmac distance
##   base 1.0, mud 0.28  ->  still 100%
##   base 1.0, mud 0.14  ->  see the [mud] block of verify_jeep_runtime
## Anything that reads as "mud is slippery" but measures as 100% is decoration, so
## these are set where the difference actually reaches the solver.
const GRIP: Dictionary = {
	&"tarmac": 1.0,
	&"gravel": 0.45,
	&"mud": 0.14,
	&"ice": 0.06,
}
## Rolling resistance, added to the wheel's brake. Intended to separate mud from
## ice: mud is low grip AND drags, ice is low grip and free.
##
## Known limitation, worth stating because it is invisible from the outside: this
## only bites while COASTING. Godot's wheel solver takes the braking branch only
## when engine_force is zero, so drag does nothing under throttle -- raising mud's
## drag to 6.0 changed the measured mud distance by 0.02 m. Grip is the only lever
## that works while accelerating; drag is what makes mud feel sticky when you lift.
const DRAG: Dictionary = {
	&"tarmac": 0.0,
	&"gravel": 2.0,
	&"mud": 6.0,
	&"ice": 0.0,
}
## Surface name -> the group a body joins to declare itself that surface.
const GROUPS: Dictionary = {
	&"gravel": &"surface_gravel",
	&"mud": &"surface_mud",
	&"ice": &"surface_ice",
}

## body instance id -> surface name. Contact bodies change rarely and this runs
## four times per physics frame in a web build, so the group scan is memoised.
static var _cache: Dictionary = {}


## The surface a contacted body declares, or DEFAULT if it declares none.
static func name_for(body: Node) -> StringName:
	if body == null:
		return DEFAULT
	var id: int = body.get_instance_id()
	if _cache.has(id):
		return _cache[id]
	var found: StringName = DEFAULT
	for surface: StringName in GROUPS:
		if body.is_in_group(GROUPS[surface]):
			found = surface
			break
	_cache[id] = found
	return found


static func grip(surface: StringName) -> float:
	return GRIP.get(surface, 1.0)


static func drag(surface: StringName) -> float:
	return DRAG.get(surface, 0.0)


## Drops memoised lookups. Only needed when a body changes its groups at runtime
## or a level is unloaded -- instance ids are recycled, so a stale entry would
## report the old level's mud on a new level's tarmac.
static func clear_cache() -> void:
	_cache.clear()
