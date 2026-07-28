class_name RtsHud
extends CanvasLayer

## The match HUD: gold and income, capture-point pips, production buttons, a selection
## summary, a controls cheat sheet, and the end-of-match panel.
##
## Sits at layer 5 so the shared pause menu (layer 20) still covers it.
##
## Readouts are polled in _process rather than driven by signals. At one HUD and a handful of
## labels the polling is free, and it cannot go stale the way a missed signal connection can.

const PIP_SIZE: Vector2 = Vector2(58, 36)
## White with a dark outline rather than a flat colour: the pip behind it slides between
## neutral grey, blue and red, and no single text colour reads on all three.
const PIP_TEXT_COLOR: Color = Color(1.0, 1.0, 1.0)
const PIP_OUTLINE_COLOR: Color = Color(0.05, 0.05, 0.07, 0.85)
const TICKET_TRACK_COLOR: Color = Color(0.11, 0.11, 0.13)
const RESULT_COLORS: Dictionary = {
	RtsTeam.Id.PLAYER: Color(0.16, 0.6, 0.25),
	RtsTeam.Id.ENEMY: Color(0.7, 0.16, 0.14),
	RtsTeam.Id.NEUTRAL: Color(0.35, 0.35, 0.38),
}

var _world: RtsWorld
var _commander: PlayerCommander
var _camera: RtsCamera
var _pips: Array[ColorRect] = []
var _buttons: Array[Button] = []
var _blocking_panels: Array[Control] = []
var _ticket_fills: Dictionary = {}
var _ticket_labels: Dictionary = {}

@onready var gold_label: Label = %GoldLabel
@onready var income_label: Label = %IncomeLabel
@onready var army_label: Label = %ArmyLabel
@onready var timer_label: Label = %TimerLabel
@onready var pip_row: HBoxContainer = %PipRow
@onready var production_row: HBoxContainer = %ProductionRow
@onready var selection_label: Label = %SelectionLabel
@onready var hint_panel: PanelContainer = %HintPanel
@onready var resource_panel: PanelContainer = %ResourcePanel
@onready var production_panel: PanelContainer = %ProductionPanel
@onready var selection_panel: PanelContainer = %SelectionPanel
@onready var result_panel: PanelContainer = %ResultPanel
@onready var result_title: Label = %ResultTitle
@onready var result_detail: Label = %ResultDetail
@onready var menu_button: Button = %MenuButton


func _ready() -> void:
	result_panel.visible = false
	_blocking_panels = [resource_panel, production_panel, selection_panel, hint_panel]
	menu_button.pressed.connect(_on_menu_pressed)


func _process(_delta: float) -> void:
	if _world == null:
		return
	_refresh_resources()
	_refresh_tickets()
	_refresh_pips()
	_refresh_production()
	_block_edge_scroll_over_ui()


## Called by the match root once every node exists. The HUD cannot resolve these itself:
## it is an instanced sub-scene, so scene-unique names in the root are not visible to it.
func bind(world: RtsWorld, commander: PlayerCommander, camera: RtsCamera) -> void:
	_world = world
	_commander = commander
	_camera = camera
	_build_ticket_bars()
	_build_pips()
	_build_production_buttons()
	commander.selection_changed.connect(_on_selection_changed)
	commander.hint_toggle_requested.connect(_on_hint_toggled)
	_on_selection_changed([])


func show_result(winning_team: int, reason: String, elapsed_seconds: float) -> void:
	result_panel.visible = true
	match winning_team:
		RtsTeam.Id.PLAYER:
			result_title.text = "VICTORY"
		RtsTeam.Id.ENEMY:
			result_title.text = "DEFEAT"
		_:
			result_title.text = "DRAW"
	result_title.add_theme_color_override("font_color", RESULT_COLORS[winning_team])
	result_detail.text = (
		"%s\nMatch time %s\n\nPress R to play again" % [reason, _format_time(elapsed_seconds)]
	)


## Two bars above the timer: yours and theirs, side by side, with the live drain rate next to
## each. The whole point of switching to a ticket race was to make the score legible at a
## glance, so this is the one readout that has to be impossible to miss.
func _build_ticket_bars() -> void:
	var column: VBoxContainer = pip_row.get_parent()
	var panel: PanelContainer = PanelContainer.new()
	panel.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	var margin: MarginContainer = MarginContainer.new()
	for side: String in ["left", "top", "right", "bottom"]:
		margin.add_theme_constant_override("margin_" + side, 8)
	var rows: VBoxContainer = VBoxContainer.new()
	rows.add_theme_constant_override("separation", 4)
	for team: int in [RtsTeam.Id.PLAYER, RtsTeam.Id.ENEMY]:
		rows.add_child(_build_ticket_row(team))
	margin.add_child(rows)
	panel.add_child(margin)
	column.add_child(panel)
	column.move_child(panel, 0)
	_blocking_panels.append(panel)


func _build_ticket_row(team: int) -> HBoxContainer:
	var row: HBoxContainer = HBoxContainer.new()
	row.add_theme_constant_override("separation", 8)

	var name_label: Label = Label.new()
	name_label.text = "YOU" if team == RtsTeam.Id.PLAYER else "FOE"
	name_label.custom_minimum_size = Vector2(42, 0)
	name_label.add_theme_font_size_override("font_size", 15)
	name_label.add_theme_color_override("font_color", RtsTeam.color_of(team).lightened(0.25))
	row.add_child(name_label)

	var track: ColorRect = ColorRect.new()
	track.custom_minimum_size = Vector2(190, 16)
	track.color = TICKET_TRACK_COLOR
	var fill: ColorRect = ColorRect.new()
	fill.color = RtsTeam.color_of(team)
	fill.set_anchors_preset(Control.PRESET_LEFT_WIDE)
	fill.anchor_right = 1.0
	fill.offset_right = 0.0
	track.add_child(fill)
	row.add_child(track)
	_ticket_fills[team] = fill

	var value_label: Label = Label.new()
	value_label.custom_minimum_size = Vector2(96, 0)
	value_label.add_theme_font_size_override("font_size", 15)
	row.add_child(value_label)
	_ticket_labels[team] = value_label
	return row


