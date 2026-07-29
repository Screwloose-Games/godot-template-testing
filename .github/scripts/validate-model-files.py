# Validate 3D models against their .spec.yaml, locally and in CI.
#
# Run this with: python .github/scripts/validate-model-files.py --all
# (positional args also work, and are how pre-commit and the Claude Code hook
# call it: ... validate-model-files.py assets/3d/barrel/sm_barrel.gltf)
#
# This is the pass/fail authority for 3D models. The Docker image in
# tools/gltf-validator/ still renders the nine-view preview that goes in the PR
# comment, but it no longer decides anything -- everything it used to judge is
# judged here, from the glTF JSON, in about a second, with no container.
#
# NOTE: don't invoke this via `$(cat model_files.txt)` -- unquoted shell command
# substitution word-splits on spaces, which silently corrupts any filename that
# contains a space. --file-list reads the file directly, one path per line.
#
# IMPORTANT: nothing outside the standard library may be imported at module
# scope. validate-pipeline-doc.py imports this file to read the constants below
# and compare them against documentation/pipeline/pipeline.yaml, and that
# workflow does not install numpy. The heavy imports live inside main().

import argparse
import json
import os
import re
import sys

REPO_ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
VALIDATOR_DIR = os.path.join(REPO_ROOT, "tools", "gltf-validator")

MODEL_EXTENSIONS = (".gltf", ".glb")
SPEC_EXTENSION = ".spec.yaml"

# Filename rules. These mirror documentation/pipeline/pipeline.yaml -- see the
# code_mirrors block there, which fails CI if the two drift apart.
MODEL_FILENAME_PATTERN = re.compile(r"^sm_[a-z0-9]+(_[a-z0-9]+)*\.gltf$")
SKELETAL_FILENAME_PATTERN = re.compile(r"^sk_[a-z0-9]+(_[a-z0-9]+)*\.gltf$")

# Where the naming rules apply. Everything outside this root is exempt, which
# mirrors PATH_CONVENTION_ROOT in validate-aseprite-files.py.
#
# examples/ is deliberately not covered: it holds self-contained prototypes whose
# whole point is to answer "is this loop fun?" without adopting shared
# conventions, and its third-party art (grey-wolf-gaits-and-jump.glb) would fail
# every naming rule here.
MODEL_ROOT = "assets/3d"

# Directories that never get validated, in any mode.
# test-fixtures holds a deliberately broken model -- unapplied_rotation_90z.gltf
# exists precisely to fail -- so validating it would make the repo permanently
# un-committable.
EXCLUDED_PATH_PARTS = (
    ".godot",
    "addons",
    "test-fixtures",
)

# --- What is enforced -------------------------------------------------------
#
# Each switch is here so a rule can be turned off without deleting the code that
# implements it, and so the reason a rule is off stays next to the rule.

# Every file the model references must exist on disk. The highest-value check in
# the set: it needs no spec, fires on every model, and catches the failure that
# actually reaches main -- a .gltf committed without its .bin.
ENFORCE_EXTERNAL_RESOURCES = True

# Check .spec.yaml files against schemas/model-spec.schema.json. The schema sets
# additionalProperties: false, so a misspelled key becomes an error instead of
# being ignored in silence while the check it was meant to enable never runs.
ENFORCE_SPEC_SCHEMA = True

# Filenames under MODEL_ROOT must match the sm_/sk_ patterns above.
ENFORCE_FILENAME_CONVENTION = True

# A .spec.yaml with no model beside it. Almost always the near-miss the pipeline
# doc warns about: sm_rain_barrel.spec.yaml instead of sm_rain_barrel.gltf.spec.yaml.
ENFORCE_ORPHAN_SPEC = True

# Require every model to have a spec. Deliberately off: both the schema and
# documentation/pipeline/pipeline.yaml describe the spec as optional, and a model
# without one passes silently by design. Turn this on once specs are the norm --
# `--all` will tell you how far off that is.
ENFORCE_SPEC_REQUIRED = False

# Checks that a model is still correct after Godot has imported it -- node names
# the importer reinterprets, and collision proxies larger than the art they stand
# in for. Both describe files that are valid glTF and wrong in the engine, so
# nothing else here can see them. See tools/gltf-validator/gltf_godot_import.py.
ENFORCE_GODOT_IMPORT = True

# Godot .import sidecars are deliberately NOT checked here. check-import-files.yml
# already covers .gltf/.glb/.bin and generates the missing sidecars on same-repo
# PRs, and only Godot can write one -- a pre-commit hook that demanded them would
# block commits nobody could unblock from a shell.

# Verdict markers. INFO is a declaration the validator cannot verify, so it gets
# its own marker rather than a cross that reads as a failure nobody can act on.
OK = "OK"
FAIL = "FAIL"
INFO = "INFO"


