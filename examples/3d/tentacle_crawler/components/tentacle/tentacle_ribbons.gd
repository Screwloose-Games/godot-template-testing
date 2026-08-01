class_name TentacleRibbons
extends MeshInstance3D

## Draws the tentacles. Reads state, writes geometry, and does nothing else.
##
## It applies NO FORCE and NAMES NO NODE outside its own exports -- `[input]` in the
## static suite greps this file for `apply_`, `Input.` and `intersect_ray` and fails
## if any appear. TentacleArray decides where the strands are; this decides what that
## looks like.
##
## Built as world-space ribbons of ImmediateMesh triangle strips, ported from
## examples/3d/cargo_tether/components/tether/tether_line.gd, INCLUDING the reason it
## is not PRIMITIVE_LINE_STRIP: line width is not portable and is ignored outright on
## most GL Compatibility targets, which would leave every tentacle a sub-pixel
## hairline at range -- and the tentacles are the entire point of this example.
##
## THE CURVE IS A CUBIC BEZIER WITH SPRING-LAGGED CONTROL POINTS, not a verlet chain.
## A verlet chain needs per-segment collision or it sinks through walls, and it is
## dt-coupled, which would make the one non-deterministic part of an otherwise
## reproducible example. But a plain Bezier has no inertia, and inertia is exactly
## what makes a tendril feel boneless -- so the two control points are themselves
## second-order springs chasing their ideal positions. When the body lurches, the
## midsection stays behind about 150 ms and then whips. That lag IS the symbiote read.

## Samples along each strand. 12 gives 26 vertices per tentacle -- 156 for the whole
## creature, which is a rounding error of geometry.
const SEGMENTS: int = 12
## Where along the chord the two control points nominally sit.
const CONTROL_NEAR: float = 0.30
const CONTROL_FAR: float = 0.70
## How much of the solved sag each control point takes.
const SAG_NEAR: float = 0.34
const SAG_FAR: float = 0.22
## Metres the anchor pad floats off the wall, to keep it out of a z-fight.
const PAD_LIFT: float = 0.02

@export_group("Wiring")
@export var tentacles: TentacleArray

@export_group("Curve")
## How hard the control points chase their targets, 1/s^2.
@export var ctrl_stiffness: float = 55.0
## And how hard they are damped, 1/s. Lower makes the strands whip more.
@export var ctrl_damping: float = 9.0
## How fast the coil axis rotates about the strand, rad/s. This is what makes a
## strand WRITHE rather than merely bow.
@export var writhe_rate: float = 1.3
## Sideways wobble as a fraction of strand length.
@export var noise_amplitude: float = 0.18

@export_group("Look")
@export var root_color: Color = Color(0.05, 0.045, 0.06)
@export var tip_color: Color = Color(0.16, 0.09, 0.14)
## Flashed along a strand as it hauls, root to tip.
@export var stroke_color: Color = Color(0.55, 0.16, 0.22)
## One surface for all six strands, stitched with degenerate triangles: 1 draw call
## instead of 6. Turn it off to bisect a geometry bug -- an unstitched build is the
## known-good shape, and a mis-stitch produces one enormous triangle across the level.
@export var single_surface: bool = true

var _mesh: ImmediateMesh
var _material: StandardMaterial3D
var _p1: PackedVector3Array = PackedVector3Array()
var _p2: PackedVector3Array = PackedVector3Array()
var _v1: PackedVector3Array = PackedVector3Array()
var _v2: PackedVector3Array = PackedVector3Array()
var _seeded: bool = false
var _time: float = 0.0
var _last_vertex: Vector3 = Vector3.ZERO
var _last_color: Color = Color.BLACK

@onready var _pads: MultiMeshInstance3D = %AnchorPads as MultiMeshInstance3D


func _ready() -> void:
	_mesh = ImmediateMesh.new()
	mesh = _mesh
	_material = StandardMaterial3D.new()
	# Unshaded because a ribbon is a flat strip with no real volume, so any lighting
	# on it reads as the strand flickering as it twists. Cull-disabled because the
	# strip is rebuilt facing the camera every frame and its winding flips whenever a
	# strand crosses its own axis.
	_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_material.cull_mode = BaseMaterial3D.CULL_DISABLED
	_material.vertex_color_use_as_albedo = true
	_material.disable_receive_shadows = true
	material_override = _material
	cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	# The ribbon is rebuilt in WORLD space every frame, so this node must not add a
	# transform of its own on top of it.
	top_level = true
	transform = Transform3D.IDENTITY

	var count: int = TentacleTuning.TENTACLE_COUNT
	_p1.resize(count)
	_p2.resize(count)
	_v1.resize(count)
	_v2.resize(count)
	_setup_pads(count)


