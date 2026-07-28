class_name AiCommander
extends Node

## The enemy general.
##
## Two independent layers, re-evaluated on a slow tick: what to build, and where to send what
## it has. That split is why a competent-looking opponent fits in a couple of hundred lines —
## all the local fighting is already handled by each unit's own target acquisition, so the
## commander only ever has to set destinations.
##
## It reads the player's army composition directly rather than through any kind of fog of
## war. For a prototype that is the honest trade: the point is to find out whether the counter
## triangle creates interesting decisions, which needs an opponent that actually responds to
## what you build.

const TEAM: int = RtsTeam.Id.ENEMY
## The AI never spends its last coins if it already has a real army — a small float lets it
## react to a push instead of being permanently broke.
const RESERVE_GOLD: int = 40
const RESERVE_ARMY_SIZE: int = 12

## How often the commander thinks. Slow on purpose — reacting instantly to every unit that
## dies reads as twitchy, and re-deciding at 60fps makes squads oscillate between lanes.
@export var decision_interval: float = 1.8
## Chance the AI simply does not buy on a tick it could have. Without this it converts gold
## into units at 100% efficiency forever, which no human matches while also fighting a battle —
## and losing to an opponent because it clicks more, not because it thinks better, is the least
## interesting way to lose. Raise toward 0 for a harder game, toward 0.6 for an easier one.
@export_range(0.0, 1.0) var purchase_skip_chance: float = 0.35
## 1.0 picks the best counter every time, which reads as cheating rather than as competent.
## Lower values blend the choice back toward a plain weighted roll.
@export_range(0.0, 1.0) var counter_accuracy: float = 0.75
## Points owned and army size needed before it commits everything to killing the player HQ.
@export var push_point_threshold: int = 3
@export var push_army_threshold: int = 10
## An objective sticks for at least this long. Without it the commander re-decides every tick
## and its army spends the match walking back and forth between two points.
@export var assignment_hold_seconds: float = 3.0

var _world: RtsWorld
var _tick_timer: float = 0.0
var _assignments: Dictionary = {}
var _pushing: bool = false


func _ready() -> void:
	_world = RtsWorld.find_in(self)
	_tick_timer = decision_interval * 0.5


func _process(delta: float) -> void:
	if _world == null or not _world.is_running:
		return
	_tick_timer -= delta
	if _tick_timer > 0.0:
		return
	_tick_timer = decision_interval
	_decide_production()
	_decide_movement()


func _decide_production() -> void:
	var hq: Node3D = _world.hq_of(TEAM)
	if hq == null or not hq.is_alive():
		return
	if randf() < purchase_skip_chance:
		return
	var economy: RtsEconomy = _world.economy_of(TEAM)
	if economy == null:
		return
	var army_size: int = _world.population_of(TEAM)
	if army_size >= RESERVE_ARMY_SIZE and economy.gold() < RESERVE_GOLD:
		return
	var choice: UnitStats = _pick_unit_to_build()
	if choice == null:
		return
	# Deliberately does NOT fall back to a cheaper unit it can afford. Saving up for the right
	# answer is the single biggest reason this reads as an opponent with a plan rather than as
	# a bot spending gold the instant it has any.
	hq.request_unit(choice)


## Scores each buildable type against what the player currently fields: reward types that
## counter their army, punish types their army counters, and lightly punish doubling down on
## what we already have so the AI never ends up mono-army.
func _pick_unit_to_build() -> UnitStats:
	var enemy_composition: Dictionary = _world.composition_of(RtsTeam.Id.PLAYER)
	var own_composition: Dictionary = _world.composition_of(TEAM)
	var enemy_total: int = _total_of(enemy_composition)
	var own_total: int = _total_of(own_composition)

	var best: UnitStats = null
	var best_score: float = -INF
	for stats: UnitStats in _world.unit_roster:
		var score: float = 1.0
		if enemy_total > 0:
			score += 2.0 * counter_accuracy * _counter_fraction(stats.kind, enemy_composition, true)
			score -= (
				1.5 * counter_accuracy * _counter_fraction(stats.kind, enemy_composition, false)
			)
		if own_total > 0:
			score -= 0.6 * float(own_composition.get(stats.kind, 0)) / float(own_total)
		# A little noise keeps successive matches from playing out identically.
		score += randf() * 0.25
		if score > best_score:
			best_score = score
			best = stats
	return best


## Fraction of `composition` that `kind` beats (when `attacking` is true) or is beaten by.
func _counter_fraction(kind: int, composition: Dictionary, attacking: bool) -> float:
	var total: int = _total_of(composition)
	if total == 0:
		return 0.0
	var matched: int = 0
	for other_kind: int in composition:
		var multiplier: float = (
			RtsConfig.counter_multiplier(kind, other_kind)
			if attacking
			else RtsConfig.counter_multiplier(other_kind, kind)
		)
		if multiplier > 1.0:
			matched += composition[other_kind]
	return float(matched) / float(total)


func _total_of(composition: Dictionary) -> int:
	var total: int = 0
	for kind: int in composition:
		total += composition[kind]
	return total


func _decide_movement() -> void:
	var army: Array = _world.units_of(TEAM)
	if army.is_empty():
		return
	_pushing = _should_push(army.size())
	if _pushing:
		_send_all_at_player_hq(army)
		return
	var objectives: Array[Vector3] = _world.ranked_objectives_for(TEAM)
	if objectives.is_empty():
		return
	var index: int = 0
	for unit: Node3D in army:
		if not _needs_new_orders(unit):
			continue
		_assign(unit, objectives[index % objectives.size()])
		index += 1


## Under a ticket race, holding points *is* winning — so abandoning them to siege a base is
## something the AI should only do when the slow route is losing. That inverts the old logic
## on purpose: the AI now comes for your headquarters precisely when you are ahead on the
## scoreboard, which turns a comfortable lead into a decision instead of a victory lap.
func _should_push(army_size: int) -> bool:
	var behind: bool = _world.tickets.get(TEAM, 0.0) < _world.tickets.get(RtsTeam.Id.PLAYER, 0.0)
	if _pushing:
		return behind and army_size >= push_army_threshold / 2
	return behind and army_size >= push_army_threshold


func _send_all_at_player_hq(army: Array) -> void:
	var hq: Node3D = _world.hq_of(RtsTeam.Id.PLAYER)
	if hq == null or not hq.is_alive():
		return
	for unit: Node3D in army:
		if _needs_new_orders(unit):
			_assign(unit, hq.global_position)


## Units keep their objective until it has had time to matter, or until they are standing on
## it with nothing left to do.
func _needs_new_orders(unit: Node3D) -> bool:
	var record: Dictionary = _assignments.get(unit.get_instance_id(), {})
	if record.is_empty():
		return true
	var age: float = (Time.get_ticks_msec() - record.assigned_msec) / 1000.0
	if age < assignment_hold_seconds:
		return false
	return unit.global_position.distance_to(record.destination) < RtsConfig.CAPTURE_RADIUS


func _assign(unit: Node3D, destination: Vector3) -> void:
	var jitter: Vector3 = Vector3(randf_range(-4.0, 4.0), 0.0, randf_range(-4.0, 4.0))
	var target: Vector3 = destination + jitter
	# The commander only ever sets objectives, so its orders are always attack-moves — it has
	# no notion of retreating, and units that walked past defenders would never take anything.
	unit.move_to(target, true)
	_assignments[unit.get_instance_id()] = {
		"destination": target,
		"assigned_msec": Time.get_ticks_msec(),
	}
