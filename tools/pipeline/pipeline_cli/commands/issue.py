"""`pipeline.py issue ...` -- opening and amending the issues that track assets.

These are the only commands in the CLI that change anything outside the
checkout, so they are dry runs by default: without --apply nothing is sent, and
what would have been sent is printed instead. The choice is made once, by
picking a runner, so the printed sequence is produced by the same code that
would have executed it.
"""

from __future__ import annotations

import argparse
from dataclasses import dataclass
from pathlib import Path
from typing import Callable

from .. import board, github, issue_forms
from ..command import BOARD_FLAGS, DOC_FLAGS, REPO_FLAGS, WRITE_FLAGS
from ..common import (
    EXIT_CANNOT_RUN,
    EXIT_OK,
    DocumentError,
    fail,
    load_doc,
    print_status,
    relative,
)

PATH_FIELD_NAME = "filepath"


# -- Shared helpers --------------------------------------------------------


def resolve_repo(args: argparse.Namespace) -> str:
    """--repo, else the checkout's own origin. Never a hardcoded default.

    A silently wrong default here files an issue in the wrong repository, which
    is the one mistake --apply cannot take back.
    """
    repo = args.repo or board.local_repo_slug(args.repo_root)
    if not repo:
        raise DocumentError(
            "could not tell which repository to use: "
            f"{relative(args.repo_root)} has no origin remote. Pass --repo OWNER/NAME."
        )
    return repo


def pick_runner(apply: bool) -> github.CommandRunner:
    """--apply is the only thing that separates a rehearsal from a write."""
    if not apply:
        return github.DryRunRunner()
    github.require_gh()
    return github.GhRunner()


def parse_fields(pairs: list[str] | None) -> dict[str, str]:
    """--field id=value, repeatable. The escape hatch for any template field."""
    values: dict[str, str] = {}
    for pair in pairs or []:
        identifier, separator, value = pair.partition("=")
        if not separator or not identifier.strip():
            raise DocumentError(f"--field expects id=value, got {pair!r}")
        values[identifier.strip()] = value
    return values


def inspect_path(raw: str, doc: Path) -> tuple[str, str, str, str]:
    """(cleaned, stage, status, detail) for a filepath. Never raises, never prints.

    The facts without the prose. `validated_path` phrases these as errors about
    a `--filepath` flag; the backlog phrases them as errors about an entry in a
    file. Both need the same answer, and the rules stay in board.py either way.

    stage is "unusable" when the value is not a path at all (blank, a
    {placeholder}) and "checked" once it has been measured against
    pipeline.yaml. Keeping them apart matters: check_path's "unchecked" means
    the conventions have nothing to say about this extension, which is a pass,
    while clean_path_value's statuses are all failures.
    """
    cleaned = board.clean_path_value(raw)[0]
    if cleaned.status != "ok":
        return cleaned.path, "unusable", cleaned.status, cleaned.detail

    try:
        conventions = board.load_conventions(board.load_doc(doc))
    except DocumentError:
        # The naming rules being unreadable must not block filing an issue.
        return cleaned.path, "checked", "ok", ""

    status, detail = board.check_path(cleaned.path, conventions)
    return cleaned.path, "checked", status, detail


def validated_path(raw: str, args: argparse.Namespace) -> str:
    """Clean and check a filepath, refusing rather than warning.

    `asset list` warns about a nonstandard path and never changes its exit code,
    because by then the issue exists and the reader is not the person who typed
    it. At authoring time the fix is free, so this refuses instead.
    """
    path, stage, status, detail = inspect_path(raw, args.doc)
    if stage == "unusable":
        raise DocumentError(
            f"--filepath {raw!r} {detail}. Give a repository-relative path, "
            "e.g. assets/art/3d/props/rain_barrel/sm_rain_barrel.gltf"
        )

    if status in ("nonstandard", "deprecated") and not args.force:
        raise DocumentError(
            f"{path}: {status} -- {detail}\n"
            "Fix the path, or pass --force to open the issue anyway."
        )
    if status in ("nonstandard", "deprecated"):
        print_status("WARN", path, f"{status}: {detail}")
    return path


