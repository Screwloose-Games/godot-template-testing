class_name CrawlerRig
extends Node3D

## Assembles the imported creature into something the solver can drive.
##
## THE MODEL HAS NO SKIN AND NO ANIMATIONS. Its "bones" are 141 nested plain Node3Ds --
## eight linear chains, each link a pure local (0, 0.24, 0) translation plus a rotation,
## unit scale, carrying three cube MeshInstance3D children. Godot imports it as a Node3D
## tree with no Skeleton3D and no AnimationPlayer, so SkeletonIK3D, SkeletonModifier3D,
## bone maps and retargeting are all irrelevant here. `nodes/import_as_skeleton_bones`
## would NOT change that -- it only affects files that have skins. Do not try it.
##
## This node does three things once, at _ready, and then nothing per tick:
##
##   1. SPLITS THE MODEL ACROSS TWO BRANCHES. CrawlerBody writes a NON-UNIFORM scale to
##      %Hull every physics tick for the stroke squash. A bone chain under that node
##      would SHEAR as the creature flexes -- and a sheared chain is invisible to every
##      physics assertion in this folder, because the solver never reads a bone. So the
##      torso goes under %Hull and the eight chains go under %Limbs, which is squashed
##      by nothing. This node carries the uniform model scale above both, so every basis
##      on the limb path stays conformal.
##   2. RE-CENTRES the creature. The model stands on y=0 with its core 1.1 m up; the
##      solver integrates a point and expects the body to be centred on it.
##   3. CACHES the chains, so TentacleBones walks an array rather than the tree.
##
## The model faces +Z. Godot's forward is -Z, hence the 180 degree yaw -- the same
## correction, for the same reason, as exploration_quadraped's %ModelPivot.

## Local +Y translation between two links in the source model, metres. MEASURED from the
## glb, not chosen: all 141 bone nodes sit at exactly (0, 0.24, 0) bar the eight
## `_bone_00`s, which sit on their socket.
const LINK_LENGTH: float = 0.24
## Name fragment identifying a link.
const BONE_TOKEN: String = "_bone_"
## And one identifying a cube, which must be EXCLUDED when walking a chain.
##
## A cube is named `tentacle_00_bone_00_vox_0`, which CONTAINS `_bone_`. Matching on the
## bone token alone walks out of the chain into a cube on the first step and reports
## every tentacle as two links long -- with no error anywhere, because a two-link chain
## poses perfectly well. It just does not reach.
const VOX_TOKEN: String = "_vox_"

@export_group("Wiring")
## The imported glb, instanced in crawler.tscn. Emptied and freed during _ready.
@export var model: Node3D
## Squashed branch. Receives the torso.
@export var hull: Node3D
## Unsquashed branch. Receives the eight chain roots, in strand order.
@export var limbs: Node3D

@export_group("Shape")
## Uniform scale for the whole creature.
##
## THE CORRIDOR IS TWICE AS BIG AS ITS NUMBERS LOOK. `build_corridor_run.gd`'s `w` and
## `h` are HALF-EXTENTS, so the typical section is 9 x 8 m, the pinch is 6 x 6 m and
## the chamber is 14 x 12 m. Scaled for the widths as written the creature would be a
## speck.
##
## The binding constraint is not the pinch, it is STARVATION: a strand whose chain
## cannot span the gap from its shoulder to a wall never plants, and the runtime
## suite's stagger check calls that out. Running down the middle of a 9 m tube the wall
## is about 3.6 m from a shoulder, and FORWARD_BIAS_MIN means the ray has to angle
## forward to get there rather than going straight out -- so the shortest chain needs
## about 3.9 m of usable reach -- and more than that once the socket sits behind the
## body centre, as the two rearmost do. 1.55 gives the shortest chain 4.49 m; 1.2 gave
## it 3.44 m and four strands never planted at all.
##
## The ceiling is the corridor's 6 x 6 m pinch, which `body_radius` has to fit down
## with room to steer. That lands the workable band at roughly 1.3 to 1.5.
@export var model_scale: float = 1.55

var _sockets: Array[Node3D] = []
var _bones: Array[Node3D] = []
var _chain_start: PackedInt32Array = PackedInt32Array()
var _chain_links: PackedInt32Array = PackedInt32Array()


func _ready() -> void:
	if model == null or hull == null or limbs == null:
		push_error("CrawlerRig is missing wiring; the creature will not be assembled")
		return

	var core: Node3D = model.find_child("core", true, false) as Node3D
	if core == null:
		push_error("CrawlerRig found no `core` node in the model")
		return

	# Orientation and scale first; the offset needs the torso in place to measure, so it
	# lands at the end. `reparent` keeps world transforms, and both branches hang off
	# this node, so they move together whenever this transform changes.
	basis = Basis(Vector3.UP, PI).scaled(Vector3.ONE * model_scale)
	position = Vector3.ZERO

	var torso: Node3D = core.find_child("torso", false, false) as Node3D
	if torso != null:
		torso.reparent(hull, true)

	_adopt_chains(core)
	_fix_vertex_colour_materials()
	_centre_on_torso()

	# Everything worth keeping has been moved out; what is left is the empty glb root and
	# the eight `_tip_target` empties, which are frozen rest-pose IK goals from the
	# exporter and are actively misleading now that the tips are solved live.
	model.queue_free()


## Number of strands the model actually provides.
func strand_count() -> int:
	return _sockets.size()


