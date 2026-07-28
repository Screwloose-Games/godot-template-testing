class_name OrderMarker
extends Node3D

## The ring that pings on the ground where you right-clicked.
##
## Pure feedback, and worth far more than it costs: a unit can take most of a second to turn
## around and start walking, and without a marker that reads as the click having been
## ignored. Built entirely in code so it needs no scene file of its own.

const LIFETIME: float = 0.45
const START_SCALE: float = 0.35
const END_SCALE: float = 1.5


## Drops a marker into `parent` and forgets about it — it frees itself when the tween ends.
static func ping(parent: Node, at_position: Vector3, color: Color, radius: float = 1.1) -> void:
	var marker: OrderMarker = OrderMarker.new()
	marker.name = "OrderMarker"
	parent.add_child(marker)
	marker.global_position = Vector3(at_position.x, 0.08, at_position.z)
	marker.scale = Vector3.ONE * START_SCALE

	var ring: TorusMesh = TorusMesh.new()
	ring.inner_radius = radius * 0.82
	ring.outer_radius = radius
	ring.rings = 3
	ring.ring_segments = 20

	var material: StandardMaterial3D = StandardMaterial3D.new()
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	material.albedo_color = color
	material.cull_mode = BaseMaterial3D.CULL_DISABLED

	var mesh_instance: MeshInstance3D = MeshInstance3D.new()
	mesh_instance.mesh = ring
	mesh_instance.material_override = material
	marker.add_child(mesh_instance)

	var faded: Color = Color(color.r, color.g, color.b, 0.0)
	var tween: Tween = marker.create_tween()
	tween.set_parallel(true)
	tween.tween_property(marker, "scale", Vector3.ONE * END_SCALE, LIFETIME).set_trans(
		Tween.TRANS_QUAD
	)
	tween.tween_property(material, "albedo_color", faded, LIFETIME)
	tween.chain().tween_callback(marker.queue_free)
