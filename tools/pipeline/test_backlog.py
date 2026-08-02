#!/usr/bin/env python3
"""Tests for the backlog format and `pipeline.py backlog new` / `backlog file`.

Runs standalone (`python tools/pipeline/test_backlog.py`) like the sibling test
files, and also under pytest. No fixtures anywhere: the standalone runner calls
each test with no arguments, so a `tmp_path` parameter would break it.

Entirely offline. Writes to GitHub are captured by a RecordedRunner and writes to
disk happen in a TemporaryDirectory, so the exact gh commands and the exact bytes
of the edited file are both assertable without a token or a scratch repository.

Two tests carry most of the weight.

test_every_other_byte_survives_the_splice is the one protecting the promise the
format makes: a backlog file is hand-authored, and writing an issue number into
it must not cost the author their comments, their block scalars or their key
order. A safe_dump round trip would pass every other test in this file and fail
that one.

test_the_number_is_recorded_even_when_the_follow_up_calls_fail is the one
protecting against duplicates. `gh issue create` is followed by three more calls,
and if the number were only recorded after all four, a failure in any of them
would leave an issue nobody has a record of and the next run would open a second.
"""

from __future__ import annotations

import contextlib
import io
import sys
import tempfile
from pathlib import Path

from pipeline_cli import backlog, board, cli, github, issue_forms
from pipeline_cli.commands import backlog as backlog_command
from pipeline_cli.commands import issue as issue_command
from pipeline_cli.common import (
    EXIT_CANNOT_RUN,
    EXIT_CHECK_FAILED,
    EXIT_OK,
    DocumentError,
)

REPO = "Screwloose-Games/test-repo"
LANTERN = "assets/art/3d/props/lantern/sm_lantern.gltf"
BARREL = "assets/art/3d/props/rain_barrel/sm_rain_barrel.gltf"

# A file exercising everything the splice has to survive: a leading comment, a
# comment between entries, a blank line, a block scalar, a flow list, and an
# entry that is already filed.
SAMPLE = """\
# The tavern set.
template: create_model

defaults:
  assignee: jonathandavidlewis
  priority: high

issues:
  # the hanging one
  - name: lantern
    description: |
      Hanging lantern for the tavern.
      Must read at 10m.
    dimentions: 0.3m tall
    filepath: {lantern}
    labels: [prop, tavern]

  - name: rain_barrel
    issue: 412
    description: Weathered oak barrel.
    dimentions: 1.0m tall
    filepath: {barrel}
""".format(lantern=LANTERN, barrel=BARREL)

ISSUE_FIELDS = {
    "organization": {
        "issueFields": {
            "nodes": [
                {"__typename": "IssueFieldText", "id": "IFT_test", "name": "filepath"},
                {
                    "__typename": "IssueFieldSingleSelect",
                    "id": "IFSS_test",
                    "name": "Priority",
                    "options": [{"id": "opt_high", "name": "High"}],
                },
            ]
        }
    }
}


class FakeClient:
    """Answers the org issue-field query and nothing else."""

    name = "fake"

    def execute(self, query, variables):
        return ISSUE_FIELDS


class FailAt:
    """A runner that dies on the Nth `gh issue create`.

    RecordedRunner's `responses` queue pops on every call, so making the third
    *creation* fail through it would mean canning every call before it. This
    says what it means instead.
    """

    name = "fail-at"

    def __init__(self, nth: int) -> None:
        self.nth = nth
        self.creates = 0
        self.calls: list[tuple[list[str], str | None]] = []

    def run(self, args, stdin=None):
        self.calls.append((list(args), stdin))
        if args[:2] == ["issue", "create"]:
            self.creates += 1
            if self.creates == self.nth:
                raise github.TransportError("your token cannot write to Projects")
            return github.RunResult(0, f"https://github.com/{REPO}/issues/{529 + self.creates}\n")
        return github.RunResult(0, github.canned_stdout(args))

    def argv(self):
        return [args for args, _ in self.calls]