@dataclass(frozen=True)
class IssuePlan:
    """Everything needed to open one issue, with nothing left to decide."""

    repo: str
    title: str
    body: str
    labels: tuple[str, ...] = ()
    assignees: tuple[str, ...] = ()
    file_path: str = ""
    path_field_id: str = ""  # the form field the path went into, for reporting
    priority: str = ""


def file_issue(
    runner: github.CommandRunner,
    plan: IssuePlan,
    *,
    org: str,
    project: int | None,
    token: str | None,
    warnings: list[str],
    on_created: Callable[[str], None] | None = None,
) -> str:
    """Create the issue, board it, set its filepath and priority. Returns the URL.

    `project=None` skips the board. Nothing here prints: `issue create` and
    `backlog file` report very differently, and DryRunRunner already echoes each
    command as it goes.

    on_created fires the instant `gh issue create` returns, before the three
    calls that follow. That is the earliest moment the issue exists, and it is
    the only safe moment to record its number: a failure in `project item-add`
    or `issue view` would otherwise leave an issue nobody has a record of, and
    the next run would open a second one. Everything after the creation is
    recoverable with `issue update`; a duplicate is not.
    """
    create = ["issue", "create", "--repo", plan.repo, "--title", plan.title, "--body-file", "-"]
    for label in plan.labels:
        create += ["--label", label]
    for assignee in plan.assignees:
        create += ["--assignee", assignee]

    # The body is several KB of checklist. stdin sidesteps shell quoting and
    # argv length limits entirely, the same reason GhCliClient uses -F @-.
    url = runner.run(create, stdin=plan.body).stdout.strip().splitlines()[-1]
    if on_created is not None:
        on_created(url)

    if project is not None:
        try:
            runner.run(
                [
                    "project",
                    "item-add",
                    str(project),
                    "--owner",
                    org,
                    "--url",
                    url,
                    "--format",
                    "json",
                ]
            )
        except github.TransportError as exc:
            warnings.append(f"could not add {url} to project {project} ({exc})")

    if plan.file_path or plan.priority:
        issue_id = runner.run(
            ["issue", "view", url, "--repo", plan.repo, "--json", "id", "--jq", ".id"]
        ).stdout.strip()
        client = board.choose_client(token)
        if plan.file_path:
            set_issue_text_field(
                runner, client, org, issue_id, PATH_FIELD_NAME, plan.file_path, warnings
            )
        if plan.priority:
            set_issue_select_field(
                runner, client, org, issue_id, "Priority", plan.priority, warnings
            )

    return url


def set_issue_select_field(
    runner: github.CommandRunner,
    client: github.GraphQLClient,
    org: str,
    issue_id: str,
    field_name: str,
    value: str,
    warnings: list[str],
) -> None:
    """Set a single-select organization issue field, e.g. Priority.

    The select twin of set_issue_text_field, and degrades the same way: an
    option that does not exist is a warning naming the options that do, not a
    reason to fail an issue that has already been created.
    """
    try:
        fields = github.issue_field_ids(client, org)
        target = github.find_field(fields, field_name)
        option = target.option_id(value) if target else None
        if option is None:
            choices = ", ".join(target.options) if target else "none"
            warnings.append(f"{field_name} has no option {value!r} (options: {choices})")
            return
        runner.run(
            [
                "api",
                "graphql",
                "-f",
                "query=@-",
                "-f",
                f"issueId={issue_id}",
                "-f",
                f"fieldId={target.id}",
                "-f",
                f"optionId={option}",
            ],
            stdin=github.SET_ISSUE_SELECT_FIELD,
        )
    except github.TransportError as exc:
        warnings.append(f"could not set {field_name} ({exc})")


def set_issue_text_field(
    runner: github.CommandRunner,
    client: github.GraphQLClient,
    org: str,
    issue_id: str,
    field_name: str,
    value: str,
    warnings: list[str],
) -> None:
    """Set an organization issue field, degrading to a warning if it cannot.

    Organization issue fields are recent enough that an older GitHub will not
    have them. The issue body already carries the path, so failing here loses a
    board column and nothing else -- not a reason to fail a created issue.
    """
    try:
        fields = github.issue_field_ids(client, org)
        target = github.find_field(fields, field_name)
        if target is None:
            available = ", ".join(sorted(fields)) or "none"
            warnings.append(
                f"{org} has no issue field named {field_name!r} (available: {available}); "
                f"set it by hand to {value}"
            )
            return
        runner.run(
            [
                "api",
                "graphql",
                "-f",
                "query=@-",
                "-f",
                f"issueId={issue_id}",
                "-f",
                f"fieldId={target.id}",
                "-f",
                f"value={value}",
            ],
            stdin=github.SET_ISSUE_TEXT_FIELD,
        )
    except github.TransportError as exc:
        warnings.append(f"could not set {field_name} ({exc}); set it by hand to {value}")


