class_name RtsEconomy
extends RefCounted

## One team's gold and income.
##
## Gold accumulates as a float so a +3/s trickle actually ticks at 60fps instead of being
## rounded away every frame; only the display and the affordability checks round it down.

signal gold_changed(gold: int)
signal income_changed(income_per_second: float)

var team: int = RtsTeam.Id.NEUTRAL

var _gold: float = 0.0
var _income_per_second: float = 0.0
var _last_reported_gold: int = -1


func _init(owning_team: int, starting_gold: int = RtsConfig.STARTING_GOLD) -> void:
	team = owning_team
	_gold = float(starting_gold)
	_income_per_second = RtsConfig.HQ_TRICKLE_INCOME
	_last_reported_gold = starting_gold


func gold() -> int:
	return int(_gold)


func income_per_second() -> float:
	return _income_per_second


func set_income(value: float) -> void:
	if is_equal_approx(value, _income_per_second):
		return
	_income_per_second = value
	income_changed.emit(_income_per_second)


func can_afford(cost: int) -> bool:
	return int(_gold) >= cost


## Returns false and changes nothing when the team cannot pay, so callers can use it directly
## as the guard on a purchase.
func try_spend(cost: int) -> bool:
	if not can_afford(cost):
		return false
	_gold -= float(cost)
	_emit_if_gold_display_changed()
	return true


func refund(amount: int) -> void:
	_gold += float(amount)
	_emit_if_gold_display_changed()


func tick(delta: float) -> void:
	_gold += _income_per_second * delta
	_emit_if_gold_display_changed()


## The signal fires on whole-gold changes only. Emitting every frame would repaint the HUD
## 60 times a second to show the same number.
func _emit_if_gold_display_changed() -> void:
	var whole: int = int(_gold)
	if whole == _last_reported_gold:
		return
	_last_reported_gold = whole
	gold_changed.emit(whole)
