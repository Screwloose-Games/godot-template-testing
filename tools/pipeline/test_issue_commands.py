#!/usr/bin/env python3
"""Tests for `pipeline.py issue create` and `issue update`.

Runs standalone (`python tools/pipeline/test_issue_commands.py`) like the sibling
test files, and also under pytest.

Entirely offline. Writes are captured by a RecordedRunner -- the mutation-side
twin of RecordedClient -- so the exact gh commands, in the exact order, with the
body on stdin, are assertable without a token or a scratch repository.

test_a_dry_run_never_constructs_a_real_runner is the one that matters most.
Dry-run-by-default is the only thing standing between a typo and a live board,
and it is enforced by which runner gets built rather than by an `if` inside the
command, so that is what the test checks.
"""

from __future__ import annotations

import contextlib
import io
import sys
from pathlib import Path

from pipeline_cli import board, cli, github
from pipeline_cli.commands import issue as issue_command
from pipeline_cli.common import EXIT_CANNOT_RUN, EXIT_OK

TOOLS_DIR = Path(__file__).resolve().parent
REPO_ROOT = TOOLS_DIR.parents[1]

REPO = "Screwloose-Games/test-repo"
GOOD_PATH = "assets/art/3d/props/rain_barrel/sm_rain_barrel.gltf"

CREATE_ARGS = [
    "issue",
    "create",
    "--repo",
    REPO,
    "--template",
    "create_model",
    "--name",
    "rain barrel",
    "--description",
    "A wooden rain barrel.",
    "--field",
    "dimentions=1m x 1m x 1m",
]

ISSUE_FIELDS = {
    "organization": {
        "issueFields": {
            "nodes": [
                {"__typename": "IssueFieldText", "id": "IFT_test", "name": "filepath"},
                {
                    "__typename": "IssueFieldSingleSelect",
                    "id": "IFSS_test",
                    "name": "Priority",
                    "options": [
                        {"id": "opt_high", "name": "High"},
                        {"id": "opt_low", "name": "Low"},
                    ],
                },
            ]
        }
    }
}


class FakeClient:
    """Answers the org issue-field query and nothing else."""

    name = "fake"

    def __init__(self, payload=None, error: str = "") -> None:
        self.payload = payload if payload is not None else ISSUE_FIELDS
        self.error = error
        self.queries: list[str] = []

    def execute(self, query, variables):
        self.queries.append(query)
        if self.error:
            raise github.TransportError(self.error)
        return self.payload


class Harness:
    """Swap the two seams the issue commands reach the network through."""

    def __init__(self, responses=None, client=None) -> None:
        self.runner = github.RecordedRunner(responses=list(responses or []))
        self.client = client if client is not None else FakeClient()

    def __enter__(self):
        self._runner_factory = issue_command.pick_runner
        self._choose = board.choose_client
        issue_command.pick_runner = lambda apply: self.runner
        board.choose_client = lambda token: self.client
        return self

    def __exit__(self, *exc):
        issue_command.pick_runner = self._runner_factory
        board.choose_client = self._choose
        return False


def run(argv, harness: Harness | None = None) -> tuple[int, str, str]:
    out, err = io.StringIO(), io.StringIO()
    with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
        code = cli.main(argv)
    return code, out.getvalue(), err.getvalue()


def created(extra=None) -> tuple[Harness, int, str]:
    harness = Harness()
    with harness:
        code, out, _ = run([*CREATE_ARGS, "--filepath", GOOD_PATH, *(extra or [])])
    return harness, code, out


# --------------------------------------------------------------------------
# Dry run is the default


def test_a_dry_run_never_constructs_a_real_runner():
    assert isinstance(issue_command.pick_runner(False), github.DryRunRunner)


def test_a_dry_run_says_nothing_was_created():
    _, code, out = created()
    assert code == EXIT_OK
    assert "Nothing was created" in out
    assert "--apply" in out


def test_apply_changes_the_closing_line():
    harness = Harness()
    with harness:
        code, out, _ = run([*CREATE_ARGS, "--filepath", GOOD_PATH, "--apply"])
    assert code == EXIT_OK
    assert "Nothing was created" not in out
    assert "Created " in out


# --------------------------------------------------------------------------
# The call sequence


def test_the_three_writes_happen_in_order():
    harness, _, _ = created()
    argv = harness.runner.argv()
    assert argv[0][:2] == ["issue", "create"]
    assert argv[1][:2] == ["project", "item-add"]
    assert argv[-1][:2] == ["api", "graphql"]


