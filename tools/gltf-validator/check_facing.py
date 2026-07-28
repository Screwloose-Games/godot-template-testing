#!/usr/bin/env python3
"""Dry-run the facing/up direction checks over the models already in the repo.

The point is to see what the current assets actually measure *before* making the
check blocking. Reports only; never fails a build.

Parses .gltf and .glb with the standard library, so it runs anywhere -- no
pygltflib, no trimesh, no Docker image.

Usage:
    python tools/gltf-validator/check_facing.py
    python tools/gltf-validator/check_facing.py --path assets/3d
    python tools/gltf-validator/check_facing.py --expect-facing +Z --expect-up +Y
"""

from __future__ import annotations

import argparse
import json
import struct
import sys
from pathlib import Path
from types import SimpleNamespace

sys.path.insert(0, str(Path(__file__).resolve().parent))

import gltf_axes  # noqa: E402
import gltf_transforms  # noqa: E402

REPO_ROOT = Path(__file__).resolve().parents[2]

GLB_MAGIC = 0x46546C67  # "glTF"
CHUNK_JSON = 0x4E4F534A  # "JSON"


def read_glb_json(path: Path) -> dict:
    """Pull the JSON chunk out of a binary glTF container."""
    data = path.read_bytes()
    if len(data) < 12:
        raise ValueError("file is too short to be a GLB")
    magic, version, _length = struct.unpack_from("<III", data, 0)
    if magic != GLB_MAGIC:
        raise ValueError("not a GLB (bad magic)")
    if version != 2:
        raise ValueError(f"unsupported GLB version {version}")

    offset = 12
    while offset + 8 <= len(data):
        chunk_length, chunk_type = struct.unpack_from("<II", data, offset)
        offset += 8
        if chunk_type == CHUNK_JSON:
            return json.loads(data[offset : offset + chunk_length].decode("utf-8"))
        offset += chunk_length
    raise ValueError("no JSON chunk found in GLB")


def read_document(path: Path) -> dict:
    if path.suffix.lower() == ".glb":
        return read_glb_json(path)
    return json.loads(path.read_text(encoding="utf-8"))


def as_gltf(document: dict):
    """Give the JSON the attribute shape gltf_axes and gltf_transforms expect."""
    return SimpleNamespace(
        scene=document.get("scene", 0),
        scenes=[SimpleNamespace(nodes=scene.get("nodes")) for scene in document.get("scenes", [])],
        nodes=[
            SimpleNamespace(
                name=node.get("name"),
                mesh=node.get("mesh"),
                children=node.get("children"),
                rotation=node.get("rotation"),
                translation=node.get("translation"),
                scale=node.get("scale"),
                matrix=node.get("matrix"),
            )
            for node in document.get("nodes", [])
        ],
        # Joints and animated nodes are allowed to carry transforms; the
        # transform check needs these to know which nodes to leave alone.
        skins=[
            SimpleNamespace(joints=skin.get("joints"), skeleton=skin.get("skeleton"))
            for skin in document.get("skins", [])
        ],
        animations=[
            SimpleNamespace(
                channels=[
                    SimpleNamespace(
                        target=SimpleNamespace(node=channel.get("target", {}).get("node"))
                    )
                    for channel in animation.get("channels", [])
                ]
            )
            for animation in document.get("animations", [])
        ],
    )


