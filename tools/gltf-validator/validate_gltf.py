import json
import os
import re
import sys
from urllib.parse import unquote, quote
import numpy as np
import trimesh
import pyrender
import sys
from PIL import Image, ImageDraw
from pyrender.constants import RenderFlags
from trimesh.transformations import euler_matrix, translation_matrix
import yaml
from spec_image_tools import draw_facing_direction
from gltf_axes import get_model_facing_direction, get_model_up_direction
from gltf_transforms import find_unapplied_transforms, format_report
import logging

# This script renders. It no longer judges.
#
# The spec checks used to live here, which meant the only way to find out whether
# a model passed was to push a branch and wait for this container to boot an X
# server. They now live in model_spec, which needs neither, so the same verdicts
# are available from a laptop, a git hook and a CI step that runs in seconds --
# see .github/scripts/validate-model-files.py.
#
# pygltflib is gone with them. Nothing here needed its decoded buffers: trimesh
# loads from the path, the preview URL reads only uri strings, and the one
# function that did decode buffers (get_bounding_box) was dead code. Reading the
# document through gltf_document instead means the checks see byte-identical
# input in Docker and on a laptop as a matter of structure rather than intent.
import gltf_document
import gltf_measure
import model_spec
from model_spec import (  # noqa: F401 -- re-exported; callers and tests import these from here
    SPEC_EXTENSION,
    evaluate_model_against_spec,
    get_gltf_scale,
    list_animations,
    list_bones,
    list_images,
    list_materials,
    list_textures,
    read_spec_file,
    verdicts_failed,
)

logging.basicConfig(level=logging.INFO, format='%(asctime)s - %(levelname)s - %(message)s')
logger = logging.getLogger(__name__)

GITHUB_REPOSITORY = os.getenv("GITHUB_REPOSITORY")
GITHUB_COMMIT_SHA = os.getenv("GITHUB_COMMIT_SHA")
THICK_GRID_COLOR = (100, 100, 100, 255)
THIN_GRID_COLOR = (200, 200, 200, 255)
THICK_GRID_THICKNESS = 2
THIN_GRID_THICKNESS = 1
CAMERA_DISTANCE_PADDING = 1.0
image_width, image_height = 256, 256

def get_raw_url(repo, branch, filepath):
    # Construct the raw URL for the file in the GitHub repository
    # Example raw URL: https://github.com/Screwloose-Games/tiny-pet/blob/assets/uploaded-assets/example_character_front_4404.png?raw=true
    print(f"get_raw_url: repo={repo}, branch={branch}, filepath={filepath}")
    return f"https://github.com/{repo}/blob/{branch}/{filepath}?raw=true"

def create_3d_preview_url(gltf_filepth: str, gltf) -> str:
    """
    Create a 3D preview URL for the assets.
    """
    assets: list[str] = []
    gltf_filepth_uri = quote(gltf_filepth)
    assets.append(gltf_filepth_uri)
    if gltf_filepth_uri.endswith(".gltf"):
        # Add buffer file if it exists
        for filepath in gltf.buffers:
            if hasattr(filepath, 'uri') and filepath.uri:
                bin_file = os.path.join(os.path.dirname(gltf_filepth_uri), filepath.uri)
                if os.path.exists(bin_file):
                    assets.append(bin_file)
                else:
                    print(f"Warning: {bin_file} not found.")
        gltf_basepath = os.path.dirname(gltf_filepth_uri)
        for image in gltf.images:
            if hasattr(image, 'uri') and image.uri:
                assets.append(os.path.join(gltf_basepath, image.uri))

    comma_separated_assets = ",".join([get_raw_url(GITHUB_REPOSITORY, GITHUB_COMMIT_SHA, asset) for asset in assets])
    complete_url = f"https://3dviewer.net/#model={comma_separated_assets}"
    print(f"3D preview URL: {complete_url}")
    return complete_url

def load_gltf_with_trimesh(filepath: str) -> trimesh.Scene:
    # Trimesh can load glTF directly
    scene = trimesh.load_scene(filepath)
    return scene



