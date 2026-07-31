"""Drive a procedural vehicle from source to shipped asset in one call.

Run inside Blender with the MCP add-on, or from `blender --background --python`:

    import sys; sys.path.insert(0, "tools/blender-vehicle")
    import build
    build.blockout("jeep_turret")                    # silhouette pass, for sign-off
    build.produce("jeep_turret", repo_root="C:/...")  # the shipping asset

`blockout` is the checkpoint: it builds the same geometry at lower segment counts
with flat placeholder colours and renders five views. Get that signed off before
`produce`, because `produce` spends ~90 seconds baking and a rejected silhouette
throws all of it away.

`produce` runs build -> unwrap -> surface -> bake -> audit -> export, and stops on
the audit rather than the export: a failed audit means the .blend is still open at
the point the problem can be fixed, instead of the problem surfacing three tools
downstream in the Godot editor.
"""

import importlib
import os
import sys

_HERE = os.path.dirname(os.path.abspath(__file__))
for path in (_HERE, os.path.join(_HERE, "models")):
    if path not in sys.path:
        sys.path.insert(0, path)

import bpy  # noqa: E402

import audit          # noqa: E402
import bake           # noqa: E402
import export         # noqa: E402
import render         # noqa: E402
import surfacing      # noqa: E402
import uv             # noqa: E402


def load(model_name):
    """Import (or re-import) a model module by name from models/."""
    module = importlib.import_module(model_name)
    return importlib.reload(module)


def _render_dir(repo_root, model):
    path = os.path.join(repo_root or ".", "tools", "blender-vehicle", "_renders")
    os.makedirs(path, exist_ok=True)
    return path.replace("\\", "/")


def blockout(model_name, repo_root=None, prefix=None):
    """Silhouette pass. No UVs, no bake -- just shape, rig and dimensions."""
    model = load(model_name)
    model.build(detail="block")
    findings, report = audit.run(
        target_w_h_d=model.SPEC["target_w_h_d"],
        budget=None,
        check_uvs=False)
    out = _render_dir(repo_root, model)
    render.views(out, prefix or f"{model.SPEC['stem']}_block")
    render.clear_rig()
    report["renders"] = out
    return report


def produce(model_name, repo_root, skip_bake=False):
    """The shipping asset: geometry, atlas, glTF and a re-saved .blend."""
    model = load(model_name)
    spec = model.SPEC
    asset_dir = os.path.join(repo_root, spec["asset_dir"]).replace("\\", "/")
    os.makedirs(asset_dir, exist_ok=True)

    model.build(detail="final", material_factory=surfacing.build_all)
    uv.unwrap()

    # The render rig has to go before baking: a camera or a light left in the scene
    # occludes the AO pass and then rides along into the export.
    render.clear_rig()

    if not skip_bake:
        bake.bake_atlas(surfacing.MATERIAL_CHANNELS, asset_dir, spec["stem"],
                        size=spec["atlas_size"],
                        ao_samples=spec["ao_samples"],
                        ao_strength=spec["ao_strength"])

    materials = export.build_export_materials(asset_dir, spec["stem"])
    export.remap_materials([z[0] for z in model.ZONES], "glass", "light", materials)

    findings, report = audit.run(
        target_w_h_d=spec["target_w_h_d"],
        budget=spec["poly_budget"])
    if not report["passed"]:
        # Deliberately before the export. Shipping a file that the audit already
        # knows is broken only moves the discovery downstream.
        report["exported"] = False
        return report

    export.export(f"{asset_dir}/{spec['model_file']}")

    # Proxies out of the render, procedural materials kept alive for a re-bake.
    for obj in bpy.data.objects:
        obj.hide_render = audit._is_proxy(obj) if obj.type == 'MESH' else False
    for material in bpy.data.materials:
        if material.name.startswith("zone_"):
            material.use_fake_user = True

    out = _render_dir(repo_root, model)
    render.views(out, spec["stem"])
    render.clear_rig()
    bpy.ops.wm.save_as_mainfile(filepath=f"{asset_dir}/{spec['blend_file']}")

    report["exported"] = True
    report["asset_dir"] = asset_dir
    report["renders"] = out
    return report
