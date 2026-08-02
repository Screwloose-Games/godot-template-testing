"""Read a .github/ISSUE_TEMPLATE/*.yaml form and build an issue body from it.

The templates are GitHub issue *forms*: a list of typed fields, each with a
label and often a default `value:`. GitHub renders a submitted form into markdown
as `### label`, blank line, the answer. This module reproduces that exactly, so
an issue opened from the CLI is indistinguishable from one opened in the browser
-- same headings, same order, same `_No response_` for the blanks.

Carrying each field's `value:` default through is not incidental: that is the
mechanism by which the generated `<!-- pipeline:subtasks -->` checklist, markers
and all, ends up in the created issue. The markers are invisible on GitHub and
let `issue update --resync-subtasks` find the block again later.

One wrinkle the templates force on us: `create_model.yaml` and
`create_implementation.yaml` both put `id:` under `attributes:` on their Subtasks
field rather than at the body-item level. GitHub tolerates it because it renders
headings from `label`. Reading only the top-level key would silently drop exactly
the field carrying the checklist, so _field_id looks in both places.
"""

from __future__ import annotations

import re
from dataclasses import dataclass
from pathlib import Path

from .common import ISSUE_TEMPLATE_DIR, DocumentError, load_doc, relative

# Fields that are prose printed at the reader, not an answer to collect.
PROSE_TYPES = {"markdown"}

NO_RESPONSE = "_No response_"

# Ids and labels that have meant "where does this asset go" across the templates.
# create_model.yaml calls it file_path; create_implementation.yaml calls it
# `context` with the label "File Location".
PATH_FIELD_IDS = ("file_path", "filepath", "path", "file_location", "context")
PATH_FIELD_LABEL_RE = re.compile(r"\b(file\s+)?(path|location)\b", re.IGNORECASE)

PLACEHOLDER_RE = re.compile(r"\{[^{}]+\}")


@dataclass(frozen=True)
class FormField:
    id: str
    type: str  # markdown | input | textarea | dropdown | checkboxes
    label: str
    description: str = ""
    placeholder: str = ""
    value: str = ""  # the template's default
    required: bool = False

    @property
    def collects_input(self) -> bool:
        return self.type not in PROSE_TYPES


@dataclass(frozen=True)
class IssueForm:
    path: Path
    slug: str  # "create_model"
    name: str
    title: str  # "Create 3D model for {game object name}"
    labels: tuple[str, ...] = ()
    fields: tuple[FormField, ...] = ()

    def field(self, identifier: str) -> FormField | None:
        wanted = identifier.casefold()
        for entry in self.fields:
            if entry.id.casefold() == wanted:
                return entry
        return None

    def path_field(self) -> FormField | None:
        """The field that holds the asset's destination, by id then by label."""
        for identifier in PATH_FIELD_IDS:
            found = self.field(identifier)
            if found and found.collects_input:
                return found
        for entry in self.fields:
            if entry.collects_input and PATH_FIELD_LABEL_RE.search(entry.label):
                return entry
        return None

    def required_fields(self) -> list[FormField]:
        return [entry for entry in self.fields if entry.required and entry.collects_input]


def _slugify(label: str) -> str:
    return re.sub(r"[^a-z0-9]+", "_", label.strip().casefold()).strip("_")


def _field_id(entry: dict) -> str:
    """The id, wherever the template author put it."""
    attributes = entry.get("attributes") or {}
    identifier = entry.get("id") or attributes.get("id")
    return str(identifier or _slugify(str(attributes.get("label", ""))))


def parse_form(doc: dict, path: Path) -> IssueForm:
    """Turn a parsed template document into a form definition."""
    fields: list[FormField] = []
    for entry in doc.get("body") or []:
        if not isinstance(entry, dict):
            continue
        attributes = entry.get("attributes") or {}
        validations = entry.get("validations") or {}
        fields.append(
            FormField(
                id=_field_id(entry),
                type=str(entry.get("type", "input")),
                label=str(attributes.get("label", "")),
                description=str(attributes.get("description", "")),
                placeholder=str(attributes.get("placeholder", "")),
                value=str(attributes.get("value", "")),
                required=bool(validations.get("required")),
            )
        )

    labels = doc.get("labels") or []
    return IssueForm(
        path=path,
        slug=path.stem,
        name=str(doc.get("name", path.stem)),
        title=str(doc.get("title", "")),
        labels=tuple(str(label) for label in labels),
        fields=tuple(fields),
    )


