class_name RtsLayers
extends RefCounted

## Physics layer bits for the RTS prototype.
##
## The template README asks that named Project Settings layers be mirrored in a constants
## class so nothing hardcodes numbers. This example has to stay self-contained, so it cannot
## name layers in project.godot at all — which makes this file the only record of what each
## bit means. The .tscn files under this folder carry bare integers; cross-reference them
## here rather than inventing new ones.

const TERRAIN: int = 1 << 0
const OBSTACLE: int = 1 << 1
const UNIT_PLAYER: int = 1 << 2
const UNIT_ENEMY: int = 1 << 3
const BUILDING_PLAYER: int = 1 << 4
const BUILDING_ENEMY: int = 1 << 5
## Capture triggers sit on their own layer and are never raycast-pickable, so clicking a
## unit standing on a point still selects the unit.
const CAPTURE_ZONE: int = 1 << 6

const MASK_GROUND: int = TERRAIN
## What a left-click may select. Buildings are included so the HQ can be clicked to set a
## rally point.
const MASK_SELECTABLE: int = UNIT_PLAYER | BUILDING_PLAYER
## What a right-click treats as "attack this" rather than "walk here".
const MASK_HOSTILE_TO_PLAYER: int = UNIT_ENEMY | BUILDING_ENEMY
const MASK_ANY_UNIT: int = UNIT_PLAYER | UNIT_ENEMY
const MASK_UNIT_BLOCKERS: int = OBSTACLE | UNIT_PLAYER | UNIT_ENEMY
