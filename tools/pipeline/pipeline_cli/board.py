"""List assets tracked on the GitHub project board and whether they have landed.

Project 38 carries a custom text column named `filepath`. That column is the one
place an asset's destination is recorded, so this script reads it, and reports
two delivery signals side by side:

    on_disk        the file exists in the checkout you are standing in
    delivered_by   a linked pull request changed that file

They are deliberately separate. An asset committed without an issue-linked PR
and an asset promised by a PR that has not merged are different situations, and
collapsing them into one "delivered" column hides both. A third column,
path_status, says whether a path could be read at all -- otherwise "the column
is blank" masquerades as "not delivered".

Filepaths are validated against documentation/pipeline/pipeline.yaml as a
warning only. This never changes the exit code; it catches at issue-authoring
time what validate-model-files.py would otherwise only catch at PR time.

This is a report, not a gate. It reads and never writes anything but --out.

Requires the read:project scope, which is not granted by default:
    gh auth refresh -h github.com -s read:project

Driven by `pipeline.py asset list`; see pipeline_cli/commands/asset.py.
"""

from __future__ import annotations

import argparse
import json
import posixpath
import re
import subprocess
import sys
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any

from .common import DocumentError, load_doc, md_cell
from .github import (  # noqa: F401 -- re-exported so board is the one import for callers
    GhCliClient,
    GraphQLClient,
    RecordedClient,
    TransportError,
    UrllibClient,
    choose_client,
    explain_transport_error,
)

DEFAULT_ORG = "Screwloose-Games"
DEFAULT_PROJECT_NUMBER = 38
DEFAULT_PAGE_SIZE = 100

# The board's own column. Renameable from the project UI, hence --path-field.
DEFAULT_PATH_FIELD = "filepath"


# -- GraphQL ---------------------------------------------------------------

# Spliced in below. Kept separate so the degraded query is built by removing a
# whole block rather than by filtering lines out of the finished text.
CLOSED_BY_BLOCK = """
              closedByPullRequestsReferences(first: 10, includeClosedPrs: true) {
                nodes {
                  number url state merged mergedAt headRefOid
                  repository { nameWithOwner }
                }
              }"""

_PROJECT_QUERY_TEMPLATE = """
query($org: String!, $projectNumber: Int!, $cursor: String, $pageSize: Int!) {
  organization(login: $org) {
    projectV2(number: $projectNumber) {
      id
      title
      url
      fields(first: 50) {
        nodes {
          ... on ProjectV2FieldCommon { id name dataType }
          ... on ProjectV2SingleSelectField { id name options { id name } }
        }
      }
      items(first: $pageSize, after: $cursor) {
        totalCount
        pageInfo { hasNextPage endCursor }
        nodes {
          id
          type
          fieldValues(first: 20) {
            nodes {
              __typename
              ... on ProjectV2ItemFieldTextValue {
                text field { ... on ProjectV2FieldCommon { name } } }
              ... on ProjectV2ItemFieldNumberValue {
                number field { ... on ProjectV2FieldCommon { name } } }
              ... on ProjectV2ItemFieldDateValue {
                date field { ... on ProjectV2FieldCommon { name } } }
              ... on ProjectV2ItemFieldSingleSelectValue {
                name field { ... on ProjectV2FieldCommon { name } } }
              ... on ProjectV2ItemFieldIterationValue {
                title field { ... on ProjectV2FieldCommon { name } } }
            }
          }
          content {
            __typename
            ... on DraftIssue { title }
            ... on Issue {
              number title url state
              repository { nameWithOwner }
              assignees(first: 10) { nodes { login } }
              labels(first: 20) { nodes { name } }
              issueFieldValues(first: 20) {
                nodes {
                  __typename
                  ... on IssueFieldTextValue {
                    value field { ... on IssueFieldText { name } } }
                  ... on IssueFieldNumberValue {
                    value field { ... on IssueFieldNumber { name } } }
                  ... on IssueFieldDateValue {
                    value field { ... on IssueFieldDate { name } } }
                  ... on IssueFieldSingleSelectValue {
                    name field { ... on IssueFieldSingleSelect { name } } }
                  ... on IssueFieldMultiSelectValue {
                    options { name } field { ... on IssueFieldMultiSelect { name } } }
                }
              }__CLOSED_BY__
              timelineItems(first: 50, itemTypes: [CROSS_REFERENCED_EVENT, CONNECTED_EVENT]) {
                nodes {
                  __typename
                  ... on CrossReferencedEvent {
                    source { ... on PullRequest {
                      number url state merged headRefOid
                      repository { nameWithOwner } } }
                  }
                  ... on ConnectedEvent {
                    subject { ... on PullRequest {
                      number url state merged headRefOid
                      repository { nameWithOwner } } }
                  }
                }
              }
            }
            ... on PullRequest {
              number title url state merged
              repository { nameWithOwner }
            }
          }
        }
      }
    }
  }
}
""".strip()

