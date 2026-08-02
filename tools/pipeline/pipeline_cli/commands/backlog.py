"""`pipeline.py backlog ...` -- turning a local backlog file into issues.

`backlog new` writes a starter file for a template. `backlog file` reads the
backlog files, checks every entry, and opens an issue for each one that has not
been filed yet -- writing the issue number back into the entry as it goes.

Two things make this safe to run twice. Every selected file is validated before
anything is sent, so one bad entry stops the batch rather than filing half of
it. And the number is recorded the instant the issue exists, so a run that dies
in the middle leaves the numbers it earned on disk and the same command picks up
where it stopped. There is no separate state to reconcile: the backlog file is
the ledger.

Like `issue create`, this is a dry run without --apply, and the choice is made
once by picking a runner and a recorder rather than by an `if` in the body -- so
the rehearsal walks the identical path and only the objects differ.
"""

from __future__ import annotations

import argparse
import sys
from dataclasses import dataclass
from pathlib import Path

from .. import backlog, github, issue_forms
from ..backlog import Backlog, Entry
from ..command import BOARD_FLAGS, DOC_FLAGS, REPO_FLAGS, WRITE_FLAGS
from ..common import (
    BACKLOG_DIR,
    EXIT_CANNOT_RUN,
    EXIT_CHECK_FAILED,
    EXIT_OK,
    DocumentError,
    fail,
    print_status,
    relative,
)
from . import issue as issue_command
from .issue import IssuePlan

NEW_COMMAND = "python tools/pipeline/pipeline.py backlog new --template <slug>"


# -- Problems --------------------------------------------------------------


@dataclass(frozen=True)
class Problem:
    where: str  # documentation/pipeline/backlog/create_model.yaml:14
    label: str  # the entry, as a person would name it
    message: str
    detail: str = ""

    def report(self) -> None:
        print_status("ERROR", f"{self.where}  {self.label}", self.message)
        if self.detail:
            print(f"              {self.detail}")


def _listed(values) -> list[str]:
    """A scalar or a list, as a list. `assignee: jonathan` is what people type."""
    if values is None or values == "":
        return []
    if isinstance(values, (list, tuple)):
        return [str(value).strip() for value in values if str(value).strip()]
    return [str(values).strip()]


# -- Planning one entry ----------------------------------------------------


