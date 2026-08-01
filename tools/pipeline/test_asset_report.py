#!/usr/bin/env python3
"""Tests for asset_report.py.

Runs standalone (`python tools/pipeline/test_asset_report.py`) like the sibling
test files, and also under pytest.

Every test here is offline. The board is served from
test-fixtures/project_items.json, a recording in exactly the shape --dump-json
writes, so re-recording it against the live board is one command and the tests
never depend on the network, a token, or the state of the project.

The negative cases carry the weight: a blank filepath column, a column still
holding a {placeholder} template, and prose typed in place of a path are all
things the real board produces, and all things that must not read as a
delivered asset.
"""

from __future__ import annotations

import contextlib
import importlib.util
import io
import json
import sys
from pathlib import Path

import yaml

TOOLS_DIR = Path(__file__).resolve().parent
REPO_ROOT = TOOLS_DIR.parents[1]
FIXTURES = TOOLS_DIR / "test-fixtures"
RECORDING = FIXTURES / "project_items.json"
DOC_PATH = REPO_ROOT / "documentation" / "pipeline" / "pipeline.yaml"


def _load_module():
    path = TOOLS_DIR / "asset_report.py"
    spec = importlib.util.spec_from_file_location("asset_report", path)
    module = importlib.util.module_from_spec(spec)
    # Registering before exec matters: @dataclass resolves annotations through
    # sys.modules, and without this the import fails with a bare AttributeError.
    sys.modules["asset_report"] = module
    spec.loader.exec_module(module)
    return module


report = _load_module()


def load_conventions():
    return report.load_conventions(yaml.safe_load(DOC_PATH.read_text(encoding="utf-8")))


def load_items():
    client = report.RecordedClient.from_file(RECORDING)
    pages = report.fetch_pages(client, "Screwloose-Games", 38, 100)
    return report.build_items(pages)


def item_by_number(items, number):
    return next(item for item in items if item.number == number)


def run_cli(argv) -> str:
    buffer = io.StringIO()
    with contextlib.redirect_stdout(buffer), contextlib.redirect_stderr(io.StringIO()):
        code = report.main(argv)
    assert code == 0, f"exit {code}"
    return buffer.getvalue()


BASE_ARGS = ["--from-json", str(RECORDING), "--repo-root", str(REPO_ROOT)]


# --------------------------------------------------------------------------
# Reading the filepath column


def test_filepath_column_is_read():
    item = item_by_number(load_items(), 5)
    assert item.paths[0].path == "assets/art/3d/props/rain_barrel/sm_rain_barrel.gltf"
    assert item.paths[0].status == "ok"


def test_blank_column_is_reported_not_crashed():
    """The common case on a young board: the issue exists, the column is empty."""
    item = item_by_number(load_items(), 2)
    assert item.paths[0].status == "empty"
    assert item.paths[0].path == ""


def test_placeholder_template_is_not_reported_as_a_path():
    """The issue templates ship {placeholder} defaults that get pasted in."""
    item = item_by_number(load_items(), 7)
    assert item.paths[0].status == "placeholder"
    assert item.paths[0].path == ""


def test_prose_instead_of_a_path_is_unparseable():
    item = item_by_number(load_items(), 9)
    assert item.paths[0].status == "unparseable"
    assert item.paths[0].raw == "not sure yet, ask Meg"


def test_column_may_hold_several_paths():
    item = item_by_number(load_items(), 11)
    assert [path.path for path in item.paths] == [
        "game/hamster/hamster.gd",
        "game/hamster/hamster.tscn",
    ]


def test_backticked_and_res_prefixed_paths_normalise():
    assert report.clean_path_value("  `res://assets/art/3d/a/b/sm_b.gltf`  ")[0].path == (
        "assets/art/3d/a/b/sm_b.gltf"
    )
    assert report.clean_path_value("./game/a/b.png")[0].path == "game/a/b.png"


def test_windows_backslashes_normalise():
    cleaned = report.clean_path_value("assets\\art\\3d\\props\\barrel\\sm_barrel.gltf")[0]
    assert cleaned.path == "assets/art/3d/props/barrel/sm_barrel.gltf"
    assert cleaned.status == "ok"


def test_field_name_is_matched_case_insensitively():
    """The field is renameable from the org settings and the project UI."""
    assert report.board_path_value({"FilePath": "a/b.gltf"}, path_field="filepath") == "a/b.gltf"
    assert report.board_path_value({"other": "x"}, path_field="filepath") is None
    assert report.board_path_value({"filepath": "a/b.gltf"}, path_field="") is None


