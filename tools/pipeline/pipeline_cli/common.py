"""Paths, exit codes, and the small helpers every command shares.

Four standalone scripts used to carry their own copy of the repository root, the
PyYAML import guard, the markdown cell escaper, and the "compare the rendered
text to what is on disk, print a diff, name the command that fixes it" dance.
Four copies meant four chances to drift, and they had already drifted: two of the
renderers wrote without ``newline="\\n"``, which is why PIPELINE.md is CRLF in a
Windows checkout while the issue templates next to it are LF.

So this module owns those decisions once. In particular ``sync_text_file`` is the
single implementation of a generated file: every command that owns one calls it
and returns what it returns, which is what makes ``--check`` behave identically
across the CLI instead of by convention.
"""

from __future__ import annotations

import difflib
import hashlib
import sys
from pathlib import Path
from typing import Any

try:
    import yaml
except ImportError:  # pragma: no cover
    print("ERROR: PyYAML is required. pip install pyyaml", file=sys.stderr)
    raise SystemExit(1)


# -- Paths -----------------------------------------------------------------

# tools/pipeline/pipeline_cli/common.py -> tools/pipeline/pipeline_cli -> ...
# One level deeper than the scripts this replaced, which is the single easiest
# thing to get wrong here; test_common.py asserts it lands on the checkout.
REPO_ROOT = Path(__file__).resolve().parents[3]

DOC_PATH = REPO_ROOT / "documentation" / "pipeline" / "pipeline.yaml"
PIPELINE_MD_PATH = REPO_ROOT / "documentation" / "pipeline" / "PIPELINE.md"
ASSET_LIST_PATH = REPO_ROOT / "documentation" / "pipeline" / "asset_list.tsv"
IMAGES_DIR = REPO_ROOT / "documentation" / "pipeline" / "images"

# The one hand-authored directory here. Everything else under
# documentation/pipeline/ is generated and reverts when edited by hand; these are
# input, written by a person and read by `pipeline.py backlog file`.
BACKLOG_DIR = REPO_ROOT / "documentation" / "pipeline" / "backlog"
SVG_PATH = REPO_ROOT / "documentation" / "SolarPunk Jam - Asset Pipeline.svg"
ISSUE_TEMPLATE_DIR = REPO_ROOT / ".github" / "ISSUE_TEMPLATE"


# -- Exit codes ------------------------------------------------------------

EXIT_OK = 0
EXIT_CHECK_FAILED = 1

# "The tool could not run", as distinct from "the check failed". argparse also
# exits 2 for a usage error, which is the same class of problem: the command
# never got as far as doing its work.
EXIT_CANNOT_RUN = 2


# -- Errors ----------------------------------------------------------------


class DocumentError(RuntimeError):
    """A document could not be read or parsed. Carries the path in its message."""


def fail(message: str, remediation: str = "") -> None:
    """Report an error the way every gate in this repo does: what, then the fix."""
    print(f"ERROR: {message}", file=sys.stderr)
    if remediation:
        print(remediation, file=sys.stderr)


# -- YAML ------------------------------------------------------------------

# This is the only module that imports yaml, so the "is PyYAML installed"
# question is asked once rather than at the top of every file.


def parse_yaml(text: str, *, source: str = "") -> Any:
    """Parse YAML, raising DocumentError rather than a library-specific one."""
    try:
        return yaml.safe_load(text)
    except yaml.YAMLError as exc:
        where = f"{source}: " if source else ""
        raise DocumentError(f"{where}{exc}") from exc


def load_doc(path: Path) -> dict:
    """Read and parse a YAML document, or raise DocumentError naming the path."""
    try:
        text = path.read_text(encoding="utf-8")
    except OSError as exc:
        raise DocumentError(f"could not read {relative(path)}: {exc}") from exc

    doc = parse_yaml(text, source=relative(path))
    if not isinstance(doc, dict):
        raise DocumentError(f"{relative(path)} is not a YAML mapping")
    return doc


