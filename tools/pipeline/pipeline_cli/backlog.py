"""The local backlog: YAML files a person fills in, then drains into issues.

Every other file under documentation/pipeline/ is generated *from* something --
the board, or pipeline.yaml. These go the other way. You write them offline, in
an editor, and `pipeline.py backlog file` turns each entry into a GitHub issue
built from the same template form the browser would use.

One file per issue template, and the file names its own template. That is the
whole reason the format is shaped this way: a backlog with no `template:` key
would need the slug passed on the command line, and pointing `--template
create_sfx` at a file written for create_model would render a dozen issues full
of `_No response_` rather than failing. Here the file cannot disagree with
itself, and a key belonging to some other template is a named error.

Filing writes the issue number back into the entry, which is what makes the
command re-runnable: an entry with an `issue:` is already on the board, so it is
skipped. That write is a *splice*, not a dump. A hand-authored file is mostly
things PyYAML does not round-trip -- comments, blank lines, block scalars, key
order, quoting style -- so writing one back out through safe_dump would hand
somebody a diff touching every line of a file they wrote. Instead we ask the
parser where the entry starts (yaml_marks keeps the source marks safe_load
discards) and insert exactly one line.
"""

from __future__ import annotations

from dataclasses import dataclass, field
from pathlib import Path

from .common import BACKLOG_DIR, DocumentError, parse_yaml, relative, yaml_marks
from .issue_forms import IssueForm, is_checklist

# Keys that mean the same thing in every backlog, whatever the template.
#
# `filepath` is one of them rather than the form's own id on purpose: the
# templates disagree about what to call it (`file_path` in create_model,
# `context` in create_implementation), and a person writing three backlogs
# should not have to care. It is routed to IssueForm.path_field() at render
# time, exactly as `issue create --filepath` is.
STRUCTURAL_KEYS = ("issue", "name", "title", "filepath", "assignee", "labels", "priority")

# What `defaults:` may carry. Batch metadata only. Sharing a `description` or a
# `filepath` across entries would file near-identical issues, and sharing a
# `dimentions` would quietly put the wrong measurements on every asset that did
# not override it -- the kind of wrong that is only visible on the board.
DEFAULTS_KEYS = ("assignee", "labels", "priority")

TEMPLATE_KEY = "template"
ISSUES_KEY = "issues"
DEFAULTS_KEY = "defaults"

FILE_COMMAND = "python tools/pipeline/pipeline.py backlog file"


@dataclass(frozen=True)
class Entry:
    """One issue-to-be, and where in the file it was written."""

    index: int
    line: int  # 0-based, the entry's first key -- for messages and for the splice
    column: int
    own: dict = field(default_factory=dict)  # keys as written
    values: dict = field(default_factory=dict)  # defaults merged underneath

    @property
    def issue(self) -> str:
        """The issue number if this entry has already been filed, else ""."""
        return str(self.values.get("issue") or "").strip().lstrip("#")

    @property
    def label(self) -> str:
        """What to call this entry in a message, before it has an issue."""
        for key in ("name", "title", "filepath"):
            value = str(self.values.get(key) or "").strip()
            if value:
                return value
        return f"issues[{self.index}]"


@dataclass(frozen=True)
class Backlog:
    path: Path
    slug: str
    entries: tuple[Entry, ...] = ()

    def pending(self) -> list[Entry]:
        return [entry for entry in self.entries if not entry.issue]

    def filed(self) -> list[Entry]:
        return [entry for entry in self.entries if entry.issue]

    def where(self, entry: Entry) -> str:
        """`documentation/pipeline/backlog/create_model.yaml:14`, for a message."""
        return f"{relative(self.path)}:{entry.line + 1}"


# -- Reading ---------------------------------------------------------------


def _entry_marks(text: str, source: str) -> list[tuple[int, int]]:
    """(line, column) of the first key of every mapping under `issues:`.

    The column is the indent the key sits at, which is where a spliced-in
    `issue:` has to line up. For `  - name: lantern` that is 4, not 2: the
    `- ` stays put and the new key takes its place on that line.
    """
    node = yaml_marks(text, source=source)
    for key_node, value_node in getattr(node, "value", None) or []:
        if getattr(key_node, "value", None) != ISSUES_KEY:
            continue
        items = getattr(value_node, "value", None)
        if not isinstance(items, list):
            return []
        marks = []
        for item in items:
            keys = getattr(item, "value", None)
            if isinstance(keys, list) and keys:
                mark = keys[0][0].start_mark
            else:
                mark = item.start_mark
            marks.append((mark.line, mark.column))
        return marks
    return []


