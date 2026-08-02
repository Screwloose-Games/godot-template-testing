"""Render the board as documentation/pipeline/asset_list.tsv.

The file answers one question -- what is being made, and where does it go -- for
readers who are not going to run a CLI: a spreadsheet, a jam planning doc, a
glance at a diff. It is generated, so `--check` can say when it has drifted from
the board.

Every column is board-derived. It is tempting to compute `status` from the
delivery signals the report already has (`on_disk`, `delivered_by`), and that is
the one thing this must not do: `on_disk` depends on the working tree, so the
file would change under `git checkout` and `--check` would report noise instead
of board movement.

TSV has no comment syntax, so unlike PIPELINE.md this file cannot announce that
it is generated. CLAUDE.md and documentation/pipeline/README.md say so instead.
"""

from __future__ import annotations

from .board import Row, asset_name, sort_key
from .common import tsv_cell

COLUMNS = ("priority", "status", "name", "description", "file_location")


def _priority(row: Row) -> str:
    return tsv_cell(row.item.issue_fields.get("Priority", "")).lower()


def _status(row: Row) -> str:
    # The board's own column, lowercased and underscored so the values are
    # stable to compare: "In Progress" and "in progress" are one status.
    return tsv_cell(row.item.fields.get("Status", "")).lower().replace(" ", "_")


def _description(row: Row) -> str:
    return tsv_cell(row.item.issue_fields.get("Description") or row.item.title or "")


def rows_for_list(rows: list[Row]) -> list[Row]:
    """Only rows with a usable path.

    A row in a file called asset_list with no asset location says nothing, and
    the blank/placeholder/unparseable cases are what the text and markdown
    reports exist to surface.
    """
    return [row for row in rows if row.asset_path.status == "ok" and row.asset_path.path]


def render_tsv(rows: list[Row]) -> str:
    """One header line, then one line per asset, ordered by repo and issue number."""
    lines = ["\t".join(COLUMNS)]
    for row in sorted(rows_for_list(rows), key=sort_key):
        lines.append(
            "\t".join(
                [
                    _priority(row),
                    _status(row),
                    tsv_cell(asset_name(row)),
                    _description(row),
                    row.asset_path.path,
                ]
            )
        )
    return "\n".join(lines) + "\n"
