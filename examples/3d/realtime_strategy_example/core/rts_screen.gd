class_name RtsScreen
extends RefCounted

## The one place screen coordinates meet camera projection.
##
## project.godot stretches with mode "canvas_items" and aspect "expand". That means the
## coordinate space an InputEvent arrives in is not guaranteed to be the space
## Camera3D.project_ray_origin() and unproject_position() work in, and the two only agree
## when the window happens to be exactly 1280x720. Mixing them is the classic "my clicks are
## offset from my cursor once I maximise the window" bug.
##
## The fix is to never read `event.position` for anything 3D. Viewport.get_mouse_position()
## is defined in the viewport's own space, which is exactly the space the camera projects
## into, so picking, box select and edge scrolling all stay consistent at any window size.
## Everything in this example goes through the helpers below rather than touching either API
## directly, so if this ever needs adjusting there is a single place to adjust it.


## Cursor position in the space Camera3D projections use. Use this, never event.position.
static func pick_position(viewport: Viewport) -> Vector2:
	return viewport.get_mouse_position()


## Where a world point lands on screen, or `null` if it is behind the camera. Callers must
## check for null: points behind the camera still unproject to a finite position, and letting
## them through is what makes box select grab units standing off-screen behind you.
static func project(camera: Camera3D, world_position: Vector3) -> Variant:
	if camera.is_position_behind(world_position):
		return null
	return camera.unproject_position(world_position)


## Normalised drag rectangle. Built with abs() so dragging up-left works as well as
## down-right.
static func drag_rect(start: Vector2, end: Vector2) -> Rect2:
	return Rect2(start, end - start).abs()