func _refresh_tickets() -> void:
	for team: int in [RtsTeam.Id.PLAYER, RtsTeam.Id.ENEMY]:
		var remaining: float = _world.tickets.get(team, 0.0)
		var ratio: float = clampf(remaining / RtsConfig.STARTING_TICKETS, 0.0, 1.0)
		(_ticket_fills[team] as ColorRect).anchor_right = ratio
		var drain: float = _world.ticket_drain_for(team)
		var suffix: String = "  ▼%.0f/s" % drain if drain > 0.0 else ""
		(_ticket_labels[team] as Label).text = "%d%s" % [int(remaining), suffix]


func _build_pips() -> void:
	for point: Node3D in _world.capture_points:
		var pip: ColorRect = ColorRect.new()
		pip.custom_minimum_size = PIP_SIZE
		var label: Label = Label.new()
		label.text = point.point_label
		label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		label.set_anchors_preset(Control.PRESET_FULL_RECT)
		label.add_theme_color_override("font_color", PIP_TEXT_COLOR)
		label.add_theme_color_override("font_outline_color", PIP_OUTLINE_COLOR)
		label.add_theme_constant_override("outline_size", 5)
		pip.add_child(label)
		pip_row.add_child(pip)
		_pips.append(pip)


func _build_production_buttons() -> void:
	for index: int in _world.unit_roster.size():
		var stats: UnitStats = _world.unit_roster[index]
		var button: Button = Button.new()
		button.custom_minimum_size = Vector2(132, 0)
		button.text = "[%s] %s\n%d gold" % [stats.hotkey_label, stats.display_name, stats.gold_cost]
		button.tooltip_text = (
			"%s\n%d HP  %.0f DPS\nRange %.0fm  Speed %.1f\nBuild %.0fs"
			% [
				stats.display_name,
				int(stats.max_health),
				stats.damage_per_second(),
				stats.attack_range,
				stats.move_speed,
				stats.build_seconds,
			]
		)
		button.pressed.connect(_commander.request_production.bind(index))
		production_row.add_child(button)
		_buttons.append(button)


func _refresh_resources() -> void:
	var economy: RtsEconomy = _world.economy_of(RtsTeam.Id.PLAYER)
	if economy == null:
		return
	gold_label.text = "Gold  %d" % economy.gold()
	income_label.text = "Income  +%.0f / s" % economy.income_per_second()
	army_label.text = (
		"Army  %d / %d" % [_world.population_of(RtsTeam.Id.PLAYER), RtsConfig.POPULATION_CAP]
	)
	timer_label.text = _format_time(_world.elapsed_seconds)


## The pip colour is the same lerp the pad on the ground uses, so a glance at the top of the
## screen and a glance at the map tell the same story.
func _refresh_pips() -> void:
	for index: int in mini(_pips.size(), _world.capture_points.size()):
		var point: Node3D = _world.capture_points[index]
		var side: int = RtsTeam.Id.PLAYER if point.progress >= 0.0 else RtsTeam.Id.ENEMY
		var tint: Color = CapturePoint.NEUTRAL_COLOR.lerp(
			RtsTeam.color_of(side), absf(point.progress)
		)
		if point.is_contested():
			tint = tint.lerp(Color.WHITE, 0.4)
		_pips[index].color = tint


func _refresh_production() -> void:
	var economy: RtsEconomy = _world.economy_of(RtsTeam.Id.PLAYER)
	var hq: Node3D = _world.hq_of(RtsTeam.Id.PLAYER)
	if economy == null:
		return
	var queued: int = hq.queued_stats().size() if hq != null else 0
	var population: int = _world.population_of(RtsTeam.Id.PLAYER)
	var capped: bool = population + queued >= RtsConfig.POPULATION_CAP
	for index: int in _buttons.size():
		var stats: UnitStats = _world.unit_roster[index]
		_buttons[index].disabled = capped or not economy.can_afford(stats.gold_cost)


## Edge scrolling has to stop while the cursor is over a panel, or reaching for a production
## button at the bottom of the screen sends the camera sliding off the map.
func _block_edge_scroll_over_ui() -> void:
	if _camera == null:
		return
	var mouse: Vector2 = get_viewport().get_mouse_position()
	var blocked: bool = false
	for panel: Control in _blocking_panels:
		if panel.visible and panel.get_global_rect().has_point(mouse):
			blocked = true
			break
	_camera.edge_scroll_blocked = blocked


func _on_selection_changed(units: Array) -> void:
	if units.is_empty():
		selection_label.text = "Nothing selected"
		return
	var counts: Dictionary = {}
	for node: Node3D in units:
		var key: String = node.stats.display_name if node.has_method("move_to") else "HQ"
		counts[key] = counts.get(key, 0) + 1
	var parts: PackedStringArray = PackedStringArray()
	for key: String in counts:
		parts.append("%d %s" % [counts[key], key])
	selection_label.text = "  ·  ".join(parts)


func _on_hint_toggled() -> void:
	hint_panel.visible = not hint_panel.visible


func _on_menu_pressed() -> void:
	get_tree().paused = false
	SceneTransitionManager.change_scene_with_transition(
		SceneManager.main_menu, SceneManager.fade_transition
	)


func _format_time(seconds: float) -> String:
	var total: int = int(seconds)
	return "%d:%02d" % [total / 60, total % 60]