class Numbered:
    """Answers every creation with a real-looking, increasing issue number."""

    name = "numbered"

    def __init__(self) -> None:
        self.created = 0
        self.calls: list[tuple[list[str], str | None]] = []

    def run(self, args, stdin=None):
        self.calls.append((list(args), stdin))
        if args[:2] == ["issue", "create"]:
            self.created += 1
            return github.RunResult(0, f"https://github.com/{REPO}/issues/{529 + self.created}\n")
        return github.RunResult(0, github.canned_stdout(args))

    def argv(self):
        return [args for args, _ in self.calls]


class Harness:
    """Swap the three seams: the gh runner, the GraphQL client, and the recorder.

    The recorder is left real by default, because the whole point of most of
    these tests is what lands on disk.
    """

    def __init__(self, runner=None, recorder=None) -> None:
        self.runner = runner if runner is not None else github.RecordedRunner()
        self.recorder = recorder
        self.client = FakeClient()

    def __enter__(self):
        self._pick_runner = issue_command.pick_runner
        self._pick_recorder = backlog_command.pick_recorder
        self._choose = board.choose_client
        issue_command.pick_runner = lambda apply: self.runner
        board.choose_client = lambda token: self.client
        if self.recorder is not None:
            backlog_command.pick_recorder = lambda apply: self.recorder
        return self

    def __exit__(self, *exc):
        issue_command.pick_runner = self._pick_runner
        backlog_command.pick_recorder = self._pick_recorder
        board.choose_client = self._choose
        return False


def run(argv, harness: Harness | None = None) -> tuple[int, str, str]:
    out, err = io.StringIO(), io.StringIO()
    with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
        code = cli.main(argv)
    return code, out.getvalue(), err.getvalue()


def written(directory: str, text: str = SAMPLE, name: str = "create_model.yaml") -> Path:
    path = Path(directory) / name
    path.write_text(text, encoding="utf-8", newline="\n")
    return path


def file_argv(path: Path, *extra: str) -> list[str]:
    return ["backlog", "file", "--repo", REPO, "--from", str(path), *extra]


def expect_error(call, *fragments) -> str:
    """Assert the call raises DocumentError mentioning each fragment."""
    try:
        call()
    except DocumentError as exc:
        message = str(exc)
        for fragment in fragments:
            assert fragment in message, f"{fragment!r} not in {message!r}"
        return message
    raise AssertionError("expected a DocumentError")


def creations(runner) -> list[list[str]]:
    return [args for args in runner.argv() if args[:2] == ["issue", "create"]]


# --------------------------------------------------------------------------
# The splice


def test_a_number_is_spliced_into_the_entry_it_belongs_to():
    with tempfile.TemporaryDirectory() as tmp:
        path = written(tmp)
        backlog.splice_issue(path, 0, "530")
        doc = backlog.load_backlog(path)
        assert doc.entries[0].issue == "530"
        assert doc.entries[1].issue == "412"


def test_every_other_byte_survives_the_splice():
    # The promise the format makes to whoever hand-wrote the file: one line
    # appears, and nothing else moves.
    with tempfile.TemporaryDirectory() as tmp:
        path = written(tmp)
        before = path.read_text(encoding="utf-8").splitlines()
        backlog.splice_issue(path, 0, "530")
        after = path.read_text(encoding="utf-8").splitlines()

        # The entry's first line gains a sibling: the `- ` marker keeps its
        # place and the key it used to share a line with moves down one.
        expected = list(before)
        at = expected.index("  - name: lantern")
        expected[at : at + 1] = ["  - issue: 530", "    name: lantern"]
        assert after == expected

        # Said the other way round, because that is the promise: nothing that
        # is not an entry's first line moves at all.
        for line in before:
            if line != "  - name: lantern":
                assert line in after, f"lost {line!r}"


def test_the_spliced_file_says_the_same_thing_it_did_before():
    with tempfile.TemporaryDirectory() as tmp:
        path = written(tmp)
        before = backlog.load_backlog(path).entries[0].own
        backlog.splice_issue(path, 0, "530")
        after = dict(backlog.load_backlog(path).entries[0].own)
        assert after.pop("issue") == 530
        assert after == before


