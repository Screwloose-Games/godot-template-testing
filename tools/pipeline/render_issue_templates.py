#!/usr/bin/env python3
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

Usage:
    python tools/pipeline/render_issue_templates.py           # report
    python tools/pipeline/render_issue_templates.py --write   # apply
    python tools/pipeline/render_issue_templates.py --check   # CI: fail if stale
"""

from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path

try:
    import yaml
except ImportError:  # pragma: no cover
    print("ERROR: PyYAML is required. pip install pyyaml", file=sys.stderr)
    raise SystemExit(1)

REPO_ROOT = Path(__file__).resolve().parents[2]
DOC_PATH = REPO_ROOT / "documentation" / "pipeline" / "pipeline.yaml"

START_MARKER = "<!-- pipeline:subtasks:start -->"
END_MARKER = "<!-- pipeline:subtasks:end -->"
GENERATED_NOTE = (
    "<!-- Generated from documentation/pipeline/pipeline.yaml. "
    "Edit that file, then run tools/pipeline/render_issue_templates.py --write. -->"
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


class TemplateResult:
    def __init__(self, path: str, status: str, block: str, detail: str = ""):
        self.path = path
        self.status = status  # "current" | "stale" | "unmanaged" | "missing"
        self.block = block
        self.detail = detail


def process(template_path: Path, rel: str, items: list[str], write: bool) -> TemplateResult:
    if not template_path.is_file():
        return TemplateResult(rel, "missing", "", "file does not exist")

    text = template_path.read_text(encoding="utf-8")

    match = re.search(
        rf"^([ \t]*){re.escape(START_MARKER)}.*?^[ \t]*{re.escape(END_MARKER)}[ \t]*$",
        text,
        re.DOTALL | re.MULTILINE,
    )
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
        try:
            yaml.safe_load(updated)
        except yaml.YAMLError as exc:
            return TemplateResult(
                rel, "stale", block, f"refusing to write - result is not valid YAML: {exc}"
            )
        template_path.write_text(updated, encoding="utf-8")
        return TemplateResult(rel, "current", block, "updated")

    return TemplateResult(rel, "stale", block)


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--doc", type=Path, default=DOC_PATH)
    parser.add_argument("--write", action="store_true", help="update managed blocks in place")
    parser.add_argument(
        "--check",
        action="store_true",
        help="exit non-zero if any managed block is out of date (CI mode)",
    )
    args = parser.parse_args(argv)

    doc = yaml.safe_load(args.doc.read_text(encoding="utf-8"))
    checklists = collect_checklists(doc)

    if not checklists:
        print("No issue templates are referenced with checklist rules.")
        return 0

    results = [
        process(REPO_ROOT / rel, rel, items, args.write) for rel, items in checklists.items()
    ]

    stale = [r for r in results if r.status == "stale"]
    missing = [r for r in results if r.status == "missing"]
    unmanaged = [r for r in results if r.status == "unmanaged"]
    current = [r for r in results if r.status == "current"]

    for result in current:
        suffix = f" ({result.detail})" if result.detail else ""
        print(f"  ok         {result.path}{suffix}")
    for result in stale:
        print(f"  STALE      {result.path}")
        if result.detail:
            print(f"             {result.detail}")
    for result in missing:
        print(f"  MISSING    {result.path} - {result.detail}")

    if unmanaged:
        print(
            f"\n{len(unmanaged)} template(s) have no managed block yet. They were not "
            "modified. To let this script maintain a template's checklist, paste the "
            "block below into its Subtasks field:\n"
        )
        for result in unmanaged:
            print(f"--- {result.path} ---")
            print(result.block)
            print()

    if missing:
        print(
            "\nA template referenced by pipeline.yaml does not exist.",
            file=sys.stderr,
        )
        return 1

    if stale and args.check:
        print(
            f"\n{len(stale)} managed block(s) are out of date with pipeline.yaml.\n"
            "Run: python tools/pipeline/render_issue_templates.py --write",
            file=sys.stderr,
        )
        return 1

    if stale and not args.write:
        print("\nRun with --write to update them.")

    return 0


if __name__ == "__main__":
    sys.exit(main())
