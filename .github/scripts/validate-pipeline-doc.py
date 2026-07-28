#!/usr/bin/env python3
"""Validate documentation/pipeline/pipeline.yaml.

JSON Schema catches shape errors.  Everything interesting is a cross-reference
the schema cannot express, so most of this file is semantic checks:

  * every edge endpoint resolves to a real step
  * every step is reachable from the pipeline's entry step
  * at least one phase per pipeline declares itself iterative -- the guard
    against this document quietly collapsing back into the flat sequence the
    original diagram showed
  * every screenshot resolves to an image, the file exists, and its sha256 matches
  * every enforced_by / validated_by path exists on disk
  * every naming regex compiles, and its own valid/invalid examples agree with it
  * every declared code mirror still matches the constant it mirrors, so a
    convention cannot be changed in the script without changing the document

Exit code 0 if the document is sound, 1 otherwise.  Writes a markdown summary to
GITHUB_OUTPUT under `metadata` when running in Actions, matching the sibling
validators.

Usage:
    python .github/scripts/validate-pipeline-doc.py
    python .github/scripts/validate-pipeline-doc.py --doc path/to/pipeline.yaml
"""

from __future__ import annotations

import argparse
import hashlib
import importlib.util
import json
import os
import re
import sys
from pathlib import Path
from typing import Any

try:
    import yaml
except ImportError:  # pragma: no cover - exercised only on a bare interpreter
    print("ERROR: PyYAML is required. pip install pyyaml", file=sys.stderr)
    raise SystemExit(1)

REPO_ROOT = Path(__file__).resolve().parents[2]
DEFAULT_DOC = REPO_ROOT / "documentation" / "pipeline" / "pipeline.yaml"
SCHEMA_PATH = REPO_ROOT / "schemas" / "asset-pipeline.schema.json"


class Problem:
    """One thing wrong with the document."""

    def __init__(self, where: str, message: str):
        self.where = where
        self.message = message

    def __str__(self) -> str:
        return f"{self.where}: {self.message}"