def test_a_second_splice_lands_in_the_right_entry():
    # Every splice shifts the lines below it. Trusting marks read before the
    # first write would put the second number inside the first entry.
    body = "template: create_model\nissues:\n  - name: a\n  - name: b\n  - name: c\n"
    with tempfile.TemporaryDirectory() as tmp:
        path = written(tmp, body)
        backlog.splice_issue(path, 0, "1")
        backlog.splice_issue(path, 1, "2")
        backlog.splice_issue(path, 2, "3")
        entries = backlog.load_backlog(path).entries
        assert [entry.issue for entry in entries] == ["1", "2", "3"]
        assert [entry.values["name"] for entry in entries] == ["a", "b", "c"]


def test_a_dash_on_its_own_line_is_spliced_correctly():
    body = "template: create_model\nissues:\n  -\n    name: lantern\n"
    with tempfile.TemporaryDirectory() as tmp:
        path = written(tmp, body)
        backlog.splice_issue(path, 0, "530")
        entry = backlog.load_backlog(path).entries[0]
        assert entry.issue == "530"
        assert entry.values["name"] == "lantern"


def test_a_flow_style_entry_is_refused_rather_than_corrupted():
    body = "template: create_model\nissues:\n  - {name: lantern}\n"
    with tempfile.TemporaryDirectory() as tmp:
        path = written(tmp, body)
        original = path.read_text(encoding="utf-8")
        expect_error(
            lambda: backlog.splice_issue(path, 0, "530"),
            "530",
            "by hand",
        )
        assert path.read_text(encoding="utf-8") == original, "the file was left damaged"


def test_a_crlf_file_stays_crlf():
    # .gitattributes says eol=lf, so a Windows working tree holds CRLF. A splice
    # that normalised it would show every line as changed in git diff.
    with tempfile.TemporaryDirectory() as tmp:
        path = Path(tmp) / "create_model.yaml"
        path.write_bytes(SAMPLE.replace("\n", "\r\n").encode("utf-8"))
        backlog.splice_issue(path, 0, "530")
        raw = path.read_bytes()
        assert b"\r\n  - issue: 530\r\n" in raw
        assert raw.count(b"\n") == raw.count(b"\r\n"), "mixed line endings"


# --------------------------------------------------------------------------
# Reading the format


def test_a_file_with_no_template_key_names_the_command_that_starts_one():
    with tempfile.TemporaryDirectory() as tmp:
        path = written(tmp, "issues:\n  - name: lantern\n")
        expect_error(lambda: backlog.load_backlog(path), "template", "backlog new")


def test_defaults_fill_entries_that_do_not_set_them():
    with tempfile.TemporaryDirectory() as tmp:
        doc = backlog.load_backlog(written(tmp))
        assert doc.entries[0].values["assignee"] == "jonathandavidlewis"
        assert doc.entries[0].values["priority"] == "high"


def test_an_entry_overrides_a_default():
    body = SAMPLE.replace("  - name: lantern\n", "  - name: lantern\n    priority: low\n")
    with tempfile.TemporaryDirectory() as tmp:
        doc = backlog.load_backlog(written(tmp, body))
        assert doc.entries[0].values["priority"] == "low"
        assert doc.entries[1].values["priority"] == "high"


def test_defaults_may_only_carry_assignee_labels_and_priority():
    body = "template: create_model\ndefaults:\n  description: shared\nissues: []\n"
    with tempfile.TemporaryDirectory() as tmp:
        path = written(tmp, body)
        expect_error(lambda: backlog.load_backlog(path), "description", "assignee")


def test_an_empty_backlog_is_not_an_error():
    with tempfile.TemporaryDirectory() as tmp:
        doc = backlog.load_backlog(written(tmp, "template: create_model\nissues:\n"))
        assert doc.entries == ()
        assert doc.slug == "create_model"


def test_a_filed_entry_is_told_apart_from_an_unfiled_one():
    with tempfile.TemporaryDirectory() as tmp:
        doc = backlog.load_backlog(written(tmp))
        assert [entry.label for entry in doc.pending()] == ["lantern"]
        assert [entry.label for entry in doc.filed()] == ["rain_barrel"]