def yaml_marks(text: str, *, source: str = "") -> Any:
    """Parse to a node tree that still carries source line and column marks.

    safe_load throws those away, which is exactly what a tool that wants to edit
    one line of a hand-authored file needs to keep: `backlog file` writes an
    issue number back into a file full of comments and block scalars, and a
    load-then-dump round trip would flatten all of it.

    Returns None for an empty document, matching yaml.compose.
    """
    try:
        return yaml.compose(text)
    except yaml.YAMLError as exc:
        where = f"{source}: " if source else ""
        raise DocumentError(f"{where}{exc}") from exc


def is_valid_yaml(text: str) -> tuple[bool, str]:
    """Would this text still parse? Used before writing into a template in place."""
    try:
        yaml.safe_load(text)
    except yaml.YAMLError as exc:
        return False, str(exc)
    return True, ""


# -- Cells -----------------------------------------------------------------


def md_cell(value: Any, *, empty: str = "") -> str:
    """Collapse whitespace and escape pipes, so a value cannot break out of a row."""
    return " ".join(str(value).split()).replace("|", "\\|") or empty


def tsv_cell(value: Any) -> str:
    """Collapse whitespace to single spaces. A TSV cell cannot contain a tab."""
    return " ".join(str(value).split())


# -- Reporting -------------------------------------------------------------


def print_status(status: str, target: str, detail: str = "") -> None:
    """One aligned status line, e.g. `  ok          documentation/pipeline/PIPELINE.md`."""
    print(f"  {status:<11} {target}")
    if detail:
        print(f"              {detail}")


def relative(path: Path, root: Path = REPO_ROOT) -> str:
    """Repo-relative posix path for display, falling back to the absolute one.

    Path.relative_to raises for anything outside the repository, which turned a
    `--out /tmp/x.md` into a traceback in the renderer it replaced.
    """
    try:
        return path.resolve().relative_to(root).as_posix()
    except ValueError:
        return str(path)


# -- Generated files -------------------------------------------------------


def sync_text_file(
    path: Path,
    rendered: str,
    *,
    check: bool,
    fix_command: str,
    repo_root: Path = REPO_ROOT,
) -> int:
    """Write a generated file, or under --check prove the committed one matches.

    Reads with read_text (universal newlines) and writes with newline="\\n". A
    Windows checkout has CRLF in the working tree under .gitattributes' eol=lf,
    so comparing raw bytes would fail --check for every Windows contributor while
    the committed file was perfectly fine.
    """
    if check:
        if not path.is_file():
            fail(f"{relative(path, repo_root)} does not exist.", f"Run: {fix_command}")
            return EXIT_CHECK_FAILED

        current = path.read_text(encoding="utf-8")
        if current == rendered:
            print(f"{path.name} is up to date.")
            return EXIT_OK

        fail(f"{path.name} is out of date.")
        diff = difflib.unified_diff(
            current.splitlines(),
            rendered.splitlines(),
            fromfile=f"{path.name} (committed)",
            tofile=f"{path.name} (rendered)",
            lineterm="",
            n=2,
        )
        for line in list(diff)[:60]:
            print(line, file=sys.stderr)
        print(f"\nRun: {fix_command}", file=sys.stderr)
        return EXIT_CHECK_FAILED

    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(rendered, encoding="utf-8", newline="\n")
    print(f"Wrote {relative(path, repo_root)} ({len(rendered.splitlines())} lines)")
    return EXIT_OK


def sync_binary_file(path: Path, data: bytes, *, check: bool) -> str:
    """The binary twin of sync_text_file, reporting rather than exiting.

    Returns "ok" | "written" | "differs" | "missing". Callers extract many files
    in one pass and want every problem listed, not the first one.
    """
    if path.is_file():
        if hashlib.sha256(path.read_bytes()).hexdigest() == hashlib.sha256(data).hexdigest():
            return "ok"
        if check:
            return "differs"
    elif check:
        return "missing"

    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(data)
    return "written"