def get_front_camera_pose(scene: trimesh.Scene) -> np.ndarray:
    """
    Returns a camera pose for a top-down view of the scene.
    The camera looks down the -Z axis from above the model.
    """
    bounds = scene.bounds
    center = (bounds[0] + bounds[1]) / 2

    center_x = center[0]
    center_z = center[1]

    ending_bound = bounds[1]

    ending_bound_y = ending_bound[2]

    translation = translation_matrix([center_x, center_z, ending_bound_y + CAMERA_DISTANCE_PADDING])

    return translation

def get_top_down_camera_pose(scene: trimesh.Scene) -> np.ndarray:
    """
    Returns a camera pose for a top-down view of the scene.
    The camera looks down the -Z axis from above the model.
    """

    bounds = scene.bounds
    center = (bounds[0] + bounds[1]) / 2
    center_x = center[0]
    center_y = center[2]
    ending_bound = bounds[1]
    ending_bound_z = ending_bound[1]
    rotation = euler_matrix(-np.pi/2, 0, 0)  
    translation = translation_matrix([center_x, ending_bound_z + CAMERA_DISTANCE_PADDING, center_y])
    camera_pose = translation @ rotation
    return camera_pose

def get_right_side_camera_pose(scene: trimesh.Scene) -> np.ndarray:
    """
    Returns a camera pose for a top-down view of the scene.
    The camera looks down the -Z axis from above the model.
    """
    bounds = scene.bounds
    center = (bounds[0] + bounds[1]) / 2

    center_z = center[1]
    center_y = center[2]

    ending_bound = bounds[1]
    ending_bound_x = ending_bound[0]

    rotation = euler_matrix(0, - np.pi / 2, 0)
    translation = translation_matrix([-ending_bound_x - CAMERA_DISTANCE_PADDING, center_z, center_y])
    camera_pose = translation @ rotation

    return camera_pose


def generate_orthographic_image(scene: trimesh.Scene, camera: pyrender.OrthographicCamera, camera_pose = np.eye(4), render_flags = RenderFlags.RGBA, ) -> Image:
    """
    Renders an orthographic top view (looking down -Z axis) of the scene with transparent background.
    No grid is drawn.
    """
    pyrender_scene = pyrender.Scene.from_trimesh_scene(scene)
    print("Rendering scene")
    pyrender_scene.bg_color = [0, 0, 0, 0]

    pyrender_scene.add(camera, pose=camera_pose)
    light = pyrender.DirectionalLight(color=np.ones(3), intensity=2.0)
    pyrender_scene.add(light, pose=camera_pose)

    print("preparing renderer")
    r = pyrender.OffscreenRenderer(viewport_width=image_width, viewport_height=image_height)
    print("Rendering image")
    color, _ = r.render(pyrender_scene, flags=render_flags)
    print("Generating image from data")
    model_img = Image.fromarray(color, mode="RGBA")
    print("Image generated")
    return model_img

