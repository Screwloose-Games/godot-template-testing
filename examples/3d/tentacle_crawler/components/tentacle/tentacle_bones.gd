class_name TentacleBones
extends Node3D

## Poses the model's tentacle chains. Reads state, writes transforms, and does nothing
## else.
##
## It applies NO FORCE and NAMES NO NODE outside its own exports -- `[input]` in the
## static suite greps this file for `apply_`, `Input.` and `intersect_ray` and fails if
## any appear. TentacleArray decides where a strand is; this decides what that looks
## like. Same contract the ribbon renderer had, on the same side of the same line.
##
## THE CURVE IS A CUBIC BEZIER WITH SPRING-LAGGED CONTROL POINTS, not a verlet chain,
## and it is inherited from that renderer unchanged. A verlet chain needs per-segment
## collision or it sinks through walls, and it is dt-coupled, which would make the one
## non-deterministic part of an otherwise reproducible example. But a plain Bezier has
## no inertia, and inertia is exactly what makes a tendril feel boneless -- so the two
## control points are themselves second-order springs chasing their ideal positions.
## When the body lurches, the midsection stays behind about 150 ms and then whips.
##
## That lag is also why the bones follow this curve instead of an IK solve aimed at the
## anchor. A chain that tracks its target exactly looks mechanical no matter how
## correct its joint angles are; the whole read comes from the limb ARRIVING LATE.

## Samples used to measure a strand's arc length and to invert it.
const ARC_SAMPLES: int = 24
## Where along the chord the two control points nominally sit.
const CONTROL_NEAR: float = 0.30
const CONTROL_FAR: float = 0.70
## How much of the solved sag each control point takes.
const SAG_NEAR: float = 0.34
const SAG_FAR: float = 0.22
## How much the first control point is allowed to ignore the socket's own axis.
##
## A limb has an emergence direction baked into the mesh; an abstract marker does not.
## With the raw control point the curve's tangent at the root points straight down the
## chord, so the first bone kinks up to a right angle at the shoulder and its voxels
## tear out through the torso -- which looks exactly like the model being parented to
## the wrong node, and that is what you will go and check first. At 0.0 every limb
## leaves dead straight along its socket and reads as welded on.
const ROOT_FREEDOM: float = 0.45
## Radians each surplus bone bends past the end of the curve, about the running frame's
## own binormal, so the leftover SPIRALS rather than sticking out straight.
const COIL_TURN: float = 0.42
## Metres the anchor pad floats off the wall, to keep it out of a z-fight.
const PAD_LIFT: float = 0.02

@export_group("Wiring")
@export var tentacles: TentacleArray
@export var rig: CrawlerRig

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

var _p1: PackedVector3Array = PackedVector3Array()
var _p2: PackedVector3Array = PackedVector3Array()
var _v1: PackedVector3Array = PackedVector3Array()
var _v2: PackedVector3Array = PackedVector3Array()
var _tips: PackedVector3Array = PackedVector3Array()
var _arc: PackedFloat32Array = PackedFloat32Array()
var _arc_cursor: int = 0
var _seeded: bool = false
var _time: float = 0.0

@onready var _pads: MultiMeshInstance3D = %AnchorPads as MultiMeshInstance3D


func _ready() -> void:
	var count: int = TentacleTuning.TENTACLE_COUNT
	_p1.resize(count)
	_p2.resize(count)
	_v1.resize(count)
	_v2.resize(count)
	_tips.resize(count)
	_arc.resize(ARC_SAMPLES + 1)
	_setup_pads(count)


## Control points are integrated first, then the chains are posed from them, both on
## the PHYSICS tick. The ribbon rebuilt its geometry in `_process` because a camera-
## facing strip needs the camera; bone transforms do not, so this all belongs on the
## same clock as the solver that feeds it.
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

	if rig != null:
		for i: int in mini(tentacles.count(), rig.strand_count()):
			_pose_strand(i)
	_update_pads()


## Where strand `index`'s chain actually ended up, in world space.
##
## The readout the runtime suite needs. A chain that is sheared, left at its rest pose
## or never reparented at all still renders and still passes every physics assertion in
## this folder, because nothing in the solver ever reads a bone.
func chain_tip(index: int) -> Vector3:
	if index < 0 or index >= _tips.size():
		return Vector3.ZERO
	return _tips[index]


