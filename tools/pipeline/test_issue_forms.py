#!/usr/bin/env python3
"""Tests for pipeline_cli/issue_forms.py.

Runs standalone (`python tools/pipeline/test_issue_forms.py`) like the sibling
test files, and also under pytest.

These parse the real templates in .github/ISSUE_TEMPLATE/, the same way
test_asset_report.py reads the real pipeline.yaml. That is deliberate: the point
of failure this guards is a template being edited into a shape the CLI can no
longer read, and a synthetic fixture would never notice.

test-fixtures/issue_form_minimal.yaml covers the edge cases that should not
require editing a template artists depend on.
"""

from __future__ import annotations

import sys
from pathlib import Path

from pipeline_cli import issue_forms
from pipeline_cli.common import DocumentError

TOOLS_DIR = Path(__file__).resolve().parent
FIXTURES = TOOLS_DIR / "test-fixtures"


def expect_error(call, *fragments):
    try:
        call()
    except DocumentError as exc:
        for fragment in fragments:
            assert fragment in str(exc), f"{fragment!r} not in {exc}"
        return
    raise AssertionError("expected DocumentError")


# --------------------------------------------------------------------------
# Parsing the real templates


def test_every_template_in_the_repo_parses():
    for slug in issue_forms.available_slugs():
        form = issue_forms.load_form(slug)
        assert form.slug == slug
        assert form.fields, f"{slug} has no fields"


def test_field_order_follows_the_template():
    form = issue_forms.load_form("create_model")
    ids = [entry.id for entry in form.fields if entry.collects_input]
    assert ids == ["description", "reference-images", "dimentions", "file_path", "subtasks"]


def test_an_id_nested_under_attributes_is_still_found():
    # create_model.yaml and create_implementation.yaml both put `id:` under
    # `attributes:` on their Subtasks field. GitHub tolerates it because it
    # renders headings from `label`. Reading only the top-level key would drop
    # exactly the field carrying the generated checklist.
    for slug in ("create_model", "create_implementation"):
        form = issue_forms.load_form(slug)
        assert form.field("subtasks") is not None, slug


def test_markdown_fields_are_prose_not_answers():
    form = issue_forms.load_form("create_model")
    prose = [entry for entry in form.fields if not entry.collects_input]
    assert prose and all(entry.type == "markdown" for entry in prose)


def test_labels_come_from_the_template():
    assert issue_forms.load_form("create_model").labels == ("3d model",)


def test_both_yaml_and_yml_resolve():
    # Every template is .yaml except bug_report.yml.
    assert issue_forms.load_form("bug_report").path.suffix == ".yml"
    assert issue_forms.load_form("create_model").path.suffix == ".yaml"


def test_an_unknown_slug_lists_what_does_exist():
    expect_error(
        lambda: issue_forms.load_form("no_such_template"), "no_such_template", "create_model"
    )


# --------------------------------------------------------------------------
# The path field


def test_the_path_field_is_found_by_id():
    assert issue_forms.load_form("create_model").path_field().id == "file_path"


def test_the_path_field_is_found_by_label_when_the_id_does_not_say_so():
    # create_implementation.yaml calls it `context`, labelled "File Location".
    found = issue_forms.load_form("create_implementation").path_field()
    assert found.id == "context"
    assert found.label == "File Location"


# --------------------------------------------------------------------------
# Titles


def test_the_title_placeholder_is_filled_with_the_name():
    form = issue_forms.load_form("create_model")
    assert issue_forms.render_title(form, "rain barrel") == "Create 3D model for rain barrel"


def test_an_explicit_title_wins():
    form = issue_forms.load_form("create_model")
    assert issue_forms.render_title(form, "ignored", "My title") == "My title"


def test_an_unfilled_title_placeholder_is_refused():
    # "Create 3D model for {game object name}" on a live board is exactly the
    # garbage the asset report exists to detect.
    form = issue_forms.load_form("create_model")
    expect_error(lambda: issue_forms.render_title(form, None), "{game object name}", "--name")


# --------------------------------------------------------------------------
# Bodies


def body(slug: str, **values) -> str:
    return issue_forms.render_body(issue_forms.load_form(slug), values)


def test_the_body_uses_github_s_own_submitted_form_shape():
    text = body(
        "create_model",
        description="A crate.",
        dimentions="1m",
        file_path="assets/art/3d/props/crate/sm_crate.gltf",
    )
    assert "### Description\n\nA crate." in text
    assert "### Save File Path\n\nassets/art/3d/props/crate/sm_crate.gltf" in text


def test_an_optional_field_with_no_answer_reads_as_no_response():
    text = body("create_model", description="A crate.", dimentions="1m", file_path="a/b/sm_c.gltf")
    assert "### Reference Images\n\n_No response_" in text


def test_the_generated_subtasks_block_reaches_the_body_intact():
    # This is why template defaults are carried through at all.
    text = body("create_model", description="A crate.", dimentions="1m", file_path="a/b/sm_c.gltf")
    assert "<!-- pipeline:subtasks:start -->" in text
    assert "<!-- pipeline:subtasks:end -->" in text
    assert "- [ ] The model faces +Y in Blender." in text


def test_a_required_field_left_on_its_example_default_is_refused():
    # create_model.yaml's Description defaults to "This hamster is a
    # cheerfull..." -- filing that verbatim would say nothing.
    expect_error(lambda: body("create_model"), "Description", "example text")


def test_the_refusal_names_the_flag_that_fixes_it():
    expect_error(lambda: body("create_model"), "--field description=")


def test_a_checklist_default_counts_as_an_answer():
    # Subtasks is required and is never supplied by hand; its default is boxes
    # to tick, not an example to replace.
    text = body("create_model", description="A crate.", dimentions="1m", file_path="a/b/sm_c.gltf")
    assert "### Subtasks" in text
    assert issue_forms.is_checklist("- [ ] a box")
    assert not issue_forms.is_checklist("some prose")


def test_markdown_fields_are_not_rendered_as_headings():
    text = body("create_model", description="A crate.", dimentions="1m", file_path="a/b/sm_c.gltf")
    assert "## File Path Standards" not in text


# --------------------------------------------------------------------------
# The synthetic fixture


def test_a_field_with_no_id_falls_back_to_its_label():
    form = issue_forms.load_form(str(FIXTURES / "issue_form_minimal.yaml"))
    assert form.field("no_id_here") is not None


def test_a_form_with_no_path_field_reports_none():
    form = issue_forms.load_form(str(FIXTURES / "issue_form_minimal.yaml"))
    assert form.path_field() is None


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
