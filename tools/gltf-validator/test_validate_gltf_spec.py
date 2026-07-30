#!/usr/bin/env python3
"""Integration tests for the axis checks inside evaluate_model_against_spec.

test_gltf_axes.py covers the measurement itself. This file covers the wiring:
that a measured axis is compared against the spec, that the OK/FAIL coercion at
the end of evaluate_model_against_spec turns the result into what the PR comment
renders, and that an unmeasurable model is reported rather than passed.

validate_gltf.py imports trimesh, pyrender and PIL at module scope, none of which
are installable outside the validator's Docker image. They are stubbed here --
evaluate_model_against_spec never calls into them, it only reads the node graph,
so the stubs are never exercised.

Keep this list in step with validate_gltf.py's imports. It is not cosmetic: CI
runs this file with numpy, pyyaml and jsonschema only, so a heavy import that is
not stubbed fails the job outright. PIL was missing for exactly that reason and
only showed up in CI, because a developer machine that has ever installed pillow
imports the real thing and passes.

Runs standalone or under pytest. Needs only numpy and pyyaml.
"""

from __future__ import annotations

import sys
import types
from pathlib import Path
from types import SimpleNamespace

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))


def _stub_heavy_imports() -> None:
    """Stand in for the Docker-only dependencies so the module can be imported."""
    if "pygltflib" not in sys.modules:
        pygltflib = types.ModuleType("pygltflib")
        pygltflib.GLTF2 = object
        sys.modules["pygltflib"] = pygltflib

    if "trimesh" not in sys.modules:
        trimesh = types.ModuleType("trimesh")
        trimesh.Trimesh = type("Trimesh", (), {})
        trimesh.Scene = type("Scene", (), {})
        transformations = types.ModuleType("trimesh.transformations")
        transformations.euler_matrix = lambda *a, **k: None
        transformations.translation_matrix = lambda *a, **k: None
        trimesh.transformations = transformations
        sys.modules["trimesh"] = trimesh
        sys.modules["trimesh.transformations"] = transformations

    if "pyrender" not in sys.modules:
        # Annotations on the rendering functions are evaluated at import time, so
        # every name they reference has to resolve to something. __getattr__
        # covers them all without listing pyrender's API here.
        pyrender = types.ModuleType("pyrender")
        pyrender.__getattr__ = lambda name: type(name, (), {})
        constants = types.ModuleType("pyrender.constants")
        constants.RenderFlags = SimpleNamespace(RGBA=1)
        pyrender.constants = constants
        sys.modules["pyrender"] = pyrender
        sys.modules["pyrender.constants"] = constants

    if "PIL" not in sys.modules:
        # Both validate_gltf and spec_image_tools do `from PIL import Image,
        # ImageDraw`, and neither uses `from __future__ import annotations`, so
        # signatures like `-> Image` and `draw: ImageDraw.ImageDraw` are
        # evaluated at def time and both names must resolve. The same
        # __getattr__ trick as pyrender avoids restating pillow's API.
        pil = types.ModuleType("PIL")
        image = types.ModuleType("PIL.Image")
        image.__getattr__ = lambda name: type(name, (), {})
        image_draw = types.ModuleType("PIL.ImageDraw")
        image_draw.__getattr__ = lambda name: type(name, (), {})
        pil.Image = image
        pil.ImageDraw = image_draw
        sys.modules["PIL"] = pil
        sys.modules["PIL.Image"] = image
        sys.modules["PIL.ImageDraw"] = image_draw


_stub_heavy_imports()

import numpy as np  # noqa: E402

import validate_gltf  # noqa: E402
from test_gltf_axes import asset, axis_quaternion, load  # noqa: E402

# Bounds and poly count the size checks are happy with; the axis keys are what
# these tests are about.
BOUNDS = np.array([1.0, 1.0, 1.0])
POLY_COUNT = 100


def evaluate(gltf, spec: dict) -> dict:
    return validate_gltf.evaluate_model_against_spec(gltf, spec, BOUNDS, POLY_COUNT)


def correct_export():
    return load(asset([{"name": "sm_rain_barrel", "mesh": 0}]))


def z_up_export():
    """Exported without the Y-up conversion: up lands on +Z, front on -Y."""
    return load(asset([{"name": "sm_rain_barrel", "mesh": 0, "rotation": axis_quaternion("x", 90)}]))


def unmeasurable():
    """No mesh anywhere, so there is no orientation to read."""
    return load(asset([{"name": "Empty"}]))


# --------------------------------------------------------------------------
# Passing