class ModelReport:
    """The checks run against one model, and how each came out."""

    def __init__(self, path):
        self.path = path
        self.checks = []  # (marker, name, detail)

    def ok(self, name, detail=""):
        self.checks.append((OK, name, detail))

    def fail(self, name, detail=""):
        self.checks.append((FAIL, name, detail))

    def info(self, name, detail=""):
        self.checks.append((INFO, name, detail))

    @property
    def failures(self):
        return [(name, detail) for marker, name, detail in self.checks if marker == FAIL]

    @property
    def failed(self):
        return bool(self.failures)

    def __str__(self):
        width = max((len(name) for _marker, name, _detail in self.checks), default=0)
        lines = [display_path(self.path)]
        for marker, name, detail in self.checks:
            lines.append(f"  {marker:<5} {name.ljust(width)}  {detail}".rstrip())
        return "\n".join(lines)


def display_path(path):
    """Repo-relative and forward-slashed, so output is the same on every OS."""
    try:
        relative = os.path.relpath(os.path.abspath(path), REPO_ROOT)
    except ValueError:  # different drive on Windows
        return str(path).replace("\\", "/")
    if relative.startswith(".."):
        return str(path).replace("\\", "/")
    return relative.replace("\\", "/")


def is_excluded(path):
    parts = display_path(path).split("/")
    return any(part in EXCLUDED_PATH_PARTS for part in parts)


def is_model(path):
    return str(path).lower().endswith(MODEL_EXTENSIONS)


def is_spec(path):
    return str(path).lower().endswith(SPEC_EXTENSION)


def under_model_root(path):
    return display_path(path).startswith(MODEL_ROOT + "/")


# --- Input --------------------------------------------------------------------


def resolve_inputs(paths):
    """Turn a mix of models and specs into the list of models to validate.

    A .spec.yaml resolves to the model it describes, so editing a spec checks the
    pair. That is what makes the Claude Code hook useful: writing a spec is the
    moment a typo'd key gets introduced, and it is the moment to catch it.

    Orphan specs -- a spec whose model does not exist -- are returned separately,
    because there is nothing to validate but plenty to report.
    """
    models = []
    orphans = []
    for path in paths:
        if is_excluded(path):
            continue
        if is_spec(path):
            model = path[: -len(SPEC_EXTENSION)]
            if os.path.exists(model):
                models.append(model)
            else:
                orphans.append(path)
        elif is_model(path):
            models.append(path)
    # Editing a model and its spec in one commit must not validate it twice.
    return list(dict.fromkeys(models)), orphans


def load_file_list(path):
    with open(path, "r", encoding="utf-8") as handle:
        return [line.strip() for line in handle if line.strip()]


def load_changed_files_json(path):
    """Read the JSON array tj-actions/changed-files writes.

    The escaped-payload check is not paranoia: this is how the audio validator
    broke twice. Without `safe_output: false` the action backslash-escapes the
    file it writes, and the result parses as JSON but yields paths that match
    nothing -- so the workflow goes green having validated zero files.
    """
    with open(path, "r", encoding="utf-8") as handle:
        raw = handle.read().strip()
    if not raw:
        return []

    try:
        entries = json.loads(raw)
    except json.JSONDecodeError as exc:
        raise SystemExit(
            f"{path} is not valid JSON ({exc}). The tj-actions/changed-files step "
            "must set `json: true`, `safe_output: false` and `write_output_files: true`."
        )

    if not isinstance(entries, list):
        raise SystemExit(f"{path} should contain a JSON array, got {type(entries).__name__}.")

    if any("\\" in entry for entry in entries if isinstance(entry, str)):
        raise SystemExit(
            f"{path} contains backslash-escaped paths, so no file will ever match. "
            "The tj-actions/changed-files step must set `safe_output: false`."
        )

    return [entry for entry in entries if isinstance(entry, str)]


def sweep_repository():
    """Every model in the repo, for `--all`."""
    found = []
    for root, dirs, files in os.walk(REPO_ROOT):
        dirs[:] = [d for d in dirs if d not in EXCLUDED_PATH_PARTS and not d.startswith(".")]
        for name in files:
            path = os.path.join(root, name)
            if (is_model(path) or is_spec(path)) and not is_excluded(path):
                found.append(path)
    return sorted(found)


# --- Checks -------------------------------------------------------------------


def check_filename(report, path):
    """Names under assets/3d/ follow the sm_/sk_ convention."""
    if not ENFORCE_FILENAME_CONVENTION:
        return
    name = os.path.basename(path)
    if not under_model_root(path):
        report.info("filename_convention", f"not under {MODEL_ROOT}/, so not enforced")
        return
    if MODEL_FILENAME_PATTERN.match(name) or SKELETAL_FILENAME_PATTERN.match(name):
        report.ok("filename_convention")
        return
    report.fail(
        "filename_convention",
        f"'{name}' should be sm_{{object}}.gltf for a static mesh or "
        f"sk_{{object}}.gltf for a skeletal one: lowercase, underscores only, "
        f"no hyphens, and .gltf rather than .glb",
    )


