#!/usr/bin/env python3
"""Tests for the CLI surface: pipeline_cli/cli.py and the command wiring.

Runs standalone (`python tools/pipeline/test_pipeline_cli.py`) like the sibling
test files, and also under pytest.

test_the_command_surface_is_exactly_this is the load-bearing one. The CLI, the
workflow that invokes it, and the docs that describe it are three copies of the
same list; that assertion is what makes a rename fail here rather than in CI, or
worse, in a contributor's terminal.
"""

from __future__ import annotations

import contextlib
import io
import sys
from pathlib import Path

from pipeline_cli import cli
from pipeline_cli.command import DOC_FLAGS, Command
from pipeline_cli.common import EXIT_CANNOT_RUN, EXIT_CHECK_FAILED

TOOLS_DIR = Path(__file__).resolve().parent

# The smallest invocation of each leaf that parses. Everything else is optional
# on purpose; these are the arguments a command cannot do its work without.
REQUIRED_ARGS = {
    ("issue", "create"): ["--template", "create_model"],
    ("issue", "update"): ["1"],
    ("backlog", "new"): ["--template", "create_model"],
}


def minimal(group: str, name: str) -> list[str]:
    return [group, name, *REQUIRED_ARGS.get((group, name), [])]


def parse(argv):
    return cli.build_parser().parse_args(argv)


def exit_code_of(argv) -> int:
    """argparse exits rather than returning, so catch it."""
    with contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()):
        try:
            cli.build_parser().parse_args(argv)
        except SystemExit as exc:
            return int(exc.code or 0)
    return 0


# --------------------------------------------------------------------------
# The surface


def test_the_command_surface_is_exactly_this():
    assert set(cli.leaves()) == {
        ("issue", "create"),
        ("issue", "update"),
        ("backlog", "new"),
        ("backlog", "file"),
        ("asset", "list"),
        ("render", "pipeline"),
        ("render", "issue-templates"),
        ("extract", "images"),
    }


def test_every_leaf_is_reachable_and_carries_its_command_object():
    for group, name in cli.leaves():
        args = parse(minimal(group, name))
        assert isinstance(args.command, Command), f"{group} {name} has no command object"
        assert args.command.name == name
        assert args.command_name == name


def test_every_command_declares_help_and_a_docstring():
    for group in cli.GROUPS:
        assert group.help, f"group {group.name} has no help"
        for cmd in group.commands:
            assert cmd.help, f"{group.name} {cmd.name} has no help"
            assert (cmd.__doc__ or "").strip(), f"{group.name} {cmd.name} has no docstring"


def test_help_lists_every_leaf_command():
    # Two levels of subparser hide the leaves from the top-level --help, so the
    # epilog is the only place they all appear. It is generated from GROUPS.
    epilog = cli.surface()
    for group, name in cli.leaves():
        assert f"{group} {name}" in epilog


def test_help_exits_zero_for_every_leaf():
    for group, name in cli.leaves():
        assert exit_code_of([group, name, "--help"]) == 0


# --------------------------------------------------------------------------
# Usage errors


def test_a_bare_invocation_is_a_usage_error():
    assert exit_code_of([]) == EXIT_CANNOT_RUN


def test_a_group_with_no_command_is_a_usage_error():
    assert exit_code_of(["render"]) == EXIT_CANNOT_RUN


def test_an_unknown_command_is_a_usage_error():
    assert exit_code_of(["render", "nonsense"]) == EXIT_CANNOT_RUN


# --------------------------------------------------------------------------
# Shared flags


def test_doc_defaults_to_the_pipeline_document_everywhere_it_appears():
    for group, name in cli.leaves():
        args = parse(minimal(group, name))
        if hasattr(args, "doc"):
            assert args.doc.name == "pipeline.yaml", f"{group} {name}"


def test_every_write_command_defaults_to_a_dry_run():
    # --apply is the only thing between a typo and a live board.
    for group, name in cli.leaves():
        args = parse(minimal(group, name))
        if hasattr(args, "apply"):
            assert args.apply is False, f"{group} {name} writes by default"


def test_shared_flags_come_from_one_parent_parser():
    # The same parser object, not two that happen to agree today. This is what
    # stops --doc drifting into meaning different things in different commands.
    render = [cmd for group in cli.GROUPS if group.name == "render" for cmd in group.commands]
    assert render
    assert all(DOC_FLAGS in cmd.parents for cmd in render)


# --------------------------------------------------------------------------
# Dispatch


def test_render_pipeline_check_fails_for_a_missing_target():
    with contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()):
        code = cli.main(
            ["render", "pipeline", "--check", "--out", str(TOOLS_DIR / "does_not_exist.md")]
        )
    assert code == EXIT_CHECK_FAILED


def test_render_pipeline_check_names_the_command_that_fixes_it():
    err = io.StringIO()
    with contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(err):
        cli.main(["render", "pipeline", "--check", "--out", str(TOOLS_DIR / "does_not_exist.md")])
    assert "pipeline.py render pipeline" in err.getvalue()


def test_an_unreadable_document_exits_cannot_run_rather_than_tracebacks():
    err = io.StringIO()
    with contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(err):
        code = cli.main(["render", "pipeline", "--doc", str(TOOLS_DIR / "no_such.yaml")])
    assert code == EXIT_CANNOT_RUN
    assert "no_such.yaml" in err.getvalue()


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
