class_name UnitVisuals
extends Node3D

## Everything a unit looks like: body mesh, team tint, selection ring, health bar, and the
## small tweens that sell a hit or a death.
##
## Split out of rts_unit.gd for two reasons. gdlint caps a class at 20 public methods and the
## unit was going to crowd it, but more importantly presentation and simulation change for
## completely different reasons — a balance pass touches the unit, an art pass touches this.

const BAR_WIDTH: float = 1.3
const FLASH_SECONDS: float = 0.09

var _body_material: StandardMaterial3D
var _base_color: Color = Color.WHITE
var _bar_forced_visible: bool = false
var _health_fraction: float = 1.0
var _flash_tween: Tween

@onready var body: MeshInstance3D = %Body
@onready var selection_ring: MeshInstance3D = %SelectionRing
@onready var health_bar: Node3D = %HealthBar
@onready var health_bar_fill: MeshInstance3D = %HealthBarFill


## Builds the look for one unit type. Called once, from RtsUnit.setup(), before the unit
## enters the tree.
func apply(stats: UnitStats, team: int) -> void:
	_base_color = RtsTeam.color_of(team)
	body.mesh = _build_body_mesh(stats)
	_body_material = StandardMaterial3D.new()
	_body_material.albedo_color = _base_color
	_body_material.roughness = 0.85
	_body_material.metallic_specular = 0.1
	body.material_override = _body_material
	body.position.y = stats.body_height * 0.5

	var ring: TorusMesh = TorusMesh.new()
	ring.inner_radius = stats.body_radius * 1.15
	ring.outer_radius = stats.body_radius * 1.45
	ring.rings = 3
	ring.ring_segments = 16
	selection_ring.mesh = ring
	selection_ring.material_override = _unlit_material(_base_color.lightened(0.35))
	selection_ring.visible = false

	health_bar.position.y = stats.body_height + 0.55
	set_health_fraction(1.0)


func set_selected(selected: bool) -> void:
	selection_ring.visible = selected
	_bar_forced_visible = selected
	_refresh_bar_visibility()
	if selected:
		_pop_selection_ring()


func set_health_fraction(fraction: float) -> void:
	_health_fraction = clampf(fraction, 0.0, 1.0)
	# The quad is centred on its origin, so shrinking it also has to shift it left by half
	# the amount lost, otherwise the bar drains from both ends.
	health_bar_fill.scale.x = maxf(_health_fraction, 0.001)
	health_bar_fill.position.x = -(1.0 - _health_fraction) * BAR_WIDTH * 0.5
	_refresh_bar_visibility()


## Bars are hidden at full health unless the unit is selected. That is half readability —
## forty permanent bars is visual noise — and half draw calls.
func _refresh_bar_visibility() -> void:
	health_bar.visible = _bar_forced_visible or _health_fraction < 0.999


func flash_damage() -> void:
	if _body_material == null:
		return
	if _flash_tween != null and _flash_tween.is_valid():
		_flash_tween.kill()
	_body_material.albedo_color = _base_color.lerp(Color.WHITE, 0.85)
	_flash_tween = create_tween()
	_flash_tween.tween_property(_body_material, "albedo_color", _base_color, FLASH_SECONDS)


func play_spawn() -> void:
	body.scale = Vector3.ZERO
	var tween: Tween = create_tween()
	tween.set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	tween.tween_property(body, "scale", Vector3.ONE, 0.22)


## Squashes the body into the ground and fades it out. Returns the tween so the unit can wait
## for it before freeing itself.
func play_death() -> Tween:
	selection_ring.visible = false
	health_bar.visible = false
	if _body_material != null:
		_body_material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	var tween: Tween = create_tween()
	tween.set_parallel(true)
	tween.tween_property(body, "scale", Vector3(1.25, 0.05, 1.25), RtsConfig.DEATH_FADE_SECONDS)
	tween.tween_property(body, "position:y", 0.05, RtsConfig.DEATH_FADE_SECONDS)
	if _body_material != null:
		var faded: Color = Color(_base_color.r, _base_color.g, _base_color.b, 0.0)
		tween.tween_property(_body_material, "albedo_color", faded, RtsConfig.DEATH_FADE_SECONDS)
	return tween


func _build_body_mesh(stats: UnitStats) -> Mesh:
	match stats.body_shape:
		UnitStats.BodyShape.BOX:
			var box: BoxMesh = BoxMesh.new()
			box.size = Vector3(stats.body_radius * 2.0, stats.body_height, stats.body_radius * 2.0)
			return box
		UnitStats.BodyShape.CYLINDER:
			var cylinder: CylinderMesh = CylinderMesh.new()
			cylinder.top_radius = stats.body_radius
			cylinder.bottom_radius = stats.body_radius
			cylinder.height = stats.body_height
			cylinder.radial_segments = 10
			return cylinder
		_:
			var capsule: CapsuleMesh = CapsuleMesh.new()
			capsule.radius = stats.body_radius
			# CapsuleMesh asserts height >= 2 * radius; a squat stat block would trip it.
			capsule.height = maxf(stats.body_height, stats.body_radius * 2.0 + 0.01)
			capsule.radial_segments = 10
			capsule.rings = 4
			return capsule


func _unlit_material(color: Color) -> StandardMaterial3D:
	var material: StandardMaterial3D = StandardMaterial3D.new()
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.albedo_color = color
	material.cull_mode = BaseMaterial3D.CULL_DISABLED
	return material


func _pop_selection_ring() -> void:
	selection_ring.scale = Vector3(0.55, 1.0, 0.55)
	var tween: Tween = create_tween()
	tween.set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	tween.tween_property(selection_ring, "scale", Vector3.ONE, 0.15)