## Control points are integrated on the PHYSICS tick, with the state they lag behind.
## The geometry is rebuilt in _process, at render rate, because it needs the camera.
func _physics_process(delta: float) -> void:
	if tentacles == null or delta <= 0.0:
		return
	_time += delta
	for i: int in tentacles.count():
		var root: Vector3 = tentacles.shoulder(i)
		var tip: Vector3 = tentacles.tip(i)
		var near_target: Vector3 = _control_target(i, root, tip, CONTROL_NEAR, SAG_NEAR)
		var far_target: Vector3 = _control_target(i, root, tip, CONTROL_FAR, SAG_FAR)
		if not _seeded:
			_p1[i] = near_target
			_p2[i] = far_target
			continue
		_v1[i] += (near_target - _p1[i]) * ctrl_stiffness * delta - _v1[i] * ctrl_damping * delta
		_v2[i] += (far_target - _p2[i]) * ctrl_stiffness * delta - _v2[i] * ctrl_damping * delta
		_p1[i] += _v1[i] * delta
		_p2[i] += _v2[i] * delta
	_seeded = true


func _process(_delta: float) -> void:
	_mesh.clear_surfaces()
	if tentacles == null or not tentacles.enabled:
		visible = false
		return
	visible = true

	var eye: Vector3 = _eye_position(tentacles.shoulder(0))
	if single_surface:
		_mesh.surface_begin(Mesh.PRIMITIVE_TRIANGLE_STRIP)
	for i: int in tentacles.count():
		if not single_surface:
			_mesh.surface_begin(Mesh.PRIMITIVE_TRIANGLE_STRIP)
		_emit_strand(i, eye, single_surface and i > 0)
		if not single_surface:
			_mesh.surface_end()
	if single_surface:
		_mesh.surface_end()

	_update_pads()


## One strand's 26 vertices.
##
## When `stitch` is set, the previous strand's last vertex and this strand's first
## are each emitted twice. Those four vertices form triangles of zero area, which the
## rasteriser discards -- so six separate ribbons live in one surface and cost one
## draw call. Each strand contributes an even vertex count, so the strip's parity
## survives the joins, and the material is cull-disabled anyway.
func _emit_strand(index: int, eye: Vector3, stitch: bool) -> void:
	var root: Vector3 = tentacles.shoulder(index)
	var tip: Vector3 = tentacles.tip(index)
	var extend: float = tentacles.extend_fraction(index)
	var envelope: float = tentacles.envelope(index)
	var color_at_root: Color = _strand_color(0.0, envelope)

	var first: Vector3 = _sample_point(index, root, tip, 0.0)
	var first_side: Vector3 = _side_at(index, root, tip, 0.0, first, eye, extend)
	if stitch:
		# REPEAT THE PREVIOUS STRAND'S LAST VERTEX, THEN THIS STRAND'S FIRST.
		#
		# Emitting this strand's first vertex twice instead -- which is the obvious
		# reading of "insert two degenerates" and what this did originally -- leaves
		# the triangle (prev_last_but_one, prev_last, this_first) with real area, so
		# a thin black sliver stretches from the end of one tentacle to the root of
		# the next. It is subtle enough to look like a rendering glitch rather than
		# a bug in this function, which is exactly why `single_surface` exists as a
		# switch: unstitched is the known-good shape to bisect against.
		#
		# Two vertices inserted keeps the strip's parity, so the next strand winds
		# the same way as the first.
		_mesh.surface_set_color(_last_color)
		_mesh.surface_add_vertex(_last_vertex)
		_mesh.surface_set_color(color_at_root)
		_mesh.surface_add_vertex(first - first_side)

	for step: int in SEGMENTS + 1:
		var t: float = float(step) / float(SEGMENTS)
		var point: Vector3 = _sample_point(index, root, tip, t)
		var side: Vector3 = _side_at(index, root, tip, t, point, eye, extend)
		var color: Color = _strand_color(t, envelope)
		_mesh.surface_set_color(color)
		_mesh.surface_add_vertex(point - side)
		_mesh.surface_set_color(color)
		_mesh.surface_add_vertex(point + side)
		_last_vertex = point + side
		_last_color = color


func _sample_point(index: int, root: Vector3, tip: Vector3, t: float) -> Vector3:
	return _bezier(root, _p1[index], _p2[index], tip, t)


func _side_at(
	index: int, root: Vector3, tip: Vector3, t: float, point: Vector3, eye: Vector3, extend: float
) -> Vector3:
	var tangent: Vector3 = _bezier_tangent(root, _p1[index], _p2[index], tip, t)
	var view: Vector3 = point - eye
	var side: Vector3 = tangent.cross(view)
	if side.length_squared() < 0.000001:
		side = tangent.cross(Vector3.UP)
		if side.length_squared() < 0.000001:
			side = tangent.cross(Vector3.RIGHT)
	return side.normalized() * TentacleTuning.taper_half_width(t, extend)