# --------------------------------------------------------------------------
# Validation


def test_an_unknown_key_lists_the_ones_this_template_accepts():
    body = SAMPLE.replace("    dimentions: 0.3m tall\n", "    dimentions: 0.3m\n    loudness: 9\n")
    with tempfile.TemporaryDirectory() as tmp:
        code, out, _ = run(file_argv(written(tmp, body)))
    assert code == EXIT_CHECK_FAILED
    assert "unknown key 'loudness'" in out
    assert "dimentions" in out and "reference-images" in out


def test_a_file_written_for_another_template_fails_on_its_keys():
    # The wrong-template case, which the `template:` key turns from a silent
    # pile of _No response_ into a named error.
    body = (
        "template: create_model\n"
        "issues:\n"
        "  - name: door_creak\n"
        "    description: A creak.\n"
        "    context: assets/art/audio/sfx/sfx_door_creak.wav\n"
    )
    with tempfile.TemporaryDirectory() as tmp:
        code, out, _ = run(file_argv(written(tmp, body)))
    assert code == EXIT_CHECK_FAILED
    assert "unknown key 'context'" in out


def test_a_missing_required_field_names_the_key_not_the_flag():
    # `issue create` says (--field dimentions=...). In a backlog the fix is a
    # key in a file, and saying otherwise sends the reader to the wrong place.
    body = SAMPLE.replace("    dimentions: 0.3m tall\n", "")
    with tempfile.TemporaryDirectory() as tmp:
        code, out, _ = run(file_argv(written(tmp, body)))
    assert code == EXIT_CHECK_FAILED
    assert "`dimentions`" in out
    assert "--field" not in out


def test_an_entry_with_no_name_and_a_placeholder_title_is_refused():
    body = SAMPLE.replace("  - name: lantern\n", "  - description: nameless\n")
    with tempfile.TemporaryDirectory() as tmp:
        code, out, _ = run(file_argv(written(tmp, body)))
    assert code == EXIT_CHECK_FAILED
    assert "{game object name}" in out


def test_two_entries_claiming_one_filepath_are_refused():
    body = SAMPLE.replace(f"    filepath: {BARREL}\n", f"    filepath: {LANTERN}\n").replace(
        "    issue: 412\n", ""
    )
    with tempfile.TemporaryDirectory() as tmp:
        code, out, _ = run(file_argv(written(tmp, body)))
    assert code == EXIT_CHECK_FAILED
    assert "already claimed" in out


def test_a_placeholder_filepath_is_refused():
    body = SAMPLE.replace(
        f"    filepath: {LANTERN}\n",
        "    filepath: assets/art/3d/{category}/{object_name}/sm_{object_name}.gltf\n",
    )
    with tempfile.TemporaryDirectory() as tmp:
        code, out, _ = run(file_argv(written(tmp, body)))
    assert code == EXIT_CHECK_FAILED
    assert "filepath" in out


def test_a_nonstandard_filepath_is_refused_without_force():
    # In the right directory, wrong filename: a path pipeline.yaml governs and
    # rejects. A path outside those directories is "unchecked", not an error.
    body = SAMPLE.replace(
        f"    filepath: {LANTERN}\n",
        "    filepath: assets/art/3d/props/lantern/Lantern.gltf\n",
    )
    with tempfile.TemporaryDirectory() as tmp:
        path = written(tmp, body)
        code, out, _ = run(file_argv(path))
        assert code == EXIT_CHECK_FAILED, out
        assert "nonstandard" in out

        harness = Harness()
        with harness:
            code, out, _ = run(file_argv(path, "--force"))
        assert code == EXIT_OK, out


def test_one_bad_entry_stops_every_entry_in_the_run():
    # The cross-file rule, in one file: filing the good half and reporting the
    # rest would leave a board someone has to reconcile by hand.
    body = SAMPLE.replace("  - name: rain_barrel\n    issue: 412\n", "  - name: rain_barrel\n")
    body = body.replace("    description: Weathered oak barrel.\n", "")
    with tempfile.TemporaryDirectory() as tmp:
        harness = Harness()
        path = written(tmp, body)
        original = path.read_text(encoding="utf-8")
        with harness:
            code, _, _ = run(file_argv(path, "--apply"))
        assert code == EXIT_CHECK_FAILED
        assert harness.runner.calls == [], "something was sent despite a bad entry"
        assert path.read_text(encoding="utf-8") == original