PROJECT_QUERY = _PROJECT_QUERY_TEMPLATE.replace("__CLOSED_BY__", CLOSED_BY_BLOCK)

# closedByPullRequestsReferences is recent enough that an older GitHub Enterprise
# will reject the whole query. Degrading to the timeline alone loses the
# "closes" provenance but still finds the PRs, which beats aborting.
PROJECT_QUERY_NO_CLOSED_BY = _PROJECT_QUERY_TEMPLATE.replace("__CLOSED_BY__", "")

PR_FILES_BATCH = 20


def build_pr_files_query(numbers: list[int]) -> str:
    """One aliased request for many PRs beats one request each."""
    aliases = "\n".join(
        f"    pr{index}: pullRequest(number: {number}) {{"
        f" merged files(first: 100) {{ pageInfo {{ hasNextPage }} nodes {{ path }} }} }}"
        for index, number in enumerate(numbers)
    )
    return (
        "query($owner: String!, $name: String!) {\n"
        "  repository(owner: $owner, name: $name) {\n"
        f"{aliases}\n"
        "  }\n"
        "}"
    )


# -- Reading the filepath column -------------------------------------------


@dataclass(frozen=True)
class AssetPath:
    raw: str
    path: str
    status: str  # ok | empty | placeholder | unparseable
    detail: str = ""


_BULLET_RE = re.compile(r"^\s*(?:[-*+]|\d+[.)])\s+")
_PLAIN_PATH_RE = re.compile(r"^[\w./+-]+$")


def clean_path_value(raw: str | None) -> list[AssetPath]:
    """Normalise the board column's value. It may hold more than one path."""
    if raw is None or not raw.strip():
        return [AssetPath(raw=raw or "", path="", status="empty", detail="column is blank")]

    results: list[AssetPath] = []
    for line in raw.replace("\r\n", "\n").replace("\r", "\n").split("\n"):
        original = line.strip()
        if not original or original.startswith("```"):
            continue

        value = _BULLET_RE.sub("", original).strip()
        value = value.strip("`").strip().strip("\"'“”‘’").strip()
        value = value.replace("\\", "/")
        if value.lower().startswith("res://"):
            value = value[len("res://") :]
        value = value.lstrip("./").lstrip("/")

        if not value:
            continue
        if "{" in value or "}" in value:
            # The issue templates ship defaults like
            # assets/art/3d/{category}/{object_name}/sm_{object_name}.gltf, and those
            # get pasted into the column verbatim. They must not read as a path.
            results.append(
                AssetPath(original, "", "placeholder", "still a {placeholder} template")
            )
            continue
        if _PLAIN_PATH_RE.match(value) and ("/" in value or "." in value):
            results.append(AssetPath(original, value, "ok"))
            continue
        results.append(AssetPath(original, "", "unparseable", "does not look like a filepath"))

    if not results:
        return [AssetPath(raw=raw, path="", status="empty", detail="column is blank")]
    return results


def board_path_value(*sources: dict[str, Any], path_field: str) -> str | None:
    """Find the filepath field, matching its name case-insensitively.

    `filepath` on project 38 is an *organization issue field* (a custom field on
    the issue itself), and the board column of the same name is a projection of
    it. The value therefore lives on the issue, in issueFieldValues -- the
    project item's own fieldValues connection never returns it. Sources are
    searched in order, so the issue field wins and a plain project column of the
    same name still works for boards set up the other way round.
    """
    if not path_field:
        return None
    wanted = path_field.casefold()
    for source in sources:
        for name, value in source.items():
            if name.casefold() == wanted and isinstance(value, str) and value.strip():
                return value
    return None


# -- pipeline.yaml conventions ---------------------------------------------


@dataclass
class Conventions:
    patterns: dict[str, dict] = field(default_factory=dict)  # pattern id -> raw entry
    compiled: dict[str, re.Pattern] = field(default_factory=dict)
    deprecated: dict[str, list[tuple[str, re.Pattern]]] = field(default_factory=dict)
    by_extension: dict[str, list[str]] = field(default_factory=dict)  # ".gltf" -> pattern ids
    directories: dict[str, list[str]] = field(default_factory=dict)  # pattern id -> dir templates