def generate_grid_image(height: int = 1024, width: int = 1024, largest_dist:  float = 2.0) -> Image:
    print(f"Generating grid image with height={height}, width={width}, largest_dist={largest_dist}")
    grid_img = Image.new("RGBA", (width, height), color=(255, 255, 255, 255))
    draw = ImageDraw.Draw(grid_img)

    width_world = largest_dist
    if width_world == 0:
        width_world = 1e-6  # Prevent division by zero
    width_px = width 
    px_per_unit = width_px / width_world
    dm_size_px = int(px_per_unit * 0.1)
    dm_size_px = max(dm_size_px, 1)  # Ensure at least 1px

    meter_size_px = int(px_per_unit * 1.0)
    meter_size_px = max(meter_size_px, 1)  # Ensure at least 1px

    # Draw vertical grid lines: center and every dm to left/right'
    logger.debug(f"Drawing vertical grid lines with dm_size_px={dm_size_px}, meter_size_px={meter_size_px}")
    center_x = width // 2

    is_space_between_thick_lines = dm_size_px > THICK_GRID_THICKNESS * 2

    for x in range(center_x, width, dm_size_px):
        logger.debug(f"Drawing vertical line at x={x}")
        if (x - center_x) % (meter_size_px) == 0:
            # Thicker line each meter

            draw.line([(x, 0), (x, height)], fill=THICK_GRID_COLOR, width=THICK_GRID_THICKNESS)
        elif is_space_between_thick_lines:
            draw.line([(x, 0), (x, height)], fill=(200, 200, 200, 255), width=THIN_GRID_THICKNESS)
    for x in range(center_x, -1, -dm_size_px):
        logger.debug(f"Drawing vertical line at x={x}")
        if (x - center_x) % (meter_size_px) == 0:
            # Thicker line each meter

            draw.line([(x, 0), (x, height)], fill=THICK_GRID_COLOR, width=THICK_GRID_THICKNESS)
        elif is_space_between_thick_lines:
            draw.line([(x, 0), (x, height)], fill=(200, 200, 200, 255), width=THIN_GRID_THICKNESS)

    # Draw horizontal grid lines: start at bottom and go up every dm
    for y in range(height - 1, -1, -dm_size_px):
        logger.debug(f"Drawing horizontal line at y={y}")
        if (height - y -1) % (meter_size_px) == 0:
            # Thicker line each meter
            draw.line([(0, y), (width, y)], fill=THICK_GRID_COLOR, width=THICK_GRID_THICKNESS)
        elif is_space_between_thick_lines:
            draw.line([(0, y), (width, y)], fill=(200, 200, 200, 255), width=THIN_GRID_THICKNESS)
    return grid_img


def render_and_save_view(scene, camera, camera_pose, grid_img, output_path, render_flags=RenderFlags.RGBA, model_facing_direction: str = None) -> str:
    """
    Renders a view of the scene with the given camera pose, overlays the grid, and saves the image.
    """
    print(f"Generating image for {output_path}")
    model_img = generate_orthographic_image(scene, camera, camera_pose, render_flags)
    print(f"Rendering image for {output_path}")
    final_img = Image.alpha_composite(grid_img, model_img)
    print(f"Overlaying grid on image for {output_path}")
    draw = ImageDraw.Draw(final_img)
    if model_facing_direction:
        draw_facing_direction(draw, model_facing_direction)
    print(f"Saving image to {output_path}")
    final_img.convert("RGB").save(output_path)
    return output_path

def create_markdown_report(poly_count: int, width: float, depth: float, height: float, animations: list[str], textures: list[str], images: list[str], materials: list[str], bones: list[str], scale: float, rendered_images: dict, preview_3d_url: str = None) -> str:
    """
    Creates a markdown report of the model.
    """
    report = f"""
# [*Preview Model in 3D Viewer*]({preview_3d_url})

#### Model Statistics
- **Total Polygons**: {poly_count}

#### Size
- **Width (X)**: {width:.4f}
- **Height (Y)**: {height:.4f}
- **Depth (Z)**: {depth:.4f}
- **Scale**: {scale}
- **Animations**: {animations}
- **Textures**: {textures}
- **Images**: {images}
- **Materials**: {materials}
- **Total Bones found**: {len(bones)}
"""

    if len(bones) > 0:
        report += f"- **Bones**: {bones}\n"

    recommended_poly_max = 20000
    has_too_many_polys = poly_count > recommended_poly_max
    is_scaled = scale != 1.0

    has_issues = has_too_many_polys or is_scaled
    if has_issues:
        report += "\n# Warnings\n"

    if is_scaled:
        report += f"\nThe model is not at 1:1 scale. scale is: {scale}\nPlease check the model.\n"
    if has_too_many_polys:
        report += f"\nThe model has a high polygon count. This may affect performance. Max recommended poly count: {recommended_poly_max}\n"

    report += "#### Images\n\n"

    for image_name, image_path in rendered_images.items():
        report += f"![{image_name}]({image_path})"

    return report

