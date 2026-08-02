class_name DeliveryDock
extends Node3D

## The destination: a solid ring you have to fly THROUGH, with a trigger volume
## in the hole.
##
## The ring is real geometry on the obstacle layer, not a decorative gate. Arriving
## is therefore a piloting problem rather than a proximity check -- and with a
## crate swinging on a tether behind you, threading a 22 m hole at speed is the
## last and best test of everything the course taught you.
##
## Built in code rather than authored as twelve nodes, for the same reason both
## other 3D examples build their worlds in code: the numbers that matter (radius,
## segment count, hole clearance) end up written down as constants instead of
## baked into transforms nobody can read.

## The ship crossed the trigger.
##
## Carries nothing about the cargo on purpose. The dock can only answer "is the
## crate inside this sphere right now", and the crate is normally 14 to 30 m
## behind the ship -- so at the instant the ship arrives, a perfectly delivered
## cargo is still outside. Whether it counts as delivered is a RULE, and the rule
## lives in TetherRun, which knows about the tether.
signal ship_arrived

@export_group("Geometry")
## Radius to the centre of the ring tube. The hole is this minus the tube.
@export var ring_radius: float = 22.0
@export var segment_count: int = 12
@export var tube_thickness: float = 2.6
@export var tube_depth: float = 3.0
@export var material: Material

@export_group("Trigger")
## Radius of the arrival volume, comfortably inside the hole.
@export var trigger_radius: float = 14.0

var _cargo_inside: bool = false
var _fired: bool = false
var _area: Area3D


func _ready() -> void:
	_build_ring()
	_build_trigger()


## Whether the cargo is currently inside the arrival volume. Read by TetherRun so
## a completion can be scored on the pair rather than on the ship alone.
func cargo_inside() -> bool:
	return _cargo_inside


## Lets a restart re-arm the dock without rebuilding the scene.
func rearm() -> void:
	_fired = false
	_cargo_inside = false


func _build_ring() -> void:
	var mesh := BoxMesh.new()
	# Chord of one segment, plus a little so neighbours overlap and leave no gap
	# for a crate corner to catch in.
	var chord: float = 2.0 * ring_radius * sin(PI / float(segment_count)) * 1.08
	mesh.size = Vector3(chord, tube_thickness, tube_depth)
	var shape := BoxShape3D.new()
	shape.size = mesh.size

	for i: int in segment_count:
		var angle: float = TAU * float(i) / float(segment_count)
		var body := StaticBody3D.new()
		body.name = "Segment%02d" % i
		body.collision_layer = TetherLayers.OBSTACLE
		# A static ring never queries anything. Masking would cost broadphase for
		# no behaviour.
		body.collision_mask = 0
		body.transform = Transform3D(
			Basis(Vector3.FORWARD, angle), Vector3(sin(angle), cos(angle), 0.0) * ring_radius
		)
		var visual := MeshInstance3D.new()
		visual.mesh = mesh
		if material != null:
			visual.material_override = material
		body.add_child(visual)
		var collision := CollisionShape3D.new()
		collision.shape = shape
		body.add_child(collision)
		add_child(body)


func _build_trigger() -> void:
	_area = Area3D.new()
	_area.name = "Trigger"
	_area.collision_layer = TetherLayers.TRIGGER
	# Needs BOTH bodies: the ship to know you arrived, the cargo to know whether
	# you brought it.
	_area.collision_mask = TetherLayers.MASK_DOCK_TRIGGER
	_area.monitoring = true
	var shape := CollisionShape3D.new()
	var sphere := SphereShape3D.new()
	sphere.radius = trigger_radius
	shape.shape = sphere
	_area.add_child(shape)
	add_child(_area)
	_area.body_entered.connect(_on_body_entered)
	_area.body_exited.connect(_on_body_exited)


func _on_body_entered(body: Node3D) -> void:
	if body is CargoBody:
		_cargo_inside = true
		return
	if not (body is ShipController) or _fired:
		return
	_fired = true
	ship_arrived.emit()


func _on_body_exited(body: Node3D) -> void:
	if body is CargoBody:
		_cargo_inside = false
