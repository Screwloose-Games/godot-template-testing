#!/usr/bin/env python3
"""Tests for pipeline_cli/common.py.

Runs standalone (`python tools/pipeline/test_common.py`) like the sibling test
files, and also under pytest.

The weight here is on sync_text_file, because every generated file in the repo
now goes through it: PIPELINE.md, the issue-template blocks, the extracted
images, and asset_list.tsv. Its four states -- write, up to date, stale, missing
-- are the whole of what `--check` means, so they are tested directly rather than
through a renderer.

No pytest fixtures are used anywhere: the standalone runner calls each test with
no arguments, so a `tmp_path` parameter would break it.
"""

from __future__ import annotations

import contextlib
import io
import sys
import tempfile
from pathlib import Path

from pipeline_cli import common


def _capture(call) -> tuple[int, str, str]:
    """Run a call, returning (result, stdout, stderr)."""
    out, err = io.StringIO(), io.StringIO()
    with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
        result = call()
    return result, out.getvalue(), err.getvalue()


# --------------------------------------------------------------------------
# Paths


def test_repo_root_is_the_checkout():
    # parents[3] is one level deeper than the scripts this package replaced.
    # If it is wrong, every default path in the CLI is wrong together.
    assert (common.REPO_ROOT / "documentation" / "pipeline" / "pipeline.yaml").is_file()
    assert (common.REPO_ROOT / "CLAUDE.md").is_file()


def test_the_derived_paths_point_at_real_files():
    assert common.DOC_PATH.is_file()
    assert common.PIPELINE_MD_PATH.is_file()
    assert common.ISSUE_TEMPLATE_DIR.is_dir()
    assert common.SVG_PATH.is_file()


def test_relative_is_repo_relative_posix():
    assert common.relative(common.DOC_PATH) == "documentation/pipeline/pipeline.yaml"


def test_relative_falls_back_for_a_path_outside_the_repo():
    # Path.relative_to raises here, which used to surface as a bare traceback
    # from `render_pipeline.py --out` pointing anywhere but the checkout.
    outside = Path(tempfile.gettempdir()).resolve() / "somewhere.md"
    assert common.relative(outside) == str(outside)


# --------------------------------------------------------------------------
# YAML


def test_load_doc_reads_the_pipeline_document():
    doc = common.load_doc(common.DOC_PATH)
    assert doc["schema_version"] == 1
    assert doc["pipelines"]


def test_load_doc_names_the_path_when_the_file_is_missing():
    with tempfile.TemporaryDirectory() as tmp:
        missing = Path(tmp) / "nope.yaml"
        try:
            common.load_doc(missing)
        except common.DocumentError as exc:
            assert "nope.yaml" in str(exc)
        else:
            raise AssertionError("expected DocumentError")


def test_load_doc_rejects_a_document_that_is_not_a_mapping():
    with tempfile.TemporaryDirectory() as tmp:
        path = Path(tmp) / "list.yaml"
        path.write_text("- one\n- two\n", encoding="utf-8")
        try:
            common.load_doc(path)
        except common.DocumentError as exc:
            assert "mapping" in str(exc)
        else:
            raise AssertionError("expected DocumentError")


def test_parse_yaml_raises_document_error_not_a_yaml_error():
    try:
        common.parse_yaml("a: [1, 2\n", source="broken.yaml")
    except common.DocumentError as exc:
        assert "broken.yaml" in str(exc)
    else:
        raise AssertionError("expected DocumentError")


def test_is_valid_yaml_reports_both_ways():
    assert common.is_valid_yaml("a: 1\n") == (True, "")
    ok, detail = common.is_valid_yaml("a: [1, 2\n")
    assert not ok and detail


# --------------------------------------------------------------------------
# Cells


def test_md_cell_collapses_whitespace_and_escapes_pipes():
    assert common.md_cell("a |  b\nc") == "a \\| b c"


def test_md_cell_empty_default_differs_from_the_placeholder_form():
    # The renderer wants a blank cell; the asset report wants a dash. Both
    # behaviours existed as separate functions before.
    assert common.md_cell("") == ""
    assert common.md_cell("", empty="-") == "-"


