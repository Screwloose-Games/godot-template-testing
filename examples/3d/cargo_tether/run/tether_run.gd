class_name TetherRun
extends Node

## The run: the clock, the win and lose conditions, the score, and the one
## dictionary the HUD reads.
##
## This is the example's local hub. It joins a group in _enter_tree() and is found
## through `TetherRun.find_in(node)` rather than through an autoload, because an
## example must not reach for the host project's GlobalSignalBus -- the same rule
## RtsWorld follows in the realtime_strategy_example. Statics survive
## reload_current_scene(), groups do not, which is why the lookup is a group and
## the registration is in _enter_tree() rather than _ready().

signal run_completed(result: Dictionary)
signal run_failed(reason: StringName)

enum State { RUNNING, COMPLETE, FAILED }

const GROUP_NAME: StringName = &"tether_run"
## Score weights. Integrity is worth more than speed on purpose: this is a
## delivery job, and a prototype that rewards recklessness would be testing a
## different question.
const INTEGRITY_WEIGHT: float = 30.0
const TIME_WEIGHT: float = 40.0
## Score thresholds for each grade, best first.
const GRADES: Array[Array] = [
	[3400.0, "S"],
	[2800.0, "A"],
	[2100.0, "B"],
	[1200.0, "C"],
]

@export_group("Wiring")
@export var ship: ShipController
@export var cargo: CargoBody
@export var tether: TetherLink
@export var dock: DeliveryDock
## Where turrets get their shots from. Wired here rather than into each turret,
## because a course carries a dozen of them and threading three NodePaths into
## every one by hand is how a generator script grows bugs.
@export var projectiles: ProjectilePool

@export_group("Rules")
## Seconds the run is expected to take. Beating it is what the time score pays
## for. The course generator prints this; a hand-authored scene guesses it.
@export var par_time: float = 90.0
## How far the cargo may drift, once detached, before it counts as abandoned.
@export var abandon_distance: float = 250.0
## And for how long. BOTH conditions, so a snap is a scare rather than a loss --
## you have eight seconds to go back for it.
@export var abandon_grace: float = 8.0

var _state: State = State.RUNNING
var _elapsed: float = 0.0
var _abandon_timer: float = 0.0
var _result: Dictionary = {}

@onready var _ship_damage: TetherDamage = _damage_of(ship)
@onready var _cargo_damage: TetherDamage = _damage_of(cargo)


## The run in `node`'s scene, or null. Groups rather than an autoload: an example
## keeps its wiring inside its own folder.
static func find_in(node: Node) -> TetherRun:
	return node.get_tree().get_first_node_in_group(GROUP_NAME) as TetherRun


func _enter_tree() -> void:
	# _enter_tree, not _ready: a HUD asking for the run in its own _ready() must
	# find it whichever order the two happen to be built in.
	add_to_group(GROUP_NAME)


func _ready() -> void:
	if dock != null:
		dock.ship_arrived.connect(_on_ship_arrived)
	if _cargo_damage != null:
		_cargo_damage.destroyed.connect(_on_cargo_destroyed)
	if _ship_damage != null:
		_ship_damage.destroyed.connect(_on_ship_destroyed)


func _process(delta: float) -> void:
	if Input.is_action_just_pressed(&"ship_restart"):
		restart()
		return
	if _state != State.RUNNING:
		return
	_elapsed += delta
	_tick_abandon(delta)


## Puts everything back to the start of a run without reloading the scene.
##
## A soft reset rather than reload_current_scene() because it is the same path a
## tool or a verifier needs -- and a restart nobody can invoke from code is a
## restart nothing ever tests. It also avoids the reload hitch between attempts,
## which matters when the loop is "try that corner again".
func restart() -> void:
	_state = State.RUNNING
	_elapsed = 0.0
	_abandon_timer = 0.0
	_result = {}
	if ship != null:
		ship.respawn()
	if cargo != null:
		cargo.respawn()
	if _ship_damage != null:
		_ship_damage.restore()
	if _cargo_damage != null:
		_cargo_damage.restore()
	# After the bodies are back, or the tether re-attaches around the old pose.
	if tether != null:
		tether.reset()
	if dock != null:
		dock.rearm()
	if projectiles != null:
		projectiles.clear_all()