def test_issue_field_wins_over_a_project_column_of_the_same_name():
    """filepath is an org issue field; the board column is a projection of it."""
    issue_fields = {"filepath": "assets/art/3d/a/b/sm_b.gltf"}
    project_fields = {"filepath": "stale/project/column.gltf"}
    assert report.board_path_value(
        issue_fields, project_fields, path_field="filepath"
    ) == "assets/art/3d/a/b/sm_b.gltf"


def test_project_column_is_used_when_the_issue_field_is_absent():
    """Boards configured the other way round still work."""
    item = item_by_number(load_items(), 3)
    assert item.paths[0].path == "assets/art/3d/structures/market_stall/sm_MarketStall.gltf"


def test_blank_value_falls_through_to_the_next_source():
    assert report.board_path_value(
        {"filepath": "   "}, {"filepath": "a/b.gltf"}, path_field="filepath"
    ) == "a/b.gltf"


def test_only_title_set_means_no_path():
    """Exactly the live board's shape: Title is the only project text value."""
    fields = {"Title": "Create 3D model for x"}
    assert report.board_path_value(fields, path_field="filepath") is None


# --------------------------------------------------------------------------
# Naming rules, read from pipeline.yaml


def test_conforming_path_is_ok():
    status, detail = report.check_path(
        "assets/art/3d/props/rain_barrel/sm_rain_barrel.gltf", load_conventions()
    )
    assert status == "ok", detail


def test_naming_violation_is_reported_against_pipeline_yaml_pattern():
    status, detail = report.check_path(
        "assets/art/3d/props/rain_barrel/sm_RainBarrel.gltf", load_conventions()
    )
    assert status == "nonstandard"
    assert "static_mesh_gltf" in detail
    # The warning quotes the live regex, so it fails if the doc and tool disagree.
    assert "^sm_" in detail


def test_deprecated_alias_does_not_swallow_a_real_violation():
    """`{object}.gltf` must expand to the naming grammar, not to `anything`.

    Expanding it to [^/]+ makes every malformed .gltf look merely deprecated.
    """
    conventions = load_conventions()
    assert report.check_path("game/hamster/hamster.gltf", conventions)[0] == "deprecated"
    assert report.check_path("assets/art/3d/a/b/sm_RainBarrel.gltf", conventions)[0] == "nonstandard"


def test_right_name_in_the_wrong_directory_is_reported():
    status, detail = report.check_path("wrong/place/sm_rain_barrel.gltf", load_conventions())
    assert status == "nonstandard"
    assert "assets/art/3d" in detail


def test_extension_with_no_pattern_is_not_warned_about():
    """Silence beats a false alarm: the gate at PR time is still the authority."""
    conventions = load_conventions()
    assert report.check_path("game/hamster/hamster.aseprite", conventions)[0] == "unchecked"
    assert report.check_path("game/hamster/sfx/", conventions)[0] == "unchecked"
    assert report.check_path("", conventions)[0] == "unchecked"


def test_path_outside_the_governed_directories_is_not_warned_about():
    """A .tscn under game/ is application code, not a model container scene.

    .tscn maps to three 3D naming patterns, all of which live under assets/art/3d,
    prefabs/ or levels/. Telling the author of game/hamster/hamster.tscn that it
    should have been called sm_hamster.tscn is worse than saying nothing.
    """
    conventions = load_conventions()
    assert report.check_path("game/hamster/hamster.tscn", conventions)[0] == "unchecked"
    assert report.check_path("prefabs/structures/prefab_bed.tscn", conventions)[0] == "ok"
    assert report.check_path("levels/level_main.tscn", conventions)[0] == "ok"


def test_loose_2d_pattern_does_not_accept_a_bad_model_name():
    """The 2D and audio pipelines declare `^[a-z0-9_]+\\.[a-z0-9]+$`-ish patterns.

    Without scoping candidates by extension those would accept any lowercase
    filename, including a .gltf that is missing its sm_ prefix.
    """
    assert report.check_path("assets/art/3d/a/b/rainbarrel.gltf", load_conventions())[0] != "ok"


# --------------------------------------------------------------------------
# Board items


def test_pagination_follows_end_cursor():
    client = report.RecordedClient.from_file(RECORDING)
    pages = report.fetch_pages(client, "Screwloose-Games", 38, 100)
    assert len(pages) == 2
    assert client.calls == 2