## Where a control point wants to be: along the chord, pushed off it by the solved
## slack, and wobbled.
##
## THE BOW IS THE SLACK MADE VISIBLE, exactly as cargo_tether's TetherLine solves its
## sagitta rather than picking one. A strand at full stretch goes dead straight and a
## short one coils hard, so the curve is a free readout of "this one is hauling" that
## costs nothing because it is just the geometry being honest.
func _control_target(index: int, root: Vector3, tip: Vector3, along: float, sag: float) -> Vector3:
	var chord: Vector3 = tip - root
	var length: float = chord.length()
	if length < 0.001:
		return root
	var direction: Vector3 = chord / length
	var right: Vector3 = direction.cross(Vector3.UP)
	if right.length_squared() < 0.0001:
		right = direction.cross(Vector3.RIGHT)
	right = right.normalized()
	var up: Vector3 = direction.cross(right).normalized()

	var phase: float = TentacleTuning.phase_for(index)
	# The coil axis ROTATES about the chord, which is what makes the strand writhe
	# rather than simply bow to one fixed side forever.
	var angle: float = phase + writhe_rate * _time
	var coil: Vector3 = right * cos(angle) + up * sin(angle)
	var bow: float = sag * length * TentacleTuning.slack_fraction(length)

	# Two incommensurate sines rather than a noise resource: deterministic, free, and
	# for a wobble on a strand exactly as convincing.
	var amp: float = noise_amplitude * length
	var wobble: Vector3 = (
		right * sin(2.7 * _time + phase) * amp + up * sin(4.1 * _time + 1.7 * phase) * amp
	)
	return root + chord * along + coil * bow + wobble


## Near-black at the root, faintly sickly at the tip, with a pulse of effort running
## root-to-tip while the strand hauls. The per-vertex colours are already being
## written, so the pulse is free and it is a large readability win: it is the only
## thing that tells the player WHICH strand is doing the work.
func _strand_color(t: float, envelope: float) -> Color:
	var base: Color = root_color.lerp(tip_color, t)
	if envelope <= 0.0:
		return base
	var pulse: float = clampf(1.0 - absf(t - envelope) * 3.0, 0.0, 1.0)
	return base.lerp(stroke_color, envelope * pulse)


## Where to face the ribbons from. Falls back to a point off the strand's own axis
## when there is no camera, so a HEADLESS verifier still gets valid geometry rather
## than a degenerate side vector and a mesh of zero-width triangles.
func _eye_position(fallback_near: Vector3) -> Vector3:
	var camera: Camera3D = get_viewport().get_camera_3d()
	if camera != null:
		return camera.global_position
	return fallback_near + Vector3.UP * 10.0


func _setup_pads(count: int) -> void:
	var quad: QuadMesh = QuadMesh.new()
	quad.size = Vector2(0.5, 0.5)
	var multimesh: MultiMesh = MultiMesh.new()
	multimesh.transform_format = MultiMesh.TRANSFORM_3D
	multimesh.mesh = quad
	multimesh.instance_count = count
	multimesh.visible_instance_count = 0
	_pads.multimesh = multimesh
	_pads.top_level = true
	_pads.transform = Transform3D.IDENTITY


## The splat where a planted strand meets the wall. One draw call for all of them,
## and it is what tells the player a tentacle is STUCK to something rather than
## merely pointing at it -- without the pads the strands read as antennae.
func _update_pads() -> void:
	var multimesh: MultiMesh = _pads.multimesh
	var shown: int = 0
	for i: int in tentacles.count():
		if not tentacles.is_planted(i):
			continue
		var normal: Vector3 = tentacles.anchor_normal(i)
		if normal.length_squared() < 0.0001:
			continue
		var up: Vector3 = Vector3.UP if absf(normal.dot(Vector3.UP)) < 0.95 else Vector3.RIGHT
		# QuadMesh faces its own +Z, and Basis.looking_at points -Z along its
		# argument, so aim it at the negated normal to end up facing out of the wall.
		var basis: Basis = Basis.looking_at(-normal, up)
		multimesh.set_instance_transform(
			shown, Transform3D(basis, tentacles.anchor(i) + normal * PAD_LIFT)
		)
		shown += 1
	multimesh.visible_instance_count = shown


static func _bezier(a: Vector3, p1: Vector3, p2: Vector3, b: Vector3, t: float) -> Vector3:
	var inv: float = 1.0 - t
	return (
		a * (inv * inv * inv)
		+ p1 * (3.0 * inv * inv * t)
		+ p2 * (3.0 * inv * t * t)
		+ b * (t * t * t)
	)


static func _bezier_tangent(a: Vector3, p1: Vector3, p2: Vector3, b: Vector3, t: float) -> Vector3:
	var inv: float = 1.0 - t
	var derivative: Vector3 = (
		(p1 - a) * (3.0 * inv * inv) + (p2 - p1) * (6.0 * inv * t) + (b - p2) * (3.0 * t * t)
	)
	if derivative.length_squared() < 0.000001:
		return CrawlerMath.direction_or(b - a, Vector3.FORWARD)
	return derivative.normalized()