# The repo's filename grammar: lowercase words joined by underscores.
_NAME_TOKEN = r"[a-z0-9]+(?:_[a-z0-9]+)*"


def _template_to_regex(template: str) -> re.Pattern:
    """Expand a {placeholder} directory template into a regex.

    Directory placeholders stand for whole path segments, so `anything but a
    slash` is the right expansion here.
    """
    parts = re.split(r"(\{[^}]*\})", template.rstrip("/"))
    expanded = "".join("[^/]+" if part.startswith("{") else re.escape(part) for part in parts)
    return re.compile(rf"^{expanded}/?$")


def _alias_to_regex(template: str) -> re.Pattern:
    """Expand a deprecated-alias template, which describes an old *filename*.

    Placeholders here expand to the naming grammar, not to `[^/]+`. Expanding
    `{object}.gltf` to `[^/]+\\.gltf` would make it match every badly named
    .gltf in existence, so sm_RainBarrel.gltf would be reported as the soft
    "deprecated, rename on next touch" instead of the real violation it is.
    """
    parts = re.split(r"(\{[^}]*\})", template.rstrip("/"))
    expanded = "".join(_NAME_TOKEN if part.startswith("{") else re.escape(part) for part in parts)
    return re.compile(rf"^{expanded}$")


def load_conventions(doc: dict) -> Conventions:
    """Read the naming rules out of pipeline.yaml. Never re-encode them here."""
    conventions = Conventions()
    for pipeline in doc.get("pipelines") or []:
        block = pipeline.get("conventions") or {}
        for entry in block.get("naming_patterns") or []:
            identifier = entry.get("id")
            regex = entry.get("regex")
            if not identifier or not regex:
                continue
            try:
                compiled = re.compile(regex)
            except re.error:
                continue
            conventions.patterns[identifier] = entry
            conventions.compiled[identifier] = compiled
            aliases: list[tuple[str, re.Pattern]] = []
            for alias in entry.get("deprecated_aliases") or []:
                template = alias.get("pattern")
                if template:
                    aliases.append((template, _alias_to_regex(template)))
            conventions.deprecated[identifier] = aliases

        for kind in pipeline.get("artifact_kinds") or []:
            naming = kind.get("naming")
            if not naming:
                continue
            for extension in kind.get("extensions") or []:
                conventions.by_extension.setdefault(str(extension).lower(), []).append(naming)
            # location is prose as often as it is a path ("Beside its .gltf."),
            # so only keep the ones that actually look like a directory template.
            location = kind.get("location") or ""
            if "{" in location and "/" in location:
                conventions.directories.setdefault(naming, []).append(location)

        # directory_layout is the other half of the same fact, and the only
        # source for kinds whose artifact_kind location is prose.
        for entry in block.get("directory_layout") or []:
            template = entry.get("path")
            if not template:
                continue
            for naming in entry.get("contains") or []:
                bucket = conventions.directories.setdefault(naming, [])
                if template not in bucket:
                    bucket.append(template)
    return conventions


def _candidate_patterns(path: str, conventions: Conventions) -> list[str]:
    """Patterns that could plausibly govern this path, keyed off its extension.

    Scoping by extension matters: the 2D and audio pipelines declare very loose
    patterns (`^[a-z0-9]+(_[a-z0-9]+)*\\.[a-z0-9]+$`) that would otherwise
    happily accept a badly named .gltf.
    """
    name = posixpath.basename(path)
    if not name:
        return []
    # .gltf.spec.yaml and the like: try the longest compound suffix first.
    lowered = name.lower()
    for extension, patterns in sorted(
        conventions.by_extension.items(), key=lambda item: -len(item[0])
    ):
        if lowered.endswith(extension):
            return list(dict.fromkeys(patterns))
    return []