## Strand `index`'s socket -- the node the chain grows from. Doubles as the shoulder
## marker: it is a child of %Limbs at child index `index`, which is what lets
## TentacleArray read it positionally with no parallel marker hierarchy to keep in sync.
func socket(index: int) -> Node3D:
	if index < 0 or index >= _sockets.size():
		return null
	return _sockets[index]


func link_count(index: int) -> int:
	if index < 0 or index >= _chain_links.size():
		return 0
	return _chain_links[index]


## Link `link` of strand `index`. Indexed rather than sliced so posing a chain every
## physics tick allocates nothing.
func bone(index: int, link: int) -> Node3D:
	if index < 0 or index >= _chain_start.size():
		return null
	if link < 0 or link >= _chain_links[index]:
		return null
	return _bones[_chain_start[index] + link]


## One link's length in WORLD metres, after the model scale.
func link_step() -> float:
	return LINK_LENGTH * model_scale


## Arc length of strand `index`'s chain, world metres. ONE LINK SHORTER THAN THE BONE
## COUNT: `_bone_00` sits ON its socket with a zero translation, so 23 bones span 22
## links. Counting bones instead hands every strand a quarter-metre of reach it does
## not physically have, and the only symptom is tips that stop just short of their
## anchors -- which reads as the solver being wrong rather than the arithmetic.
func chain_span(index: int) -> float:
	return maxf(float(link_count(index) - 1), 0.0) * link_step()


## How far strand `index` can usefully stretch, world metres.
##
## Short of its true span on purpose. A chain at 100% is dead straight, and the sag IS
## the "this one is hauling" readout -- spending all of it on distance throws that away
## and leaves the creature looking like it is on stilts.
func chain_reach(index: int) -> float:
	return chain_span(index) * TentacleTuning.REACH_SAFETY


## Slides the creature so the torso's BOUNDING BOX CENTRE sits on this node's origin --
## which is the point CrawlerBody integrates and measures `body_radius` from.
##
## Not the `core` node, which is the obvious choice and is wrong: `core` is a rig pivot
## the exporter put near the base of the body, not the middle of it. Centring on it
## leaves the torso hanging 0.2 m off-centre, so its largest half-extent measured from
## the solver's origin is a fifth larger than the box's own -- and the visual pokes
## through walls the solver believes it is clear of. Measured rather than tabulated, so
## a re-export that reshapes the body corrects itself.
func _centre_on_torso() -> void:
	var box: AABB = AABB()
	var started: bool = false
	# `position` is expressed in the parent's space, so the box has to be measured there
	# too -- not in this node's own, which the scale would then double-apply.
	var host: Node3D = get_parent_node_3d()
	var into_parent: Transform3D = (
		Transform3D.IDENTITY if host == null else host.global_transform.affine_inverse()
	)
	for node: MeshInstance3D in _mesh_instances(hull):
		if node.mesh == null:
			continue
		var local: AABB = (into_parent * node.global_transform) * node.mesh.get_aabb()
		box = local if not started else box.merge(local)
		started = true
	if started:
		position = -box.get_center()


func _adopt_chains(core: Node3D) -> void:
	var index: int = 0
	while true:
		var found: Node3D = core.get_node_or_null("tentacle_%02d" % index) as Node3D
		if found == null:
			break
		found.reparent(limbs, true)
		_sockets.append(found)
		_chain_start.append(_bones.size())
		var links: int = 0
		var walker: Node3D = found
		while true:
			var next: Node3D = _next_link(walker)
			if next == null:
				break
			_bones.append(next)
			links += 1
			walker = next
		_chain_links.append(links)
		index += 1


func _next_link(node: Node3D) -> Node3D:
	for child: Node in node.get_children():
		var link: Node3D = child as Node3D
		if link == null:
			continue
		var link_name: String = String(link.name)
		if link_name.contains(BONE_TOKEN) and not link_name.contains(VOX_TOKEN):
			return link
	return null


## The body and gullet meshes carry their colour entirely as baked vertex colours -- the
## glTF materials have no base colour factor at all -- but Godot's importer leaves
## `vertex_color_use_as_albedo` OFF, so both surfaces render FLAT WHITE. That is not a
## subtle failure and it is not a material bug: the import is faithful, the flag simply
## is not inferred. Overridden per surface rather than mutated in place, so the shared
## imported resource is left alone.
func _fix_vertex_colour_materials() -> void:
	for node: MeshInstance3D in _mesh_instances(self):
		var mesh: Mesh = node.mesh
		if mesh == null:
			continue
		for surface: int in mesh.get_surface_count():
			if (mesh.surface_get_format(surface) & Mesh.ARRAY_FORMAT_COLOR) == 0:
				continue
			var source: StandardMaterial3D = (
				mesh.surface_get_material(surface) as StandardMaterial3D
			)
			if source == null or source.vertex_color_use_as_albedo:
				continue
			var fixed: StandardMaterial3D = source.duplicate() as StandardMaterial3D
			fixed.vertex_color_use_as_albedo = true
			node.set_surface_override_material(surface, fixed)


func _mesh_instances(node: Node) -> Array[MeshInstance3D]:
	var found: Array[MeshInstance3D] = []
	var mesh_node: MeshInstance3D = node as MeshInstance3D
	if mesh_node != null:
		found.append(mesh_node)
	for child: Node in node.get_children():
		found.append_array(_mesh_instances(child))
	return found