def test_correct_export_passes_the_up_check():
    results = evaluate(correct_export(), {"up_direction": "+Y"})
    assert results["up_direction"] == "OK"


def test_lowercase_and_padded_spec_values_are_normalised():
    results = evaluate(correct_export(), {"up_direction": " +y ", "facing_direction": "+z"})
    assert results["up_direction"] == "OK"
    assert "+Z" in results["facing_direction"]  # normalised before being echoed back


def test_axis_keys_are_absent_when_the_spec_omits_them():
    """A spec that says nothing about axes must not invent a verdict."""
    results = evaluate(z_up_export(), {})
    assert "up_direction" not in results
    assert "facing_direction" not in results


# --------------------------------------------------------------------------
# Failing


def test_z_up_export_fails_the_up_check():
    results = evaluate(z_up_export(), {"up_direction": "+Y"})
    assert results["up_direction"] == "FAIL"


def test_a_spec_can_describe_a_deliberately_rotated_model():
    """The up check compares against the spec, it does not hard-code +Y."""
    results = evaluate(z_up_export(), {"up_direction": "+Z"})
    assert results["up_direction"] == "OK"


def test_the_old_tautology_is_gone():
    """up_direction "+Y" used to pass for every model ever, without looking at it.

    If this regresses to a string comparison, a Z-up model passes again.
    """
    results = evaluate(z_up_export(), {"up_direction": "+Y"})
    assert results["up_direction"] != "OK"


# --------------------------------------------------------------------------
# Undeterminable


def test_unmeasurable_model_is_reported_not_passed():
    results = evaluate(unmeasurable(), {"up_direction": "+Y"})
    assert "UNKNOWN" in results["up_direction"]


def test_off_axis_model_is_reported_not_passed():
    """45 degrees about X leaves up halfway between +Y and +Z: name no axis.

    Deliberately not a rotation about Y -- a yaw leaves up on +Y untouched, so
    it would test nothing here.
    """
    gltf = load(asset([{"mesh": 0, "rotation": axis_quaternion("x", 45)}]))
    results = evaluate(gltf, {"up_direction": "+Y"})
    assert "UNKNOWN" in results["up_direction"]


# --------------------------------------------------------------------------
# facing_direction is declared, never verified
#
# Nothing in a glTF marks which side of a mesh is the face. get_model_facing_direction
# reports where the node chain sends the +Z basis vector, which reads "+Z" for
# every clean export whichever way the model was built -- so comparing it against
# this project's "-Z" geometric convention would fail every correct model. That
# was the trap the pipeline's open question feared; these tests pin the answer.


def test_facing_direction_is_reported_as_information_not_a_verdict():
    results = evaluate(correct_export(), {"facing_direction": "-Z"})
    assert results["facing_direction"].startswith("INFO")
    assert "-Z" in results["facing_direction"]


def test_the_project_convention_does_not_fail_a_clean_export():
    """The regression that matters: '-Z' in a spec must not fail a correct model."""
    results = evaluate(correct_export(), {"facing_direction": "-Z"})
    assert results["facing_direction"] != "FAIL"
    assert not results["facing_direction"].startswith("FAIL")


def test_facing_direction_says_it_cannot_be_checked():
    """A reviewer reading the comment must not think CI confirmed the facing."""
    message = evaluate(correct_export(), {"facing_direction": "-Z"})["facing_direction"]
    assert "Not machine-checkable" in message


def test_opposite_facing_conventions_are_indistinguishable():
    """Why the field cannot be a verdict, stated as a test."""
    forwards = evaluate(correct_export(), {"facing_direction": "+Z"})["facing_direction"]
    backwards = evaluate(correct_export(), {"facing_direction": "-Z"})["facing_direction"]
    assert "Node frame reads +Z" in forwards
    assert "Node frame reads +Z" in backwards  # identical measurement, opposite declarations


# --------------------------------------------------------------------------
# The facing arrow, which is the whole of the facing check
#
# Since facing_direction can never fail, the arrow drawn on the rendered views is
# the only thing that tells an artist which way their model points. It used to
# point +Z on both annotated views -- the model's back -- so it agreed with a
# model built backwards and disagreed with a correct one.


def test_the_facing_arrow_points_at_this_projects_forward():
    """-Z is forward, and these are the screen directions -Z maps to.

    Derived from the camera poses: the top view puts -Z at screen up, the right
    view puts it at screen left. Both used to be drawn towards +Z.
    """
    import spec_image_tools

    assert spec_image_tools.FORWARD_ON_SCREEN["top"] == "up"
    assert spec_image_tools.FORWARD_ON_SCREEN["right"] == "left"