def test_the_body_arrives_on_stdin_not_in_argv():
    # Several KB of checklist would hit argv limits and shell quoting.
    harness, _, _ = created()
    args, stdin = harness.runner.calls[0]
    assert "--body-file" in args and args[args.index("--body-file") + 1] == "-"
    assert stdin and "### Description" in stdin
    assert not any("### Description" in arg for arg in args)


def test_the_generated_subtasks_block_is_in_the_created_body():
    harness, _, _ = created()
    _, stdin = harness.runner.calls[0]
    assert "<!-- pipeline:subtasks:start -->" in stdin


def test_the_template_label_is_applied():
    harness, _, _ = created()
    args = harness.runner.calls[0][0]
    assert "--label" in args and "3d model" in args


def test_the_project_item_is_added_by_number_not_by_title():
    # A project title is renameable from the UI; the number is not.
    harness, _, _ = created()
    args = harness.runner.argv()[1]
    assert args[2] == str(board.DEFAULT_PROJECT_NUMBER)
    assert "--owner" in args and board.DEFAULT_ORG in args


def test_no_project_skips_the_board():
    harness, _, _ = created(["--no-project"])
    assert not any(args[:2] == ["project", "item-add"] for args in harness.runner.argv())


def test_the_filepath_field_id_is_discovered_by_name_not_hardcoded():
    harness, _, _ = created()
    mutation = harness.runner.calls[-1]
    assert "-f" in mutation[0]
    assert "fieldId=IFT_test" in mutation[0], "the id must come from the query, not a constant"
    assert f"value={GOOD_PATH}" in mutation[0]
    assert "setIssueFieldValue" in (mutation[1] or "")


def test_no_filepath_means_no_field_mutation():
    harness = Harness()
    with harness:
        run(CREATE_ARGS)
    assert not any(args[:2] == ["api", "graphql"] for args in harness.runner.argv())


# --------------------------------------------------------------------------
# Refusals happen before anything is written


def test_a_placeholder_filepath_refuses_and_writes_nothing():
    harness = Harness()
    with harness:
        code, _, err = run([*CREATE_ARGS, "--filepath", "assets/art/3d/{cat}/sm_{obj}.gltf"])
    assert code == EXIT_CANNOT_RUN
    assert harness.runner.calls == []
    assert "placeholder" in err


def test_a_nonstandard_filename_refuses_without_force():
    harness = Harness()
    with harness:
        code, _, err = run(
            [*CREATE_ARGS, "--filepath", "assets/art/3d/props/rain_barrel/sm_RainBarrel.gltf"]
        )
    assert code == EXIT_CANNOT_RUN
    assert harness.runner.calls == []
    assert "--force" in err


def test_force_lets_a_nonstandard_filename_through_with_a_warning():
    harness = Harness()
    with harness:
        code, out, _ = run(
            [
                *CREATE_ARGS,
                "--filepath",
                "assets/art/3d/props/rain_barrel/sm_RainBarrel.gltf",
                "--force",
            ]
        )
    assert code == EXIT_OK
    assert "WARN" in out
    assert harness.runner.calls


def test_a_required_field_with_no_answer_refuses_before_writing():
    harness = Harness()
    with harness:
        code, _, err = run(
            ["issue", "create", "--repo", REPO, "--template", "create_model", "--name", "x"]
        )
    assert code == EXIT_CANNOT_RUN
    assert harness.runner.calls == []
    assert "Description" in err


# --------------------------------------------------------------------------
# Degrading rather than failing


def test_an_unreachable_issue_field_warns_and_still_creates():
    # The body already carries the path; losing a board column is not a reason
    # to fail an issue that already exists.
    harness = Harness(client=FakeClient(error="Field 'issueFields' doesn't exist"))
    with harness:
        code, out, _ = run([*CREATE_ARGS, "--filepath", GOOD_PATH])
    assert code == EXIT_OK
    assert "WARN" in out
    assert GOOD_PATH in out
    assert harness.runner.argv()[0][:2] == ["issue", "create"]


def test_a_missing_field_name_says_what_to_set_by_hand():
    harness = Harness(client=FakeClient(payload={"organization": {"issueFields": {"nodes": []}}}))
    with harness:
        code, out, _ = run([*CREATE_ARGS, "--filepath", GOOD_PATH])
    assert code == EXIT_OK
    assert "set it by hand" in out


