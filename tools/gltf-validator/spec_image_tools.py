"""Annotations drawn on top of the rendered views.

The facing arrow is not decoration. facing_direction is INFO-only -- nothing in a
glTF marks which side of a mesh is the face, so no tool can read it off the
geometry -- and both the schema and the pipeline docs therefore tell artists to
confirm facing from these renders. This arrow is the whole of that check.

It used to point +Z on both annotated views, which is the model's BACK: this
project's forward is -Z (Godot's Vector3.FORWARD, from +Y in Blender). So the
arrow labelled "Facing Direction" agreed with a model built backwards and
disagreed with a correct one, inverting the only check a human has to make by
eye. Confirmed with a matched pair of wedges -- assets/3d/test_facing_forward
(nose -Z) and test_facing_backwards (nose +Z), identical in every validator
verdict -- where the arrow sided with the backwards one.

Callers pass the *view*, not a screen direction. Naming a screen direction at the
call site is what let the two drift apart in the first place: "down" is a fact
about pixels, and whether it means forward depends on a camera pose defined in
another module.
"""

from PIL import Image, ImageDraw
import numpy as np


# Where this project's forward (-Z) lands on screen, per annotated view. Read off
# the camera poses in validate_gltf.py:
#
#   top view    euler_matrix(-pi/2, 0, 0), camera above looking down -Y.
#               Local +Y maps to world -Z, so screen up is -Z and screen down +Z.
#   right view  euler_matrix(0, +pi/2, 0), camera at +X looking towards -X.
#               Local +X maps to world -Z, so screen right is -Z and screen left +Z.
#
# Change a camera pose in validate_gltf.py and this table has to change with it.
# That has already happened once: the right-side camera moved from -X to +X so the
# view would show the side it is named after, which flipped forward from the left
# of the screen to the right.
FORWARD_ON_SCREEN = {"top": "up", "right": "right"}

FACING_COLOR = "red"


def draw_arrow(draw, start, end, color='black', width=2):
    """
    Draw an arrow from start to end on the given draw object.
    """
    draw.line([start, end], fill=color, width=width)
    # Draw the arrowhead
    arrowhead_length = 10 * width
    arrowhead_angle = 30
    angle = np.arctan2(end[1] - start[1], end[0] - start[0])
    arrowhead_left = (end[0] - arrowhead_length * np.cos(angle + np.radians(arrowhead_angle)),
                      end[1] - arrowhead_length * np.sin(angle + np.radians(arrowhead_angle)))
    arrowhead_right = (end[0] - arrowhead_length * np.cos(angle - np.radians(arrowhead_angle)),
                       end[1] - arrowhead_length * np.sin(angle - np.radians(arrowhead_angle)))
    draw.polygon([end, arrowhead_left, arrowhead_right], fill=color)


def arrow_endpoints(screen_direction, img_width, img_height):
    """Centre of the image out to the edge in the given screen direction."""
    centre = (img_width // 2, img_height // 2)
    edges = {
        "up": (img_width // 2, 0),
        "down": (img_width // 2, img_height),
        "left": (0, img_height // 2),
        "right": (img_width, img_height // 2),
    }
    return centre, edges[screen_direction]


def draw_text_facing(draw: ImageDraw.ImageDraw, img_width, img_height, screen_direction):
    """Label the arrow, offset along it so the text does not sit on the shaft."""
    centre, end = arrow_endpoints(screen_direction, img_width, img_height)
    mid = ((centre[0] + end[0]) // 2, (centre[1] + end[1]) // 2)
    text = "Facing Direction"
    if screen_direction in ("up", "down"):
        position = (mid[0], mid[1] - img_height // 20)
    else:
        # Horizontal arrows: nudge the label off the shaft rather than along it,
        # so it stays inside the frame when the arrow runs to the left edge.
        position = (max(0, mid[0] - img_width // 8), mid[1] - img_height // 12)
    draw.text(position, text, fill=FACING_COLOR, font_size=img_width // 20)


def draw_facing_direction(draw, view: str):
    """Mark which way is forward on one of the annotated views.

    `view` is "top" or "right". Anything else draws nothing: the front view looks
    straight down the forward axis, so an in-plane arrow there would be a lie.
    """
    screen_direction = FORWARD_ON_SCREEN.get(view)
    if screen_direction is None:
        return
    img_width, img_height = draw.im.size
    start, end = arrow_endpoints(screen_direction, img_width, img_height)
    draw_arrow(draw, start, end, color=FACING_COLOR, width=max(1, img_width // 100))
    draw_text_facing(draw, img_width, img_height, screen_direction)


def main():
    width, height = 256, 256

    image = Image.new('RGBA', (width, height), 0)
    draw = ImageDraw.Draw(image)
    draw_facing_direction(draw, 'top')


if __name__ == "__main__":
    main()