def check_godot_import(report, document, spec, gltf_godot_import):
    """Will this model still be right once Godot has imported it?

    Run against the raw glTF document rather than through the spec evaluator,
    because two of the three need per-node bounds and node names, and because only
    one of them is spec-driven. Kept out of evaluate_model_against_spec so the
    Docker renderer's verdict list stays exactly what it always was.
    """
    if not ENFORCE_GODOT_IMPORT:
        return

    surprises = gltf_godot_import.find_surprising_suffixes(
        document, spec.get("godot_node_suffixes_allowed") or ()
    )
    if surprises:
        for name, suffix, becomes in surprises:
            report.fail(
                "godot_node_suffixes",
                f"node '{name}' ends in '{suffix}', so Godot imports it as "
                f"{becomes}. Godot matches '_{suffix}' and '${suffix}' as well as "
                f"'-{suffix}', so an ordinary descriptive name can change a node's "
                "class. Rename the node, or list the suffix in the spec's "
                "godot_node_suffixes_allowed if that node type is the intent.",
            )
    else:
        report.ok("godot_node_suffixes")

    if spec.get("allow_oversized_collision", False):
        report.info("collision_within_visual", "opted out by the spec")
    else:
        overhang = gltf_godot_import.oversized_collision(document)
        if overhang:
            detail = "; ".join(
                f"{amount * 100:.1f}cm {side} the art on {axis}"
                for axis, side, amount in overhang
            )
            report.fail(
                "collision_within_visual",
                f"collision extends {detail}. The size checks measure the whole "
                "file, so this is what the model's width/height/depth become -- "
                "and the failure then points at a number no render shows.",
            )
        else:
            report.ok("collision_within_visual")

    if "rests_on_ground" in spec:
        offset = gltf_godot_import.ground_offset(document)
        if offset is None:
            report.fail("rests_on_ground", "the model's bounds could not be measured")
        elif not spec["rests_on_ground"]:
            report.ok("rests_on_ground", "not required")
        elif abs(offset) <= gltf_godot_import.GROUND_TOLERANCE:
            report.ok("rests_on_ground", f"lowest point Y={offset:+.4f}")
        else:
            direction = "below" if offset < 0 else "above"
            report.fail(
                "rests_on_ground",
                f"lowest point is Y={offset:+.4f}, {abs(offset) * 100:.1f}cm "
                f"{direction} the floor. Dropped into a level this model "
                f"{'sinks into' if offset < 0 else 'floats over'} every surface.",
            )


def validate_model(path, model_spec, gltf_document, gltf_measure, gltf_godot_import):
    report = ModelReport(path)

    if not os.path.exists(path):
        report.fail("file", "not found")
        return report

    check_filename(report, path)

    try:
        document = gltf_document.load_document(path)
        gltf = gltf_document.as_gltf(document)
    except Exception as exc:  # noqa: BLE001 -- an unreadable model is a finding
        report.fail("readable", f"{type(exc).__name__}: {exc}")
        return report

    if ENFORCE_EXTERNAL_RESOURCES:
        missing = model_spec.check_external_resources(gltf, path)
        if missing:
            report.fail(
                "external_resources",
                ", ".join(missing) + " -- referenced by the model but not on disk. "
                "A .gltf needs its .bin and its textures committed alongside it.",
            )
        else:
            report.ok("external_resources")

    measurement = gltf_measure.measure(document)
    for problem in measurement.problems:
        report.fail("geometry", problem)

    spec_path = model_spec.spec_path_for(path)
    spec = {}
    if os.path.exists(spec_path):
        try:
            spec = model_spec.read_spec_file(spec_path)
        except Exception as exc:  # noqa: BLE001 -- malformed YAML is a finding
            report.fail("spec_readable", f"{type(exc).__name__}: {exc}")
            return report

        if ENFORCE_SPEC_SCHEMA:
            problems = model_spec.validate_spec_schema(spec, spec_path)
            for problem in problems:
                report.fail("spec_schema", problem)
            if not problems:
                report.ok("spec_schema", os.path.basename(spec_path))
    elif ENFORCE_SPEC_REQUIRED:
        report.fail(
            "spec_present",
            f"no {os.path.basename(spec_path)}; every model needs acceptance criteria",
        )
    else:
        report.info(
            "spec_present",
            f"no {os.path.basename(spec_path)} -- the model passes by default. "
            "Add one to give it acceptance criteria.",
        )

    check_godot_import(report, document, spec, gltf_godot_import)

    results = model_spec.evaluate_model_against_spec(
        gltf=gltf,
        spec=spec,
        scene_bounds_size=measurement.size,
        poly_count=measurement.triangles,
    )
    for key, value in results.items():
        detail = describe(key, value, spec, measurement)
        if value == OK:
            report.ok(key, detail)
        elif model_spec.is_informational(value):
            report.info(key, value[len("INFO - ") :] if value.startswith("INFO - ") else value)
        else:
            report.fail(key, detail or value)

    return report