def load_backlog(path: Path) -> Backlog:
    """Read one backlog file. Raises DocumentError naming the path and the fix."""
    try:
        text = path.read_text(encoding="utf-8")
    except OSError as exc:
        raise DocumentError(f"could not read {relative(path)}: {exc}") from exc

    where = relative(path)
    doc = parse_yaml(text, source=where)
    if doc is None:
        doc = {}
    if not isinstance(doc, dict):
        raise DocumentError(f"{where} is not a YAML mapping")

    slug = str(doc.get(TEMPLATE_KEY) or "").strip()
    if not slug:
        raise DocumentError(
            f"{where} has no `{TEMPLATE_KEY}:` key, so there is no way to tell which "
            "issue template its entries are for.\n"
            "Add one, e.g. `template: create_model`, or start from a scaffold:\n"
            "  python tools/pipeline/pipeline.py backlog new --template create_model"
        )

    defaults = doc.get(DEFAULTS_KEY) or {}
    if not isinstance(defaults, dict):
        raise DocumentError(f"{where}: `{DEFAULTS_KEY}:` must be a mapping, or absent")
    stray = [key for key in defaults if key not in DEFAULTS_KEYS]
    if stray:
        raise DocumentError(
            f"{where}: `{DEFAULTS_KEY}:` cannot set {', '.join(sorted(stray))}. "
            f"It carries batch metadata only: {', '.join(DEFAULTS_KEYS)}.\n"
            "Anything that describes one asset belongs on that asset's entry."
        )

    raw_issues = doc.get(ISSUES_KEY) or []
    if not isinstance(raw_issues, list):
        raise DocumentError(f"{where}: `{ISSUES_KEY}:` must be a list of entries, or empty")

    marks = _entry_marks(text, where)
    entries = []
    for index, own in enumerate(raw_issues):
        if not isinstance(own, dict):
            raise DocumentError(f"{where}: {ISSUES_KEY}[{index}] is not a mapping")
        line, column = marks[index] if index < len(marks) else (0, 4)
        entries.append(
            Entry(
                index=index,
                line=line,
                column=column,
                own=dict(own),
                values={**defaults, **own},
            )
        )

    return Backlog(path=path, slug=slug, entries=tuple(entries))


def known_keys(form: IssueForm) -> list[str]:
    """Every key an entry for this template may carry, for an error message."""
    fields = [entry.id for entry in form.fields if entry.collects_input]
    return fields + [key for key in STRUCTURAL_KEYS if key not in fields]


def backlog_paths(directory: Path = BACKLOG_DIR) -> list[Path]:
    """Every backlog file in the directory, in a stable order."""
    if not directory.is_dir():
        return []
    return sorted(
        path for path in directory.glob("*.y*ml") if path.suffix in (".yaml", ".yml")
    )


# -- Writing the number back -----------------------------------------------


def splice_issue(path: Path, index: int, number: str) -> None:
    """Insert `issue: <number>` into one entry, leaving every other byte alone.

    The entry is found by index and its marks re-derived from the file as it is
    right now, rather than trusted from an earlier load. Filing a batch splices
    the same file once per issue, and every splice shifts the lines below it --
    caching the marks would put the second number in the wrong entry.

    Reads and writes with newline="" so a CRLF working tree stays CRLF. The
    promise here is that `git diff` shows the added lines and nothing else, and
    silently normalising line endings would break it for every Windows
    contributor.
    """
    # newline="" so a CRLF checkout stays CRLF. Path.read_text only learned the
    # argument in 3.13, hence open().
    with path.open(encoding="utf-8", newline="") as handle:
        text = handle.read()
    marks = _entry_marks(text.replace("\r\n", "\n"), relative(path))
    if index >= len(marks):
        raise DocumentError(
            f"{relative(path)} no longer has an entry {index}; "
            f"issue #{number} was created but its number was not written back."
        )

    line, column = marks[index]
    lines = text.splitlines(keepends=True)
    target = lines[line]
    ending = "\r\n" if target.endswith("\r\n") else "\n"
    lines[line] = f"{target[:column]}issue: {number}{ending}{' ' * column}{target[column:]}"
    updated = "".join(lines)

    # A flow-style entry (`- {name: x}`) would have put the column inside the
    # braces and this would have produced nonsense. Rather than enumerate the
    # shapes that splice cleanly, check the result: the file must still parse,
    # and this entry must now hold this number.
    try:
        check = parse_yaml(updated, source=relative(path))
        entries = (check or {}).get(ISSUES_KEY) or []
        landed = index < len(entries) and str(
            entries[index].get("issue") or ""
        ).lstrip("#") == number
    except DocumentError:
        # The parser's own complaint is about a file this function invented, so
        # it would send the reader hunting for a syntax error they did not make.
        landed = False

    if not landed:
        raise DocumentError(
            f"could not write issue #{number} back into {relative(path)} "
            f"({ISSUES_KEY}[{index}] is not in a shape this can edit -- "
            "block mappings only, not `- {key: value}`).\n"
            f"The issue exists. Add `issue: {number}` to that entry by hand."
        )

    path.write_text(updated, encoding="utf-8", newline="")