class Validator:
    def __init__(self, doc: dict[str, Any], doc_path: Path, repo_root: Path = REPO_ROOT):
        self.doc = doc
        self.doc_path = doc_path
        self.doc_dir = doc_path.parent
        self.repo_root = repo_root
        self.problems: list[Problem] = []

    def fail(self, where: str, message: str) -> None:
        self.problems.append(Problem(where, message))

    # -- schema ------------------------------------------------------------

    def check_schema(self) -> None:
        try:
            import jsonschema
        except ImportError:
            self.fail(
                "schema",
                "jsonschema is not installed, so structural validation was SKIPPED. "
                "pip install jsonschema",
            )
            return

        schema = json.loads(SCHEMA_PATH.read_text(encoding="utf-8"))
        validator_cls = jsonschema.validators.validator_for(schema)
        validator_cls.check_schema(schema)
        for error in sorted(validator_cls(schema).iter_errors(self.doc), key=str):
            location = "/".join(str(part) for part in error.absolute_path) or "<root>"
            self.fail(location, error.message)

    # -- helpers -----------------------------------------------------------

    def repo_file(self, rel: str) -> Path:
        return self.repo_root / rel

    def iter_pipelines(self):
        for pipeline in self.doc.get("pipelines", []):
            yield pipeline

    def steps_of(self, pipeline: dict) -> dict[str, dict]:
        found: dict[str, dict] = {}
        for phase in pipeline.get("phases", []):
            for step in phase.get("steps", []):
                found[step["id"]] = step
        return found

    def iter_enforcements(self, pipeline: dict):
        """Yield (where, enforcement) for every enforcement block in a pipeline."""
        conventions = pipeline.get("conventions") or {}
        for rule in conventions.get("rules", []):
            for enforcement in rule.get("enforced_by", []):
                yield f"{pipeline['id']}.conventions.rules.{rule['id']}", enforcement
        for pattern in conventions.get("naming_patterns", []):
            for enforcement in pattern.get("enforced_by", []):
                yield f"{pipeline['id']}.naming.{pattern['id']}", enforcement
        for kind in pipeline.get("artifact_kinds", []):
            for enforcement in kind.get("validated_by", []):
                yield f"{pipeline['id']}.artifact.{kind['id']}", enforcement
        for phase in pipeline.get("phases", []):
            for step in phase.get("steps", []):
                for rule in step.get("rules", []):
                    for enforcement in rule.get("enforced_by", []):
                        yield f"{step['id']}.rules.{rule['id']}", enforcement

    # -- checks ------------------------------------------------------------

    def check_unique_ids(self) -> None:
        for collection in ("roles", "tools", "images"):
            seen: set[str] = set()
            for entry in self.doc.get(collection, []):
                entry_id = entry.get("id")
                if entry_id in seen:
                    self.fail(collection, f"duplicate id {entry_id!r}")
                seen.add(entry_id)

        pipeline_ids: set[str] = set()
        for pipeline in self.iter_pipelines():
            if pipeline["id"] in pipeline_ids:
                self.fail("pipelines", f"duplicate pipeline id {pipeline['id']!r}")
            pipeline_ids.add(pipeline["id"])

            step_ids: set[str] = set()
            for phase in pipeline.get("phases", []):
                for step in phase.get("steps", []):
                    if step["id"] in step_ids:
                        self.fail(pipeline["id"], f"duplicate step id {step['id']!r}")
                    step_ids.add(step["id"])

    def check_step_ids_match_phase(self) -> None:
        for pipeline in self.iter_pipelines():
            for phase in pipeline.get("phases", []):
                for step in phase.get("steps", []):
                    prefix = step["id"].split(".", 1)[0]
                    if prefix != phase["id"]:
                        self.fail(
                            step["id"],
                            f"step id is prefixed {prefix!r} but sits in phase "
                            f"{phase['id']!r}; the two must agree",
                        )

    def check_lanes(self) -> None:
        for pipeline in self.iter_pipelines():
            lanes = [phase["lane"] for phase in pipeline.get("phases", [])]
            if len(set(lanes)) != len(lanes):
                self.fail(pipeline["id"], f"phase lanes are not unique: {lanes}")

    def check_role_and_tool_refs(self) -> None:
        roles = {role["id"] for role in self.doc.get("roles", [])}
        tools = {tool["id"] for tool in self.doc.get("tools", [])}
        for pipeline in self.iter_pipelines():
            for phase in pipeline.get("phases", []):
                for role in phase.get("roles", []):
                    if role not in roles:
                        self.fail(phase["id"], f"unknown role {role!r}")
                for step in phase.get("steps", []):
                    if step.get("role") not in roles:
                        self.fail(step["id"], f"unknown role {step.get('role')!r}")
                    tool = step.get("tool")
                    if tool is not None and tool not in tools:
                        self.fail(step["id"], f"unknown tool {tool!r}")

    def check_artifact_refs(self) -> None:
        for pipeline in self.iter_pipelines():
            kinds = {kind["id"] for kind in pipeline.get("artifact_kinds", [])}
            patterns = {
                pattern["id"]
                for pattern in (pipeline.get("conventions") or {}).get("naming_patterns", [])
            }

            for kind in pipeline.get("artifact_kinds", []):
                naming = kind.get("naming")
                if naming is not None and naming not in patterns:
                    self.fail(
                        f"{pipeline['id']}.artifact.{kind['id']}",
                        f"naming references unknown pattern {naming!r}",
                    )
                for field in ("required_siblings", "optional_siblings"):
                    for sibling in kind.get(field, []):
                        if sibling not in kinds:
                            self.fail(
                                f"{pipeline['id']}.artifact.{kind['id']}",
                                f"{field} references unknown artifact kind {sibling!r}",
                            )
                spec = kind.get("spec_file")
                if spec and not self.repo_file(spec["schema"]).is_file():
                    self.fail(
                        f"{pipeline['id']}.artifact.{kind['id']}",
                        f"spec_file.schema does not exist: {spec['schema']}",
                    )

            for directory in (pipeline.get("conventions") or {}).get("directory_layout", []):
                for kind_id in directory.get("contains", []):
                    if kind_id not in kinds:
                        self.fail(
                            f"{pipeline['id']}.directory.{directory['path']}",
                            f"contains unknown artifact kind {kind_id!r}",
                        )

            for phase in pipeline.get("phases", []):
                for step in phase.get("steps", []):
                    for field in ("inputs", "outputs"):
                        for ref in step.get(field, []):
                            if ref["artifact_kind"] not in kinds:
                                self.fail(
                                    step["id"],
                                    f"{field} references unknown artifact kind "
                                    f"{ref['artifact_kind']!r}",
                                )

    def check_edges(self) -> None:
        for pipeline in self.iter_pipelines():
            steps = self.steps_of(pipeline)
            for index, edge in enumerate(pipeline.get("edges", [])):
                where = f"{pipeline['id']}.edges[{index}]"
                for end in ("from", "to"):
                    if edge[end] not in steps:
                        self.fail(where, f"{end} references unknown step {edge[end]!r}")
                if edge["from"] == edge["to"] and edge["kind"] != "repeat":
                    self.fail(
                        where,
                        f"a self-edge must be kind 'repeat', not {edge['kind']!r}",
                    )

            entry = pipeline.get("entry_step")
            if entry not in steps:
                self.fail(pipeline["id"], f"entry_step references unknown step {entry!r}")

    def check_reachability(self) -> None:
        for pipeline in self.iter_pipelines():
            steps = self.steps_of(pipeline)
            entry = pipeline.get("entry_step")
            if entry not in steps:
                continue  # already reported

            adjacency: dict[str, list[str]] = {step_id: [] for step_id in steps}
            for edge in pipeline.get("edges", []):
                if edge["from"] in adjacency and edge["to"] in steps:
                    adjacency[edge["from"]].append(edge["to"])

            reached = {entry}
            queue = [entry]
            while queue:
                current = queue.pop()
                for neighbour in adjacency[current]:
                    if neighbour not in reached:
                        reached.add(neighbour)
                        queue.append(neighbour)

            unreachable = sorted(set(steps) - reached)
            if unreachable:
                self.fail(
                    pipeline["id"],
                    f"step(s) unreachable from entry_step {entry!r}: {', '.join(unreachable)}. "
                    "Add an edge, or remove the step.",
                )

    def check_loops_declared(self) -> None:
        """The document exists because the pipeline is iterative. Keep it that way."""
        for pipeline in self.iter_pipelines():
            iterative = [
                phase["id"]
                for phase in pipeline.get("phases", [])
                if phase.get("loop", {}).get("is_iterative")
            ]
            if not iterative:
                self.fail(
                    pipeline["id"],
                    "no phase declares loop.is_iterative. This document exists "
                    "because the pipeline is a set of loops, not a sequence -- if "
                    "that is genuinely no longer true, say so explicitly here.",
                )

            if pipeline.get("status") != "authoritative":
                continue

            cyclic = [
                edge for edge in pipeline.get("edges", []) if edge["kind"] in ("rework", "repeat")
            ]
            if not cyclic:
                self.fail(
                    pipeline["id"],
                    "an authoritative pipeline has no rework or repeat edges, so it "
                    "renders as a straight line. Record how work actually flows "
                    "backwards.",
                )

    def check_images(self) -> None:
        images = {image["id"]: image for image in self.doc.get("images", [])}

        for image_id, image in images.items():
            path = self.doc_dir / image["file"]
            if not path.is_file():
                self.fail(f"images.{image_id}", f"file not found: {image['file']}")
                continue
            digest = hashlib.sha256(path.read_bytes()).hexdigest()
            if digest != image["sha256"]:
                self.fail(
                    f"images.{image_id}",
                    f"sha256 mismatch for {image['file']}: document says "
                    f"{image['sha256'][:12]}..., file is {digest[:12]}...",
                )

        used: set[str] = set()
        for pipeline in self.iter_pipelines():
            for phase in pipeline.get("phases", []):
                for step in phase.get("steps", []):
                    for shot in step.get("screenshots", []):
                        if shot["image_id"] not in images:
                            self.fail(
                                step["id"],
                                f"screenshot references unknown image {shot['image_id']!r}",
                            )
                        used.add(shot["image_id"])

        for orphan in sorted(set(images) - used):
            self.fail(
                f"images.{orphan}",
                "image is declared but no step references it. Attach it to a step "
                "or delete it -- an unreferenced screenshot never gets rendered.",
            )

    def check_enforcement_paths(self) -> None:
        for pipeline in self.iter_pipelines():
            for where, enforcement in self.iter_enforcements(pipeline):
                path = enforcement.get("path")
                if path is None:
                    continue
                if not self.repo_file(path).exists():
                    self.fail(where, f"enforced_by path does not exist: {path}")

        for pipeline in self.iter_pipelines():
            for phase in pipeline.get("phases", []):
                for step in phase.get("steps", []):
                    template = step.get("opened_by_issue_template")
                    if template and not self.repo_file(template).is_file():
                        self.fail(
                            step["id"],
                            f"opened_by_issue_template does not exist: {template}",
                        )

    def check_naming_patterns(self) -> None:
        for pipeline in self.iter_pipelines():
            for pattern in (pipeline.get("conventions") or {}).get("naming_patterns", []):
                where = f"{pipeline['id']}.naming.{pattern['id']}"
                try:
                    compiled = re.compile(pattern["regex"])
                except re.error as exc:
                    self.fail(where, f"regex does not compile: {exc}")
                    continue

                for example in pattern["examples"]["valid"]:
                    if not compiled.match(example):
                        self.fail(
                            where,
                            f"example {example!r} is listed as valid but does not "
                            f"match {pattern['regex']}",
                        )
                for example in pattern["examples"]["invalid"]:
                    if compiled.match(example):
                        self.fail(
                            where,
                            f"example {example!r} is listed as invalid but matches "
                            f"{pattern['regex']}",
                        )

    def check_code_mirrors(self) -> None:
        """Fail when a constant this document quotes has changed in its script."""
        for mirror in self.doc.get("code_mirrors", []):
            where = f"code_mirrors.{mirror['id']}"
            path = self.repo_file(mirror["path"])
            if not path.is_file():
                self.fail(where, f"path does not exist: {mirror['path']}")
                continue

            try:
                module = load_module(path)
            except Exception as exc:  # noqa: BLE001 - any import failure is a finding
                self.fail(where, f"could not import {mirror['path']}: {exc}")
                continue

            if not hasattr(module, mirror["symbol"]):
                self.fail(
                    where,
                    f"{mirror['path']} has no symbol {mirror['symbol']!r}. It was "
                    "probably renamed; update this document to match.",
                )
                continue

            actual = getattr(module, mirror["symbol"])
            if isinstance(actual, re.Pattern):
                actual = actual.pattern

            if actual != mirror["value"]:
                self.fail(
                    where,
                    f"{mirror['path']}::{mirror['symbol']} is {actual!r} but this "
                    f"document says {mirror['value']!r}. One of the two is stale -- "
                    "decide which, and change both.",
                )

    def run(self) -> list[Problem]:
        self.check_schema()
        self.check_unique_ids()
        self.check_step_ids_match_phase()
        self.check_lanes()
        self.check_role_and_tool_refs()
        self.check_artifact_refs()
        self.check_edges()
        self.check_reachability()
        self.check_loops_declared()
        self.check_images()
        self.check_enforcement_paths()
        self.check_naming_patterns()
        self.check_code_mirrors()
        return self.problems


