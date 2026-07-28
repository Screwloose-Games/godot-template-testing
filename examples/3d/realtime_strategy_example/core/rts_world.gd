class_name RtsWorld
extends Node

## Match-wide state and the event hub for the skirmish.
##
## The template's GlobalSignalBus lives in globals/ and this example has to stay inside its
## own folder, so this node plays that role locally. It is a plain scene node in the
## "rts_world" group rather than a static singleton on purpose: statics survive
## reload_current_scene(), so restarting would hand every freshly spawned unit a reference to
## the previous match's freed state.
##
## It also owns the unit registry. Units ask it for targets instead of calling
## get_nodes_in_group() themselves — that call allocates an Array per invocation, which is
## the actual O(n^2) trap in an RTS, not the distance maths.

signal unit_spawned(unit: Node3D)
signal unit_died(unit: Node3D)
signal population_changed(team: int, population: int)
signal point_owner_changed(point: Node3D)
signal hq_damaged(team: int, health_fraction: float)
signal match_ended(winning_team: int, reason: String)

const GROUP_NAME: StringName = &"rts_world"
const UNIT_SCENE_PATH: String = "res://examples/3d/realtime_strategy_example/units/rts_unit.tscn"
## Buildable types in hotkey order. The player HUD, the hotkeys and the enemy AI all read the
## roster from here, so there is exactly one answer to "what can be built".
const UNIT_STATS_PATHS: PackedStringArray = [
	"res://examples/3d/realtime_strategy_example/data/unit_grunt.tres",
	"res://examples/3d/realtime_strategy_example/data/unit_archer.tres",
	"res://examples/3d/realtime_strategy_example/data/unit_tank.tres",
]

var unit_roster: Array[UnitStats] = []
var capture_points: Array[Node3D] = []
var elapsed_seconds: float = 0.0
var is_running: bool = true
## Remaining tickets per team. Public because the HUD paints it every frame and the AI reads
## it to decide whether it needs a fast win.
var tickets: Dictionary = {}

var _units: Dictionary = {}
var _hqs: Dictionary = {}
var _economies: Dictionary = {}
## load(), not a const preload(): rts_unit.tscn carries a script that names this class, and a
## preload chain resolved at parse time turns that into a cyclic reference. Same reasoning as
## globals/scene_manager.gd.
var _unit_scene: PackedScene

@onready var _unit_container: Node3D = %Units


## Every other script resolves the world this way in _ready(). Kept here so the group name
## is written down exactly once.
static func find_in(node: Node) -> RtsWorld:
	return node.get_tree().get_first_node_in_group(GROUP_NAME) as RtsWorld


## Joining the group in _enter_tree(), not _ready(): every HQ and capture point resolves the
## world in its own _ready(), and _enter_tree fires top-down as the scene is built, so the
## group is populated before anything can look for it.
func _enter_tree() -> void:
	add_to_group(GROUP_NAME)


func _ready() -> void:
	_unit_scene = load(UNIT_SCENE_PATH)
	for path: String in UNIT_STATS_PATHS:
		unit_roster.append(load(path))
	for team: int in [RtsTeam.Id.PLAYER, RtsTeam.Id.ENEMY]:
		_units[team] = []
		_economies[team] = RtsEconomy.new(team)
		tickets[team] = RtsConfig.STARTING_TICKETS


## Instantiates a unit, wires it up and drops it on the ground at `at_position`. setup() has
## to happen before add_child(), because _ready() sizes the collision shape and agent from
## the stat block.
func spawn_unit(stats: UnitStats, team: int, at_position: Vector3) -> Node3D:
	var unit: Node3D = _unit_scene.instantiate()
	unit.setup(self, stats, team)
	_unit_container.add_child(unit)
	unit.global_position = Vector3(at_position.x, 0.0, at_position.z)
	return unit


func _process(delta: float) -> void:
	if not is_running:
		return
	elapsed_seconds += delta
	for team: int in _economies:
		(_economies[team] as RtsEconomy).tick(delta)
	_drain_tickets(delta)
	if is_running and elapsed_seconds >= RtsConfig.MATCH_TIME_LIMIT:
		_end_on_time_limit()


func register_unit(unit: Node3D) -> void:
	var team: int = unit.team
	if not _units.has(team):
		_units[team] = []
	_units[team].append(unit)
	unit_spawned.emit(unit)
	population_changed.emit(team, _units[team].size())


func unregister_unit(unit: Node3D) -> void:
	var team: int = unit.team
	if not _units.has(team):
		return
	_units[team].erase(unit)
	# Losing bodies costs tickets too, so a won position can still be thrown away by trading
	# badly into it.
	tickets[team] = maxf(0.0, tickets.get(team, 0.0) - RtsConfig.TICKET_COST_PER_UNIT)
	unit_died.emit(unit)
	population_changed.emit(team, _units[team].size())


func register_hq(hq: Node3D) -> void:
	_hqs[hq.team] = hq


func register_capture_point(point: Node3D) -> void:
	capture_points.append(point)


func units_of(team: int) -> Array:
	return _units.get(team, [])


func enemies_of(team: int) -> Array:
	return units_of(RtsTeam.opponent_of(team))


func population_of(team: int) -> int:
	return units_of(team).size()


