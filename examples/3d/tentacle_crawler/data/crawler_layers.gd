class_name CrawlerLayers
extends RefCounted

## The one place collision layer bits are named.
##
## Three files raycast against this world -- the tentacles looking for something to
## grip, the body probing for walls, and two camera arms -- and each wants a
## DIFFERENT subset. Spelling those subsets as four named masks here is what stops
## a fifth caller from inventing a sixth one.
##
## Every static body in this example carries `collision_mask = 0`. Nothing here
## moves under physics, so nothing needs to detect anything; a mask costs broadphase
## work for a query that is never asked.

## The corridor shell: walls, floor, ceiling, end caps. Always grippable.
const CORRIDOR: int = 1 << 0
## Ribs, pipes, dents. Grippable, but not structural -- the corridor is still a
## sealed tube if every prop is deleted, which is what makes them optional.
const PROP: int = 1 << 1
## RESERVED AND DELIBERATELY UNOCCUPIED.
##
## The creature is kinematic on purpose (see CLAUDE.md): one integrator owns the
## velocity, which is what buys determinism and what stops a stroke impulse being
## laundered through contact resolution. The day somebody makes the body a
## RigidBody3D they will need a layer, and this is the one they will reach for --
## at which point `[layers]` in the static suite fails and tells them why, instead
## of the drag feel silently changing under everyone.
const CREATURE: int = 1 << 2

## Tentacles grip anything solid, structural or not. A rib is a great handhold.
const MASK_TENTACLE_QUERY: int = CORRIDOR | PROP
## The body's wall probe wants everything it could smear against.
const MASK_BODY_PROBE: int = CORRIDOR | PROP
## The marker is an INTENT, not an object. Let the player push it through a rib --
## the body will still route around the rib on its own probe. Only the shell is a
## hard boundary, because outside the shell there is nothing to crawl on.
const MASK_MARKER_PROBE: int = CORRIDOR
## Camera arms ignore props. A 0.25 m rib every 8 m would otherwise stutter the
## camera forward and back for the entire length of the corridor.
const MASK_CAMERA_ARM: int = CORRIDOR