def check_path(path: str, conventions: Conventions) -> tuple[str, str]:
    """Return (status, detail). Status is ok | deprecated | nonstandard | unchecked.

    Warning only. Ambiguity resolves toward silence -- a false alarm on an
    artist's issue costs more than a missed one, because validate-model-files.py
    is still the gate at PR time.
    """
    if not path:
        return "unchecked", ""
    if path.endswith("/"):
        return "unchecked", "path names a directory, not a file"

    candidates = _candidate_patterns(path, conventions)
    if not candidates:
        return "unchecked", "no naming pattern in pipeline.yaml covers this extension"

    name = posixpath.basename(path)
    directory = posixpath.dirname(path)

    for identifier in candidates:
        if conventions.compiled[identifier].match(name):
            homes = conventions.directories.get(identifier) or []
            if homes and not any(_template_to_regex(home).match(directory) for home in homes):
                return (
                    "nonstandard",
                    f"filename is fine but pipeline.yaml puts {identifier} in "
                    + " or ".join(homes),
                )
            return "ok", identifier

    for identifier in candidates:
        for template, compiled in conventions.deprecated.get(identifier, []):
            target = path if "/" in template else name
            if compiled.match(target):
                detail = f"matches the deprecated {identifier} form {template}"
                # A deprecated name in the wrong directory is two problems, and
                # reporting only the rename sends the author back for a second
                # round. Say both at once.
                homes = conventions.directories.get(identifier) or []
                if homes and not any(_template_to_regex(h).match(directory) for h in homes):
                    detail += f", and belongs under {' or '.join(homes)}"
                return "deprecated", detail

    # Nothing matched. Before warning, check the path is even somewhere these
    # patterns govern -- a .tscn under common/ or an old game/ path is
    # application code, not a model container scene, and telling its author it
    # should be named sm_*.tscn is worse than saying nothing.
    homes = [
        home for identifier in candidates for home in conventions.directories.get(identifier, [])
    ]
    if homes and not any(_template_to_regex(home).match(directory) for home in homes):
        return "unchecked", "outside the directories pipeline.yaml governs for this extension"

    nearest = candidates[0]
    return "nonstandard", f"does not match {nearest}: {conventions.patterns[nearest]['regex']}"


# -- Project items ---------------------------------------------------------


@dataclass
class LinkedPR:
    repo: str
    number: int
    url: str
    state: str
    merged: bool
    head_oid: str
    provenance: str  # closes | mentions
    files: list[str] | None = None
    files_truncated: bool = False

    @property
    def key(self) -> tuple[str, int, str]:
        return (self.repo, self.number, self.head_oid)

    def label(self) -> str:
        return f"#{self.number} ({'merged' if self.merged else self.state.lower()})"


@dataclass
class AssetItem:
    item_id: str
    item_type: str  # ISSUE | PULL_REQUEST | DRAFT_ISSUE | REDACTED
    repo: str = ""
    number: int | None = None
    title: str = ""
    url: str = ""
    state: str = ""
    assignees: list[str] = field(default_factory=list)
    labels: list[str] = field(default_factory=list)
    fields: dict[str, Any] = field(default_factory=dict)  # project board columns
    issue_fields: dict[str, Any] = field(default_factory=dict)  # org issue fields
    paths: list[AssetPath] = field(default_factory=list)
    linked_prs: list[LinkedPR] = field(default_factory=list)
    skip_reason: str = ""

    @property
    def slug(self) -> str:
        if self.number is None:
            return "(draft)"
        return f"{self.repo}#{self.number}"


def _field_values(node: dict) -> dict[str, Any]:
    values: dict[str, Any] = {}
    for entry in (node.get("fieldValues") or {}).get("nodes") or []:
        if not isinstance(entry, dict):
            continue
        name = ((entry.get("field") or {}).get("name")) or ""
        if not name:
            continue
        for key in ("text", "number", "date", "name", "title"):
            if key in entry and entry[key] is not None:
                values[name] = entry[key]
                break
    return values


def _issue_field_values(issue: dict) -> dict[str, Any]:
    """Flatten the issue's own custom fields (Priority, Effort, filepath, ...)."""
    values: dict[str, Any] = {}
    for entry in (issue.get("issueFieldValues") or {}).get("nodes") or []:
        if not isinstance(entry, dict):
            continue
        name = ((entry.get("field") or {}).get("name")) or ""
        if not name:
            continue
        if entry.get("options"):
            values[name] = ", ".join(
                option.get("name", "") for option in entry["options"] if isinstance(option, dict)
            )
            continue
        for key in ("value", "name"):
            if entry.get(key) is not None:
                values[name] = entry[key]
                break
    return values