def plan_for(
    doc: Backlog,
    form: issue_forms.IssueForm,
    entry: Entry,
    *,
    repo: str,
    args: argparse.Namespace,
) -> tuple[IssuePlan | None, list[Problem]]:
    """Turn one entry into an IssuePlan, or into the reasons it cannot be one.

    Every check that could refuse this entry runs here, and they all run: a
    person filling in twenty entries wants the whole list of what is wrong, not
    the first thing.
    """
    where = doc.where(entry)
    problems: list[Problem] = []

    def problem(message: str, detail: str = "") -> None:
        problems.append(Problem(where, entry.label, message, detail))

    path_field = form.path_field()
    valid = backlog.known_keys(form)
    for key in entry.own:
        if key not in valid:
            problem(
                f"unknown key {key!r}",
                f"{form.slug} accepts: {', '.join(valid)}",
            )

    # The template's own id for the path field is accepted as an alias, because
    # someone reading create_model.yaml will reasonably write `file_path:`.
    # Both at once is refused rather than resolved -- picking one silently is
    # how the wrong path ends up on the board.
    alias = path_field.id if path_field else ""
    if alias and alias != "filepath" and alias in entry.own and "filepath" in entry.own:
        problem(
            f"gives both `filepath` and `{alias}`",
            "They are the same field. Keep `filepath`.",
        )

    raw_path = entry.values.get("filepath")
    if raw_path is None and alias:
        raw_path = entry.values.get(alias)

    file_path = ""
    if raw_path:
        path, stage, status, detail = issue_command.inspect_path(str(raw_path), args.doc)
        if stage == "unusable":
            problem(
                f"filepath {str(raw_path)!r} {detail}",
                "Give a repository-relative path, e.g. "
                "assets/art/3d/props/rain_barrel/sm_rain_barrel.gltf",
            )
        elif status in ("nonstandard", "deprecated") and not args.force:
            problem(
                f"filepath {path}: {status} -- {detail}",
                "Fix the path, or pass --force to file it anyway.",
            )
        else:
            if status in ("nonstandard", "deprecated"):
                print_status("WARN", f"{where}  {entry.label}", f"{status}: {detail}")
            file_path = path
        if path_field is None:
            problem(
                "gives a filepath, but this template has no field to put it in",
                f"{form.slug} fields: {', '.join(f.id for f in form.fields)}",
            )

    values = {
        key: str(value)
        for key, value in entry.values.items()
        if form.field(key) is not None and key not in backlog.STRUCTURAL_KEYS
    }
    if file_path and path_field is not None:
        values.setdefault(path_field.id, file_path)

    for missing in issue_forms.unanswered_required(form, values):
        problem(
            f"needs an answer for `{missing.id}`" + (f" ({missing.label})" if missing.label else ""),
            "The template's own default is example text, not an answer.",
        )

    title = ""
    try:
        title = issue_forms.render_title(
            form,
            str(entry.values.get("name") or "") or None,
            str(entry.values.get("title") or "") or None,
        )
    except DocumentError as exc:
        problem(str(exc).splitlines()[0], "Give the entry a `name:`, or a `title:` to replace it.")

    if problems:
        return None, problems

    return (
        IssuePlan(
            repo=repo,
            title=title,
            body=issue_forms.render_body(form, values),
            labels=tuple(
                dict.fromkeys([*form.labels, *_listed(entry.values.get("labels"))])
            ),
            assignees=tuple(_listed(entry.values.get("assignee"))),
            file_path=file_path,
            path_field_id=path_field.id if path_field else "",
            priority=str(entry.values.get("priority") or "").strip(),
        ),
        [],
    )


# -- The recorder ----------------------------------------------------------


class DryRunRecorder:
    """Says where the number would go. Touches nothing."""

    def record(self, path: Path, entry: Entry, number: str) -> None:
        print_status("", f"would write `issue: {number}` into {relative(path)}")


class FileRecorder:
    """Splices the number into the entry it came from, immediately."""

    def record(self, path: Path, entry: Entry, number: str) -> None:
        backlog.splice_issue(path, entry.index, number)
        print_status("", f"issue: {number} written to {relative(path)}")


def pick_recorder(apply: bool):
    """--apply is the only thing that separates a rehearsal from an edit.

    The local twin of pick_runner, for the reason github.py gives: no command
    body contains `if args.apply`, so the dry run walks the same path with a
    different object rather than a different path with the same one.
    """
    return FileRecorder() if apply else DryRunRecorder()


def issue_number(url: str) -> str:
    return url.rstrip("/").rsplit("/", 1)[-1]


# -- backlog new -----------------------------------------------------------


class BacklogNewCommand:
    """Start a backlog file for an issue template.

    Writes documentation/pipeline/backlog/<slug>.yaml: a header explaining what
    the file is, a commented-out `defaults:` block, and one commented-out
    example entry carrying the template's own example text for every required
    field. Uncomment it, fill it in, copy it per asset.

    The example is commented out on purpose. A scaffold whose first entry was
    live would either file something nobody asked for, or fail validation on a
    file this tool had just written -- the templates' defaults are worked
    examples full of {placeholder}, which is exactly what `backlog file`
    refuses.

    There is no --check here, unlike every other command in this CLI that writes
    a file. --check means "this is generated and must equal what the generator
    produces", and a backlog file is meant to diverge from its scaffold the
    moment somebody uses it. Running `backlog file` without --apply is the
    check that applies to a filled-in one.
    """

    name = "new"
    help = "start a backlog file for an issue template"
    parents = ()

    def add_arguments(self, parser: argparse.ArgumentParser) -> None:
        parser.add_argument(
            "--template",
            required=True,
            help="issue template slug, e.g. create_model (see .github/ISSUE_TEMPLATE/)",
        )
        parser.add_argument(
            "--out", type=Path, help="write here instead of the backlog directory"
        )
        parser.add_argument(
            "--force", action="store_true", help="overwrite an existing backlog file"
        )

    def run(self, args: argparse.Namespace) -> int:
        form = issue_forms.load_form(args.template)
        path = args.out or backlog.scaffold_path(form)

        if path.exists() and not args.force:
            fail(
                f"{relative(path)} already exists.",
                "Add entries to it instead, or pass --force to start it over. "
                "--force discards whatever is in it, including issue numbers.",
            )
            return EXIT_CANNOT_RUN

        rendered = backlog.render_scaffold(form)
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(rendered, encoding="utf-8", newline="\n")

        print(f"Wrote {relative(path)} ({len(rendered.splitlines())} lines)")
        print_status("template", relative(form.path))
        print_status("keys", ", ".join(backlog.scaffold_keys(form)))
        print("\nFill it in, then:")
        print("  python tools/pipeline/pipeline.py backlog file")
        return EXIT_OK