# --------------------------------------------------------------------------
# backlog new


def test_the_scaffold_asks_for_the_required_fields_and_a_name():
    form = issue_forms.load_form("create_model")
    assert backlog.scaffold_keys(form) == ["name", "description", "dimentions", "filepath"]


def test_the_subtasks_checklist_is_not_a_scaffolded_key():
    # It is required, but its default is the generated checklist, which
    # render_body already carries into the issue. Asking a person to paste forty
    # checkboxes into YAML would go stale on the next re-render.
    for slug in issue_forms.available_slugs():
        keys = backlog.scaffold_keys(issue_forms.load_form(slug))
        assert "subtasks" not in keys, slug


def test_the_path_field_is_scaffolded_under_one_name_for_every_template():
    # create_model calls it file_path, create_implementation calls it context.
    for slug in ("create_model", "create_texture_for_model", "create_implementation"):
        form = issue_forms.load_form(slug)
        keys = backlog.scaffold_keys(form)
        assert "filepath" in keys, slug
        assert form.path_field().id not in keys or form.path_field().id == "filepath", slug


def test_every_template_this_repo_ships_scaffolds_a_file_that_loads():
    with tempfile.TemporaryDirectory() as tmp:
        for slug in issue_forms.available_slugs():
            form = issue_forms.load_form(slug)
            path = Path(tmp) / f"{slug}.yaml"
            path.write_text(backlog.render_scaffold(form), encoding="utf-8", newline="\n")
            doc = backlog.load_backlog(path)
            assert doc.slug == slug
            assert doc.entries == (), f"{slug} scaffolded a live entry"


def test_every_templates_title_can_be_filled_by_a_name():
    # create_ambient_audio.yaml and integrate_audio_file.yaml once wrote their
    # placeholder as {{name}}. PLACEHOLDER_RE matches the inner braces, so
    # substituting left {widget} behind and render_title refused every entry --
    # which broke `issue create --name` on those two templates as well.
    for slug in issue_forms.available_slugs():
        form = issue_forms.load_form(slug)
        if not form.title:
            continue
        title = issue_forms.render_title(form, "widget")
        assert "{" not in title and "}" not in title, f"{slug}: {title}"


def test_new_writes_the_file_and_names_its_keys():
    with tempfile.TemporaryDirectory() as tmp:
        out_path = Path(tmp) / "create_model.yaml"
        code, out, _ = run(["backlog", "new", "--template", "create_model", "--out", str(out_path)])
        assert code == EXIT_OK
        assert out_path.is_file()
        assert "dimentions" in out


def test_new_refuses_to_clobber_a_backlog_that_already_has_numbers_in_it():
    with tempfile.TemporaryDirectory() as tmp:
        path = written(tmp)
        argv = ["backlog", "new", "--template", "create_model", "--out", str(path)]
        code, _, err = run(argv)
        assert code == EXIT_CANNOT_RUN
        assert "--force" in err
        assert path.read_text(encoding="utf-8") == SAMPLE

        code, _, _ = run([*argv, "--force"])
        assert code == EXIT_OK
        assert path.read_text(encoding="utf-8") != SAMPLE


def test_the_default_path_is_derived_from_the_template():
    form = issue_forms.load_form("create_model")
    assert backlog.scaffold_path(form).name == "create_model.yaml"
    assert backlog.scaffold_path(form).parent.name == "backlog"


def test_an_unknown_template_lists_the_ones_that_exist():
    code, _, err = run(["backlog", "new", "--template", "create_modle"])
    assert code == EXIT_CANNOT_RUN
    assert "create_model" in err


# --------------------------------------------------------------------------
# backlog file -- the dry run


def test_a_dry_run_never_constructs_a_real_runner_or_a_real_recorder():
    assert isinstance(issue_command.pick_runner(False), github.DryRunRunner)
    assert isinstance(backlog_command.pick_recorder(False), backlog_command.DryRunRecorder)
    assert isinstance(backlog_command.pick_recorder(True), backlog_command.FileRecorder)