def _linked_prs(issue: dict) -> list[LinkedPR]:
    found: dict[tuple[str, int], LinkedPR] = {}

    def add(node: dict | None, provenance: str) -> None:
        if not node or node.get("number") is None:
            return
        repo = (node.get("repository") or {}).get("nameWithOwner") or ""
        key = (repo, int(node["number"]))
        if key in found and found[key].provenance == "closes":
            return
        found[key] = LinkedPR(
            repo=repo,
            number=int(node["number"]),
            url=node.get("url") or "",
            state=node.get("state") or "",
            merged=bool(node.get("merged")),
            head_oid=node.get("headRefOid") or "",
            provenance=provenance,
        )

    for node in (issue.get("closedByPullRequestsReferences") or {}).get("nodes") or []:
        add(node, "closes")
    for node in (issue.get("timelineItems") or {}).get("nodes") or []:
        if not isinstance(node, dict):
            continue
        add(node.get("source") or node.get("subject"), "mentions")

    return sorted(found.values(), key=lambda pr: (pr.repo, pr.number))


def build_items(pages: list[dict], path_field: str = DEFAULT_PATH_FIELD) -> list[AssetItem]:
    """Flatten the project payload into one AssetItem per board item.

    Every item type is treated the same way: read the filepath column. A draft
    with the column filled in is as much a tracked asset as an issue is.
    """
    items: list[AssetItem] = []

    for page in pages:
        project = ((page.get("organization") or {}).get("projectV2")) or {}
        for node in ((project.get("items") or {}).get("nodes") or []):
            if not isinstance(node, dict):
                continue
            item = AssetItem(
                item_id=node.get("id") or "",
                item_type=node.get("type") or "",
                fields=_field_values(node),
            )
            content = node.get("content") or {}
            typename = content.get("__typename") or ""

            if item.item_type == "REDACTED" or not typename:
                item.skip_reason = "item is hidden from this token"
                items.append(item)
                continue

            item.title = content.get("title") or ""
            if typename != "DraftIssue":
                item.repo = (content.get("repository") or {}).get("nameWithOwner") or ""
                item.number = content.get("number")
                item.url = content.get("url") or ""
                item.state = content.get("state") or ""
                item.assignees = [
                    entry.get("login", "")
                    for entry in (content.get("assignees") or {}).get("nodes") or []
                ]
                item.labels = [
                    entry.get("name", "")
                    for entry in (content.get("labels") or {}).get("nodes") or []
                ]
            if typename == "Issue":
                item.linked_prs = _linked_prs(content)
                item.issue_fields = _issue_field_values(content)

            raw = board_path_value(item.issue_fields, item.fields, path_field=path_field)
            item.paths = clean_path_value(raw)
            items.append(item)
    return items


def fetch_pages(
    client: GraphQLClient, org: str, number: int, page_size: int, max_pages: int = 50
) -> list[dict]:
    """Walk the board with an explicit cursor.

    `gh api graphql --paginate` is not used: it follows only the first pageInfo
    it finds and writes concatenated JSON documents to stdout.
    """
    pages: list[dict] = []
    cursor: str | None = None
    query = PROJECT_QUERY

    for _ in range(max_pages):
        variables = {"org": org, "projectNumber": number, "pageSize": page_size}
        if cursor:
            variables["cursor"] = cursor
        try:
            data = client.execute(query, variables)
        except TransportError as exc:
            if "closedByPullRequestsReferences" in str(exc) and query is PROJECT_QUERY:
                query = PROJECT_QUERY_NO_CLOSED_BY
                continue
            raise
        pages.append(data)

        project = ((data.get("organization") or {}).get("projectV2")) or {}
        if not project:
            raise TransportError(f"organization {org!r} has no project number {number}")
        page_info = (project.get("items") or {}).get("pageInfo") or {}
        if not page_info.get("hasNextPage"):
            break
        cursor = page_info.get("endCursor")
        if not cursor:
            break
    return pages


def project_meta(pages: list[dict]) -> dict[str, Any]:
    if not pages:
        return {}
    project = ((pages[0].get("organization") or {}).get("projectV2")) or {}
    return {
        "id": project.get("id") or "",
        "title": project.get("title") or "",
        "url": project.get("url") or "",
        "total_items": ((project.get("items") or {}).get("totalCount")),
        # id and options are carried so `issue update --status` can name the
        # column and the option it is setting. A recording made before they were
        # selected simply has None there, which is why nothing requires them.
        "fields": [
            {
                "name": node.get("name"),
                "dataType": node.get("dataType"),
                "id": node.get("id"),
                "options": {
                    option["name"]: option["id"]
                    for option in (node.get("options") or [])
                    if isinstance(option, dict) and option.get("name") and option.get("id")
                },
            }
            for node in (project.get("fields") or {}).get("nodes") or []
            if isinstance(node, dict) and node.get("name")
        ],
    }