# -- issue create ----------------------------------------------------------


class IssueCreateCommand:
    """Open an asset issue from a .github/ISSUE_TEMPLATE form.

    The body is rendered from the template exactly as GitHub renders a submitted
    form, so an issue opened here and one opened in the browser are the same
    document -- including the generated subtasks checklist the template carries.

    The filepath is validated against pipeline.yaml before anything is created:
    a {placeholder} or a nonstandard name is refused, because it costs nothing
    to fix now and shows up as an unusable row on the board forever otherwise.

    Dry run by default. Needs `gh`, with the repo and project scopes:
        gh auth refresh -h github.com -s project
    """

    name = "create"
    help = "open an asset issue from an issue template"
    parents = (BOARD_FLAGS, DOC_FLAGS, REPO_FLAGS, WRITE_FLAGS)

    def add_arguments(self, parser: argparse.ArgumentParser) -> None:
        parser.add_argument(
            "--template",
            required=True,
            help="issue template slug, e.g. create_model (see .github/ISSUE_TEMPLATE/)",
        )
        parser.add_argument("--name", help="asset name, substituted into the template title")
        parser.add_argument("--title", help="use this title verbatim instead of the template's")
        parser.add_argument("--filepath", help="where the asset will live in the repository")
        parser.add_argument("--description", help="fills the template's Description field")
        parser.add_argument(
            "--field",
            action="append",
            metavar="ID=VALUE",
            help="fill any other template field; repeatable",
        )
        parser.add_argument("--repo", help="OWNER/NAME (default: this checkout's origin)")
        parser.add_argument("--label", action="append", help="extra label; repeatable")
        parser.add_argument("--assignee", action="append", help="assignee; repeatable")
        parser.add_argument(
            "--no-project",
            action="store_true",
            help="do not add the new issue to the project board",
        )
        parser.add_argument(
            "--force",
            action="store_true",
            help="open the issue even if the filepath breaks a naming convention",
        )

    def run(self, args: argparse.Namespace) -> int:
        form = issue_forms.load_form(args.template)
        repo = resolve_repo(args)

        values = parse_fields(args.field)
        if args.description:
            values.setdefault("description", args.description)

        path_field = form.path_field()
        file_path = ""
        if args.filepath:
            file_path = validated_path(args.filepath, args)
            if path_field is None:
                raise DocumentError(
                    f"{form.slug} has no field that holds a filepath, so --filepath "
                    f"has nowhere to go. Fields: {', '.join(f.id for f in form.fields)}"
                )
            values.setdefault(path_field.id, file_path)

        title = issue_forms.render_title(form, args.name, args.title)
        body = issue_forms.render_body(form, values)
        labels = list(dict.fromkeys([*form.labels, *(args.label or [])]))

        print(f"issue create{'' if args.apply else ' (dry run)'}")
        print_status("template", relative(form.path))
        print_status("repo", repo)
        print_status("title", title)
        if file_path:
            print_status("filepath", file_path)
            print_status("", f"-> form field `{path_field.id}` ({path_field.label})")
        print()

        runner = pick_runner(args.apply)
        warnings: list[str] = []
        url = file_issue(
            runner,
            IssuePlan(
                repo=repo,
                title=title,
                body=body,
                labels=tuple(labels),
                assignees=tuple(args.assignee or []),
                file_path=file_path,
                path_field_id=path_field.id if path_field else "",
            ),
            org=args.org,
            project=None if args.no_project else args.project,
            token=args.token,
            warnings=warnings,
        )

        print(f"\n--- body ({len(body.encode('utf-8'))} bytes) ---")
        print(body.rstrip())
        print("--- end body ---")

        for warning in warnings:
            print_status("WARN", warning)

        if args.apply:
            print(f"\nCreated {url}")
        else:
            print("\nNothing was created. Re-run with --apply.")
        return EXIT_OK


