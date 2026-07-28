class_name UnitStats
extends Resource

## Everything that makes one unit type different from another.
##
## All three types share a single scene and script; only this resource changes. Balancing is
## therefore three .tres files you can edit with the game running, and every tuning change is
## a one-line diff. The alternative — three inherited scenes — means three places to keep in
## sync and no single file the AI can read a cost out of before it decides what to buy.

enum Kind {
	GRUNT,
	ARCHER,
	TANK,
}

enum BodyShape {
	CAPSULE,
	BOX,
	CYLINDER,
}

@export var kind: Kind = Kind.GRUNT
@export var display_name: String = "Grunt"
## Shown on the production button. Number keys are control groups and WASD is the camera, so
## production sits on the Z/X/C row — left-hand reachable and free of both.
@export var hotkey_label: String = "Z"
@export var gold_cost: int = 50
@export var build_seconds: float = 3.0
@export var max_health: float = 120.0
@export var damage_per_hit: float = 14.4
@export var attack_interval: float = 0.8
@export var attack_range: float = 2.0
@export var move_speed: float = 6.0
@export var body_radius: float = 0.5
@export var body_height: float = 1.6
@export var body_shape: BodyShape = BodyShape.CAPSULE


## Sustained output. The HUD tooltip and the AI's composition scoring both want this rather
## than the per-hit number, and deriving it keeps the two from drifting apart.
func damage_per_second() -> float:
	if attack_interval <= 0.0:
		return 0.0
	return damage_per_hit / attack_interval


## Where a health bar or selection ring should sit relative to the unit origin.
func chest_height() -> float:
	return body_height * 0.5