# -- Delivery --------------------------------------------------------------


def local_repo_slug(repo_root: Path) -> str:
    """owner/name of the checkout we are standing in, or "" if it cannot be read."""
    try:
        proc = subprocess.run(
            ["git", "-C", str(repo_root), "remote", "get-url", "origin"],
            capture_output=True,
            text=True,
            check=False,
        )
    except (FileNotFoundError, OSError):
        return ""
    url = proc.stdout.strip()
    match = re.search(r"[:/]([^/:]+/[^/]+?)(?:\.git)?$", url)
    return match.group(1) if match else ""


def check_on_disk(path: str, repo_root: Path) -> str:
    if not path:
        return "n/a"
    try:
        return "yes" if (repo_root / path).exists() else "no"
    except OSError:
        return "n/a"


def pr_delivers(path: str, files: list[str]) -> bool:
    """A PR delivers an asset when it touches the file or its directory.

    Directory-level matching is the honest test: assets/art/3d/{category}/{object}/
    means the .bin, the textures and the .import sidecars all land together, so
    a PR that adds the whole directory has delivered the asset named in it.
    """
    if not path or not files:
        return False
    if path in files:
        return True
    prefix = path if path.endswith("/") else posixpath.dirname(path)
    if not prefix:
        return False
    prefix = prefix.rstrip("/") + "/"
    return any(candidate.startswith(prefix) for candidate in files)


def load_pr_files(
    client: GraphQLClient, prs: list[LinkedPR], cache: dict[str, Any], warn: list[str]
) -> None:
    """Fill in .files for every PR, batching by repository."""
    by_repo: dict[str, list[LinkedPR]] = {}
    for pr in prs:
        cached = cache.get("|".join(str(part) for part in pr.key))
        if cached is not None:
            pr.files = list(cached)
            continue
        if pr.repo:
            by_repo.setdefault(pr.repo, []).append(pr)

    for repo, repo_prs in sorted(by_repo.items()):
        owner, _, name = repo.partition("/")
        for start in range(0, len(repo_prs), PR_FILES_BATCH):
            batch = repo_prs[start : start + PR_FILES_BATCH]
            query = build_pr_files_query([pr.number for pr in batch])
            try:
                data = client.execute(query, {"owner": owner, "name": name})
            except TransportError as exc:
                warn.append(f"could not read changed files for {repo}: {exc}")
                continue
            repository = data.get("repository") or {}
            for index, pr in enumerate(batch):
                node = repository.get(f"pr{index}") or {}
                files_block = node.get("files") or {}
                pr.files = [
                    entry.get("path", "")
                    for entry in files_block.get("nodes") or []
                    if isinstance(entry, dict)
                ]
                pr.files_truncated = bool((files_block.get("pageInfo") or {}).get("hasNextPage"))
                cache["|".join(str(part) for part in pr.key)] = pr.files


# -- Rows ------------------------------------------------------------------


@dataclass
class Row:
    item: AssetItem
    asset_path: AssetPath
    on_disk: str
    delivered_by: list[str]
    naming_status: str
    naming_detail: str

    @property
    def status(self) -> str:
        if self.item.skip_reason:
            return "SKIP"
        return {
            "ok": "ok",
            "empty": "NO PATH",
            "placeholder": "PLACEHOLDER",
            "unparseable": "UNPARSEABLE",
        }.get(self.asset_path.status, self.asset_path.status.upper())

    @property
    def detail(self) -> str:
        if self.item.skip_reason:
            return self.item.skip_reason
        return self.asset_path.detail


def asset_name(row: Row) -> str:
    """Prefer the filename stem with its pipeline prefix stripped."""
    path = row.asset_path.path
    if path:
        stem = posixpath.basename(path.rstrip("/")).split(".")[0]
        return re.sub(r"^(sm|sk|t|prefab|level)_", "", stem) or stem
    title = row.item.title or ""
    match = re.search(r"\bfor\s+(.+)$", title, re.I)
    return (match.group(1) if match else title).strip()


