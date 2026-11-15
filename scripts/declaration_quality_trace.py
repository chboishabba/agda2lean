#!/usr/bin/env python3
"""Attach reviewed Agda/Lean construct IDs to emitted declaration metadata.

Every output is a source-bound *observation*, NOT a second-kernel proof.
The expected mapping is human-reviewed; emitted Agda tags are produced by the
translator; neither is an independently authenticated checker witness.
"""
from __future__ import annotations

import argparse
import csv
import hashlib
import json
import pathlib
import re
from collections import defaultdict

from check_foundational_mapping import audit as audit_registry

CASE_SCHEMA = "a2l-declaration-mapping-case-v1"
TRACE_SCHEMA = "a2l-declaration-quality-trace-v1"
HEX64 = re.compile(r"[0-9a-f]{64}\Z")
NAME = re.compile(r"[A-Za-z_][A-Za-z0-9_.\-]*\Z")
LEAN_NAME = re.compile(r"[A-Za-z_][A-Za-z0-9_]*(?:\.(?:[A-Za-z_][A-Za-z0-9_]*|«[^«»\n]+»))*\Z")
AGDA_TAG = re.compile(r"-- Agda:\s+(.+)\Z")
MAPPING_TAG = re.compile(r"-- Mapping:\s+(.+)\Z")
DEPENDENCIES_TAG = re.compile(r"-- Direct dependencies:\s+(.+)\Z")
LEAN_RELATIONS = {"type-direct", "value-direct", "axiom-closure"}

class TraceError(ValueError):
    pass

