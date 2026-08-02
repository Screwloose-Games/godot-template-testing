"""`pipeline.py render ...` -- the documents generated from pipeline.yaml."""

from __future__ import annotations

import argparse
from pathlib import Path

from ..command import DOC_FLAGS
from ..common import (
    EXIT_CHECK_FAILED,
    EXIT_OK,
    PIPELINE_MD_PATH,
    REPO_ROOT,
    fail,
    load_doc,
    print_status,
    sync_text_file,
)
from ..renderer import Renderer
from ..templates import collect_checklists, process

RENDER_PIPELINE_FIX = "python tools/pipeline/pipeline.py render pipeline"
RENDER_TEMPLATES_FIX = "python tools/pipeline/pipeline.py render issue-templates --write"


class RenderPipelineCommand:
    """Render pipeline.yaml into documentation/pipeline/PIPELINE.md.

    The whole command is one call to the renderer and one call to the shared
    generated-file writer. That is deliberate: --check has to mean exactly the
    same thing here as it does for the issue templates and the images.
    """

    name = "pipeline"
    help = "render pipeline.yaml into PIPELINE.md"
    parents = (DOC_FLAGS,)

    def add_arguments(self, parser: argparse.ArgumentParser) -> None:
        parser.add_argument("--out", type=Path, default=PIPELINE_MD_PATH)
        parser.add_argument(
            "--check",
            action="store_true",
            help="fail if the rendered file on disk is out of date; write nothing",
        )

    def run(self, args: argparse.Namespace) -> int:
        rendered = Renderer(load_doc(args.doc)).render()
        return sync_text_file(
            args.out,
            rendered,
            check=args.check,
            fix_command=RENDER_PIPELINE_FIX,
        )


class RenderIssueTemplatesCommand:
    """Write the generated subtask checklists into .github/ISSUE_TEMPLATE/*.yaml.

    Reports by default and only writes with --write, so it cannot clobber a
    template nobody opted in. A template with no markers is never modified: the
    block it would have inserted is printed instead, for a maintainer to paste
    in once.
    """

    name = "issue-templates"
    help = "write generated subtask checklists into the issue templates"
    parents = (DOC_FLAGS,)

    def add_arguments(self, parser: argparse.ArgumentParser) -> None:
        parser.add_argument("--write", action="store_true", help="update managed blocks in place")
        parser.add_argument(
            "--check",
            action="store_true",
            help="exit non-zero if any managed block is out of date (CI mode)",
        )

    def run(self, args: argparse.Namespace) -> int:
        checklists = collect_checklists(load_doc(args.doc))
        if not checklists:
            print("No issue templates are referenced with checklist rules.")
            return EXIT_OK

        results = [
            process(REPO_ROOT / rel, rel, items, args.write) for rel, items in checklists.items()
        ]

        stale = [r for r in results if r.status == "stale"]
        missing = [r for r in results if r.status == "missing"]
        unmanaged = [r for r in results if r.status == "unmanaged"]

        for result in results:
            if result.status == "current":
                print_status("ok", result.path, result.detail)
            elif result.status == "stale":
                print_status("STALE", result.path, result.detail)
            elif result.status == "missing":
                print_status("MISSING", result.path, result.detail)

        if unmanaged:
            print(
                f"\n{len(unmanaged)} template(s) have no managed block yet. They were not "
                "modified. To let this command maintain a template's checklist, paste the "
                "block below into its Subtasks field:\n"
            )
            for result in unmanaged:
                print(f"--- {result.path} ---")
                print(result.block)
                print()

        if missing:
            fail(
                "a template referenced by pipeline.yaml does not exist.",
                "Fix opened_by_issue_template in pipeline.yaml, or add the template.",
            )
            return EXIT_CHECK_FAILED

        if stale and args.check:
            fail(
                f"{len(stale)} managed block(s) are out of date with pipeline.yaml.",
                f"Run: {RENDER_TEMPLATES_FIX}",
            )
            return EXIT_CHECK_FAILED

        if stale and not args.write:
            print("\nRun with --write to update them.")

        return EXIT_OK
