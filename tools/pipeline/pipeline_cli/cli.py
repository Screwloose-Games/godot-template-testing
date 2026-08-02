"""Argument parsing and dispatch for `tools/pipeline/pipeline.py`.

The registry is argparse's own `set_defaults(command=...)`: building the parser
is what registers the commands, so there is no second list to keep in step. Two
levels of subparser buy a readable surface (`issue create`, `render pipeline`)
at the cost of discoverability, since `--help` on the top level would otherwise
show four nouns and nothing else -- hence the epilog, generated from GROUPS so it
cannot drift from what actually exists.

Errors are caught here rather than in the commands. One place decides how a
GitHub failure is explained, which is what lets a write command get the
write-scope remediation while a read command gets the read-scope one.
"""

from __future__ import annotations

import argparse
import inspect
import sys

from .board import TransportError, explain_transport_error
from .command import Group
from .commands.asset import AssetListCommand
from .commands.backlog import BacklogFileCommand, BacklogNewCommand
from .commands.extract import ExtractImagesCommand
from .commands.issue import IssueCreateCommand, IssueUpdateCommand
from .commands.render import RenderIssueTemplatesCommand, RenderPipelineCommand
from .common import EXIT_CANNOT_RUN, DocumentError, fail

PROG = "pipeline.py"

# Not __doc__: that describes this module to a maintainer, and --help is read by
# someone who wants to know what the tool does.
DESCRIPTION = "One CLI for the asset pipeline: the board, the issues, and the generated docs."

GROUPS: tuple[Group, ...] = (
    Group(
        "issue",
        "open and amend the issues that track assets",
        (IssueCreateCommand(), IssueUpdateCommand()),
    ),
    Group(
        "backlog",
        "turn a hand-authored backlog file into issues",
        (BacklogNewCommand(), BacklogFileCommand()),
    ),
    Group(
        "asset",
        "read the asset board",
        (AssetListCommand(),),
    ),
    Group(
        "render",
        "generate documentation from pipeline.yaml",
        (RenderPipelineCommand(), RenderIssueTemplatesCommand()),
    ),
    Group(
        "extract",
        "pull source material out of the Miro export",
        (ExtractImagesCommand(),),
    ),
)


def leaves() -> list[tuple[str, str]]:
    """Every (group, command) pair the CLI exposes, in declaration order."""
    return [(group.name, cmd.name) for group in GROUPS for cmd in group.commands]


def surface() -> str:
    """Every leaf command as one block, for the top-level --help epilog."""
    labels = {(g, c): f"{PROG} {g} {c}" for g, c in leaves()}
    width = max(len(label) for label in labels.values())
    lines = ["commands:"]
    for group in GROUPS:
        for cmd in group.commands:
            lines.append(f"  {labels[(group.name, cmd.name)]:<{width}}  {cmd.help}")
    return "\n".join(lines)


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog=PROG,
        description=DESCRIPTION,
        epilog=surface(),
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    groups = parser.add_subparsers(dest="group", metavar="<group>", required=True)

    for group in GROUPS:
        group_parser = groups.add_parser(
            group.name,
            help=group.help,
            description=group.help,
        )
        leaves = group_parser.add_subparsers(
            dest="command_name", metavar="<command>", required=True
        )
        for cmd in group.commands:
            leaf = leaves.add_parser(
                cmd.name,
                help=cmd.help,
                description=inspect.getdoc(cmd) or cmd.help,
                parents=list(cmd.parents),
                formatter_class=argparse.RawDescriptionHelpFormatter,
            )
            cmd.add_arguments(leaf)
            # `command_name` holds the string and `command` holds the object.
            # Using one name for both would let argparse overwrite the object.
            leaf.set_defaults(command=cmd)

    return parser


def main(argv: list[str] | None = None) -> int:
    args = build_parser().parse_args(argv)
    try:
        return args.command.run(args)
    except DocumentError as exc:
        fail(str(exc))
        return EXIT_CANNOT_RUN
    except TransportError as exc:
        print(explain_transport_error(str(exc)), file=sys.stderr)
        return EXIT_CANNOT_RUN