def load_module(path: Path):
    """Import a module from a path, including hyphenated filenames."""
    module_name = "pipeline_mirror_" + re.sub(r"\W", "_", path.stem)
    spec = importlib.util.spec_from_file_location(module_name, path)
    if spec is None or spec.loader is None:
        raise ImportError(f"cannot build a module spec for {path}")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def summarise(doc: dict) -> str:
    """A short markdown summary of what the document currently describes."""
    lines = ["### Asset pipeline document", ""]
    for pipeline in doc.get("pipelines", []):
        steps = sum(len(phase.get("steps", [])) for phase in pipeline.get("phases", []))
        edges = pipeline.get("edges", [])
        loops = [edge for edge in edges if edge["kind"] in ("rework", "repeat")]
        questions = pipeline.get("open_questions", [])
        lines.append(
            f"- **{pipeline['title']}** (`{pipeline['status']}`): "
            f"{len(pipeline.get('phases', []))} phases, {steps} steps, "
            f"{len(edges)} edges ({len(loops)} of them loops)"
            + (f", {len(questions)} open question(s)" if questions else "")
        )
    return "\n".join(lines)


def write_github_output(name: str, value: str) -> None:
    output = os.environ.get("GITHUB_OUTPUT")
    if not output:
        return
    delimiter = "EOF_" + hashlib.sha256(value.encode()).hexdigest()[:16]
    with open(output, "a", encoding="utf-8") as handle:
        handle.write(f"{name}<<{delimiter}\n{value}\n{delimiter}\n")


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--doc", type=Path, default=DEFAULT_DOC)
    args = parser.parse_args(argv)

    if not args.doc.is_file():
        print(f"ERROR: pipeline document not found: {args.doc}", file=sys.stderr)
        return 1

    try:
        doc = yaml.safe_load(args.doc.read_text(encoding="utf-8"))
    except yaml.YAMLError as exc:
        print(f"ERROR: {args.doc} is not valid YAML:\n{exc}", file=sys.stderr)
        return 1

    if not isinstance(doc, dict):
        print(f"ERROR: {args.doc} must contain a mapping at the top level", file=sys.stderr)
        return 1

    problems = Validator(doc, args.doc).run()

    if problems:
        print(f"{len(problems)} problem(s) in {args.doc.name}:\n", file=sys.stderr)
        for problem in problems:
            print(f"  - {problem}", file=sys.stderr)
        write_github_output(
            "metadata",
            f"### Asset pipeline document\n\n"
            f"{len(problems)} problem(s) found:\n\n"
            + "\n".join(f"- `{p.where}` {p.message}" for p in problems),
        )
        return 1

    summary = summarise(doc)
    print(summary.replace("**", "").replace("`", ""))
    print("\nOK")
    write_github_output("metadata", summary + "\n\nNo problems found.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
