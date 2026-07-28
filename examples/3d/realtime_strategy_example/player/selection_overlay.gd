class_name SelectionOverlay
extends Control

## Draws the box-select rectangle.
##
## It tracks the drag itself rather than being handed a rectangle by PlayerCommander, and
## that is deliberate. Control drawing happens in canvas space, while the 3D hit test the
## commander runs happens in viewport space; under this project's "canvas_items" stretch mode
## those are not guaranteed to be the same coordinates. Each side reading the mouse in the
## space it actually draws or tests in keeps both correct at any window size.

const FILL_COLOR: Color = Color(0.31, 0.76, 1.0, 0.14)
const BORDER_COLOR: Color = Color(0.58, 0.87, 1.0, 0.9)
const BORDER_WIDTH: float = 1.5

var _anchor: Vector2 = Vector2.ZERO
var _rect: Rect2 = Rect2()
var _active: bool = false


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	set_process(false)


func _process(_delta: float) -> void:
	var next: Rect2 = Rect2(_anchor, get_global_mouse_position() - _anchor).abs()
	if next != _rect:
		_rect = next
		queue_redraw()


func begin_drag() -> void:
	_anchor = get_global_mouse_position()
	_rect = Rect2(_anchor, Vector2.ZERO)
	_active = true
	set_process(true)
	queue_redraw()


func end_drag() -> void:
	_active = false
	set_process(false)
	queue_redraw()


func _draw() -> void:
	if not _active:
		return
	draw_rect(_rect, FILL_COLOR, true)
	draw_rect(_rect, BORDER_COLOR, false, BORDER_WIDTH)