def test_a_dry_run_leaves_the_backlog_file_byte_identical():
    with tempfile.TemporaryDirectory() as tmp:
        path = written(tmp)
        before = path.read_bytes()
        with Harness():
            code, out, _ = run(file_argv(path))
        assert code == EXIT_OK
        assert path.read_bytes() == before
        assert "Nothing was created" in out


def test_a_dry_run_says_where_the_number_would_go():
    with tempfile.TemporaryDirectory() as tmp:
        with Harness():
            _, out, _ = run(file_argv(written(tmp)))
    assert "would write" in out


# --------------------------------------------------------------------------
# backlog file -- applying


def test_apply_writes_the_number_back_into_the_entry():
    with tempfile.TemporaryDirectory() as tmp:
        path = written(tmp)
        with Harness(runner=Numbered()):
            code, _, _ = run(file_argv(path, "--apply"))
        assert code == EXIT_OK
        assert backlog.load_backlog(path).entries[0].issue == "530"


def test_an_entry_that_already_has_a_number_is_never_sent_again():
    with tempfile.TemporaryDirectory() as tmp:
        harness = Harness(runner=Numbered())
        with harness:
            run(file_argv(written(tmp), "--apply"))
        titles = [args[args.index("--title") + 1] for args in creations(harness.runner)]
    assert titles == ["Create 3D model for lantern"]


def test_re_running_files_nothing_the_second_time():
    with tempfile.TemporaryDirectory() as tmp:
        path = written(tmp)
        with Harness(runner=Numbered()):
            run(file_argv(path, "--apply"))
        second = Harness(runner=Numbered())
        with second:
            code, out, _ = run(file_argv(path, "--apply"))
    assert code == EXIT_OK
    assert creations(second.runner) == []
    assert "Nothing to file" in out


def test_the_number_is_recorded_even_when_the_follow_up_calls_fail():
    # gh issue create succeeds, then `project item-add` dies. The issue exists;
    # if its number were only written after all four calls, the next run would
    # open a second one.
    class DiesAfterCreating(Numbered):
        def run(self, args, stdin=None):
            if args[:2] == ["project", "item-add"]:
                raise github.TransportError("your token cannot write to Projects")
            return super().run(args, stdin)

    with tempfile.TemporaryDirectory() as tmp:
        path = written(tmp)
        with Harness(runner=DiesAfterCreating()):
            run(file_argv(path, "--apply"))
        assert backlog.load_backlog(path).entries[0].issue == "530"


def test_the_file_is_written_after_each_issue_not_at_the_end():
    body = (
        "template: create_model\n"
        "issues:\n"
        "  - name: a\n    description: a\n    dimentions: 1m\n"
        "    filepath: assets/art/3d/props/a/sm_a.gltf\n"
        "  - name: b\n    description: b\n    dimentions: 1m\n"
        "    filepath: assets/art/3d/props/b/sm_b.gltf\n"
        "  - name: c\n    description: c\n    dimentions: 1m\n"
        "    filepath: assets/art/3d/props/c/sm_c.gltf\n"
    )
    with tempfile.TemporaryDirectory() as tmp:
        path = written(tmp, body)
        with Harness(runner=FailAt(3)):
            code, out, err = run(file_argv(path, "--apply"))

        entries = backlog.load_backlog(path).entries
    assert code == EXIT_CANNOT_RUN
    # The two that were created kept their numbers; the third never happened.
    assert [entry.issue for entry in entries] == ["530", "531", ""]
    assert "re-run the same command" in out