def display_path(path: Path, scan_root: Path) -> str:
    """Repo-relative where possible, else relative to whatever was scanned."""
    for base in (REPO_ROOT, scan_root):
        try:
            return path.relative_to(base).as_posix()
        except ValueError:
            continue
    return path.as_posix()


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--path", type=Path, default=REPO_ROOT, help="directory to scan")
    # "+Z" here is the *node frame*, not the model's facing: this reports where
    # the node chain sends the glTF forward basis vector, which reads +Z for
    # every clean export no matter which way the geometry was built. The
    # project's geometric convention is -Z (Godot's forward, from Blender +Y),
    # and no value passed here can verify it -- see the facing_direction_gltf
    # rule in documentation/pipeline/. Deviation from +Z means a leftover
    # rotation, which the transforms column reports properly.
    parser.add_argument("--expect-facing", default="+Z")
    parser.add_argument("--expect-up", default="+Y")
    args = parser.parse_args(argv)

    root = args.path if args.path.is_absolute() else REPO_ROOT / args.path
    models = sorted(
        path
        for pattern in ("**/*.gltf", "**/*.glb")
        for path in root.glob(pattern)
        if ".godot" not in path.parts and "addons" not in path.parts
    )

    if not models:
        print(f"No .gltf or .glb files found under {root}.")
        return 0

    print(f"Scanning {len(models)} model(s) under {root}.")
    print(f"Expecting facing {args.expect_facing}, up {args.expect_up}.\n")

    counts = {"pass": 0, "fail": 0, "unknown": 0, "error": 0, "unapplied": 0}
    rows: list[tuple[str, str, str, str, str]] = []
    details: list[tuple[str, str]] = []

    for path in models:
        rel = display_path(path, root)
        try:
            gltf = as_gltf(read_document(path))
        except Exception as exc:  # noqa: BLE001 — a bad file is a finding, not a crash
            rows.append((rel, "ERROR", type(exc).__name__, str(exc)[:60], "-"))
            counts["error"] += 1
            continue

        facing = gltf_axes.get_model_facing_direction(gltf)
        up = gltf_axes.get_model_up_direction(gltf)
        transforms = gltf_transforms.find_unapplied_transforms(gltf)

        if transforms.findings:
            details.append((rel, gltf_transforms.format_report(transforms)))

        # The axis reading and the transform check are reported side by side
        # rather than one overriding the other: they read the same node
        # rotation, and which of the two stories it tells is not something the
        # node graph can settle. The verdict column fails on either.
        if facing is None or up is None:
            axis_verdict = "UNKNOWN"
        elif facing == args.expect_facing and up == args.expect_up:
            axis_verdict = "pass"
        else:
            axis_verdict = "FAIL"

        transform_state = "ok" if transforms.ok else "UNAPPLIED"
        if not transforms.ok:
            counts["unapplied"] += 1

        if axis_verdict == "FAIL" or not transforms.ok:
            verdict = "FAIL"
            counts["fail"] += 1
        elif axis_verdict == "UNKNOWN":
            verdict = "UNKNOWN"
            counts["unknown"] += 1
        else:
            verdict = "pass"
            counts["pass"] += 1

        rows.append((rel, verdict, facing or "?", up or "?", transform_state))

    width = max(len(row[0]) for row in rows)
    print(f"{'model'.ljust(width)}  {'verdict':8}  {'facing':7}  {'up':7}  transforms")
    print(f"{'-' * width}  {'-' * 8}  {'-' * 7}  {'-' * 7}  {'-' * 10}")
    for rel, verdict, facing, up, transform_state in rows:
        print(f"{rel.ljust(width)}  {verdict:8}  {facing:7}  {up:7}  {transform_state}")

    if details:
        print("\nLeftover node transforms")
        print("------------------------")
        for rel, report in details:
            print(f"{rel}:")
            print(report)
            print()

    print(
        f"{counts['pass']} pass, {counts['fail']} fail, "
        f"{counts['unknown']} undeterminable, {counts['error']} unreadable."
    )
    if counts["unapplied"]:
        print(
            f"\n{counts['unapplied']} model(s) carry a rotation or scale on the node chain. "
            "Fix those first: the facing and up columns above are reading that transform, "
            "so until it is gone they describe the node rather than the geometry."
        )
    if counts["fail"] or counts["unknown"]:
        print(
            "\nThis is a dry run and always exits 0. Nothing is blocked. Decide what "
            "to do about the non-passing models before making the check blocking."
        )
    return 0


if __name__ == "__main__":
    sys.exit(main())