def create_png_filename(gltf_file: str, view: str) -> str:
    """
    Create a PNG filename based on the GLTF file name and view.
    """
    base_name = os.path.splitext(os.path.basename(gltf_file))[0]
    return f"{base_name}_{view}.png"


def process_gltf_file(gltf_file: str, output_dir: str) -> dict:
    """
    Process a single GLTF file and return results.
    """
    print(f"Processing GLTF file: {gltf_file}")
    try:
        # First check if the file exists
        if not os.path.exists(gltf_file):
            print(f"File not found: {gltf_file}")
            return {
                "file": gltf_file,
                "error": f"File not found: {gltf_file}",
                "success": False
            }

        # Check if the file is a GLTF file
        if not gltf_file.lower().endswith(('.gltf', '.glb')):
            print(f"Not a GLTF file: {gltf_file}")
            return {
                "file": gltf_file,
                "error": f"Not a GLTF file: {gltf_file}",
                "success": False
            }
        
        


        # Read the document once, through the same loader the local CLI and the
        # git hooks use, so a verdict computed here and a verdict computed on a
        # laptop are computed from identical input.
        document = gltf_document.load_document(gltf_file)
        gltf = gltf_document.as_gltf(document)

        # Check for missing resources
        print(f"Checking for missing resources in {gltf_file}")
        missing_resources = model_spec.check_external_resources(gltf, gltf_file)

        # A .gltf is expected to sit beside a .bin of the same name. Reported,
        # never failed: the export is still loadable, and renaming the pair is a
        # judgement call about which of the two names is the right one.
        if gltf_file.lower().endswith('.gltf'):
            expected_bin = os.path.splitext(os.path.basename(gltf_file))[0] + ".bin"
            buffer_names = [
                os.path.basename(unquote(buffer.uri))
                for buffer in gltf.buffers or []
                if getattr(buffer, "uri", None)
            ]
            if buffer_names and expected_bin not in buffer_names:
                logger.warning(
                    f"Expected buffer file {expected_bin} beside {gltf_file}; "
                    f"found {buffer_names} instead."
                )

        if missing_resources:
            print(f"Missing resources:\n" + "\n".join(f"- {r}" for r in missing_resources))
            return {
                "file": gltf_file,
                "error": f"Missing resources:\n" + "\n".join(f"- {r}" for r in missing_resources),
                "success": False
            }

        try:
            scene = load_gltf_with_trimesh(gltf_file)
        except Exception as e:
            print(f"Failed to load GLTF file: {str(e)}")
            return {
                "file": gltf_file,
                "error": f"Failed to load GLTF file: {str(e)}",
                "success": False
            }

        # The spec verdicts are measured from the glTF JSON, not from trimesh, so
        # that the numbers in this comment are the same numbers a contributor
        # sees locally. trimesh's own bounds still frame the camera below --
        # that is cosmetic, and only ever needs to be approximately right.
        measurement = gltf_measure.measure(document)
        scene_bounds_size = measurement.size
        poly_count = measurement.triangles
        for problem in measurement.problems:
            logger.warning(problem)
        print(f"Scene bounds size: {scene_bounds_size}")
        print(
            f"Triangles: {poly_count} across {measurement.instances} instance(s) "
            f"of {measurement.unique_meshes} mesh(es)"
        )

        camera_bounds_size = scene.bounds[1] - scene.bounds[0]
        SCENE_BOUNDS_PADDING_PERCENTAGE = 0.1
        padded_scene_bounds_size = camera_bounds_size * (1 + SCENE_BOUNDS_PADDING_PERCENTAGE)  # add some padding to the bounds in all directions

        largest_dim = max(padded_scene_bounds_size)
        camera = pyrender.OrthographicCamera(xmag=largest_dim / 2, ymag=largest_dim / 2)
        grid_img = generate_grid_image(height=image_height, width=image_width, largest_dist=largest_dim)
        wireframe_render_flags = RenderFlags.RGBA + RenderFlags.ALL_WIREFRAME

        logger.debug(f"Loading spec file for {gltf_file}")
        spec_file = model_spec.spec_path_for(gltf_file)
        spec = read_spec_file(spec_file)

        # A spec key with a typo in it used to be ignored in silence, so the
        # check the artist asked for simply never ran. Surface it here too, not
        # only in the local CLI, so the PR comment says what went unchecked.
        spec_problems = model_spec.validate_spec_schema(spec, spec_file)
        for problem in spec_problems:
            logger.warning(problem)

        logger.debug(f"Evaluating model against spec for {gltf_file}")
        report = model_spec.transform_report(gltf)
        if report:
            print("Unapplied transform check:")
            print(report)
        validation_results = evaluate_model_against_spec(
            gltf=gltf,
            spec=spec,
            scene_bounds_size=scene_bounds_size,
            poly_count=poly_count
        )
        if spec_problems:
            validation_results["spec_schema"] = "FAIL - " + "; ".join(spec_problems)

        # Create output directory for this file
        file_output_dir = os.path.join(output_dir, os.path.splitext(os.path.basename(gltf_file))[0])
        os.makedirs(file_output_dir, exist_ok=True)

        # Render and save views
        print(f"Rendering and saving views for {gltf_file}")
        print(f"Output directory: {file_output_dir}")

        rendered_images = {
            "front": render_and_save_view(scene, camera, get_front_camera_pose(scene), grid_img, create_png_filename(gltf_file, "front")),
            "top": render_and_save_view(scene, camera, get_top_down_camera_pose(scene), grid_img, create_png_filename(gltf_file, "top"), model_facing_direction="down"),
            "right": render_and_save_view(scene, camera, get_right_side_camera_pose(scene), grid_img, create_png_filename(gltf_file, "right"), model_facing_direction="right"),
            "front_wireframe": render_and_save_view(scene, camera, get_front_camera_pose(scene), grid_img, create_png_filename(gltf_file, "front_wireframe"), render_flags=wireframe_render_flags),
            "top_wireframe": render_and_save_view(scene, camera, get_top_down_camera_pose(scene), grid_img, create_png_filename(gltf_file, "top_wireframe"), render_flags=wireframe_render_flags),
            "right_wireframe": render_and_save_view(scene, camera, get_right_side_camera_pose(scene), grid_img, create_png_filename(gltf_file, "right_wireframe"), render_flags=wireframe_render_flags),
            "front_normals": render_and_save_view(scene, camera, get_front_camera_pose(scene), grid_img, create_png_filename(gltf_file, "front_normals"), render_flags=RenderFlags.RGBA + RenderFlags.OFFSCREEN + RenderFlags.FACE_NORMALS),
            "top_normals": render_and_save_view(scene, camera, get_top_down_camera_pose(scene), grid_img, create_png_filename(gltf_file, "top_normals"), render_flags=RenderFlags.RGBA + RenderFlags.OFFSCREEN + RenderFlags.FACE_NORMALS),
            "right_normals": render_and_save_view(scene, camera, get_right_side_camera_pose(scene), grid_img, create_png_filename(gltf_file, "right_normals"), render_flags=RenderFlags.RGBA + RenderFlags.OFFSCREEN + RenderFlags.FACE_NORMALS),
        }

        # Create 3D preview URL

        preview_3d_url = create_3d_preview_url(gltf_file, gltf)
        
        # Create markdown report
        print(f"Creating markdown report for {gltf_file}")
        # A model whose POSITION accessors declare no min/max cannot be measured;
        # fall back to trimesh's numbers for the report rather than crashing, and
        # let the spec verdicts say UNKNOWN.
        reported_size = scene_bounds_size if scene_bounds_size is not None else camera_bounds_size
        report = create_markdown_report(
            poly_count=poly_count,
            width=reported_size[0],
            depth=reported_size[2],
            height=reported_size[1],
            animations=list_animations(gltf),
            textures=list_textures(gltf),
            images=list_images(gltf),
            materials=list_materials(gltf),
            bones=list_bones(gltf),
            scale=get_gltf_scale(gltf),
            rendered_images=rendered_images,
            preview_3d_url=preview_3d_url,
        )

        REPORT_FILEPATH = os.path.join(file_output_dir, "report.md")
        with open(REPORT_FILEPATH, "w") as f:
            f.write(report)

        print(f"Report saved to: {REPORT_FILEPATH}")

        return {
            "file": gltf_file,
            "report": report,
            "validation_results": validation_results,
            "report_filepath": REPORT_FILEPATH,
            "file_output_dir": file_output_dir,
            "success": True
        }
    except Exception as e:
        print(f"Error processing file: {str(e)}")
        return {
            "file": gltf_file,
            "error": f"Error processing file: {str(e)}",
            "success": False
        }