def test_the_arrow_runs_from_the_centre_to_the_correct_edge():
    import spec_image_tools

    start, end = spec_image_tools.arrow_endpoints("up", 256, 256)
    assert start == (128, 128)
    assert end == (128, 0), "up must mean towards row 0, not the bottom"

    start, end = spec_image_tools.arrow_endpoints("left", 256, 256)
    assert end == (0, 128), "left must mean towards column 0"


def test_only_the_annotated_views_get_an_arrow():
    """The front view looks straight down the forward axis.

    An in-plane arrow there would point somewhere forward is not.
    """
    import spec_image_tools

    assert spec_image_tools.FORWARD_ON_SCREEN.get("front") is None


# --------------------------------------------------------------------------
# The ground line
#
# The cameras frame each model on its own bounds, so a model authored a metre off
# the origin looks exactly like one resting on the floor. Marking world Y=0 is
# what makes a rests_on_ground failure visible in the render it tells you to check.


def test_a_grounded_model_puts_the_floor_at_the_bottom_of_the_frame():
    # A 1m model resting on Y=0 has its centre at Y=0.5 and is framed 1m tall, so
    # the floor lands on the bottom edge -- clamped to the last real row, because
    # a line at `image_height` would fall outside the image and draw nothing.
    assert validate_gltf.ground_line_row(0.5, 1.0, 256) == 255

    # With the camera's 10% padding, which is what actually happens, it sits just
    # inside the frame instead.
    assert validate_gltf.ground_line_row(0.5, 1.1, 256) == 244


def test_a_floating_model_puts_the_floor_below_the_frame():
    """sm_test_wrong_size: a 1m cube authored 0.5m up. Y=0 is off-frame."""
    assert validate_gltf.ground_line_row(1.0, 1.0, 256) is None


def test_a_model_straddling_the_origin_puts_the_floor_mid_frame():
    assert validate_gltf.ground_line_row(0.0, 2.0, 256) == 128


def test_degenerate_bounds_do_not_raise():
    assert validate_gltf.ground_line_row(0.0, 0.0, 256) is None
    assert validate_gltf.ground_line_row(0.5, 1.0, 0) is None


# --------------------------------------------------------------------------
# Unapplied transforms
#
# This check and the axis checks read the same node rotation. It is reported
# beside them rather than instead of them, because the node graph cannot tell
# you whether that rotation is an artist's unapplied transform or an export
# left in Z-up -- so suppressing the axis verdicts would throw away the Z-up
# detection the tests above exist to protect.


def test_clean_export_passes_the_transform_check():
    assert evaluate(correct_export(), {})["unapplied_transforms"] == "OK"


def test_leftover_rotation_fails_the_transform_check():
    results = evaluate(z_up_export(), {})
    assert results["unapplied_transforms"] != "OK"
    assert "rotation" in results["unapplied_transforms"]


def test_the_transform_check_does_not_suppress_the_axis_verdicts():
    """The regression that matters: a Z-up export must still fail its up check."""
    results = evaluate(z_up_export(), {"up_direction": "+Y"})
    assert results["up_direction"] == "FAIL"
    assert results["unapplied_transforms"] != "OK"


def test_a_spec_can_opt_out_of_the_transform_check():
    """A spec that deliberately describes a rotated node is not fighting the check."""
    spec = {"up_direction": "+Z", "facing_direction": "-Y", "allow_unapplied_transforms": True}
    results = evaluate(z_up_export(), spec)
    assert "unapplied_transforms" not in results
    assert results["up_direction"] == "OK"
    assert results["facing_direction"].startswith("INFO")


def test_the_transform_failure_says_how_to_fix_it():
    message = evaluate(z_up_export(), {})["unapplied_transforms"]
    assert "Ctrl+A" in message or "allow_unapplied_transforms" in message


# --------------------------------------------------------------------------


def run_standalone() -> int:
    tests = [
        (name, obj)
        for name, obj in sorted(globals().items())
        if name.startswith("test_") and callable(obj)
    ]
    failures = 0
    for name, test in tests:
        try:
            test()
        except AssertionError as exc:
            failures += 1
            print(f"FAIL  {name}\n      {exc}")
        except Exception as exc:  # noqa: BLE001
            failures += 1
            print(f"ERROR {name}\n      {type(exc).__name__}: {exc}")
        else:
            print(f"ok    {name}")

    print(f"\n{len(tests) - failures}/{len(tests)} passed")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(run_standalone())