# -- issue update ----------------------------------------------------------


class IssueUpdateCommand:
    """Amend an issue that already exists: its filepath, fields, labels or state.

    --filepath sets the organization issue field the board projects as its
    filepath column. It is validated exactly as `issue create` validates it, so
    a path that could not be filed cannot be patched in later either.

    --resync-subtasks re-renders the generated checklist inside an issue that is
    already open, which is otherwise only possible by closing and reopening it:
    re-rendering the templates only affects issues created afterwards.

    Dry run by default. Needs `gh`, with the repo and project scopes:
        gh auth refresh -h github.com -s project
    """

    name = "update"
    help = "amend an existing asset issue"
    parents = (BOARD_FLAGS, DOC_FLAGS, REPO_FLAGS, WRITE_FLAGS)

    def add_arguments(self, parser: argparse.ArgumentParser) -> None:
        parser.add_argument("number", type=int, help="issue number")
        parser.add_argument("--repo", help="OWNER/NAME (default: this checkout's origin)")
        parser.add_argument("--filepath", help="set the issue's filepath field")
        parser.add_argument("--title", help="new title")
        parser.add_argument("--body-file", type=Path, help="replace the body with this file")
        parser.add_argument("--add-label", action="append", help="repeatable")
        parser.add_argument("--remove-label", action="append", help="repeatable")
        parser.add_argument("--state", choices=("open", "closed"))
        parser.add_argument("--priority", help="set the Priority issue field")
        parser.add_argument("--status", help="set the Status column on the project board")
        parser.add_argument(
            "--resync-subtasks",
            action="store_true",
            help="re-render the generated subtasks block inside the issue body",
        )
        parser.add_argument(
            "--template",
            help="template slug the issue came from; required by --resync-subtasks",
        )
        parser.add_argument(
            "--force",
            action="store_true",
            help="accept a filepath that breaks a naming convention",
        )

    def run(self, args: argparse.Namespace) -> int:
        repo = resolve_repo(args)
        file_path = validated_path(args.filepath, args) if args.filepath else ""

        wanted = [
            name
            for name, value in (
                ("--filepath", file_path),
                ("--title", args.title),
                ("--body-file", args.body_file),
                ("--add-label", args.add_label),
                ("--remove-label", args.remove_label),
                ("--state", args.state),
                ("--priority", args.priority),
                ("--status", args.status),
                ("--resync-subtasks", args.resync_subtasks),
            )
            if value
        ]
        if not wanted:
            fail(
                "nothing to change.",
                "Pass at least one of --filepath, --title, --body-file, --add-label, "
                "--remove-label, --state, --priority, --status, --resync-subtasks.",
            )
            return EXIT_CANNOT_RUN

        if args.resync_subtasks and not args.template:
            fail(
                "--resync-subtasks needs --template.",
                "An issue does not record which template it came from, and splicing "
                "the wrong checklist in is worse than not splicing one.",
            )
            return EXIT_CANNOT_RUN

        print(f"issue update #{args.number}{'' if args.apply else ' (dry run)'}")
        print_status("repo", repo)
        print_status("changing", ", ".join(wanted))
        print()

        runner = pick_runner(args.apply)
        warnings: list[str] = []

        edit = self._edit_args(args, repo)
        if edit:
            runner.run(edit)

        if args.resync_subtasks:
            self._resync_subtasks(runner, args, repo, warnings)

        if file_path or args.priority:
            issue_id = runner.run(
                ["issue", "view", str(args.number), "--repo", repo, "--json", "id", "--jq", ".id"]
            ).stdout.strip()
            client = board.choose_client(args.token)
            if file_path:
                set_issue_text_field(
                    runner, client, args.org, issue_id, PATH_FIELD_NAME, file_path, warnings
                )
            if args.priority:
                self._set_priority(runner, client, args, issue_id, warnings)

        if args.status:
            self._set_status(runner, args, repo, warnings)

        if args.state:
            runner.run(
                ["issue", "close" if args.state == "closed" else "reopen", str(args.number),
                 "--repo", repo]
            )

        for warning in warnings:
            print_status("WARN", warning)

        if args.apply:
            print(f"\nUpdated https://github.com/{repo}/issues/{args.number}")
        else:
            print("\nNothing was changed. Re-run with --apply.")
        return EXIT_OK

    # -- the pieces --------------------------------------------------------

    def _edit_args(self, args: argparse.Namespace, repo: str) -> list[str] | None:
        """Everything `gh issue edit` can do, in one call, or None for nothing.

        --state is deliberately not here: gh models it as close/reopen rather
        than as an edit flag.
        """
        changes: list[str] = []
        if args.title:
            changes += ["--title", args.title]
        if args.body_file:
            changes += ["--body-file", str(args.body_file)]
        for label in args.add_label or []:
            changes += ["--add-label", label]
        for label in args.remove_label or []:
            changes += ["--remove-label", label]

        if not changes:
            return None
        return ["issue", "edit", str(args.number), "--repo", repo, *changes]

    def _resync_subtasks(
        self,
        runner: github.CommandRunner,
        args: argparse.Namespace,
        repo: str,
        warnings: list[str],
    ) -> None:
        """Re-render the generated block inside an already-open issue.

        Which template an issue came from is not recorded anywhere on the issue,
        so --template says it. Getting that wrong would splice one asset kind's
        checklist into another's, which is why it is required rather than
        guessed.
        """
        from ..templates import BLOCK_RE, build_block, collect_checklists

        template_path = relative(issue_forms.load_form(args.template).path)
        checklists = collect_checklists(load_doc(args.doc))
        items = checklists.get(template_path)
        if items is None:
            warnings.append(
                f"{template_path} has no checklist rules in pipeline.yaml; "
                "nothing was resynced"
            )
            return

        body = runner.run(
            ["issue", "view", str(args.number), "--repo", repo, "--json", "body", "--jq", ".body"]
        ).stdout
        match = BLOCK_RE.search(body)
        if match is None:
            warnings.append(
                f"issue #{args.number} has no pipeline:subtasks block; nothing was resynced. "
                "Only issues opened from a managed template carry one."
            )
            return

        block = build_block(items, match.group(1))
        if match.group(0) == block:
            print_status("ok", f"#{args.number} subtasks already current")
            return

        updated = body[: match.start()] + block + body[match.end() :]
        runner.run(
            ["issue", "edit", str(args.number), "--repo", repo, "--body-file", "-"],
            stdin=updated,
        )

    def _set_priority(
        self,
        runner: github.CommandRunner,
        client: github.GraphQLClient,
        args: argparse.Namespace,
        issue_id: str,
        warnings: list[str],
    ) -> None:
        set_issue_select_field(
            runner, client, args.org, issue_id, "Priority", args.priority, warnings
        )

    def _set_status(
        self,
        runner: github.CommandRunner,
        args: argparse.Namespace,
        repo: str,
        warnings: list[str],
    ) -> None:
        """Status is a project column, so it needs the item id, not the issue id."""
        try:
            client = board.choose_client(args.token)
            pages = board.fetch_pages(client, args.org, args.project, board.DEFAULT_PAGE_SIZE)
            meta = board.project_meta(pages)
            items = board.build_items(pages)
        except github.TransportError as exc:
            warnings.append(f"could not read project {args.project} to set Status ({exc})")
            return

        item = next(
            (i for i in items if i.number == args.number and i.repo == repo),
            None,
        )
        if item is None:
            warnings.append(f"#{args.number} is not on project {args.project}; Status not set")
            return

        column = next(
            (f for f in meta.get("fields", []) if (f.get("name") or "").casefold() == "status"),
            None,
        )
        option = None
        if column:
            wanted = args.status.casefold()
            options = (column.get("options") or {}).items()
            option = next((i for name, i in options if name.casefold() == wanted), None)
        if not column or not column.get("id") or option is None:
            choices = ", ".join((column or {}).get("options") or {}) or "none"
            warnings.append(f"Status has no option {args.status!r} (options: {choices})")
            return

        runner.run(
            [
                "api",
                "graphql",
                "-f",
                "query=@-",
                "-f",
                f"projectId={meta['id']}",
                "-f",
                f"itemId={item.item_id}",
                "-f",
                f"fieldId={column['id']}",
                "-f",
                f"optionId={option}",
            ],
            stdin=github.SET_PROJECT_SELECT_FIELD,
        )
