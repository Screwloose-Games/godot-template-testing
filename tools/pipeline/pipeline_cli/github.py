"""Transport to GitHub: how a request is made, not what is asked.

Reads go over GraphQL through a swappable client, so the same query text can run
against the gh CLI, a bare token, or a recorded fixture. The tests never touch
the network because of that last one -- the recording is in exactly the shape
`--dump-json` writes, so re-recording against the live board is one command.

Writes go through gh and nothing else, behind a second swappable seam: the same
command sequence runs for real, prints itself, or is captured by a test. That is
why no command body contains `if args.apply` -- the choice is made once, when the
runner is picked, so the dry run exercises the identical code path.

Nothing here knows what a project board or an asset is. The queries live beside
the code that interprets their answers, in board.py.
"""

from __future__ import annotations

import json
import os
import re
import shlex
import shutil
import subprocess
import urllib.error
import urllib.request
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any, Protocol


class TransportError(RuntimeError):
    """The request could not be made or came back unusable."""


class GraphQLClient(Protocol):
    def execute(self, query: str, variables: dict[str, Any]) -> dict[str, Any]: ...


class GhCliClient:
    """Shell out to `gh api graphql`.

    gh already holds the token, handles org SSO authorization and host config,
    and reports rate limits properly. Reimplementing that here would mean a
    GITHUB_TOKEN dance the artists this tool serves have not set up.
    """

    name = "gh"

    def __init__(self, executable: str = "gh") -> None:
        self.executable = executable

    def execute(self, query: str, variables: dict[str, Any]) -> dict[str, Any]:
        # -F reads the @- placeholder from stdin (-f would pass "@-" literally)
        # and sidesteps shell quoting of a multi-line query entirely.
        args = [self.executable, "api", "graphql", "-F", "query=@-"]
        for key, value in variables.items():
            if value is None:
                continue
            if isinstance(value, bool) or isinstance(value, int):
                args += ["-F", f"{key}={value}"]
            else:
                # -f keeps strings raw. A cursor that happens to look numeric
                # must not be type-inferred into an Int.
                args += ["-f", f"{key}={value}"]

        try:
            proc = subprocess.run(
                args, input=query, capture_output=True, text=True, encoding="utf-8", check=False
            )
        except FileNotFoundError as exc:
            raise TransportError(f"could not run {self.executable!r}: {exc}") from exc

        if proc.stdout.strip():
            try:
                payload = json.loads(proc.stdout)
            except json.JSONDecodeError:
                payload = None
            if payload is not None:
                return _unwrap(payload, proc.stderr)

        raise TransportError(proc.stderr.strip() or f"gh exited {proc.returncode} with no output")


class UrllibClient:
    """Stdlib fallback for containers that have a token but no gh.

    Deliberately not `requests`: it appears in exactly one file in this repo and
    adding a second consumer would create an install story that does not exist.
    """

    name = "GITHUB_TOKEN"

    def __init__(self, token: str, endpoint: str = "https://api.github.com/graphql") -> None:
        self.token = token
        self.endpoint = endpoint

    def execute(self, query: str, variables: dict[str, Any]) -> dict[str, Any]:
        body = json.dumps({"query": query, "variables": variables}).encode("utf-8")
        request = urllib.request.Request(
            self.endpoint,
            data=body,
            headers={
                "Authorization": f"bearer {self.token}",
                "Content-Type": "application/json",
                "User-Agent": "godot-jam-template-asset-report",
            },
        )
        try:
            with urllib.request.urlopen(request, timeout=30) as response:
                payload = json.loads(response.read().decode("utf-8"))
        except (urllib.error.URLError, TimeoutError, json.JSONDecodeError) as exc:
            raise TransportError(str(exc)) from exc
        return _unwrap(payload, "")


_ALIAS_RE = re.compile(r"(pr\d+): pullRequest\(number: (\d+)\)")


class RecordedClient:
    """Replay a --dump-json recording so the tests never touch the network.

    Serves both query shapes: board pages in order, and PR file lists looked up
    by number. The aliases are re-derived from the query text so a recording
    stays valid however the batches happen to be split up on replay.
    """

    name = "recording"

    def __init__(
        self, pages: list[dict[str, Any]], pr_files: dict[str, dict[str, list[str]]] | None = None
    ) -> None:
        self.pages = list(pages)
        self.pr_files = pr_files or {}
        self.calls = 0
        self.pr_calls = 0

    @classmethod
    def from_file(cls, path: Path) -> RecordedClient:
        payload = json.loads(path.read_text(encoding="utf-8"))
        if isinstance(payload, list):
            return cls(payload)
        return cls(payload.get("pages", [payload]), payload.get("pr_files"))

    def execute(self, query: str, variables: dict[str, Any]) -> dict[str, Any]:
        if "pullRequest(number:" in query:
            self.pr_calls += 1
            repo = f"{variables.get('owner', '')}/{variables.get('name', '')}"
            table = self.pr_files.get(repo, {})
            repository: dict[str, Any] = {}
            for alias, number in _ALIAS_RE.findall(query):
                paths = table.get(str(number))
                if paths is None:
                    continue
                repository[alias] = {
                    "files": {
                        "pageInfo": {"hasNextPage": False},
                        "nodes": [{"path": path} for path in paths],
                    }
                }
            return {"repository": repository}

        if self.calls >= len(self.pages):
            raise TransportError(
                f"recording has {len(self.pages)} page(s) but a {self.calls + 1}th was requested"
            )
        page = self.pages[self.calls]
        self.calls += 1
        return page