# -- backlog file ----------------------------------------------------------


class BacklogFileCommand:
    """Open an issue for every unfiled entry in the backlog files.

    Reads documentation/pipeline/backlog/*.yaml -- each one naming the issue
    template its entries are for -- and files them, writing `issue: <number>`
    back into each entry as it goes. An entry that already has a number is
    skipped, so this is safe to run again, and running it again is exactly how
    you resume after a failure.

    Every selected file is validated before anything is sent, and one bad entry
    anywhere stops the whole run. Filing half a batch and reporting the rest is
    worse than filing none: the half that went is on the board, and the person
    who has to reconcile it is you. Narrow the run with --template or --from
    when that is not what you want.

    Validation itself is entirely local -- the templates and pipeline.yaml -- so
    every problem below is found before anything is sent. The dry run is not
    fully offline though: it still resolves the organization field ids in order
    to print the commands it would run, which is why it is not a CI gate.

    Dry run by default. Writes need `gh`, with the repo and project scopes:
        gh auth refresh -h github.com -s project
    """

    name = "file"
    help = "open issues for every unfiled entry in the backlog"
    parents = (BOARD_FLAGS, DOC_FLAGS, REPO_FLAGS, WRITE_FLAGS)

    def add_arguments(self, parser: argparse.ArgumentParser) -> None:
        parser.add_argument("--template", help="only this template's backlog file")
        parser.add_argument(
            "--from",
            dest="source",
            type=Path,
            help="read this backlog file instead of the backlog directory",
        )
        parser.add_argument("--repo", help="OWNER/NAME (default: this checkout's origin)")
        parser.add_argument(
            "--no-project",
            action="store_true",
            help="do not add the new issues to the project board",
        )
        parser.add_argument(
            "--force",
            action="store_true",
            help="file entries whose filepath breaks a naming convention",
        )

    def run(self, args: argparse.Namespace) -> int:
        paths = self._paths(args)
        if not paths:
            print(f"No backlog files in {relative(BACKLOG_DIR)}.")
            print(f"Start one:\n  {NEW_COMMAND}")
            return EXIT_OK

        repo = issue_command.resolve_repo(args)
        print(f"backlog file{'' if args.apply else ' (dry run)'}")
        print_status("repo", repo)
        print()

        # -- Everything is checked before anything is sent.
        planned: list[tuple[Backlog, Entry, IssuePlan]] = []
        problems: list[Problem] = []
        seen: dict[str, str] = {}
        loaded: list[tuple[Backlog, issue_forms.IssueForm]] = []

        for path in paths:
            doc = backlog.load_backlog(path)
            form = issue_forms.load_form(doc.slug)
            loaded.append((doc, form))
            pending, filed = doc.pending(), doc.filed()
            print_status(
                "backlog",
                relative(path),
                f"template {doc.slug} -- {len(pending)} to file, {len(filed)} already filed",
            )

            for entry in pending:
                plan, entry_problems = plan_for(doc, form, entry, repo=repo, args=args)
                problems += entry_problems
                if plan is None:
                    continue
                if plan.file_path:
                    other = seen.get(plan.file_path)
                    if other:
                        problems.append(
                            Problem(
                                doc.where(entry),
                                entry.label,
                                f"filepath {plan.file_path} is already claimed by {other}",
                                "Two issues for one asset is the thing the board "
                                "cannot sort out later.",
                            )
                        )
                        continue
                    seen[plan.file_path] = f"{entry.label} ({doc.where(entry)})"
                planned.append((doc, entry, plan))

        if problems:
            print()
            for problem in problems:
                problem.report()
            print()
            fail(
                f"{len(problems)} problem(s). Nothing was created.",
                "Every backlog file is checked before anything is sent, so one bad entry "
                "holds up the batch.\nFix them, or narrow the run with --template or --from.",
            )
            return EXIT_CHECK_FAILED

        if not planned:
            if any(doc.entries for doc, _ in loaded):
                print("\nNothing to file. Every entry already has an issue number.")
            else:
                print("\nNothing to file: no entries yet. Add some, then run this again.")
            return EXIT_OK

        return self._create(args, planned)

    # -- the pieces --------------------------------------------------------

    def _paths(self, args: argparse.Namespace) -> list[Path]:
        if args.source:
            if not args.source.is_file():
                raise DocumentError(f"{relative(args.source)} does not exist")
            return [args.source]
        if args.template:
            form = issue_forms.load_form(args.template)
            path = backlog.scaffold_path(form)
            if not path.is_file():
                raise DocumentError(
                    f"{relative(path)} does not exist.\nStart it:\n"
                    f"  python tools/pipeline/pipeline.py backlog new --template {form.slug}"
                )
            return [path]
        return backlog.backlog_paths()

    def _create(
        self,
        args: argparse.Namespace,
        planned: list[tuple[Backlog, Entry, IssuePlan]],
    ) -> int:
        runner = issue_command.pick_runner(args.apply)
        recorder = pick_recorder(args.apply)
        warnings: list[str] = []
        filed: list[tuple[str, str]] = []

        print(f"\nfiling {len(planned)} issue(s){'' if args.apply else ' (dry run)'}\n")

        for doc, entry, plan in planned:
            print_status("filing", f"{entry.label}  ({relative(doc.path)})")
            try:
                url = issue_command.file_issue(
                    runner,
                    plan,
                    org=args.org,
                    project=None if args.no_project else args.project,
                    token=args.token,
                    warnings=warnings,
                    # Recorded here, not after the call returns: this fires the
                    # moment the issue exists, which is the only point at which
                    # losing the number would mean filing a duplicate.
                    on_created=lambda url, doc=doc, entry=entry: recorder.record(
                        doc.path, entry, issue_number(url)
                    ),
                )
            except github.TransportError as exc:
                for warning in warnings:
                    print_status("WARN", warning)
                print()
                print(github.explain_transport_error(str(exc), write=True), file=sys.stderr)
                self._ledger(filed, len(planned))
                return EXIT_CANNOT_RUN

            filed.append((relative(doc.path), issue_number(url)))
            print_status("", f"-> {url}")

        for warning in warnings:
            print_status("WARN", warning)

        if args.apply:
            print(f"\nCreated {len(filed)} issue(s).")
            print("The numbers are in the backlog files; re-running files nothing.")
        else:
            print("\nNothing was created. Re-run with --apply.")
        return EXIT_OK

    def _ledger(self, filed: list[tuple[str, str]], total: int) -> None:
        """What was created, and what to do next. The whole point of the splice."""
        print(f"\n{len(filed)} of {total} issue(s) were created before this stopped.")
        if filed:
            by_file: dict[str, list[str]] = {}
            for path, number in filed:
                by_file.setdefault(path, []).append(f"#{number}")
            for path, numbers in by_file.items():
                print_status("", f"{path}  {' '.join(numbers)}")
            print("\nTheir numbers are already written back.")
        print("Fix the above and re-run the same command: what was filed is skipped.")