def create_github_comment(results: list[dict]) -> str:
    """
    Create a GitHub comment from the validation results.
    """
    comment = ""

    # Result:
    # {
    #     "file": gltf_file,
    #     "report": report,
    #     "validation_results": validation_results,
    #     "report_filepath": REPORT_FILEPATH,
    #     "images_dir": file_output_dir,
    #     "success": True
    # }

    
    for result in results:
        
        if not result["success"]:
            comment += f"## ❌ {os.path.basename(result['file'])}\n"
            comment += f"Error: {result['error']}\n\n"
            continue

        comment += f"## ✅ {os.path.basename(result['file'])}\n"
        
        # Add validation results
        comment += "### Validation Results:\n"
        for key, value in result["validation_results"].items():
            # INFO keys are declarations the validator cannot verify, so they
            # get their own marker rather than a red cross that reads as a
            # failure nobody can act on.
            if value == "OK":
                status = "✅"
            elif isinstance(value, str) and value.startswith("INFO"):
                status = "ℹ️"
            else:
                status = "❌"
            comment += f"- {key}: {status} {value}\n"
        
        # Add report content
        # with open(result["report_filepath"], "r") as f:
        #     report_content = f.read()
        #     comment += f"\n#### Model Report:\n{report_content}\n"

        report = result.get("report", None)
        if report:
            comment += f"### Model Report:\n{report}\n\n"
        
        # # Add images
        # comment += "\n#### Model Views:\n"
        # for view in ["front", "top", "right"]:
        #     image_path = os.path.join(result["images_dir"], f"{view}.png")
        #     if os.path.exists(image_path):
        #         comment += f"![{view} view]({image_path})\n"
        
        comment += "\n---\n\n"
    
    return comment