def test_draft_with_a_filepath_is_a_tracked_asset():
    """A draft carries the column just as an issue does, so it gets a row."""
    items = load_items()
    draft = next(item for item in items if item.title == "Hanging lantern")
    assert not draft.skip_reason
    assert draft.paths[0].path == "assets/art/3d/props/lantern/sm_lantern.gltf"


def test_draft_without_a_filepath_reports_no_path():
    items = load_items()
    draft = next(item for item in items if item.title.startswith("Define and Align"))
    assert draft.paths[0].status == "empty"


def test_pull_request_board_item_does_not_crash():
    items = load_items()
    pull = next(item for item in items if item.item_type == "PULL_REQUEST")
    assert pull.number == 40
    assert pull.paths[0].status == "empty"


def test_board_and_issue_field_values_are_flattened_separately():
    item = item_by_number(load_items(), 5)
    assert item.fields["Status"] == "Done"
    assert item.issue_fields["filepath"] == "assets/art/3d/props/rain_barrel/sm_rain_barrel.gltf"
    assert item.issue_fields["Priority"] == "High"


def test_linked_prs_keep_their_provenance():
    items = load_items()
    assert item_by_number(items, 5).linked_prs[0].provenance == "closes"
    assert item_by_number(items, 11).linked_prs[0].provenance == "mentions"


# --------------------------------------------------------------------------
# Delivery


def test_pr_delivers_matches_the_parent_directory():
    """A PR that adds the whole asset directory delivered the asset in it."""
    files = [
        "assets/art/3d/props/rain_barrel/sm_rain_barrel.bin",
        "assets/art/3d/props/rain_barrel/t_rain_barrel_basecolor.png",
    ]
    assert report.pr_delivers("assets/art/3d/props/rain_barrel/sm_rain_barrel.gltf", files)


def test_pr_that_touches_nothing_relevant_does_not_deliver():
    assert not report.pr_delivers("assets/art/3d/props/barrel/sm_barrel.gltf", ["README.md"])
    assert not report.pr_delivers("", ["README.md"])


def test_sibling_directory_does_not_count_as_delivery():
    assert not report.pr_delivers(
        "assets/art/3d/props/barrel/sm_barrel.gltf",
        ["assets/art/3d/props/barrel_lid/sm_barrel_lid.gltf"],
    )


def test_on_disk_is_na_for_items_from_another_repo():
    """An org board spans repos; the local tree only speaks for one of them."""
    rows = report.build_rows(
        load_items(), load_conventions(), REPO_ROOT, "Screwloose-Games/back-in-the-game-jam"
    )
    other = next(row for row in rows if row.item.repo == "Screwloose-Games/some-other-repo")
    assert other.on_disk == "n/a"


def test_on_disk_detects_a_file_that_exists():
    assert report.check_on_disk("documentation/pipeline/pipeline.yaml", REPO_ROOT) == "yes"
    assert report.check_on_disk("documentation/pipeline/nope.yaml", REPO_ROOT) == "no"
    assert report.check_on_disk("", REPO_ROOT) == "n/a"


def test_recorded_client_serves_pr_files_by_number():
    client = report.RecordedClient.from_file(RECORDING)
    data = client.execute(
        report.build_pr_files_query([14]),
        {"owner": "Screwloose-Games", "name": "back-in-the-game-jam"},
    )
    paths = [node["path"] for node in data["repository"]["pr0"]["files"]["nodes"]]
    assert "assets/art/3d/props/rain_barrel/sm_rain_barrel.gltf" in paths


def test_delivered_by_is_populated_from_the_linked_pr():
    items = load_items()
    prs = [pr for item in items for pr in item.linked_prs]
    report.load_pr_files(report.RecordedClient.from_file(RECORDING), prs, {}, [])
    rows = report.build_rows(items, load_conventions(), REPO_ROOT, "")
    assert next(row for row in rows if row.item.number == 5).delivered_by == ["#14 (merged)"]


def test_open_pr_is_reported_as_open_not_merged():
    items = load_items()
    prs = [pr for item in items for pr in item.linked_prs]
    report.load_pr_files(report.RecordedClient.from_file(RECORDING), prs, {}, [])
    rows = report.build_rows(items, load_conventions(), REPO_ROOT, "")
    row = next(r for r in rows if r.item.number == 11 and r.asset_path.path.endswith(".gd"))
    assert row.delivered_by == ["#21 (open)"]


