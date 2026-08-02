"""`pipeline.py extract ...` -- pulling source material out of the Miro export."""

from __future__ import annotations

import argparse

from ..common import (
    EXIT_CHECK_FAILED,
    EXIT_OK,
    IMAGES_DIR,
    fail,
    print_status,
    relative,
    sync_binary_file,
)
from ..images import ExtractionError, emit_yaml, extract

EXTRACT_IMAGES_FIX = "python tools/pipeline/pipeline.py extract images"


class ExtractImagesCommand:
    """Extract the screenshots embedded in the asset-pipeline SVG export.

    Idempotent: an image already on disk is verified by sha256 rather than
    rewritten, so a clean run is silent about the files that did not change.
    """

    name = "images"
    help = "extract the screenshots embedded in the pipeline SVG"
    parents = ()

    def add_arguments(self, parser: argparse.ArgumentParser) -> None:
        parser.add_argument(
            "--check",
            action="store_true",
            help="verify the files on disk match the SVG; write nothing",
        )
        parser.add_argument(
            "--emit-yaml",
            action="store_true",
            help="print the images: block for pipeline.yaml",
        )

    def run(self, args: argparse.Namespace) -> int:
        try:
            images = extract()
        except ExtractionError as exc:
            fail(str(exc))
            return EXIT_CHECK_FAILED

        if args.emit_yaml:
            print(emit_yaml(images))
            return EXIT_OK

        if not args.check:
            IMAGES_DIR.mkdir(parents=True, exist_ok=True)

        problems: list[str] = []
        counts = {"ok": 0, "written": 0}

        for image in images:
            rel = relative(image.path)
            status = sync_binary_file(image.path, image.data, check=args.check)
            if status == "ok":
                counts["ok"] += 1
                print_status("ok", rel)
            elif status == "written":
                counts["written"] += 1
                print_status(
                    "written", rel, f"{image.width}x{image.height}, {image.sha256[:12]}"
                )
            elif status == "differs":
                problems.append(f"{rel} differs from the SVG payload")
            else:
                problems.append(f"{rel} is missing")

        if problems:
            fail(
                "extracted images are out of sync with the SVG:\n"
                + "\n".join(f"  - {problem}" for problem in problems),
                f"Run: {EXTRACT_IMAGES_FIX}",
            )
            return EXIT_CHECK_FAILED

        print(
            f"\n{len(images)} image(s): {counts['written']} written, "
            f"{counts['ok']} already current."
        )
        return EXIT_OK