def _unwrap(payload: dict[str, Any], stderr: str) -> dict[str, Any]:
    """Turn a GraphQL error envelope into a TransportError with a usable message."""
    errors = payload.get("errors")
    if errors:
        messages = [str(err.get("message", err)) for err in errors]
        raise TransportError("; ".join(dict.fromkeys(messages)) or stderr.strip())
    if "data" not in payload:
        raise TransportError(stderr.strip() or "response contained no data")
    return payload["data"]


def explain_transport_error(message: str, *, write: bool = False) -> str:
    """The likely first-run failures need different fixes, so name them.

    `write` matters: reading a board needs read:project, but adding an item to
    one or setting an issue field needs the full project scope. Handing someone
    the read-only remediation for a write failure sends them round the loop
    twice.
    """
    lowered = message.lower()
    if write and (
        "insufficient_scopes" in lowered
        or "project" in lowered
        or "403" in lowered
        or "resource not accessible" in lowered
        or "must have admin rights" in lowered
    ):
        return (
            "ERROR: your GitHub token cannot write to Projects.\n"
            "Run:  gh auth refresh -h github.com -s project\n"
            f"\n{message}"
        )
    if "read:project" in lowered or "insufficient_scopes" in lowered:
        return (
            "ERROR: your GitHub token cannot read Projects.\n"
            "Run:  gh auth refresh -h github.com -s read:project"
        )
    if "saml" in lowered or "sso" in lowered:
        return (
            "ERROR: this token is not authorized for the organization's SAML SSO.\n"
            "Run:  gh auth login   and authorize the org in the browser when prompted."
        )
    if "could not run" in lowered or ("not found" in lowered and "gh" in lowered):
        return (
            "ERROR: the GitHub CLI is not available.\n"
            "Install gh, or set GITHUB_TOKEN and re-run."
        )
    return f"ERROR: could not read the project board.\n{message}"


def choose_client(prefer_token: str | None) -> GraphQLClient:
    if prefer_token:
        return UrllibClient(prefer_token)
    if shutil.which("gh"):
        return GhCliClient()
    token = os.environ.get("GITHUB_TOKEN") or os.environ.get("GH_TOKEN")
    if token:
        return UrllibClient(token)
    raise TransportError("could not run 'gh': not on PATH, and no GITHUB_TOKEN is set")


# -- Writing ---------------------------------------------------------------

# Mutations go through the gh CLI rather than GraphQL-over-urllib: gh already
# holds a token with the right scopes, and a write is the last place to
# reimplement auth. The Protocol exists so the dry run and the tests execute the
# same call sequence as a real run, with only the runner swapped.


@dataclass(frozen=True)
class RunResult:
    code: int
    stdout: str = ""
    stderr: str = ""


class CommandRunner(Protocol):
    name: str

    def run(self, args: list[str], stdin: str | None = None) -> RunResult: ...


# What a dry run pretends `gh` said, so the steps after the first still print.
# The URL ends in a word no issue number can be, because it will be echoed into
# the later commands and must never be mistaken for a real one.
DRY_RUN_ISSUE_URL = "https://github.com/OWNER/REPO/issues/DRY-RUN"
DRY_RUN_NODE_ID = "I_DRY-RUN"


class GhRunner:
    """Run gh for real."""

    name = "gh"

    def __init__(self, executable: str = "gh") -> None:
        self.executable = executable

    def run(self, args: list[str], stdin: str | None = None) -> RunResult:
        try:
            proc = subprocess.run(
                [self.executable, *args],
                input=stdin,
                capture_output=True,
                text=True,
                encoding="utf-8",
                check=False,
            )
        except FileNotFoundError as exc:
            raise TransportError(f"could not run {self.executable!r}: {exc}") from exc

        if proc.returncode != 0:
            raise TransportError(
                proc.stderr.strip() or f"gh {' '.join(args)} exited {proc.returncode}"
            )
        return RunResult(proc.returncode, proc.stdout, proc.stderr)


class DryRunRunner:
    """Print what would run and answer plausibly, so the whole plan is visible.

    Stopping at the first command would show one line of a three-command
    sequence. Answering with an obvious placeholder shows all of it, and the
    placeholder is visibly not a real issue.
    """

    name = "dry-run"

    def __init__(self) -> None:
        self.calls: list[list[str]] = []

    def run(self, args: list[str], stdin: str | None = None) -> RunResult:
        self.calls.append(list(args))
        print(f"  gh {shlex.join(args)}")
        return RunResult(0, canned_stdout(args))


