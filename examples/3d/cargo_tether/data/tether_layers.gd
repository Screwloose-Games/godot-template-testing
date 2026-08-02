class_name TetherLayers
extends RefCounted

## The physics layer allocation for this example, and the only record of what each
## bit means.
##
## Scene files store `collision_layer` and `collision_mask` as bare integers -- a
## `.tscn` property cannot reference a constant -- so the numbers in `ship.tscn`
## and friends are unexplained on sight. `verify_cargo_tether_static.gd` check 4
## reads this file and asserts every body in the generated scene matches, which is
## what stops the two drifting apart.
##
## Layer 1 is OBSTACLE rather than "everything", matching the convention both
## other 3D examples use: the camera's SpringArm3D masks the world and nothing
## else, so it can never catch on the thing it is following and no exclusion
## bookkeeping is needed.

## Asteroids, course bounds, the dock structure. Anything solid you can hit.
const OBSTACLE: int = 1 << 0
## The player.
const SHIP: int = 1 << 1
## The towed crate.
const CARGO: int = 1 << 2
## RESERVED, AND DELIBERATELY UNOCCUPIED.
##
## Turret shots are raycasts, not bodies, which is what makes them untunnellable
## at 220 m/s. Nothing is on this layer and check 4 asserts that no body carries
## this bit -- so if someone later converts projectiles to RigidBody3D and
## reintroduces tunnelling, a test fails instead of a player reporting that fast
## shots sometimes miss. A reserved-and-asserted bit is cheaper than a comment.
const PROJECTILE: int = 1 << 3
## Area3D volumes only: the delivery dock, checkpoint gates.
const TRIGGER: int = 1 << 4
## Turret emplacements. Separate from OBSTACLE so a line-of-sight ray can ignore
## turrets (they do not block each other) while the camera arm still avoids them.
const TURRET: int = 1 << 5

## What the ship collides with. Not TRIGGER: an Area3D detects bodies, bodies do
## not detect areas, so masking it here would do nothing but cost broadphase.
const MASK_SHIP_BODY: int = OBSTACLE | CARGO | TURRET
## What the cargo collides with. Includes SHIP on purpose -- at the 6 m minimum
## winch length the crate can bump the hull, and feeling that is the point of
## reeling in that far.
const MASK_CARGO_BODY: int = OBSTACLE | SHIP | TURRET
## The chase camera's SpringArm3D. Never SHIP or CARGO: the arm must not catch on
## the ship it follows, nor on the cargo it is trying to keep in frame.
const MASK_CAMERA_ARM: int = OBSTACLE | TURRET
## Turret shot raycasts. Everything solid, so a shot can be stopped by a rock.
const MASK_PROJECTILE_QUERY: int = SHIP | CARGO | OBSTACLE | TURRET
## Turret line-of-sight. Only rock blocks sight, so two turrets covering the same
## chokepoint both fire rather than one silently holding.
const MASK_TURRET_LOS: int = OBSTACLE
## The dock trigger needs both bodies: arriving without the cargo is a distinct
## outcome from arriving with it, and the Area3D is what tells them apart.
const MASK_DOCK_TRIGGER: int = SHIP | CARGO
## Checkpoint gates time the ship only. The cargo trails through afterwards and
## would double-fire the gate.
const MASK_GATE_TRIGGER: int = SHIP
