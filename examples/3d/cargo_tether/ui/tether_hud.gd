class_name TetherHud
extends CanvasLayer

## The readout, and the off-screen cargo marker.
##
## Reads exactly one thing -- TetherRun.debug_state() -- so it names no damage
## node, computes no grade, and the tension it prints is the same number the
## solver used.
##
## THE OFF-SCREEN MARKER IS NOT DECORATION. A cargo trailing straight astern sits
## behind the camera: the arm is 9-22 m and the tether is 6-30 m. Pulling back far
## enough to frame a 30 m tether would render the ship a dot, so the honest fix is
## not more camera, it is telling the player where the crate is when the camera
## cannot. Without this, long-tether play is illegible.

## Text refreshes per second. Not per frame: formatting a dozen floats into
## strings sixty times a second is a real cost in a web build. The marker still
## moves every frame, because a hint that lags is worse than none.
const REFRESH_HZ: float = 20.0
const BAR_WIDTH: int = 12
## How far inside the viewport edge the marker sits, in pixels.
const MARKER_INSET: float = 48.0

@export var run: TetherRun
@export var cargo: Node3D
@export var panel_visible: bool = true

var _time_since_refresh: float = 0.0

@onready var _panel: Control = %Panel as Control
@onready var _readout: Label = %Readout as Label
@onready var _banner: Label = %Banner as Label
@onready var _marker: Label = %Marker as Label


func _ready() -> void:
	if run == null:
		run = TetherRun.find_in(self)
	_panel.visible = panel_visible
	_banner.text = ""
	_refresh()


func _process(delta: float) -> void:
	if Input.is_action_just_pressed(&"ship_hud"):
		_panel.visible = not _panel.visible
	_update_marker()
	_time_since_refresh += delta
	if _time_since_refresh < 1.0 / REFRESH_HZ:
		return
	_time_since_refresh = 0.0
	if _panel.visible:
		_refresh()


func _refresh() -> void:
	if run == null:
		_readout.text = "no run assigned"
		return
	var state: Dictionary = run.debug_state()
	var tether: Dictionary = state["tether"]
	var attached: bool = bool(tether.get("attached", false))
	var lines: PackedStringArray = PackedStringArray()
	lines.append(
		(
			"CARGO   %s %3.0f%%"
			% [_bar(state["cargo_integrity"]), (state["cargo_integrity"] as float) * 100.0]
		)
	)
	lines.append(
		(
			"HULL    %s %3.0f%%"
			% [_bar(state["ship_integrity"]), (state["ship_integrity"] as float) * 100.0]
		)
	)
	if attached:
		(
			lines
			. append(
				(
					"TETHER  %s  %4.1f m   %5.1f kN"
					% [
						_bar(tether["strain"]),
						tether["rest_length"],
						(tether["tension"] as float) / 1000.0,
					]
				)
			)
		)
	else:
		lines.append("TETHER  -- DETACHED --   G to grab within 8 m")
	(
		lines
		. append(
			(
				"SPEED   %5.1f m/s%s   DAMPENER %s"
				% [
					state["speed"],
					"  BOOST" if state["boosting"] else "",
					"ON" if state["dampener"] else "off",
				]
			)
		)
	)
	lines.append(
		(
			"DOCK    %6.0f m      TIME %5.1f / %.0f s"
			% [state["distance_to_dock"], state["elapsed"], state["par_time"]]
		)
	)
	var abandon_left: float = state["abandon_left"]
	if not attached and abandon_left < run.abandon_grace:
		lines.append("CARGO ABANDONED IN %.1f s" % abandon_left)
	_readout.text = "\n".join(lines)
	_update_banner(state)


func _update_banner(state: Dictionary) -> void:
	var result: Dictionary = state["result"]
	if (state["state"] as int) == TetherRun.State.COMPLETE:
		_banner.text = (
			"DELIVERED\n%s   score %.0f   %.1f s   integrity %.0f%%\nBackspace to run again"
			% [
				result.get("grade", "F"),
				result.get("score", 0.0),
				result.get("elapsed", 0.0),
				(result.get("integrity", 0.0) as float) * 100.0,
			]
		)
	elif (state["state"] as int) == TetherRun.State.FAILED:
		_banner.text = (
			"RUN FAILED\n%s\nBackspace to try again"
			% String(result.get("reason", &"")).replace("_", " ").to_upper()
		)
	else:
		_banner.text = ""


## Points at the cargo when it is not on screen. Colour carries its integrity, so
## a crate you cannot see still tells you it is being shot at.
func _update_marker() -> void:
	var camera: Camera3D = get_viewport().get_camera_3d()
	if cargo == null or camera == null or run == null:
		_marker.visible = false
		return
	var size: Vector2 = get_viewport().get_visible_rect().size
	var behind: bool = camera.is_position_behind(cargo.global_position)
	var point: Vector2 = camera.unproject_position(cargo.global_position)
	var inset := Rect2(
		Vector2(MARKER_INSET, MARKER_INSET), size - Vector2(MARKER_INSET, MARKER_INSET) * 2.0
	)
	if not behind and inset.has_point(point):
		_marker.visible = false
		return

	# unproject_position mirrors the point when the target is behind the camera,
	# so it has to be flipped about the centre before it means anything.
	var centre: Vector2 = size * 0.5
	var offset: Vector2 = point - centre
	if behind:
		offset = -offset
	if offset.length() < 0.001:
		offset = Vector2.DOWN
	# Push the direction out to the edge of the inset rectangle.
	var half: Vector2 = inset.size * 0.5
	var scale: float = minf(
		half.x / maxf(absf(offset.x), 0.001), half.y / maxf(absf(offset.y), 0.001)
	)
	_marker.visible = true
	_marker.position = centre + offset * scale - _marker.size * 0.5
	var state: Dictionary = run.debug_state()
	var integrity: float = state["cargo_integrity"]
	_marker.modulate = Color(1.0, 0.35 + integrity * 0.5, 0.15 + integrity * 0.3)


func _bar(fraction: float) -> String:
	var filled: int = int(round(clampf(fraction, 0.0, 1.0) * BAR_WIDTH))
	return "[%s%s]" % ["#".repeat(filled), ".".repeat(BAR_WIDTH - filled)]