func state() -> State:
	return _state


## Everything the HUD draws. One call, so no UI file has to know how a grade is
## computed or where integrity lives.
func debug_state() -> Dictionary:
	var tether_state: Dictionary = {} if tether == null else tether.debug_state()
	return {
		"state": _state,
		"elapsed": _elapsed,
		"par_time": par_time,
		"cargo_integrity": 1.0 if _cargo_damage == null else _cargo_damage.fraction(),
		"ship_integrity": 1.0 if _ship_damage == null else _ship_damage.fraction(),
		"distance_to_dock": _distance_to_dock(),
		"speed": 0.0 if ship == null else ship.linear_velocity.length(),
		"boosting": false if ship == null else ship.is_boosting(),
		"dampener": false if ship == null else ship.dampener_on,
		"abandon_left": maxf(abandon_grace - _abandon_timer, 0.0),
		"tether": tether_state,
		"result": _result,
	}


## Score and grade for a finished run. Public so a verifier can check the table
## without having to complete one.
func score_for(integrity: float, elapsed: float) -> Dictionary:
	var integrity_points: float = integrity * 100.0 * INTEGRITY_WEIGHT
	var time_points: float = maxf(par_time - elapsed, 0.0) * TIME_WEIGHT
	var total: float = integrity_points + time_points
	var grade: String = "F"
	for row: Array in GRADES:
		if total >= (row[0] as float):
			grade = row[1] as String
			break
	return {
		"integrity": integrity,
		"elapsed": elapsed,
		"integrity_points": integrity_points,
		"time_points": time_points,
		"score": total,
		"grade": grade,
	}


func _distance_to_dock() -> float:
	if ship == null or dock == null:
		return 0.0
	return ship.global_position.distance_to(dock.global_position)


## Losing the cargo is only a loss if you leave it. Detached AND far AND for a
## while -- any one of those alone would turn a recoverable mistake into a
## restart, which is the difference between a setback and a rage quit.
func _tick_abandon(delta: float) -> void:
	if tether == null or cargo == null or ship == null:
		return
	var gone: bool = (
		not tether.is_attached()
		and ship.global_position.distance_to(cargo.global_position) > abandon_distance
	)
	if not gone:
		_abandon_timer = 0.0
		return
	_abandon_timer += delta
	if _abandon_timer >= abandon_grace:
		_fail(&"cargo_abandoned")


func _on_ship_arrived() -> void:
	if _state != State.RUNNING:
		return
	# Arriving without the crate is NOT a failure. It is a completion worth zero
	# integrity, which grades F and still pays the time bonus -- a more
	# interesting outcome than a failure screen, and it keeps a bad run playable
	# to the end instead of ending it early.
	var delivered: bool = _cargo_delivered()
	var integrity: float = 0.0
	if delivered and _cargo_damage != null:
		integrity = _cargo_damage.fraction()
	_state = State.COMPLETE
	_result = score_for(integrity, _elapsed)
	_result["cargo_delivered"] = delivered
	run_completed.emit(_result)


## Did you bring it?
##
## Still on the tether counts, which is the normal case and the whole point -- a
## crate towed correctly is 14 to 30 m astern when the ship crosses the line, so
## asking whether it is inside the dock volume at that instant marks every clean
## delivery as a failure. (It did, for exactly one test run: 100% integrity,
## grade F.) A released crate coasting through the hole counts too, because
## throwing it ahead of you is a legitimate way to take the last gate.
func _cargo_delivered() -> bool:
	if tether != null and tether.is_attached():
		return true
	if dock != null and dock.cargo_inside():
		return true
	if dock == null or cargo == null:
		return false
	return cargo.global_position.distance_to(dock.global_position) <= abandon_distance


func _on_cargo_destroyed() -> void:
	_fail(&"cargo_destroyed")


func _on_ship_destroyed() -> void:
	_fail(&"ship_destroyed")


func _fail(reason: StringName) -> void:
	if _state != State.RUNNING:
		return
	_state = State.FAILED
	_result = {"reason": reason, "elapsed": _elapsed, "score": 0.0, "grade": "F"}
	run_failed.emit(reason)


func _damage_of(body: Node) -> TetherDamage:
	if body == null:
		return null
	return body.get_node_or_null("%Damage") as TetherDamage
