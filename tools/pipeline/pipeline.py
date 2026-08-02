#!/usr/bin/env python3
"""One CLI for the asset pipeline: the board, the issues, and the generated docs.

Everything under tools/pipeline/ is reached through this file. The four scripts
it replaced each carried their own copy of the repository root, the PyYAML guard,
and the "compare to what is on disk, print a diff, name the command that fixes
it" dance, which is exactly the kind of duplication that drifts. Here `--check`
means one thing, implemented once.

Exit codes: 0 fine, 1 a check failed, 2 the command could not run. argparse also
exits 2 for a usage error, which is the same class of problem -- the command
never got as far as doing its work.

Anything that writes to GitHub is a dry run until --apply: the commands are
printed and nothing is sent. Those need the gh CLI, with the project scope:

    gh auth refresh -h github.com -s project

Usage:
    python tools/pipeline/pipeline.py --help

    python tools/pipeline/pipeline.py issue create --template create_model \\
        --name "rain barrel" --description "A wooden rain barrel." \\
        --field "dimentions=1m x 1m x 1m" \\
        --filepath assets/art/3d/props/rain_barrel/sm_rain_barrel.gltf
    python tools/pipeline/pipeline.py issue update 42 --filepath a/b/sm_c.gltf --apply

    python tools/pipeline/pipeline.py backlog new --template create_model
    python tools/pipeline/pipeline.py backlog file            # check every entry
    python tools/pipeline/pipeline.py backlog file --apply    # open the issues

    python tools/pipeline/pipeline.py asset list
    python tools/pipeline/pipeline.py asset list --format markdown
    python tools/pipeline/pipeline.py asset list --write    # asset_list.tsv

    python tools/pipeline/pipeline.py render pipeline --check
    python tools/pipeline/pipeline.py render issue-templates --write
    python tools/pipeline/pipeline.py extract images --check
"""

from __future__ import annotations

import sys
from pathlib import Path

# sys.path[0] is already this directory when the script is run by path, which is
# how everyone runs it. The insert covers the cases where it is not: invocation
# through a symlink from elsewhere, or runpy from a harness. It is idempotent.
sys.path.insert(0, str(Path(__file__).resolve().parent))

from pipeline_cli.cli import main  # noqa: E402  -- must follow the path insert

if __name__ == "__main__":
    sys.exit(main())