def available_slugs(directory: Path = ISSUE_TEMPLATE_DIR) -> list[str]:
    """Every template that could be named, minus the ones that are not forms."""
    return sorted(
        path.stem
        for path in directory.glob("*.y*ml")
        if path.stem not in ("config",) and path.suffix in (".yaml", ".yml")
    )


def load_form(slug_or_path: str, directory: Path = ISSUE_TEMPLATE_DIR) -> IssueForm:
    """Resolve a template by slug (`create_model`) or by path, and parse it.

    Both extensions are tried: every template uses .yaml except bug_report.yml.
    """
    candidate = Path(slug_or_path)
    if candidate.suffix in (".yaml", ".yml") and candidate.is_file():
        return parse_form(load_doc(candidate), candidate)

    for suffix in (".yaml", ".yml"):
        path = directory / f"{Path(slug_or_path).stem}{suffix}"
        if path.is_file():
            return parse_form(load_doc(path), path)

    raise DocumentError(
        f"no issue template named {slug_or_path!r} in {relative(directory)}. "
        f"Available: {', '.join(available_slugs(directory))}"
    )


def render_title(form: IssueForm, name: str | None, override: str | None = None) -> str:
    """Fill the template's title, or use the override verbatim.

    A title left holding a {placeholder} is refused rather than created: that is
    precisely the garbage `asset list` exists to report on, and it is free to fix
    now and expensive to fix on a board of fifty issues.
    """
    if override:
        return override

    title = form.title or form.name
    if name:
        title = PLACEHOLDER_RE.sub(name, title)

    leftover = PLACEHOLDER_RE.findall(title)
    if leftover:
        raise DocumentError(
            f"the title for {form.slug} still contains {', '.join(leftover)}. "
            "Pass --name to fill it, or --title to replace it."
        )
    return title


def is_checklist(value: str) -> bool:
    """A default that is a list of checkboxes is content, not example text."""
    return "- [ ]" in value or "- [x]" in value


def unanswered_required(form: IssueForm, values: dict[str, str]) -> list[FormField]:
    """Required fields nobody answered, ignoring those whose default is a checklist.

    Split out of render_body so the backlog can phrase the same rule in its own
    vocabulary -- an entry names a key, not a `--field` flag -- without a second
    implementation of "which fields still need an answer" to drift from this one.
    """
    return [
        entry
        for entry in form.required_fields()
        if not values.get(entry.id, "").strip() and not is_checklist(entry.value)
    ]


def render_body(form: IssueForm, values: dict[str, str]) -> str:
    """Render the form the way GitHub renders a submitted one.

    Supplied values win; a field with none falls back to the template's own
    default, which is how the generated subtasks block reaches the issue.

    A *required* field is the exception. Its default is example prose meant to
    show the shape of an answer -- create_model.yaml's Description defaults to
    "This hamster is a cheerfull, cartoonish...", and its Save File Path to a
    {placeholder} template. Carrying those through would file an issue that says
    nothing and puts an unusable path on the board, which is the exact failure
    `asset list` exists to report. So a required field must be answered, unless
    its default is a checklist: a list of boxes is content to tick, not an
    example to replace.
    """
    unanswered = unanswered_required(form, values)
    if unanswered:
        listed = ", ".join(
            f"{entry.label or entry.id} (--field {entry.id}=...)" for entry in unanswered
        )
        raise DocumentError(
            f"{form.slug} needs an answer for: {listed}\n"
            "The template's own default is example text, not an answer."
        )

    blocks: list[str] = []
    for entry in form.fields:
        if not entry.collects_input:
            continue
        answer = (values.get(entry.id) or entry.value).strip() or NO_RESPONSE
        blocks.append(f"### {entry.label or entry.id}\n\n{answer}")
    return "\n\n".join(blocks) + "\n"