# -- Scaffolding -----------------------------------------------------------


def scaffold_fields(form: IssueForm) -> list:
    """The template fields a scaffolded backlog asks for.

    Required fields only, in the template's own order, minus two:

    The path field, because `filepath` covers it under a name that means the
    same thing in every backlog.

    Anything whose default is a checklist -- in practice `subtasks`, whose
    generated `<!-- pipeline:subtasks -->` block already reaches the issue
    through render_body's fallback to the template's own value. Asking a person
    to paste forty checkboxes into a YAML cell would be worse than useless: it
    would go stale the next time the templates are re-rendered.

    Optional fields are not scaffolded, but nothing stops you adding one.
    """
    path_field = form.path_field()
    return [
        entry
        for entry in form.required_fields()
        if not (path_field and entry.id == path_field.id) and not is_checklist(entry.value)
    ]


def scaffold_keys(form: IssueForm) -> list[str]:
    """Every key a scaffolded entry carries, in the order it is written."""
    keys = ["name"]
    keys += [entry.id for entry in scaffold_fields(form)]
    if form.path_field():
        keys.append("filepath")
    return keys


def _commented(text: str, indent: str) -> list[str]:
    return [f"{indent}# {line}".rstrip() for line in text.splitlines() or [""]]


def render_scaffold(form: IssueForm) -> str:
    """A backlog file for this template: the header, and one example entry.

    The example is commented out rather than live. A scaffold whose first entry
    was real would either file something nobody asked for, or -- because the
    templates' own defaults are worked examples full of {placeholder} -- fail
    validation on a file the tool itself had just written.
    """
    optional = [
        entry.id
        for entry in form.fields
        if entry.collects_input
        and not entry.required
        and entry.id not in scaffold_keys(form)
        and not is_checklist(entry.value)
    ]

    lines = [
        f"# Backlog for {relative(form.path)}",
        "#",
        "# Fill in the entries below, then:",
        f"#   {FILE_COMMAND}            # dry run -- validates every entry, creates nothing",
        f"#   {FILE_COMMAND} --apply    # create them; the numbers are written back here",
        "#",
        "# An entry that already has an `issue:` is skipped, so this is safe to re-run.",
    ]
    if optional:
        lines += [
            "#",
            f"# Optional fields this template also accepts: {', '.join(optional)}",
        ]
    lines += [
        "",
        f"{TEMPLATE_KEY}: {form.slug}",
        "",
        "# Applied to every entry that does not set them itself.",
        f"{DEFAULTS_KEY}:",
        "  # assignee: your-github-handle",
        "  # priority: high",
        "",
        f"{ISSUES_KEY}:",
    ]

    example = ["- name: example_asset"]
    for entry in scaffold_fields(form):
        hint = (entry.value or entry.placeholder or "").strip()
        if "\n" in hint:
            example.append(f"  {entry.id}: |")
            example += [f"    {piece}" for piece in hint.splitlines()]
        else:
            example.append(f"  {entry.id}: {hint or '...'}")
    path_field = form.path_field()
    if path_field:
        hint = (path_field.value or path_field.placeholder or "").strip()
        example.append(f"  filepath: {hint or '...'}")

    lines += _commented("\n".join(example), "  ")
    return "\n".join(lines) + "\n"


def scaffold_path(form: IssueForm, directory: Path = BACKLOG_DIR) -> Path:
    return directory / f"{form.slug}.yaml"