## Lays one chain along its Bezier.
##
## BONES ARE NESTED, so this cannot write a world basis per bone: the write to bone k
## would immediately be re-based by the write to bone k-1 that just happened. Instead a
## running world frame is carried forward by hand and each bone is given the DELTA from
## its parent, which telescopes exactly -- R0 * (R0'R1) * (R1'R2) ... = Rk.
##
## THE STRETCH GOES IN THE TRANSLATION, NEVER IN A SCALE. Godot composes a child's
## global basis as `parent.basis * child.basis`, so a Y-scaled parent times a child
## rotation is a SHEAR -- and because the bones are nested that shear compounds as
## s^k down 22 levels, which at 1.12 is a factor of 11 by the tip. The limb would
## corkscrew apart. Varying only the spacing keeps every basis a pure rotation, and the
## voxel cubes stay cubes.
func _pose_strand(index: int) -> void:
	var bones: int = rig.link_count(index)
	if bones < 2:
		return
	var socket: Node3D = rig.socket(index)
	if socket == null:
		return

	var root: Vector3 = tentacles.shoulder(index)
	var frame: Basis = socket.global_basis.orthonormalized()
	var p1: Vector3 = _root_biased(root, _p1[index], frame.y)
	var p2: Vector3 = _p2[index]
	var tip: Vector3 = tentacles.tip(index)

	# One fewer link than there are bones: `_bone_00` sits ON the socket.
	var links: int = bones - 1
	var nominal: float = rig.link_step()
	var total: float = _measure_arc(root, p1, p2, tip)
	var step: float = (
		nominal
		* clampf(
			total / maxf(float(links) * nominal, 0.001),
			TentacleTuning.STRETCH_MIN,
			TentacleTuning.STRETCH_MAX
		)
	)
	# The chain's own units. Only the uniform model scale sits between the socket and
	# the world, so this is a plain divide rather than a basis solve.
	var local_step: float = step / maxf(rig.model_scale, 0.0001)

	var here: Vector3 = root
	var cursor: float = 0.0
	_arc_cursor = 0
	for k: int in bones:
		var direction: Vector3 = frame.y
		if k < links:
			cursor += step
			var target: Vector3
			if cursor <= total:
				target = _bezier(root, p1, p2, tip, _t_at_arc(cursor))
			else:
				# PAST THE END OF THE CURVE, which is the normal case for a searching
				# strand: its tip flails two metres from a shoulder with five metres of
				# limb behind it. The surplus CURLS -- a fixed bend per bone about the
				# running frame's binormal, so it spirals -- rather than sticking out
				# straight, which reads as a stick, or being swallowed by the link
				# stretch, which reads as rubber.
				target = here + (Basis(frame.z, COIL_TURN) * frame.y).normalized() * step
			direction = CrawlerMath.direction_or(target - here, frame.y)

		var next: Basis = (_swing(frame.y, direction) * frame).orthonormalized()
		# `transposed()` rather than `inverse()`: both are pure rotations, for which the
		# transpose IS the inverse, at no cost and with no near-singular case.
		var bone: Node3D = rig.bone(index, k)
		if bone == null:
			return
		bone.transform = Transform3D(
			frame.transposed() * next, Vector3.ZERO if k == 0 else Vector3(0.0, local_step, 0.0)
		)
		if k < links:
			here += direction * step
		frame = next
	_tips[index] = here


## The shortest rotation carrying `from` onto `to`.
##
## PARALLEL TRANSPORT, not `Basis.looking_at`. looking_at needs an up reference, and
## whichever axis is picked the frame FLIPS the instant the tangent crosses it -- so
## every limb rolls 180 degrees in one frame somewhere in the middle of every sweep and
## its voxels visibly pop. Carrying the previous bone's frame forward by the minimum
## rotation has no reference axis to cross, so it cannot flip, and it gives the limb a
## free and plausible twist as it curls.
static func _swing(from: Vector3, to: Vector3) -> Basis:
	var axis: Vector3 = from.cross(to)
	if axis.length_squared() < 0.000001:
		if from.dot(to) > 0.0:
			return Basis.IDENTITY
		# Antiparallel: any perpendicular axis is a correct half turn.
		var perpendicular: Vector3 = CrawlerMath.direction_or(from.cross(Vector3.UP), Vector3.RIGHT)
		return Basis(perpendicular, PI)
	return Basis(axis.normalized(), from.angle_to(to))


## Pulls the near control point toward the socket's own axis, so a limb LEAVES the body
## in the direction it grows out of it. See ROOT_FREEDOM.
static func _root_biased(root: Vector3, near: Vector3, axis: Vector3) -> Vector3:
	var lead: Vector3 = near - root
	var length: float = lead.length()
	if length < 0.001:
		return near
	return root + (axis * length).lerp(lead, ROOT_FREEDOM)


