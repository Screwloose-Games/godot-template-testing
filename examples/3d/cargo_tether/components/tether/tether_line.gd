class_name TetherLine
extends MeshInstance3D

## Draws the tether, and in doing so draws its state.
##
## NO GRAVITY SAG. In zero g a cable does not droop, so a downward curve is a lie
## the player reads as a bug. What a trailing cable actually does is bow toward
## where the cargo has BEEN, so the curve's control point is pushed against the
## cargo's motion relative to the ship.
##
## The bow magnitude is solved from the slack (rest length minus separation)
## rather than picked, which makes the visual the readout: the line bows while
## there is rope to spare and goes dead straight the instant it comes taut. That
## straightening is the best "you are about to snap this" cue available, and it
## costs nothing because it is just the geometry being honest.
##
## Built as a world-space-width ribbon, NOT PRIMITIVE_LINE_STRIP. Line width is
## not portable and is ignored outright on most GL Compatibility targets, which
## would leave the tether a sub-pixel hairline at 200 m -- and the tether is this
## prototype's entire HUD.

## Samples along the curve. 10 segments is 22 vertices in one surface, which is a
## rounding error of CPU and a single draw call.
const SEGMENTS: int = 10
## How hard the cargo's relative motion pushes the bow, in metres of offset per
## metre per second. Purely cosmetic.
const BOW_GAIN: float = 0.05

@export var tether: TetherLink
## Half-thickness of the ribbon, in metres. Wide enough to survive a 720p web
## build at range, narrow enough not to read as a girder up close.
@export var half_width: float = 0.05
@export var slack_color: Color = Color(0.62, 0.64, 0.68)
@export var taut_color: Color = Color(0.98, 0.55, 0.16)
@export var snapping_color: Color = Color(1.0, 0.24, 0.18)
## Strain past which the line reads as about to go. Matches the HUD's warning.
@export var warn_strain: float = 0.62

var _mesh: ImmediateMesh
var _material: StandardMaterial3D


func _ready() -> void:
	_mesh = ImmediateMesh.new()
	mesh = _mesh
	_material = StandardMaterial3D.new()
	_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_material.cull_mode = BaseMaterial3D.CULL_DISABLED
	_material.vertex_color_use_as_albedo = true
	_material.disable_receive_shadows = true
	material_override = _material
	cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	# The ribbon is rebuilt in world space every frame, so the node must not add
	# a transform of its own on top of it.
	top_level = true
	transform = Transform3D.IDENTITY


func _process(_delta: float) -> void:
	_mesh.clear_surfaces()
	if tether == null or not tether.is_attached():
		visible = false
		return
	if tether.ship_anchor == null or tether.cargo_anchor == null:
		visible = false
		return
	visible = true

	var from: Vector3 = tether.ship_anchor.global_position
	var to: Vector3 = tether.cargo_anchor.global_position
	var control: Vector3 = _control_point(from, to)
	var color: Color = _strain_color(tether.strain())
	var eye: Vector3 = _eye_position(from)

	_mesh.surface_begin(Mesh.PRIMITIVE_TRIANGLE_STRIP)
	for i: int in SEGMENTS + 1:
		var t: float = float(i) / float(SEGMENTS)
		var point: Vector3 = _bezier(from, control, to, t)
		var tangent: Vector3 = _bezier_tangent(from, control, to, t)
		var side: Vector3 = _ribbon_side(tangent, point, eye)
		_mesh.surface_set_color(color)
		_mesh.surface_add_vertex(point - side)
		_mesh.surface_set_color(color)
		_mesh.surface_add_vertex(point + side)
	_mesh.surface_end()


## The quadratic Bezier control point: the chord's midpoint, pushed against the
## cargo's motion relative to the ship, by however much rope is spare.
func _control_point(from: Vector3, to: Vector3) -> Vector3:
	var midpoint: Vector3 = (from + to) * 0.5
	var chord: float = from.distance_to(to)
	var slack: float = maxf(tether.rest_length - chord, 0.0)
	if slack <= 0.0 or chord <= 0.001:
		return midpoint

	# Arc length of a shallow parabola is about L * (1 + 8/3 * (s/L)^2), so the
	# sagitta that eats `slack` metres of rope is sqrt(3 * L * slack / 8). A
	# quadratic Bezier sits at half its control offset when t = 0.5, hence the 2x.
	var sagitta: float = sqrt(3.0 * chord * slack / 8.0)
	var axis: Vector3 = (to - from) / chord
	var residual: Vector3 = Vector3.ZERO
	if tether.cargo != null and tether.ship != null:
		residual = tether.cargo.linear_velocity - tether.ship.linear_velocity
	# Only the component across the line can bow it; along it is just slack.
	var across: Vector3 = residual - axis * residual.dot(axis)
	var bow: Vector3 = -across * BOW_GAIN
	if bow.length() < 0.001:
		# Stationary relative to the ship: hang the bow off any consistent
		# perpendicular rather than snapping the curve flat.
		bow = axis.cross(Vector3.UP)
		if bow.length_squared() < 0.001:
			bow = axis.cross(Vector3.RIGHT)
	return midpoint + bow.normalized() * sagitta * 2.0


func _strain_color(strain: float) -> Color:
	if strain <= 0.0:
		return slack_color
	var body: Color = slack_color.lerp(taut_color, clampf(strain / warn_strain, 0.0, 1.0))
	if strain <= warn_strain:
		return body
	var over: float = (strain - warn_strain) / maxf(1.0 - warn_strain, 0.001)
	return body.lerp(snapping_color, clampf(over, 0.0, 1.0))


## Where to face the ribbon from. Falls back to a point off the line's own axis
## when there is no camera, so a headless verifier still gets a valid mesh.
func _eye_position(fallback_near: Vector3) -> Vector3:
	var camera: Camera3D = get_viewport().get_camera_3d()
	if camera != null:
		return camera.global_position
	return fallback_near + Vector3.UP * 10.0


func _ribbon_side(tangent: Vector3, point: Vector3, eye: Vector3) -> Vector3:
	var view: Vector3 = point - eye
	var side: Vector3 = tangent.cross(view)
	if side.length_squared() < 0.000001:
		side = tangent.cross(Vector3.UP)
		if side.length_squared() < 0.000001:
			side = tangent.cross(Vector3.RIGHT)
	return side.normalized() * half_width


static func _bezier(a: Vector3, control: Vector3, b: Vector3, t: float) -> Vector3:
	var inv: float = 1.0 - t
	return a * (inv * inv) + control * (2.0 * inv * t) + b * (t * t)


static func _bezier_tangent(a: Vector3, control: Vector3, b: Vector3, t: float) -> Vector3:
	var derivative: Vector3 = (control - a) * (2.0 * (1.0 - t)) + (b - control) * (2.0 * t)
	if derivative.length_squared() < 0.000001:
		return (b - a).normalized()
	return derivative.normalized()
