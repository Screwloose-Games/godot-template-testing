"""`pipeline.py asset ...` -- what the board says is being made, and whether it landed."""

from __future__ import annotations

import argparse
import sys
from pathlib import Path

from .. import board
from ..asset_list import render_tsv
from ..command import BOARD_FLAGS, BOARD_READ_FLAGS, DOC_FLAGS, REPO_FLAGS, add_generated_file_flags
from ..common import ASSET_LIST_PATH, EXIT_CANNOT_RUN, EXIT_OK, fail, relative, sync_text_file

ASSET_LIST_FIX = "python tools/pipeline/pipeline.py asset list --write"


class AssetListCommand:
    """List the assets on the project board and whether they have landed.

    Two delivery signals are reported side by side and never collapsed into one:
    `on_disk` is whether the file exists in the checkout you are standing in,
    `delivered_by` is whether a linked pull request changed it. An asset
    committed without an issue-linked PR and an asset promised by a PR that has
    not merged are different situations.

    This is a report, not a gate: a nonstandard filepath is a warning and never
    changes the exit code.

    --write and --check maintain documentation/pipeline/asset_list.tsv. Unlike
    the other generated files in this repo, --check needs the network and the
    read:project scope, so it is a local command and never a PR gate: the
    workflow's GITHUB_TOKEN is repo-scoped and cannot see an org project at all.

    Requires the read:project scope, which is not granted by default:
        gh auth refresh -h github.com -s read:project
    """

    name = "list"
    help = "list board assets with their filepath, status and delivery"
    parents = (BOARD_FLAGS, BOARD_READ_FLAGS, DOC_FLAGS, REPO_FLAGS)

    def add_arguments(self, parser: argparse.ArgumentParser) -> None:
        parser.add_argument(
            "--format", choices=("text", "markdown", "json", "tsv"), default="text"
        )
        parser.add_argument("--out", type=Path, help="write the report here instead of stdout")
        parser.add_argument(
            "--with-paths",
            action="store_true",
            help="list only items whose filepath column is set",
        )
        add_generated_file_flags(parser, target=relative(ASSET_LIST_PATH))

    def run(self, args: argparse.Namespace) -> int:
        # --write/--check own one specific file in one specific format, so a
        # --format that contradicts them is a mistake worth naming rather than
        # silently overriding.
        if (args.write or args.check) and args.format not in ("text", "tsv"):
            fail(
                f"--{'write' if args.write else 'check'} maintains "
                f"{relative(ASSET_LIST_PATH)}, which is TSV, but --format "
                f"{args.format} was given.",
                "Drop --format, or drop --write/--check.",
            )
            return EXIT_CANNOT_RUN

        report = board.collect(args)

        if args.write or args.check:
            # --out retargets the generated file rather than being ignored, so
            # a dry comparison against a scratch copy is possible.
            return sync_text_file(
                args.out or ASSET_LIST_PATH,
                render_tsv(report.rows),
                check=args.check,
                fix_command=ASSET_LIST_FIX,
            )

        if args.format == "tsv":
            text = render_tsv(report.rows)
        elif args.format == "json":
            text = board.render_json(report.rows, report.meta, report.notes, report.context)
        elif args.format == "markdown":
            text = board.render_markdown(report.rows, report.meta, report.notes)
        else:
            text = board.render_text(report.rows, report.meta, report.notes)

        if args.out:
            args.out.parent.mkdir(parents=True, exist_ok=True)
            args.out.write_text(text, encoding="utf-8", newline="\n")
            print(f"Wrote {relative(args.out)}", file=sys.stderr)
        else:
            sys.stdout.write(text)

        return EXIT_OK