if __name__ == "__main__":
    if len(sys.argv) < 2:
        print("Usage: python validate_gltf.py <output_dir> [gltf_file1] [gltf_file2] ...")
        sys.exit(1)
    
    output_dir = sys.argv[1]
    gltf_files = sys.argv[2:]

    print(f"Output directory: {output_dir}")
    print(f"GLTF files: {gltf_files}")
    
    if not gltf_files:
        print("No GLTF files provided")
        sys.exit(1)
    
    os.makedirs(output_dir, exist_ok=True)
    
    results = []
    for gltf_file in gltf_files:
        result = process_gltf_file(gltf_file, output_dir)
        results.append(result)
    
    # Create GitHub comment
    comment = create_github_comment(results)
    
    # Save comment to file for GitHub Action to use
    with open(os.path.join(output_dir, "github_comment.md"), "w") as f:
        f.write(comment)
    
    # Print summary
    success_count = sum(1 for r in results if r["success"])
    all_succeeded = all(r["success"] for r in results)
    if not all_succeeded:
        print("Some files failed validation. Check the output directory for details.")
    else:
        print("All files passed validation successfully.")
    print(f"Processed {len(results)} files: {success_count} successful, {len(results) - success_count} failed")

    # if there is a github file, output to the github file: results, comment
    out_path = os.environ.get("GITHUB_OUTPUT", None)
    print(f"GITHUB_OUTPUT: {out_path}")
    if out_path:
        print(f"Writing results to {out_path}")
        with open(out_path, "a") as fh:
            print(f"comment<<EOF\n{comment}\nEOF", file=fh)
            print(f"results={json.dumps(results)}", file=fh)
            print(f"success={json.dumps(all_succeeded)}", file=fh)