def digest(path: pathlib.Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as handle:
        for part in iter(lambda: handle.read(1024 * 1024), b""):
            h.update(part)
    return h.hexdigest()

def load_registry(path: pathlib.Path) -> dict[str, dict[str, str]]:
    audit_registry(path)  # Completeness and refusal to claim certification.
    with path.open(encoding="utf-8", newline="") as handle:
        return {row["id"]: row for row in csv.DictReader(handle, delimiter="\t")}

def parse_emission(path: pathlib.Path) -> dict[str, dict]:
    """Accept only actual emitter comments, never a source-text name guess."""
    declarations: dict[str, dict] = {}
    current: str | None = None
    for n, line in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
        agda = AGDA_TAG.fullmatch(line)
        if agda:
            current = agda.group(1).strip()
            if not current or current in declarations:
                raise TraceError(f"Duplicate/empty -- Agda: declaration at line {n}")
            declarations[current] = {"line": n, "mapping": None,
                                     "direct_dependencies": None}
            continue
        if current is None:
            continue
        mapping = MAPPING_TAG.fullmatch(line)
        if mapping:
            if declarations[current]["mapping"] is not None:
                raise TraceError(f"Duplicate -- Mapping for {current}")
            declarations[current]["mapping"] = mapping.group(1).strip()
            if not declarations[current]["mapping"]:
                raise TraceError(f"Empty -- Mapping for {current}")
        deps = DEPENDENCIES_TAG.fullmatch(line)
        if deps:
            if declarations[current]["direct_dependencies"] is not None:
                raise TraceError(f"Duplicate -- Direct dependencies for {current}")
            raw = deps.group(1).strip()
            names = [] if raw == "(none)" else [s.strip() for s in raw.split(",")]
            if not raw or any(not x for x in names) or len(names) != len(set(names)):
                raise TraceError(f"Malformed -- Direct dependencies for {current}")
            declarations[current]["direct_dependencies"] = sorted(names)
    if not declarations:
        raise TraceError("No source-declaration metadata in emitted Lean artifact")
    return declarations

def read_manifest(path: pathlib.Path) -> dict[str, dict[str, list[str]]]:
    """Parse Lean's deterministic type/value/axiom manifest (untrusted file)."""
    result = defaultdict(lambda: {kind: set() for kind in LEAN_RELATIONS})
    encountered = set()
    for n, line in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
        cells = line.split("\t")
        if len(cells) != 3:
            raise TraceError(f"Lean manifest line {n} has wrong TSV width")
        name, kind, dep = cells
        if not name or kind not in LEAN_RELATIONS or (name, kind, dep) in encountered:
            raise TraceError(f"Malformed/duplicate Lean manifest record {n}")
        encountered.add((name, kind, dep))
        if dep:
            result[name][kind].add(dep)
        else:
            _ = result[name][kind]
    return {name: {k: sorted(v) for k, v in kinds.items()}
            for name, kinds in result.items()}

def checked_case(case: dict, registry: dict) -> list[dict]:
    if not isinstance(case, dict) or case.get("schema") != CASE_SCHEMA:
        raise TraceError("Unsupported declaration case schema")
    if not isinstance(case.get("source_sha256"), str) or not HEX64.fullmatch(case["source_sha256"]):
        raise TraceError("Case requires exact lower-hex SHA256 of original Agda source")
    module = case.get("module")
    if not isinstance(module, str) or not NAME.fullmatch(module):
        raise TraceError("Missing/invalid original Agda module")
    specs = case.get("declarations")
    if not isinstance(specs, list) or not specs:
        raise TraceError("Case requires reviewed declaration expectations")
    names = set()
    for spec in specs:
        if not isinstance(spec, dict) or set(spec) != {"agda", "lean", "registry_ids"}:
            raise TraceError("Invalid declaration mapping shape")
        name, lean = spec["agda"], spec["lean"]
        if not isinstance(name, str) or not name.startswith(module + ".") or not NAME.fullmatch(name):
            raise TraceError("Declaration lies outside the selected source module")
        if not isinstance(lean, str) or not LEAN_NAME.fullmatch(lean):
            raise TraceError("Missing exact Lean constant name")
        if name in names:
            raise TraceError("Duplicate declaration expectation")
        names.add(name)
        ids = spec["registry_ids"]
        if not isinstance(ids, list) or not ids or not all(isinstance(x, str) for x in ids):
            raise TraceError(f"No feature IDs for {name}")
        if len(ids) != len(set(ids)) or any(x not in registry for x in ids):
            raise TraceError(f"Unknown or duplicate mapping ID for {name}")
    return specs

def build_trace(*, case_path: pathlib.Path, source: pathlib.Path,
                emitted: pathlib.Path, registry_path: pathlib.Path,
                manifest: pathlib.Path | None = None,
                source_ir: pathlib.Path | None = None,
                diagnostics: pathlib.Path | None = None) -> dict:
    registry = load_registry(registry_path)
    case = json.loads(case_path.read_text(encoding="utf-8"))
    expected = checked_case(case, registry)
    source_sha = digest(source)
    if source_sha != case["source_sha256"]:
        raise TraceError("Original Agda source SHA256 does not match reviewed case")
    emitted_sha = digest(emitted)
    annotations = parse_emission(emitted)
    lean_manifest = read_manifest(manifest) if manifest is not None else {}
    rows = []
    for spec in sorted(expected, key=lambda x: x["agda"]):
        origin = spec["agda"]
        if origin not in annotations:
            raise TraceError(f"Missing emitted declaration with exact source tag: {origin}")
        header = annotations[origin]
        # Metadata may be incomplete: record the absence rather than pretending
        # that an output has been independently checked by the Lean kernel.
        features = sorted(spec["registry_ids"])
        obligations = sorted(set.union(*(set(registry[f]["proof_obligations"].split(","))
                                         for f in features)))
        conflicts = [f for f in features if registry[f]["correspondence"] in
                     {"conflict", "no-direct"}]
        lean_info = lean_manifest.get(spec["lean"])
        rows.append({
            "agda_declaration": origin,
            "lean_expected_constant": spec["lean"],
            "reviewed_feature_ids": features,
            "observed_emitter_annotation": header["mapping"],
            "observed_agda_direct_dependencies": header["direct_dependencies"],
            "agda_header_line": header["line"],
            "lean_manifest_observation": lean_info,
            "foundation_conflicts": sorted(conflicts),
            "unpaid_obligations": obligations,
            "status": "quarantined-foundational-conflict" if conflicts else
                      "candidate-observation-only",
            "kernel_correspondence_certified": False,
        })
    return {
        "schema": TRACE_SCHEMA,
        "authority": "source-bound-compiler-annotation-observation-only",
        "case_sha256": digest(case_path),
        "registry_sha256": digest(registry_path),
        "source_sha256": source_sha,
        "emitted_lean_sha256": emitted_sha,
        "agda_elaborated_ir_sha256": digest(source_ir) if source_ir else None,
        "emitter_diagnostics_sha256": digest(diagnostics) if diagnostics else None,
        "lean_manifest_sha256": digest(manifest) if manifest else None,
        "module": case["module"],
        "declarations": rows,
        "declaration_count": len(rows),
        "semantic_correspondence_proved": False,
        "independent_agda_kernel_receipt_authenticated": False,
        "independent_lean_kernel_receipt_authenticated": False,
        "certified_roundtrips": 0,
    }

def main() -> int:
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--case", required=True, type=pathlib.Path)
    p.add_argument("--source", required=True, type=pathlib.Path)
    p.add_argument("--emitted", required=True, type=pathlib.Path)
    p.add_argument("--registry", type=pathlib.Path,
                   default=pathlib.Path(__file__).resolve().parents[1] /
                   "docs/agda_lean_foundational_mapping.tsv")
    p.add_argument("--manifest", type=pathlib.Path)
    p.add_argument("--source-ir", type=pathlib.Path)
    p.add_argument("--diagnostics", type=pathlib.Path)
    p.add_argument("--out", required=True, type=pathlib.Path)
    args = p.parse_args()
    report = build_trace(case_path=args.case, source=args.source,
                         emitted=args.emitted, registry_path=args.registry,
                         manifest=args.manifest, source_ir=args.source_ir,
                         diagnostics=args.diagnostics)
    args.out.parent.mkdir(parents=True, exist_ok=True)
    # Write atomically: no partial observation report on validation failure.
    tmp = args.out.with_name(f".{args.out.name}.tmp")
    tmp.write_text(json.dumps(report, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    tmp.replace(args.out)
    print(json.dumps({"authority": report["authority"],
                      "declarations": report["declaration_count"],
                      "certified_roundtrips": 0}, sort_keys=True))
    return 0

if __name__ == "__main__":
    raise SystemExit(main())