def test_tsv_cell_removes_tabs_and_newlines():
    assert common.tsv_cell("a\tb\nc  d") == "a b c d"


# --------------------------------------------------------------------------
# sync_text_file


def test_sync_text_file_writes_and_reports():
    with tempfile.TemporaryDirectory() as tmp:
        path = Path(tmp) / "nested" / "out.md"
        code, out, _ = _capture(
            lambda: common.sync_text_file(path, "one\ntwo\n", check=False, fix_command="fix me")
        )
        assert code == common.EXIT_OK
        assert path.read_text(encoding="utf-8") == "one\ntwo\n"
        assert "2 lines" in out


def test_sync_text_file_writes_lf_even_on_windows():
    # The two renderers this replaced omitted newline="\n", which is why
    # PIPELINE.md is CRLF on disk while the templates beside it are LF.
    with tempfile.TemporaryDirectory() as tmp:
        path = Path(tmp) / "out.md"
        _capture(lambda: common.sync_text_file(path, "one\ntwo\n", check=False, fix_command="x"))
        assert b"\r\n" not in path.read_bytes()


def test_sync_text_file_check_passes_when_current():
    with tempfile.TemporaryDirectory() as tmp:
        path = Path(tmp) / "out.md"
        path.write_text("one\n", encoding="utf-8", newline="\n")
        code, out, _ = _capture(
            lambda: common.sync_text_file(path, "one\n", check=True, fix_command="fix me")
        )
        assert code == common.EXIT_OK
        assert "up to date" in out


def test_sync_text_file_check_tolerates_crlf_on_disk():
    # A Windows checkout has CRLF in the working tree under .gitattributes'
    # eol=lf. Comparing bytes would fail --check for every Windows contributor
    # while the committed file was fine.
    with tempfile.TemporaryDirectory() as tmp:
        path = Path(tmp) / "out.md"
        path.write_bytes(b"one\r\ntwo\r\n")
        code, _, _ = _capture(
            lambda: common.sync_text_file(path, "one\ntwo\n", check=True, fix_command="x")
        )
        assert code == common.EXIT_OK


def test_sync_text_file_check_fails_when_stale_and_names_the_fix():
    with tempfile.TemporaryDirectory() as tmp:
        path = Path(tmp) / "out.md"
        path.write_text("old\n", encoding="utf-8", newline="\n")
        code, _, err = _capture(
            lambda: common.sync_text_file(path, "new\n", check=True, fix_command="run this")
        )
        assert code == common.EXIT_CHECK_FAILED
        assert "out of date" in err
        assert "run this" in err
        assert path.read_text(encoding="utf-8") == "old\n", "--check must not write"


def test_sync_text_file_check_fails_when_missing():
    with tempfile.TemporaryDirectory() as tmp:
        path = Path(tmp) / "out.md"
        code, _, err = _capture(
            lambda: common.sync_text_file(path, "new\n", check=True, fix_command="run this")
        )
        assert code == common.EXIT_CHECK_FAILED
        assert "does not exist" in err
        assert "run this" in err
        assert not path.exists()


# --------------------------------------------------------------------------
# sync_binary_file


def test_sync_binary_file_writes_then_reports_ok():
    with tempfile.TemporaryDirectory() as tmp:
        path = Path(tmp) / "img.png"
        assert common.sync_binary_file(path, b"payload", check=False) == "written"
        assert common.sync_binary_file(path, b"payload", check=False) == "ok"


def test_sync_binary_file_check_distinguishes_missing_from_differs():
    with tempfile.TemporaryDirectory() as tmp:
        path = Path(tmp) / "img.png"
        assert common.sync_binary_file(path, b"payload", check=True) == "missing"
        path.write_bytes(b"stale")
        assert common.sync_binary_file(path, b"payload", check=True) == "differs"
        assert path.read_bytes() == b"stale", "--check must not write"


# --------------------------------------------------------------------------
# Errors


def test_fail_prints_the_message_and_the_remediation():
    _, _, err = _capture(lambda: common.fail("it broke", "Run: the fix"))
    assert "ERROR: it broke" in err
    assert "Run: the fix" in err


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