def build_rows(
    items: list[AssetItem], conventions: Conventions, repo_root: Path, on_disk_repo: str
) -> list[Row]:
    rows: list[Row] = []
    for item in items:
        paths = item.paths or [AssetPath("", "", "empty", "column is blank")]
        for asset_path in paths:
            if item.skip_reason:
                on_disk = "n/a"
            elif on_disk_repo and item.repo and item.repo != on_disk_repo:
                on_disk = "n/a"
            else:
                on_disk = check_on_disk(asset_path.path, repo_root)

            delivered = [
                pr.label()
                for pr in item.linked_prs
                if pr.files is not None and pr_delivers(asset_path.path, pr.files)
            ]
            naming_status, naming_detail = check_path(asset_path.path, conventions)
            rows.append(Row(item, asset_path, on_disk, delivered, naming_status, naming_detail))
    return rows


def sort_key(row: Row) -> tuple:
    return (row.item.repo, row.item.number or 0, row.item.title)


# -- Renderers -------------------------------------------------------------


def render_text(rows: list[Row], meta: dict, notes: list[str]) -> str:
    lines: list[str] = []
    title = meta.get("title") or "project"
    lines.append(f"{title} - {len(rows)} row(s) from {meta.get('total_items', '?')} board item(s)")
    lines.append("")

    for row in sorted(rows, key=sort_key):
        label = row.item.slug if row.item.number is not None else f"(draft) {row.item.title}"
        if row.status == "ok":
            lines.append(f"  ok          {label:<48} {row.asset_path.path}")
            delivered = ", ".join(row.delivered_by) or "-"
            lines.append(f"              on_disk={row.on_disk}  delivered_by={delivered}")
        else:
            detail = f" - {row.detail}" if row.detail else ""
            lines.append(f"  {row.status:<11} {label}{detail}")
        if row.naming_status in ("nonstandard", "deprecated"):
            lines.append(f"              WARN {row.naming_status}: {row.naming_detail}")

    if notes:
        lines.append("")
        for note in notes:
            lines.append(f"  note: {note}")
    return "\n".join(lines) + "\n"


def _md_cell(value: str) -> str:
    """A blank cell would collapse the column, so an empty value reads as a dash."""
    return md_cell(value, empty="-")


def render_markdown(rows: list[Row], meta: dict, notes: list[str]) -> str:
    lines = [f"# {meta.get('title') or 'Asset report'}", ""]
    if meta.get("url"):
        lines += [f"Board: {meta['url']}", ""]

    header = [
        "Item",
        "Asset",
        "Status",
        "Priority",
        "Assignee",
        "File path",
        "path_status",
        "on_disk",
        "delivered_by",
        "Naming",
    ]
    lines.append("| " + " | ".join(header) + " |")
    lines.append("|" + "|".join(["---"] * len(header)) + "|")

    for row in sorted(rows, key=sort_key):
        item = row.item
        if item.url:
            label = f"[{item.slug}]({item.url})"
        else:
            label = f"(draft) {item.title}"
        naming = (
            f"{row.naming_status}: {row.naming_detail}"
            if row.naming_status in ("nonstandard", "deprecated")
            else ""
        )
        lines.append(
            "| "
            + " | ".join(
                _md_cell(cell)
                for cell in [
                    label,
                    asset_name(row),
                    str(item.fields.get("Status", "") or "") or row.status,
                    str(item.issue_fields.get("Priority", "") or ""),
                    ", ".join(item.assignees),
                    f"`{row.asset_path.path}`" if row.asset_path.path else "",
                    row.asset_path.status if not item.skip_reason else "skipped",
                    row.on_disk,
                    ", ".join(row.delivered_by),
                    naming,
                ]
            )
            + " |"
        )

    if notes:
        lines += ["", "## Notes", ""] + [f"- {note}" for note in notes]
    return "\n".join(lines) + "\n"


def render_json(rows: list[Row], meta: dict, notes: list[str], context: dict) -> str:
    payload = {
        "project": meta,
        "context": context,
        "notes": notes,
        "items": [
            {
                "repo": row.item.repo,
                "number": row.item.number,
                "title": row.item.title,
                "url": row.item.url,
                "state": row.item.state,
                "item_type": row.item.item_type,
                "assignees": row.item.assignees,
                "labels": row.item.labels,
                "fields": row.item.fields,
                "issue_fields": row.item.issue_fields,
                "file_path": row.asset_path.path,
                "file_path_raw": row.asset_path.raw,
                "path_status": row.asset_path.status,
                "path_detail": row.asset_path.detail,
                "naming_status": row.naming_status,
                "naming_detail": row.naming_detail,
                "on_disk": row.on_disk,
                "delivered_by": row.delivered_by,
                "linked_prs": [
                    {
                        "repo": pr.repo,
                        "number": pr.number,
                        "url": pr.url,
                        "state": pr.state,
                        "merged": pr.merged,
                        "provenance": pr.provenance,
                        "files_truncated": pr.files_truncated,
                    }
                    for pr in row.item.linked_prs
                ],
                "skipped": row.item.skip_reason,
            }
            for row in sorted(rows, key=sort_key)
        ],
    }
    return json.dumps(payload, indent=2) + "\n"