## How fast `team` is losing tickets right now, in tickets per second. Zero when the point
## count is level — a stalemate drains nobody, which is what makes breaking a tie urgent.
func ticket_drain_for(team: int) -> float:
	var deficit: int = _points_held_by(RtsTeam.opponent_of(team)) - _points_held_by(team)
	return maxf(0.0, float(deficit)) * RtsConfig.TICKET_DRAIN_PER_POINT


func economy_of(team: int) -> RtsEconomy:
	return _economies.get(team)


func hq_of(team: int) -> Node3D:
	return _hqs.get(team)


## Counts of each UnitStats.Kind a team currently fields. The AI reads this to decide what to
## counter, and the HUD reads it for the selection summary.
func composition_of(team: int) -> Dictionary:
	var counts: Dictionary = {}
	for unit: Node3D in units_of(team):
		if not is_instance_valid(unit):
			continue
		var kind: int = unit.stats.kind
		counts[kind] = counts.get(kind, 0) + 1
	return counts


## Closest hostile unit or enemy HQ within `max_distance`, or null. The HQ is considered last
## and only wins on distance, so units prefer chewing through defenders over walking past
## them into the guns.
func nearest_hostile(team: int, from_position: Vector3, max_distance: float) -> Node3D:
	var best: Node3D = null
	var best_distance: float = max_distance * max_distance
	for unit: Node3D in enemies_of(team):
		if not is_instance_valid(unit) or not unit.is_alive():
			continue
		var distance: float = from_position.distance_squared_to(unit.global_position)
		if distance < best_distance:
			best_distance = distance
			best = unit
	var enemy_hq: Node3D = hq_of(RtsTeam.opponent_of(team))
	if enemy_hq != null and is_instance_valid(enemy_hq) and enemy_hq.is_alive():
		var hq_distance: float = from_position.distance_squared_to(enemy_hq.global_position)
		if hq_distance < best_distance:
			best = enemy_hq
	return best


## Called by capture points whenever ownership changes. Recomputing the whole table is
## cheaper and far less bug-prone than incrementally adjusting one team's income.
func recalculate_income() -> void:
	var totals: Dictionary = {
		RtsTeam.Id.PLAYER: RtsConfig.HQ_TRICKLE_INCOME,
		RtsTeam.Id.ENEMY: RtsConfig.HQ_TRICKLE_INCOME,
	}
	for point: Node3D in capture_points:
		if not is_instance_valid(point):
			continue
		if totals.has(point.owner_team):
			totals[point.owner_team] += point.income_value
	# Catch-up: the side holding fewer points earns a little extra per point of deficit.
	# Without it, losing the opening means never being able to afford the army you would need
	# to take anything back, and the rest of the match is a formality.
	for team: int in totals:
		var deficit: int = _points_held_by(RtsTeam.opponent_of(team)) - _points_held_by(team)
		if deficit > 0:
			totals[team] += float(deficit) * RtsConfig.CATCHUP_INCOME_PER_POINT
	for team: int in totals:
		var economy: RtsEconomy = economy_of(team)
		if economy != null:
			economy.set_income(totals[team])


## Capture points ranked by how much this team should want to be standing on them. Shared by
## the enemy commander and by HQ auto-rally so a freshly built unit walks somewhere useful by
## default instead of idling next to the base.
func ranked_objectives_for(team: int) -> Array[Vector3]:
	var scored: Array = []
	for point: Node3D in capture_points:
		if not is_instance_valid(point):
			continue
		var weight: float = point.income_value
		if point.owner_team == team:
			weight *= 0.3
		elif point.owner_team == RtsTeam.Id.NEUTRAL:
			weight *= 1.5
		else:
			weight *= 2.0
		scored.append({"position": point.global_position, "weight": weight})
	scored.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return a.weight > b.weight)
	var result: Array[Vector3] = []
	for entry: Dictionary in scored:
		result.append(entry.position)
	return result


func report_point_changed(point: Node3D) -> void:
	point_owner_changed.emit(point)
	recalculate_income()


func report_hq_damage(team: int, health_fraction: float) -> void:
	hq_damaged.emit(team, health_fraction)


func end_match(winning_team: int, reason: String = "") -> void:
	if not is_running:
		return
	is_running = false
	match_ended.emit(winning_team, reason)


func _points_held_by(team: int) -> int:
	var held: int = 0
	for point: Node3D in capture_points:
		if is_instance_valid(point) and point.owner_team == team:
			held += 1
	return held


func _drain_tickets(delta: float) -> void:
	for team: int in tickets:
		tickets[team] = maxf(0.0, tickets[team] - ticket_drain_for(team) * delta)
	for team: int in tickets:
		if tickets[team] <= 0.0:
			end_match(RtsTeam.opponent_of(team), "Reinforcements exhausted")
			return


## Time-limit tiebreak: whoever has more tickets left. An exact tie goes to NEUTRAL so the
## result screen can honestly say it was a draw.
func _end_on_time_limit() -> void:
	var player_tickets: float = tickets.get(RtsTeam.Id.PLAYER, 0.0)
	var enemy_tickets: float = tickets.get(RtsTeam.Id.ENEMY, 0.0)
	if is_equal_approx(player_tickets, enemy_tickets):
		end_match(RtsTeam.Id.NEUTRAL, "Time limit — dead level")
	elif player_tickets > enemy_tickets:
		end_match(RtsTeam.Id.PLAYER, "Time limit — ahead on reinforcements")
	else:
		end_match(RtsTeam.Id.ENEMY, "Time limit — ahead on reinforcements")