def test_pr_file_lookups_are_cached_between_runs():
    items = load_items()
    prs = [pr for item in items for pr in item.linked_prs]
    cache: dict = {}
    report.load_pr_files(report.RecordedClient.from_file(RECORDING), prs, cache, [])
    assert cache

    for pr in prs:
        pr.files = None
    second = report.RecordedClient.from_file(RECORDING)
    report.load_pr_files(second, prs, cache, [])
    assert second.pr_calls == 0, "a cached PR was fetched again"


# --------------------------------------------------------------------------
# Errors


def test_insufficient_scopes_error_names_the_exact_fix():
    message = report.explain_transport_error(
        "Your token has not been granted the required scopes ... ['read:project']"
    )
    assert "gh auth refresh" in message
    assert "read:project" in message


def test_saml_error_is_distinguished_from_a_scope_error():
    message = report.explain_transport_error("Resource protected by organization SAML enforcement")
    assert "gh auth login" in message
    assert "read:project" not in message


def test_degraded_query_drops_the_closed_by_block():
    assert "closedByPullRequestsReferences" in report.PROJECT_QUERY
    assert "closedByPullRequestsReferences" not in report.PROJECT_QUERY_NO_CLOSED_BY
    assert "timelineItems" in report.PROJECT_QUERY_NO_CLOSED_BY


def test_recording_that_runs_out_of_pages_raises_transport_error():
    client = report.RecordedClient([])
    try:
        client.execute(report.PROJECT_QUERY, {})
    except report.TransportError:
        return
    raise AssertionError("an exhausted recording should raise TransportError")


def test_missing_recording_exits_cannot_run():
    with contextlib.redirect_stderr(io.StringIO()):
        code = report.main(["--from-json", str(FIXTURES / "does_not_exist.json")])
    assert code == report.EXIT_CANNOT_RUN


# --------------------------------------------------------------------------
# Rendering


def test_render_is_deterministic_from_recorded_json():
    assert run_cli(BASE_ARGS + ["--format", "json"]) == run_cli(BASE_ARGS + ["--format", "json"])


def test_json_output_exposes_file_path_for_jq():
    payload = json.loads(run_cli(BASE_ARGS + ["--format", "json"]))
    paths = [item["file_path"] for item in payload["items"] if item["file_path"]]
    assert "assets/art/3d/props/rain_barrel/sm_rain_barrel.gltf" in paths
    assert payload["context"]["path_field"] == "filepath"


def test_json_output_keeps_delivery_signals_separate():
    payload = json.loads(run_cli(BASE_ARGS + ["--format", "json"]))
    entry = next(item for item in payload["items"] if item["number"] == 5)
    assert entry["delivered_by"] == ["#14 (merged)"]
    assert "on_disk" in entry
    assert entry["path_status"] == "ok"


def test_markdown_cells_never_break_the_table():
    text = run_cli(BASE_ARGS + ["--format", "markdown"])
    rows = [line for line in text.splitlines() if line.startswith("|")]
    widths = {line.count("|") for line in rows}
    assert len(widths) == 1, f"ragged markdown table: {widths}"
    assert report._md_cell("a | b\nc") == "a \\| b c"


def test_text_report_names_the_unusable_items():
    text = run_cli(BASE_ARGS)
    assert "NO PATH" in text
    assert "PLACEHOLDER" in text
    assert "UNPARSEABLE" in text


def test_every_board_item_appears_in_the_report():
    payload = json.loads(run_cli(BASE_ARGS + ["--format", "json"]))
    # 9 board items, but #11 declares two paths and gets a row each.
    assert len(payload["items"]) == 10


def test_with_paths_hides_the_rows_that_have_none():
    payload = json.loads(run_cli(BASE_ARGS + ["--format", "json", "--with-paths"]))
    assert payload["items"], "everything was filtered out"
    assert all(item["file_path"] for item in payload["items"])
    assert any("--with-paths hid" in note for note in payload["notes"])


def test_no_pr_files_flag_skips_delivery_lookups():
    payload = json.loads(run_cli(BASE_ARGS + ["--format", "json", "--no-pr-files"]))
    assert all(not item["delivered_by"] for item in payload["items"])
    assert any("--no-pr-files" in note for note in payload["notes"])


def test_unknown_board_column_degrades_with_a_note():
    payload = json.loads(
        run_cli(BASE_ARGS + ["--format", "json", "--path-field", "Nonexistent"])
    )
    assert any("Nonexistent" in note for note in payload["notes"])
    assert all(not item["file_path"] for item in payload["items"])


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