# -- Collecting a report ---------------------------------------------------


@dataclass
class BoardReport:
    """Everything a renderer needs, and the caveats that came with it.

    `notes` is not decoration: an empty report and a report that could not read
    the filepath column look identical without it.
    """

    rows: list[Row]
    meta: dict
    notes: list[str]
    context: dict


def collect(args: argparse.Namespace) -> BoardReport:
    """Read the board and evaluate delivery, driven by the parsed CLI flags.

    Raises TransportError or DocumentError rather than exiting, so the one place
    that decides how a GitHub failure is explained stays in cli.main().
    """
    notes: list[str] = []

    try:
        conventions = load_conventions(load_doc(args.doc))
    except DocumentError as exc:
        conventions = Conventions()
        notes.append(f"naming rules unavailable ({exc}); filepaths were not checked")

    if args.from_json:
        try:
            client: GraphQLClient = RecordedClient.from_file(args.from_json)
        except (OSError, json.JSONDecodeError) as exc:
            raise DocumentError(f"could not read {args.from_json}: {exc}") from exc
        source = "recording"
    else:
        client = choose_client(args.token)
        source = getattr(client, "name", "live")

    pages = fetch_pages(client, args.org, args.project, args.page_size)

    meta = project_meta(pages)
    known = {entry["name"].casefold() for entry in meta.get("fields", [])}
    if known and args.path_field.casefold() not in known:
        available = ", ".join(sorted(entry["name"] for entry in meta.get("fields", [])))
        notes.append(
            f"board has no column named {args.path_field!r}; available: {available or 'none'}"
        )

    items = build_items(pages, args.path_field)

    on_disk_repo = local_repo_slug(args.repo_root)
    if on_disk_repo:
        notes.append(f"on_disk was evaluated against {on_disk_repo} at {args.repo_root}")
    else:
        notes.append(f"on_disk was evaluated against the tree at {args.repo_root}")

    cache: dict[str, Any] = {}
    if args.cache and args.cache.is_file():
        try:
            cache = json.loads(args.cache.read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError):
            cache = {}

    if not args.no_pr_files:
        all_prs = [pr for item in items for pr in item.linked_prs]
        if all_prs:
            load_pr_files(client, all_prs, cache, notes)
            truncated = [pr for pr in all_prs if pr.files_truncated]
            if truncated:
                notes.append(
                    f"{len(truncated)} pull request(s) changed more than 100 files; "
                    "delivery for those is based on the first 100 only"
                )
        if args.cache:
            try:
                args.cache.parent.mkdir(parents=True, exist_ok=True)
                args.cache.write_text(
                    json.dumps(cache, indent=2) + "\n", encoding="utf-8", newline="\n"
                )
            except OSError as exc:
                notes.append(f"could not write the cache: {exc}")
    else:
        notes.append("--no-pr-files was set; delivered_by is empty for every row")

    if args.dump_json:
        recorded_files: dict[str, dict[str, list[str]]] = {}
        for item in items:
            for pr in item.linked_prs:
                if pr.files is not None:
                    recorded_files.setdefault(pr.repo, {})[str(pr.number)] = pr.files
        args.dump_json.parent.mkdir(parents=True, exist_ok=True)
        args.dump_json.write_text(
            json.dumps({"pages": pages, "pr_files": recorded_files}, indent=2) + "\n",
            encoding="utf-8",
            newline="\n",
        )
        print(f"Recorded {len(pages)} page(s) to {args.dump_json}", file=sys.stderr)

    rows = build_rows(items, conventions, args.repo_root, on_disk_repo)
    if args.with_paths:
        hidden = [row for row in rows if not row.asset_path.path]
        rows = [row for row in rows if row.asset_path.path]
        if hidden:
            notes.append(f"--with-paths hid {len(hidden)} item(s) with no filepath set")

    context = {
        "source": source,
        "org": args.org,
        "project_number": args.project,
        "repo_root": str(args.repo_root),
        "on_disk_repo": on_disk_repo,
        "path_field": args.path_field,
    }
    return BoardReport(rows, meta, notes, context)
