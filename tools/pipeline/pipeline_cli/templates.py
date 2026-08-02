"""Generate issue-template subtask checklists from pipeline.yaml.

Every rule in the pipeline document can carry a `checklist:` line. This script
collects them per issue template -- from the steps that name that template, plus
the pipeline's own cross-cutting rules -- and writes them into a marker-delimited
block inside the template's Subtasks field:

    <!-- pipeline:subtasks:start -->
    - [ ] ...
    <!-- pipeline:subtasks:end -->

Only the text between those markers is ever touched. Hand-written prose outside
them is left alone, and a template with no markers is never modified at all --
the script prints the block it would have inserted so a maintainer can paste it
in once and opt that template into being generated from then on.

It reports by default and only writes with --write, so it cannot clobber
anything you have not opted in.

Driven by `pipeline.py render issue-templates`; see
pipeline_cli/commands/render.py. The block builder is also reused by
`pipeline.py issue update --resync-subtasks`, which re-renders the same markers
inside an issue that is already open.
"""

from __future__ import annotations

import re
from dataclasses import dataclass
from pathlib import Path

from .common import is_valid_yaml

START_MARKER = "<!-- pipeline:subtasks:start -->"
END_MARKER = "<!-- pipeline:subtasks:end -->"

# Written verbatim into every managed template, so changing this text makes every
# managed block stale and requires committing a re-render alongside the change.
GENERATED_NOTE = (
    "<!-- Generated from documentation/pipeline/pipeline.yaml. "
    "Edit that file, then run tools/pipeline/pipeline.py render issue-templates --write. -->"
)

BLOCK_RE = re.compile(
    rf"^([ \t]*){re.escape(START_MARKER)}.*?^[ \t]*{re.escape(END_MARKER)}[ \t]*$",
    re.DOTALL | re.MULTILINE,
)


def collect_checklists(doc: dict) -> dict[str, list[str]]:
    """Map each referenced issue template to its ordered, deduplicated checklist."""
    per_template: dict[str, list[str]] = {}
    contributing_pipelines: dict[str, set[str]] = {}

    for pipeline in doc.get("pipelines", []):
        for phase in sorted(pipeline.get("phases", []), key=lambda p: p["lane"]):
            for step in phase.get("steps", []):
                template = step.get("opened_by_issue_template")
                if not template:
                    continue
                contributing_pipelines.setdefault(template, set()).add(pipeline["id"])
                items = per_template.setdefault(template, [])
                for rule in step.get("rules", []):
                    if rule.get("checklist"):
                        items.append(rule["checklist"])

    # Cross-cutting rules apply to every template the pipeline feeds.
    for pipeline in doc.get("pipelines", []):
        conventions = pipeline.get("conventions") or {}
        cross_cutting = [
            rule["checklist"] for rule in conventions.get("rules", []) if rule.get("checklist")
        ]
        if not cross_cutting:
            continue
        for template, pipeline_ids in contributing_pipelines.items():
            if pipeline["id"] in pipeline_ids:
                per_template[template].extend(cross_cutting)

    return {
        template: list(dict.fromkeys(items))
        for template, items in sorted(per_template.items())
        if items
    }


def build_block(items: list[str], indent: str) -> str:
    lines = [indent + START_MARKER, indent + GENERATED_NOTE]
    lines += [f"{indent}- [ ] {' '.join(item.split())}" for item in items]
    lines.append(indent + END_MARKER)
    return "\n".join(lines)


@dataclass
class TemplateResult:
    path: str
    status: str  # "current" | "stale" | "unmanaged" | "missing"
    block: str
    detail: str = ""


def process(template_path: Path, rel: str, items: list[str], write: bool) -> TemplateResult:
    if not template_path.is_file():
        return TemplateResult(rel, "missing", "", "file does not exist")

    text = template_path.read_text(encoding="utf-8")

    match = BLOCK_RE.search(text)
    if match is None:
        # Guess the indentation a maintainer would need, from the Subtasks block.
        indent = "        "
        subtasks = re.search(r"^([ \t]*)- \[ \] ", text, re.MULTILINE)
        if subtasks:
            indent = subtasks.group(1)
        return TemplateResult(rel, "unmanaged", build_block(items, indent))

    indent = match.group(1)
    block = build_block(items, indent)
    if match.group(0) == block:
        return TemplateResult(rel, "current", block)

    if write:
        updated = text[: match.start()] + block + text[match.end() :]
        # The block lives inside a `value: |` scalar, so a mis-indented splice
        # would produce a file GitHub silently stops rendering as a form.
        valid, detail = is_valid_yaml(updated)
        if not valid:
            return TemplateResult(
                rel, "stale", block, f"refusing to write - result is not valid YAML: {detail}"
            )
        template_path.write_text(updated, encoding="utf-8", newline="\n")
        return TemplateResult(rel, "current", block, "updated")

    return TemplateResult(rel, "stale", block)