## Fills the arc table and returns the strand's total length. Chord-sums the samples,
## which is within a millimetre on a curve this shallow.
func _measure_arc(root: Vector3, p1: Vector3, p2: Vector3, tip: Vector3) -> float:
	var previous: Vector3 = root
	var total: float = 0.0
	_arc[0] = 0.0
	for step: int in ARC_SAMPLES:
		var point: Vector3 = _bezier(root, p1, p2, tip, float(step + 1) / float(ARC_SAMPLES))
		total += previous.distance_to(point)
		_arc[step + 1] = total
		previous = point
	return total


## Inverts the arc table. A cubic Bezier's parameter is NOT proportional to its arc
## length, so stepping in `t` bunches bones wherever the curve is tight -- which is
## exactly at the coil, where it shows most. Read with a MONOTONE cursor because the
## walk only ever moves forward.
func _t_at_arc(distance: float) -> float:
	# `ARC_SAMPLES - 1`, not `ARC_SAMPLES`. The table holds SAMPLES + 1 entries, so the
	# last legal segment starts at SAMPLES - 1; letting the cursor reach SAMPLES reads
	# one past the end on the final bone of a fully extended strand.
	while _arc_cursor < ARC_SAMPLES - 1 and _arc[_arc_cursor + 1] < distance:
		_arc_cursor += 1
	var lower: float = _arc[_arc_cursor]
	var upper: float = _arc[_arc_cursor + 1]
	var span: float = upper - lower
	var within: float = 0.0 if span < 0.000001 else (distance - lower) / span
	return clampf((float(_arc_cursor) + within) / float(ARC_SAMPLES), 0.0, 1.0)


## Where a control point wants to be: along the chord, pushed off it by the solved
## slack, and wobbled.
##
## THE BOW IS THE SLACK MADE VISIBLE, exactly as cargo_tether's TetherLine solves its
## sagitta rather than picking one. A strand at full stretch goes dead straight and a
## short one coils hard, so the curve is a free readout of "this one is hauling" that
## costs nothing because it is just the geometry being honest.
##
## WHAT THAT READOUT DISTINGUISHES CHANGED WITH THE PAIR-LUNGE GAIT. It used to separate
## the model's short and long tentacles at the same distance, because a strand held at a
## comfortable 0.8 of its reach had slack left to show. The solver now maximises distance
## instead, so a planted strand sits at its own reach by construction, `slack_fraction`
## pins at its 0.12 floor, and every gripping limb is taut. The bow now separates GRIPPING
## from FLAILING rather than one gripping limb from another -- which is the more useful
## of the two reads for this gait, and is why nothing here needed changing.
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
	var bow: float = sag * length * TentacleTuning.slack_fraction(length, tentacles.reach_of(index))

	# Two incommensurate sines rather than a noise resource: deterministic, free, and
	# for a wobble on a strand exactly as convincing.
	var amp: float = noise_amplitude * length
	var wobble: Vector3 = (
		right * sin(2.7 * _time + phase) * amp + up * sin(4.1 * _time + 1.7 * phase) * amp
	)
	return root + chord * along + coil * bow + wobble


func _setup_pads(count: int) -> void:
	var quad: QuadMesh = QuadMesh.new()
	quad.size = Vector2(0.5, 0.5)
	var multimesh: MultiMesh = MultiMesh.new()
	multimesh.transform_format = MultiMesh.TRANSFORM_3D
	multimesh.mesh = quad
	multimesh.instance_count = count
	multimesh.visible_instance_count = 0
	_pads.multimesh = multimesh
	# Written in WORLD space, so this node must not add a transform of its own on top.
	_pads.top_level = true
	_pads.transform = Transform3D.IDENTITY


## The splat where a planted strand meets the wall. One draw call for all of them, and
## it is what tells the player a tentacle is STUCK to something rather than merely
## reaching toward it -- the model's own geometry cannot say that, because a posed
## chain looks the same whether its tip is gripping or in mid-air.
func _update_pads() -> void:
	var multimesh: MultiMesh = _pads.multimesh
	if multimesh == null:
		return
	var shown: int = 0
	for i: int in tentacles.count():
		if not tentacles.is_planted(i):
			continue
		var normal: Vector3 = tentacles.anchor_normal(i)
		if normal.length_squared() < 0.0001:
			continue
		var up: Vector3 = Vector3.UP if absf(normal.dot(Vector3.UP)) < 0.95 else Vector3.RIGHT
		# QuadMesh faces its own +Z, and Basis.looking_at points -Z along its argument,
		# so aim it at the negated normal to end up facing out of the wall.
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