def describe(key, value, spec, measurement):
    """Put the measured number next to the verdict.

    "FAIL height" tells an artist nothing; "FAIL height 2.30 m (spec 1.80,
    +/-10%)" tells them how far out they are and which way to go.
    """
    axis = {"width": 0, "height": 1, "depth": 2}
    if key in axis and measurement.size is not None:
        measured = measurement.size[axis[key]]
        expected = spec.get(key)
        if expected is None:
            return f"{measured:.3f} m"
        return f"{measured:.3f} m  (spec {expected:g}, +/-10%)"
    if key == "poly_count_budget":
        instancing = (
            f"  ({measurement.unique_meshes} mesh(es), {measurement.instances} instance(s))"
        )
        return f"{measurement.triangles} <= {spec.get(key)}{instancing}"
    if key == "min_material_count":
        return f"minimum {spec.get(key)}"
    if value in (OK, FAIL):
        return ""
    return value


# --- Reporting ----------------------------------------------------------------


def report_all(reports, orphans):
    blocks = []
    for spec_path in orphans:
        model = spec_path[: -len(SPEC_EXTENSION)]
        blocks.append(
            f"{display_path(spec_path)}\n"
            f"  {FAIL:<5} orphan_spec  no model at {os.path.basename(model)}. "
            "A spec is named for the whole model filename, so sm_rain_barrel.gltf "
            "pairs with sm_rain_barrel.gltf.spec.yaml -- not sm_rain_barrel.spec.yaml."
        )
    blocks.extend(str(report) for report in reports)
    text = "\n\n".join(blocks)

    # Count failed *checks*, not failed files: a model with a wrong width and a
    # blown poly budget has two things to fix, and saying "1 failure" hides one.
    failures = sum(len(report.failures) for report in reports) + len(orphans)
    checked = len(reports) + len(orphans)
    noun = "file" if checked == 1 else "files"
    summary = f"{checked} {noun}, {failures} failure{'' if failures == 1 else 's'}"
    return (text + "\n\n" + summary).lstrip(), failures


def write_github_output(text, has_errors):
    """GITHUB_OUTPUT is only set inside GitHub Actions; skip it for local runs."""
    out_path = os.environ.get("GITHUB_OUTPUT")
    if not out_path or not os.path.exists(out_path):
        return
    with open(out_path, "a", encoding="utf-8") as handle:
        print("metadata<<EOF", file=handle)
        print(json.dumps({"model_reports": text}, indent=2), file=handle)
        print("EOF", file=handle)
        print(f"has_errors={'true' if has_errors else 'false'}", file=handle)


def main(paths):
    """Returns True when something failed, matching the other validators."""
    sys.path.insert(0, VALIDATOR_DIR)
    try:
        import gltf_document
        import gltf_godot_import
        import gltf_measure
        import model_spec
    except ImportError as exc:
        raise SystemExit(
            f"Could not import the model checks ({exc}).\n"
            "They need numpy and pyyaml: pip install numpy pyyaml jsonschema"
        )

    models, orphans = resolve_inputs(paths)
    if not ENFORCE_ORPHAN_SPEC:
        orphans = []

    if not models and not orphans:
        print("No 3D model files to validate.")
        return False

    reports = [
        validate_model(path, model_spec, gltf_document, gltf_measure, gltf_godot_import)
        for path in models
    ]
    text, failures = report_all(reports, orphans)
    print(text)
    write_github_output(text, bool(failures))
    return bool(failures)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(
        description="Validate 3D models against their .spec.yaml files."
    )
    parser.add_argument(
        "model_files",
        nargs="*",
        help="Model (.gltf/.glb) or spec (.spec.yaml) paths to validate",
    )
    parser.add_argument(
        "--file-list",
        metavar="FILE",
        help="File containing one path per line",
    )
    parser.add_argument(
        "--changed-files-json",
        metavar="FILE",
        help="JSON array of paths, as written by tj-actions/changed-files",
    )
    parser.add_argument(
        "--all",
        action="store_true",
        help="Validate every model in the repository",
    )
    args = parser.parse_args()

    model_files = list(args.model_files)
    if args.file_list:
        model_files.extend(load_file_list(args.file_list))
    if args.changed_files_json:
        model_files.extend(load_changed_files_json(args.changed_files_json))
    if args.all:
        model_files.extend(sweep_repository())

    if not model_files:
        print("No 3D model files to validate.")
        sys.exit(0)

    sys.exit(1 if main(model_files) else 0)
