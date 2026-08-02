"""The command pattern the CLI is built from, and the flags commands share.

A command is four things: a name, a help string, the arguments it adds, and the
work it does. Expressing that as a Protocol rather than a base class follows the
same reasoning as GraphQLClient in github.py -- the implementations are plain
classes that happen to fit, and inheriting from an ABC would buy nothing but an
import.

The registry is argparse's own `set_defaults(command=...)`. Dispatch is then a
single attribute access in main(), with no if/elif ladder that could drift out of
step with the parser it mirrors.
"""

from __future__ import annotations

import argparse
from dataclasses import dataclass
from pathlib import Path
from typing import Callable, Protocol, runtime_checkable

from .board import (
    DEFAULT_ORG,
    DEFAULT_PAGE_SIZE,
    DEFAULT_PATH_FIELD,
    DEFAULT_PROJECT_NUMBER,
)
from .common import DOC_PATH, REPO_ROOT


# -- The contract ----------------------------------------------------------


@runtime_checkable
class Command(Protocol):
    """One leaf subcommand, e.g. `pipeline.py render pipeline`."""

    name: str
    help: str

    # Parent parsers contributing shared flags. Empty for a command that has none.
    parents: tuple[argparse.ArgumentParser, ...]

    def add_arguments(self, parser: argparse.ArgumentParser) -> None:
        """Add the flags that belong to this command alone."""

    def run(self, args: argparse.Namespace) -> int:
        """Do the work. Returns the process exit code."""


@dataclass(frozen=True)
class Group:
    """A first-level noun: issue, asset, render, extract."""

    name: str
    help: str
    commands: tuple[Command, ...]


# -- Shared flags ----------------------------------------------------------

# Parent parsers, built once at import and handed to add_parser(parents=...), so
# `--doc` means the same thing and reads the same help text in every command that
# takes it. The alternative -- a mixin, or copy-paste -- is what let the four
# scripts this replaced disagree about their own defaults.


def _flags(add: Callable[[argparse.ArgumentParser], None]) -> argparse.ArgumentParser:
    parent = argparse.ArgumentParser(add_help=False)
    add(parent)
    return parent


DOC_FLAGS = _flags(
    lambda parser: parser.add_argument(
        "--doc",
        type=Path,
        default=DOC_PATH,
        help="pipeline.yaml to read (default: %(default)s)",
    )
)

REPO_FLAGS = _flags(
    lambda parser: parser.add_argument(
        "--repo-root",
        type=Path,
        default=REPO_ROOT,
        help="checkout to resolve repository-relative paths against",
    )
)

WRITE_FLAGS = _flags(
    lambda parser: parser.add_argument(
        "--apply",
        action="store_true",
        help="actually write to GitHub. Without it the commands are printed and nothing happens.",
    )
)


def _add_board_flags(parser: argparse.ArgumentParser) -> None:
    """Which board, and how to reach it. Every command that talks to GitHub."""
    parser.add_argument("--org", default=DEFAULT_ORG, help="(default: %(default)s)")
    parser.add_argument(
        "--project", type=int, default=DEFAULT_PROJECT_NUMBER, help="(default: %(default)s)"
    )
    parser.add_argument("--token", help="use this token instead of the gh CLI")


def _add_board_read_flags(parser: argparse.ArgumentParser) -> None:
    """How much of the board to read, and whether to read it live at all."""
    parser.add_argument("--page-size", type=int, default=DEFAULT_PAGE_SIZE)
    parser.add_argument(
        "--path-field", default=DEFAULT_PATH_FIELD, help="board column holding the asset path"
    )
    parser.add_argument("--no-pr-files", action="store_true", help="skip the changed-file lookups")
    parser.add_argument("--cache", type=Path, help="cache PR file lists here between runs")
    parser.add_argument("--from-json", type=Path, help="replay a --dump-json recording")
    parser.add_argument("--dump-json", type=Path, help="record the raw project pages here")


BOARD_FLAGS = _flags(_add_board_flags)
BOARD_READ_FLAGS = _flags(_add_board_read_flags)


def add_generated_file_flags(parser: argparse.ArgumentParser, *, target: str) -> None:
    """Add the --write/--check pair for a command that owns a generated file.

    A helper rather than a parent parser: mutually exclusive groups survive
    `parents=` badly enough that debugging one is not worth the symmetry.
    """
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument("--write", action="store_true", help=f"write {target}")
    mode.add_argument(
        "--check",
        action="store_true",
        help=f"fail if {target} is out of date; write nothing",
    )