def test_a_resumed_run_files_only_what_is_left():
    body = (
        "template: create_model\n"
        "issues:\n"
        "  - name: a\n    description: a\n    dimentions: 1m\n"
        "    filepath: assets/art/3d/props/a/sm_a.gltf\n"
        "  - name: b\n    description: b\n    dimentions: 1m\n"
        "    filepath: assets/art/3d/props/b/sm_b.gltf\n"
        "  - name: c\n    description: c\n    dimentions: 1m\n"
        "    filepath: assets/art/3d/props/c/sm_c.gltf\n"
    )
    with tempfile.TemporaryDirectory() as tmp:
        path = written(tmp, body)
        with Harness(runner=FailAt(3)):
            run(file_argv(path, "--apply"))

        # The operator's next move is the identical command.
        resumed = Harness(runner=Numbered())
        with resumed:
            code, _, _ = run(file_argv(path, "--apply"))

        entries = backlog.load_backlog(path).entries
    assert code == EXIT_OK
    titles = [args[args.index("--title") + 1] for args in creations(resumed.runner)]
    assert titles == ["Create 3D model for c"], "a filed entry was sent again"
    assert [entry.issue for entry in entries] == ["530", "531", "530"]


# --------------------------------------------------------------------------
# What reaches GitHub


def test_backlog_file_and_issue_create_send_the_same_gh_sequence():
    # The test that keeps the four-call sequence in one place. If someone
    # reimplements it here, this is what says so.
    body = (
        "template: create_model\n"
        "issues:\n"
        "  - name: rain barrel\n"
        "    description: A wooden rain barrel.\n"
        "    dimentions: 1m x 1m x 1m\n"
        f"    filepath: {BARREL}\n"
    )
    with tempfile.TemporaryDirectory() as tmp:
        from_backlog = Harness()
        with from_backlog:
            run(file_argv(written(tmp, body)))

    direct = Harness()
    with direct:
        run(
            [
                "issue", "create", "--repo", REPO, "--template", "create_model",
                "--name", "rain barrel", "--description", "A wooden rain barrel.",
                "--field", "dimentions=1m x 1m x 1m", "--filepath", BARREL,
            ]
        )

    assert from_backlog.runner.argv() == direct.runner.argv()
    assert [stdin for _, stdin in from_backlog.runner.calls] == [
        stdin for _, stdin in direct.runner.calls
    ]


def test_a_block_scalar_description_reaches_the_body_with_its_newlines():
    # The reason the format is YAML and not TSV.
    with tempfile.TemporaryDirectory() as tmp:
        harness = Harness()
        with harness:
            run(file_argv(written(tmp)))
        body = harness.runner.calls[0][1]
    assert "Hanging lantern for the tavern.\nMust read at 10m." in body


def test_the_templates_own_labels_are_merged_with_the_entrys():
    with tempfile.TemporaryDirectory() as tmp:
        harness = Harness()
        with harness:
            run(file_argv(written(tmp)))
        args = creations(harness.runner)[0]
    labels = [args[i + 1] for i, value in enumerate(args) if value == "--label"]
    assert labels == ["3d model", "prop", "tavern"]


def test_an_assignee_may_be_a_string_or_a_list():
    body = SAMPLE.replace(
        "  assignee: jonathandavidlewis\n", "  assignee: [alice, bob]\n"
    )
    with tempfile.TemporaryDirectory() as tmp:
        harness = Harness()
        with harness:
            run(file_argv(written(tmp, body)))
        args = creations(harness.runner)[0]
    assignees = [args[i + 1] for i, value in enumerate(args) if value == "--assignee"]
    assert assignees == ["alice", "bob"]


def test_the_priority_default_sets_the_priority_issue_field():
    with tempfile.TemporaryDirectory() as tmp:
        harness = Harness()
        with harness:
            run(file_argv(written(tmp)))
        sent = [args for args in harness.runner.argv() if args[:2] == ["api", "graphql"]]
    assert any("optionId=opt_high" in arg for args in sent for arg in args)


def test_no_project_skips_the_board():
    with tempfile.TemporaryDirectory() as tmp:
        harness = Harness()
        with harness:
            run(file_argv(written(tmp), "--no-project"))
    assert not any(args[:2] == ["project", "item-add"] for args in harness.runner.argv())


def test_a_missing_backlog_file_says_so_rather_than_tracebacks():
    code, _, err = run(["backlog", "file", "--repo", REPO, "--from", "nope.yaml"])
    assert code == EXIT_CANNOT_RUN
    assert "nope.yaml" in err


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
