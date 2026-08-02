#!/usr/bin/env python3
"""Tests for pipeline_cli/asset_list.py, the generated asset_list.tsv.

Runs standalone (`python tools/pipeline/test_asset_list.py`) like the sibling
test files, and also under pytest.

Offline throughout, replayed from test-fixtures/project_items.json. The golden
assertion is the point: this file is drift-checked with --check, so any change
to a column, a transform, or the row order has to be an intentional edit here
rather than a surprise in someone's diff.
"""

from __future__ import annotations

import contextlib
import io
import sys
import tempfile
from pathlib import Path

from pipeline_cli import asset_list, board, cli
from pipeline_cli.common import EXIT_CHECK_FAILED, EXIT_OK

TOOLS_DIR = Path(__file__).resolve().parent
REPO_ROOT = TOOLS_DIR.parents[1]
RECORDING = TOOLS_DIR / "test-fixtures" / "project_items.json"

BASE_ARGS = ["--from-json", str(RECORDING), "--repo-root", str(REPO_ROOT)]

GOLDEN = (
    "priority\tstatus\tname\tdescription\tfile_location\n"
    "\t\tlantern\tHanging lantern\tassets/art/3d/props/lantern/sm_lantern.gltf\n"
    "high\tdone\train_barrel\tCreate 3D model for rain_barrel\t"
    "assets/art/3d/props/rain_barrel/sm_rain_barrel.gltf\n"
    "\t\thamster\tImplement the hamster controller\tgame/hamster/hamster.gd\n"
    "\t\thamster\tImplement the hamster controller\tgame/hamster/hamster.tscn\n"
    "\t\tMarketStall\tCreate 3D model for market_stall\t"
    "assets/art/3d/structures/market_stall/sm_MarketStall.gltf\n"
)


def render() -> str:
    out = io.StringIO()
    with contextlib.redirect_stdout(out), contextlib.redirect_stderr(io.StringIO()):
        code = cli.main(["asset", "list", *BASE_ARGS, "--format", "tsv"])
    assert code == EXIT_OK, f"exit {code}"
    return out.getvalue()


def load_rows():
    client = board.RecordedClient.from_file(RECORDING)
    pages = board.fetch_pages(client, "Screwloose-Games", 38, 100)
    items = board.build_items(pages)
    return board.build_rows(items, board.Conventions(), REPO_ROOT, "")


# --------------------------------------------------------------------------
# The generated content


def test_the_tsv_is_exactly_this():
    assert render() == GOLDEN


def test_the_header_names_the_columns_in_order():
    assert render().splitlines()[0].split("\t") == list(asset_list.COLUMNS)


def test_rendering_twice_is_byte_identical():
    # --check compares text, so anything order-dependent would make the file
    # drift against a board that had not changed.
    assert render() == render()


def test_rows_without_a_usable_path_are_excluded():
    rows = load_rows()
    kept = asset_list.rows_for_list(rows)
    assert len(kept) < len(rows), "the fixture is meant to contain unusable rows"
    assert all(row.asset_path.path for row in kept)
    # The blank, {placeholder} and prose rows belong to the text report.
    assert not any("{" in line for line in render().splitlines())


def test_status_is_board_derived_not_delivery_derived():
    # on_disk depends on the working tree; if it leaked into this column the
    # file would drift on every git checkout.
    text = render()
    assert "\tdone\t" in text
    for marker in ("on_disk", "delivered_by", "missing", "present"):
        assert marker not in text


def test_no_cell_can_contain_a_tab_or_newline():
    for line in render().splitlines():
        assert len(line.split("\t")) == len(asset_list.COLUMNS)


# --------------------------------------------------------------------------
# --write / --check


def test_check_reports_drift_and_names_the_fix():
    with tempfile.TemporaryDirectory() as tmp:
        stale = Path(tmp) / "asset_list.tsv"
        stale.write_text("priority\tstatus\tname\tdescription\tfile_location\n", encoding="utf-8")
        err = io.StringIO()
        with contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(err):
            code = cli.main(["asset", "list", *BASE_ARGS, "--check", "--out", str(stale)])
        assert code == EXIT_CHECK_FAILED
        assert "asset list --write" in err.getvalue()
        assert stale.read_text(encoding="utf-8").splitlines() == [
            "priority\tstatus\tname\tdescription\tfile_location"
        ], "--check must not write"


def test_write_produces_a_file_that_then_checks_clean():
    with tempfile.TemporaryDirectory() as tmp:
        target = Path(tmp) / "asset_list.tsv"
        with contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()):
            assert cli.main(["asset", "list", *BASE_ARGS, "--write", "--out", str(target)]) == 0
            assert cli.main(["asset", "list", *BASE_ARGS, "--check", "--out", str(target)]) == 0
        assert target.read_text(encoding="utf-8") == GOLDEN


def test_a_contradictory_format_is_refused_before_the_board_is_read():
    err = io.StringIO()
    with contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(err):
        code = cli.main(["asset", "list", *BASE_ARGS, "--format", "json", "--write"])
    assert code == 2
    assert "TSV" in err.getvalue()


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
