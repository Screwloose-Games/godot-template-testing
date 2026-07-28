class_name CapturePoint
extends Area3D

## A contested income node.
##
## Progress runs from -1 (fully enemy) through 0 to +1 (fully player), and ownership is read
## off that with a dead band in the middle. The dead band is what makes a point worth
## defending rather than worth trading: an owner does not lose the income the instant one
## enemy scout steps inside, but a real push turns the income off well before it flips.
##
## Contested — equal numbers from both sides standing on it — freezes progress entirely and
## pulses the pad white. Doing nothing is the correct outcome there, but it has to *look*
## like a stand-off rather than a bug.

## How far from 0 progress has to be for anyone to collect the income.
const OWN_THRESHOLD: float = 0.6
const NEUTRAL_COLOR: Color = Color(0.3, 0.3, 0.29)

@export var income_value: float = RtsConfig.FLANK_POINT_INCOME
@export var point_label: String = "A"

var owner_team: int = RtsTeam.Id.NEUTRAL
var progress: float = 0.0

var _world: RtsWorld
var _contested: bool = false
var _pulse: float = 0.0
var _pad_material: StandardMaterial3D
var _banner_material: StandardMaterial3D

@onready var collision: CollisionShape3D = %Collision
@onready var pad: MeshInstance3D = %Pad
@onready var banner: MeshInstance3D = %Banner


func _ready() -> void:
	_world = RtsWorld.find_in(self)
	collision_layer = RtsLayers.CAPTURE_ZONE
	# Detects units, but sits on a layer nothing raycasts, so clicking a unit standing on the
	# pad still selects the unit rather than the point.
	collision_mask = RtsLayers.MASK_ANY_UNIT
	monitorable = false
	var shape: CylinderShape3D = CylinderShape3D.new()
	shape.radius = RtsConfig.CAPTURE_RADIUS
	shape.height = 6.0
	collision.shape = shape
	collision.position.y = 3.0
	_build_materials()
	_refresh_visuals()
	if _world != null:
		_world.register_capture_point(self)


func _process(delta: float) -> void:
	if _world == null or not _world.is_running:
		return
	_advance_capture(delta)
	_pulse = fmod(_pulse + delta * 4.0, TAU)
	_refresh_visuals()


func team_progress() -> float:
	return progress


func is_contested() -> bool:
	return _contested


## Counts bodies inside, nets them off, and moves progress toward whoever is winning. The
## contributor cap is what stops "send literally everything" from being the only capture
## tactic worth knowing.
func _advance_capture(delta: float) -> void:
	var player_count: int = 0
	var enemy_count: int = 0
	for node: Node3D in get_overlapping_bodies():
		if not node.has_method("is_alive") or not node.is_alive():
			continue
		if node.team == RtsTeam.Id.PLAYER:
			player_count += 1
		elif node.team == RtsTeam.Id.ENEMY:
			enemy_count += 1

	_contested = player_count > 0 and player_count == enemy_count
	var net: int = clampi(
		player_count - enemy_count,
		-RtsConfig.CAPTURE_MAX_CONTRIBUTORS,
		RtsConfig.CAPTURE_MAX_CONTRIBUTORS
	)
	if net == 0:
		return
	var previous_owner: int = owner_team
	progress = clampf(progress + float(net) * delta / RtsConfig.CAPTURE_SECONDS, -1.0, 1.0)
	owner_team = _owner_for_progress()
	if owner_team != previous_owner and _world != null:
		_world.report_point_changed(self)


func _owner_for_progress() -> int:
	if progress >= OWN_THRESHOLD:
		return RtsTeam.Id.PLAYER
	if progress <= -OWN_THRESHOLD:
		return RtsTeam.Id.ENEMY
	return RtsTeam.Id.NEUTRAL


func _build_materials() -> void:
	_pad_material = StandardMaterial3D.new()
	_pad_material.roughness = 1.0
	_pad_material.metallic_specular = 0.0
	pad.material_override = _pad_material

	_banner_material = StandardMaterial3D.new()
	_banner_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_banner_material.cull_mode = BaseMaterial3D.CULL_DISABLED
	banner.material_override = _banner_material


## The pad's colour is the scoreboard. Lerping it continuously with progress — rather than
## snapping on ownership — means the map itself shows who is winning a fight you are not
## looking at, which is the cheapest readability win in the whole prototype.
func _refresh_visuals() -> void:
	var side: int = RtsTeam.Id.PLAYER if progress >= 0.0 else RtsTeam.Id.ENEMY
	var tint: Color = NEUTRAL_COLOR.lerp(RtsTeam.color_of(side), absf(progress))
	if _contested:
		tint = tint.lerp(Color.WHITE, 0.35 + 0.25 * sin(_pulse))
	_pad_material.albedo_color = tint.darkened(0.25)
	_banner_material.albedo_color = tint
	banner.scale.y = 0.35 + absf(progress) * 0.65
