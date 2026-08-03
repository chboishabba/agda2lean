#!/usr/bin/env python3
"""Build and verify the strict JFixedPoint dependency correspondence receipt."""

from __future__ import annotations

import argparse
import pathlib
import re
import sys


class ReceiptError(RuntimeError):
    pass


def normalize(name: str) -> str:
    return name.replace("«", "").replace("»", "")


def source_dependencies(path: pathlib.Path) -> tuple[dict[str, set[str]], set[str]]:
    declarations: dict[str, set[str]] = {}
    public: set[str] = set()
    current: str | None = None
    for line in path.read_text(encoding="utf-8").splitlines():
        match = re.fullmatch(r"-- Agda:\s+(.+)", line)
        if match:
            current = normalize(match.group(1).strip())
            public.add(current)
            continue
        match = re.fullmatch(r"-- Direct dependencies:\s+(.+)", line)
        if match and current is not None:
            rendered = match.group(1).strip()
            declarations[current] = (
                set()
                if rendered == "(none)"
                else {normalize(item.strip()) for item in rendered.split(",")}
            )
            current = None
    return declarations, public


def manifest_relations(path: pathlib.Path) -> dict[tuple[str, str], set[str]]:
    relations: dict[tuple[str, str], set[str]] = {}
    for line_number, line in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
        fields = line.split("\t")
        if len(fields) != 3:
            raise ReceiptError(f"{path}:{line_number}: expected three TSV fields")
        declaration, relation, reference = map(normalize, fields)
        relations.setdefault((declaration, relation), set())
        if reference:
            relations[(declaration, relation)].add(reference)
    return relations


def expected_dependencies(path: pathlib.Path) -> dict[str, set[str]]:
    expected: dict[str, set[str]] = {}
    for line_number, line in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
        if not line or line.startswith("#") or line.startswith("declaration\t"):
            continue
        fields = line.split("\t")
        if len(fields) != 2:
            raise ReceiptError(f"{path}:{line_number}: expected declaration and dependency")
        expected.setdefault(normalize(fields[0]), set()).add(normalize(fields[1]))
    if not expected:
        raise ReceiptError(f"{path}: dependency policy is empty")
    return expected


def project_boundary(dependencies: set[str], public: set[str], declaration: str) -> set[str]:
    return {
        dependency
        for dependency in dependencies
        if dependency in public and dependency != declaration
    }


def render_set(values: set[str]) -> str:
    return ",".join(sorted(values)) if values else "-"


def build_receipt(
    lean_source: pathlib.Path,
    manifest: pathlib.Path,
    expected_path: pathlib.Path,
) -> str:
    agda_dependencies, public = source_dependencies(lean_source)
    lean_relations = manifest_relations(manifest)
    expected = expected_dependencies(expected_path)
    rows = ["declaration\tfacet\tvalue"]
    failures: list[str] = []
    for declaration in sorted(expected):
        wanted = expected[declaration]
        if declaration not in agda_dependencies:
            failures.append(f"missing Agda dependency metadata for {declaration}")
            actual_agda: set[str] = set()
        else:
            actual_agda = project_boundary(
                agda_dependencies[declaration], public, declaration
            )
        actual_lean = project_boundary(
            lean_relations.get((declaration, "type-direct"), set())
            | lean_relations.get((declaration, "value-direct"), set()),
            public,
            declaration,
        )
        axioms = lean_relations.get((declaration, "axiom-closure"), set())
        rows.extend(
            [
                f"{declaration}\texpected-project-direct\t{render_set(wanted)}",
                f"{declaration}\tagda-project-direct\t{render_set(actual_agda)}",
                f"{declaration}\tlean-project-direct\t{render_set(actual_lean)}",
                f"{declaration}\tlean-axiom-closure\t{render_set(axioms)}",
            ]
        )
        if actual_agda != wanted:
            failures.append(
                f"{declaration}: Agda boundary {render_set(actual_agda)} != expected {render_set(wanted)}"
            )
        if actual_lean != wanted:
            failures.append(
                f"{declaration}: Lean boundary {render_set(actual_lean)} != expected {render_set(wanted)}"
            )
        if axioms:
            failures.append(
                f"{declaration}: unexpected Lean axiom closure {render_set(axioms)}"
            )
    rows.append("gate\tstatus\tpass" if not failures else "gate\tstatus\tfail")
    if failures:
        raise ReceiptError("dependency correspondence failed:\n  " + "\n  ".join(failures))
    return "\n".join(rows) + "\n"


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--lean-source", required=True, type=pathlib.Path)
    parser.add_argument("--manifest", required=True, type=pathlib.Path)
    parser.add_argument("--expected", required=True, type=pathlib.Path)
    parser.add_argument("--output", required=True, type=pathlib.Path)
    args = parser.parse_args()
    try:
        receipt = build_receipt(args.lean_source, args.manifest, args.expected)
        args.output.parent.mkdir(parents=True, exist_ok=True)
        temporary = args.output.with_name(f".{args.output.name}.tmp")
        temporary.write_text(receipt, encoding="utf-8", newline="\n")
        temporary.replace(args.output)
        return 0
    except (OSError, ReceiptError) as error:
        print(f"jfixedpoint-receipt: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