@dataclass
class RecordedRunner:
    """Capture calls and replay canned answers, so the tests stay offline.

    The mutation-side twin of RecordedClient. `calls` is the assertion surface:
    a dry run must produce an empty one on the real runner.
    """

    name: str = "recording"
    responses: list[RunResult] = field(default_factory=list)
    calls: list[tuple[list[str], str | None]] = field(default_factory=list)

    def run(self, args: list[str], stdin: str | None = None) -> RunResult:
        self.calls.append((list(args), stdin))
        if self.responses:
            result = self.responses.pop(0)
            if result.code != 0:
                raise TransportError(result.stderr or f"gh exited {result.code}")
            return result
        return RunResult(0, canned_stdout(args))

    def argv(self) -> list[list[str]]:
        return [args for args, _ in self.calls]


def canned_stdout(args: list[str]) -> str:
    """A believable answer for the gh commands whose output a later step reads."""
    if args[:2] == ["issue", "create"]:
        return DRY_RUN_ISSUE_URL + "\n"
    if args[:2] == ["issue", "view"]:
        return DRY_RUN_NODE_ID + "\n"
    if "--format" in args and "json" in args:
        return "{}\n"
    return ""


def require_gh() -> None:
    """Fail before doing half a job, rather than between two of three writes."""
    if not shutil.which("gh"):
        raise TransportError(
            "could not run 'gh': not on PATH. Writing to GitHub needs the gh CLI; "
            "a token is not enough here."
        )


# -- Organization issue fields ---------------------------------------------

# `filepath` is an organization issue field, not a project column, and no gh
# subcommand can set one -- hence the raw mutation. The ids are discovered by
# name every time rather than pinned: the field is renameable from org settings,
# and a hardcoded id would fail with something unreadable when it changed.

ISSUE_FIELDS_QUERY = """
query($org: String!) {
  organization(login: $org) {
    issueFields(first: 50) {
      nodes {
        __typename
        ... on IssueFieldText { id name }
        ... on IssueFieldNumber { id name }
        ... on IssueFieldDate { id name }
        ... on IssueFieldSingleSelect { id name options { id name } }
      }
    }
  }
}
""".strip()

# Two mutations rather than one taking a list, because `gh api graphql` can only
# pass scalar variables (-f/-F). Building the list inline would mean interpolating
# values into query text, which is exactly the escaping problem the -f flags exist
# to avoid.
SET_ISSUE_TEXT_FIELD = """
mutation($issueId: ID!, $fieldId: ID!, $value: String!) {
  setIssueFieldValue(input: {
    issueId: $issueId,
    issueFields: [{fieldId: $fieldId, textValue: $value}]
  }) { issue { number url } }
}
""".strip()

SET_ISSUE_SELECT_FIELD = """
mutation($issueId: ID!, $fieldId: ID!, $optionId: String!) {
  setIssueFieldValue(input: {
    issueId: $issueId,
    issueFields: [{fieldId: $fieldId, singleSelectOptionId: $optionId}]
  }) { issue { number url } }
}
""".strip()

SET_PROJECT_SELECT_FIELD = """
mutation($projectId: ID!, $itemId: ID!, $fieldId: ID!, $optionId: String!) {
  updateProjectV2ItemFieldValue(input: {
    projectId: $projectId,
    itemId: $itemId,
    fieldId: $fieldId,
    value: {singleSelectOptionId: $optionId}
  }) { projectV2Item { id } }
}
""".strip()


@dataclass(frozen=True)
class IssueField:
    id: str
    name: str
    kind: str  # text | number | date | single_select
    options: dict[str, str] = field(default_factory=dict)

    def option_id(self, value: str) -> str | None:
        """Match an option by name, case-insensitively like every other name here."""
        wanted = value.casefold()
        for name, identifier in self.options.items():
            if name.casefold() == wanted:
                return identifier
        return None


_FIELD_KINDS = {
    "IssueFieldText": "text",
    "IssueFieldNumber": "number",
    "IssueFieldDate": "date",
    "IssueFieldSingleSelect": "single_select",
}


def issue_field_ids(client: GraphQLClient, org: str) -> dict[str, IssueField]:
    """Map organization issue-field name -> its id, kind and options."""
    data = client.execute(ISSUE_FIELDS_QUERY, {"org": org})
    nodes = (((data.get("organization") or {}).get("issueFields") or {}).get("nodes")) or []

    fields: dict[str, IssueField] = {}
    for node in nodes:
        kind = _FIELD_KINDS.get(node.get("__typename", ""))
        if not kind or not node.get("id"):
            continue
        options = {
            option["name"]: option["id"]
            for option in (node.get("options") or [])
            if option.get("name") and option.get("id")
        }
        fields[node["name"]] = IssueField(node["id"], node["name"], kind, options)
    return fields


def find_field(fields: dict[str, IssueField], name: str) -> IssueField | None:
    """Look a field up by name, case-insensitively."""
    wanted = name.casefold()
    for field_name, value in fields.items():
        if field_name.casefold() == wanted:
            return value
    return None