def test_a_gh_failure_is_explained_with_the_write_scope():
    message = github.explain_transport_error(
        "your token has insufficient_scopes for project", write=True
    )
    assert "gh auth refresh -h github.com -s project" in message
    assert "read:project" not in message


# --------------------------------------------------------------------------
# issue update


def test_update_with_no_flags_refuses():
    harness = Harness()
    with harness:
        code, _, err = run(["issue", "update", "7", "--repo", REPO])
    assert code == EXIT_CANNOT_RUN
    assert harness.runner.calls == []
    assert "nothing to change" in err


def test_update_filepath_sets_the_issue_field():
    harness = Harness()
    with harness:
        code, _, _ = run(["issue", "update", "7", "--repo", REPO, "--filepath", GOOD_PATH])
    assert code == EXIT_OK
    argv = harness.runner.argv()
    assert argv[0][:2] == ["issue", "view"]
    assert argv[-1][:2] == ["api", "graphql"]
    assert f"value={GOOD_PATH}" in argv[-1]


def test_update_validates_the_filepath_exactly_as_create_does():
    harness = Harness()
    with harness:
        code, _, err = run(["issue", "update", "7", "--repo", REPO, "--filepath", "res://{x}.gltf"])
    assert code == EXIT_CANNOT_RUN
    assert harness.runner.calls == []
    assert "placeholder" in err


def test_update_batches_the_edit_flags_into_one_call():
    harness = Harness()
    with harness:
        run(
            [
                "issue",
                "update",
                "7",
                "--repo",
                REPO,
                "--title",
                "New title",
                "--add-label",
                "blocked",
                "--remove-label",
                "ready",
            ]
        )
    edits = [args for args in harness.runner.argv() if args[:2] == ["issue", "edit"]]
    assert len(edits) == 1
    assert "--title" in edits[0] and "--add-label" in edits[0] and "--remove-label" in edits[0]


def test_update_state_uses_close_rather_than_an_edit_flag():
    harness = Harness()
    with harness:
        run(["issue", "update", "7", "--repo", REPO, "--state", "closed"])
    assert harness.runner.argv() == [["issue", "close", "7", "--repo", REPO]]


def test_update_priority_resolves_the_option_id():
    harness = Harness()
    with harness:
        run(["issue", "update", "7", "--repo", REPO, "--priority", "high"])
    mutation = harness.runner.argv()[-1]
    assert "optionId=opt_high" in mutation, "the option must be matched case-insensitively"


def test_update_priority_lists_the_options_when_the_value_is_unknown():
    harness = Harness()
    with harness:
        code, out, _ = run(["issue", "update", "7", "--repo", REPO, "--priority", "Urgent"])
    assert code == EXIT_OK
    assert "High" in out and "Low" in out


def test_resync_subtasks_needs_a_template():
    harness = Harness()
    with harness:
        code, _, err = run(["issue", "update", "7", "--repo", REPO, "--resync-subtasks"])
    assert code == EXIT_CANNOT_RUN
    assert harness.runner.calls == []
    assert "--template" in err


def test_resync_subtasks_warns_when_the_issue_has_no_block():
    harness = Harness(responses=[github.RunResult(0, "a body with no markers\n")])
    with harness:
        code, out, _ = run(
            [
                "issue",
                "update",
                "7",
                "--repo",
                REPO,
                "--resync-subtasks",
                "--template",
                "create_model",
            ]
        )
    assert code == EXIT_OK
    assert "no pipeline:subtasks block" in out
    assert not any(args[:2] == ["issue", "edit"] for args in harness.runner.argv())


def test_resync_subtasks_rewrites_only_the_block():
    body = (
        "### Subtasks\n\nkeep me\n\n"
        "<!-- pipeline:subtasks:start -->\n- [ ] stale\n<!-- pipeline:subtasks:end -->\n\ntrailer\n"
    )
    harness = Harness(responses=[github.RunResult(0, body)])
    with harness:
        code, _, _ = run(
            [
                "issue",
                "update",
                "7",
                "--repo",
                REPO,
                "--resync-subtasks",
                "--template",
                "create_model",
            ]
        )
    assert code == EXIT_OK
    edit = next(call for call in harness.runner.calls if call[0][:2] == ["issue", "edit"])
    updated = edit[1]
    assert "keep me" in updated and "trailer" in updated
    assert "- [ ] stale" not in updated
    assert "- [ ] The model faces +Y in Blender." in updated


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
