"""
validate_loops.py

Two-layer validation for gameplay-loop documents:
  1. SHAPE    — JSON Schema (types, enums, required fields, id patterns) via jsonschema.
  2. SEMANTIC — cross-reference integrity + graph/economy invariants that
                JSON Schema structurally cannot express.

Usage:
  pip install jsonschema pyyaml
  python validate_loops.py ./example-roguelite.loops.yaml

Exit code 0 = valid (warnings allowed), 1 = errors found, 2 = bad invocation.
"""

from __future__ import annotations

import json
import sys
from dataclasses import dataclass
from pathlib import Path

import yaml
from jsonschema import Draft202012Validator

SCHEMA_PATH = Path(__file__).with_name("gameplay-loops.schema.json")


@dataclass
class Issue:
    level: str  # "error" | "warning"
    where: str
    message: str


# ---------- effective edges (resolve `next` defaults) ----------
def next_of(loop: dict, index: int) -> list[str]:
    """Step ids reachable in one hop, applying the default-closure rule."""
    steps = loop["steps"]
    step = steps[index]
    nxt = step.get("next")
    if nxt:
        return nxt
    is_last = index == len(steps) - 1
    return [steps[0]["id"]] if is_last else [steps[index + 1]["id"]]


def has_cycle(loop: dict) -> bool:
    """DFS for a back-edge in the effective next-graph."""
    steps = loop["steps"]
    index_by_id = {s["id"]: i for i, s in enumerate(steps)}
    step_ids = set(index_by_id)
    state: dict[str, int] = {}  # 0=white, 1=gray, 2=black

    def dfs(node: str) -> bool:
        state[node] = 1
        for target in next_of(loop, index_by_id[node]):
            if target not in step_ids:
                continue
            st = state.get(target, 0)
            if st == 1:  # back-edge -> cycle
                return True
            if st == 0 and dfs(target):
                return True
        state[node] = 2
        return False

    return any(state.get(s["id"], 0) == 0 and dfs(s["id"]) for s in steps)


# ---------- semantic checks ----------
def check_semantics(doc: dict) -> list[Issue]:
    issues: list[Issue] = []

    def err(where: str, message: str) -> None:
        issues.append(Issue("error", where, message))

    def warn(where: str, message: str) -> None:
        issues.append(Issue("warning", where, message))

    # uniqueness: resources, loops
    resource_ids: set[str] = set()
    for r in doc["resources"]:
        if r["id"] in resource_ids:
            err(f"resource:{r['id']}", "duplicate resource id")
        resource_ids.add(r["id"])

    loop_ids: set[str] = set()
    for loop in doc["loops"]:
        if loop["id"] in loop_ids:
            err(f"loop:{loop['id']}", "duplicate loop id")
        loop_ids.add(loop["id"])

    produced: set[str] = set()
    consumed: set[str] = set()

    for loop in doc["loops"]:
        lid = loop["id"]

        # unique step ids within the loop
        step_ids: set[str] = set()
        for s in loop["steps"]:
            if s["id"] in step_ids:
                err(f"{lid}.{s['id']}", "duplicate step id within loop")
            step_ids.add(s["id"])

        # resource-ref integrity + economy tracking
        for s in loop["steps"]:
            for ref in s.get("consumes", []):
                if ref["resource"] not in resource_ids:
                    err(f"{lid}.{s['id']}.consumes", f'unknown resource "{ref["resource"]}"')
                consumed.add(ref["resource"])
            for ref in s.get("produces", []):
                if ref["resource"] not in resource_ids:
                    err(f"{lid}.{s['id']}.produces", f'unknown resource "{ref["resource"]}"')
                produced.add(ref["resource"])

        # `next` targets must be steps in this loop
        for s in loop["steps"]:
            for target in s.get("next", []):
                if target not in step_ids:
                    err(f"{lid}.{s['id']}.next", f'dangling step reference "{target}"')

        # exit + feed loop references
        for ex in loop.get("exit", []):
            to = ex.get("to")
            if to is not None and to not in loop_ids:
                err(f"{lid}.exit", f'unknown loop "{to}"')
        for f in loop.get("feeds", []):
            if f["loop"] not in loop_ids:
                err(f"{lid}.feeds", f'unknown loop "{f["loop"]}"')
            for v in f.get("via", []):
                if v not in resource_ids:
                    err(f"{lid}.feeds.via", f'unknown resource "{v}"')

        # reachability from the first step (following effective edges)
        index_by_id = {s["id"]: i for i, s in enumerate(loop["steps"])}
        seen: set[str] = set()
        stack = [loop["steps"][0]["id"]]
        while stack:
            sid = stack.pop()
            if sid in seen:
                continue
            seen.add(sid)
            for t in next_of(loop, index_by_id[sid]):
                if t in step_ids:
                    stack.append(t)
        for s in loop["steps"]:
            if s["id"] not in seen:
                warn(f"{lid}.{s['id']}", "step is unreachable from the loop entry")

        # cyclicity: a "loop" should actually cycle
        if not has_cycle(loop):
            warn(lid, "loop has no cycle in its step graph — is it really a loop?")

    # economy: dangling sources/sinks (warnings — cross-loop flows are legitimate)
    for rid in produced - consumed:
        warn(f"resource:{rid}", "produced but never consumed anywhere")
    for rid in consumed - produced:
        warn(f"resource:{rid}", "consumed but never produced anywhere")

    return issues


# ---------- entry point ----------
def validate_file(path: str) -> list[Issue]:
    doc = yaml.safe_load(Path(path).read_text(encoding="utf8"))  # also parses JSON
    schema = json.loads(SCHEMA_PATH.read_text(encoding="utf8"))
    validator = Draft202012Validator(schema)

    schema_errors = sorted(validator.iter_errors(doc), key=lambda e: list(e.absolute_path))
    if schema_errors:
        # shape is untrustworthy — report schema errors only, skip semantic pass
        return [Issue("error", f"schema:{e.json_path}", e.message) for e in schema_errors]

    return check_semantics(doc)


def main() -> None:
    if len(sys.argv) != 2:
        print("usage: python validate_loops.py <doc.yaml|doc.json>", file=sys.stderr)
        sys.exit(2)

    issues = validate_file(sys.argv[1])
    errors = [i for i in issues if i.level == "error"]
    warnings = [i for i in issues if i.level == "warning"]

    for i in issues:
        mark = "\u2717" if i.level == "error" else "!"
        print(f"{mark} [{i.where}] {i.message}")
    print(f"\n{len(errors)} error(s), {len(warnings)} warning(s).")
    sys.exit(1 if errors else 0)


if __name__ == "__main__":
    main()
