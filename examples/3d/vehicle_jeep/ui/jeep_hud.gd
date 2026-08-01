class_name JeepHud
extends CanvasLayer

## Debug readout for the jeep, and the crosshair the turret aims at.
##
## Its whole job is to make the terrain legible: which wheels are touching what,
## how much grip that surface left, and how close each tyre is to breaking away.
## Without it, "mud is slippery" is something you take on faith.
##
## It reads exactly one thing -- JeepController.debug_state() -- so it names no
## wheel node and no model node, and the grip figure it prints is the same table
## the solver used. See "Component boundaries" in CLAUDE.md.

## Refreshes per second. Not per frame: this is a debug readout, and formatting a
## dozen floats into strings 60 times a second is a real cost in a web build.
const REFRESH_HZ: float = 20.0
## Longest bar drawn for the skid readout.
const SKID_BAR_WIDTH: int = 10

@export var vehicle: JeepController
## Starts hidden when embedding this in a capture or tool scene.
@export var panel_visible: bool = true

var _time_since_refresh: float = 0.0

@onready var _panel: Control = %Panel as Control
@onready var _summary: Label = %Summary as Label
@onready var _wheels: Label = %Wheels as Label


func _ready() -> void:
	_panel.visible = panel_visible
	_refresh()


func _process(delta: float) -> void:
	if Input.is_action_just_pressed(&"jeep_hud"):
		_panel.visible = not _panel.visible
	_time_since_refresh += delta
	if _time_since_refresh < 1.0 / REFRESH_HZ:
		return
	_time_since_refresh = 0.0
	if _panel.visible:
		_refresh()


func _refresh() -> void:
	if vehicle == null:
		_summary.text = "no vehicle assigned"
		_wheels.text = ""
		return

	var state: Dictionary = vehicle.debug_state()
	var drive: String = "coast"
	if state["handbrake"]:
		drive = "HANDBRAKE"
	elif state["brake"] > 0.0:
		drive = "brake"
	elif state["throttle"] > 0.0:
		drive = "throttle"
	elif state["throttle"] < 0.0:
		drive = "reverse"

	_summary.text = (
		"%5.1f km/h   %-9s steer %+5.1f deg   airborne %d/4   %d fps"
		% [
			state["speed_kmh"],
			drive,
			state["steering_deg"],
			state["airborne_wheels"],
			Engine.get_frames_per_second(),
		]
	)

	var lines: PackedStringArray = PackedStringArray()
	for wheel: Dictionary in state["wheels"]:
		(
			lines
			. append(
				(
					"%-2s %s %-7s grip %.2f  slip %5.2f  rpm %6.0f  susp %+.3f  %s"
					% [
						wheel["label"],
						"contact" if wheel["contact"] else "  AIR  ",
						wheel["surface"],
						wheel["grip"],
						wheel["friction_slip"],
						wheel["rpm"],
						wheel["suspension"],
						_skid_bar(wheel["skid"]),
					]
				)
			)
		)
	_wheels.text = "\n".join(lines)


## get_skidinfo() is 1.0 at full grip and 0.0 at full skid, so the bar fills as the
## tyre lets go -- the thing worth watching, rather than the thing that is normal.
func _skid_bar(skid: float) -> String:
	var slipping: int = int(round(clampf(1.0 - skid, 0.0, 1.0) * SKID_BAR_WIDTH))
	return "[%s%s]" % ["#".repeat(slipping), ".".repeat(SKID_BAR_WIDTH - slipping)]
