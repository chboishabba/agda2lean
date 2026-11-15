#!/usr/bin/env python3
"""Fail-closed registry audit; a classification manifest is never a proof."""
from __future__ import annotations

import argparse
import csv
import json
import pathlib
import re

SCHEMA = (
    "id", "domain", "agda_construct", "lean_construct", "correspondence",
    "target_profiles", "semantic_caveat", "proof_obligations",
    "certification", "upstream_gap",
)
GAPS = frozenset({
    "impredicative-prop", "proof-irrelevance", "k-and-uip",
    "large-elimination", "quotients", "axioms", "universe-levels",
    "structure-eta", "literals", "trust-escape-hatches",
    "decidable-and-noncomputable", "nested-and-mutual-inductives",
    "projections-and-let",
})
KINDS = frozenset({"fragment", "bridge", "conflict", "no-direct"})
PROFILES = frozenset({"K,CC,CU", "CC,CU", "CU", "U-only"})
REQUIRED_ANCHORS = {
    "sort.set": ("fragment", "Type"),
    "sort.proof": ("conflict", "Prop"),
    "subtype.proof": ("conflict", "Subtype"),
    "irrelevance": ("conflict", "irrelevance"),
    "eq.uip": ("conflict", "UIP"),
    "quotient": ("conflict", "Quot"),
    "cubical.path": ("no-direct", "Eq"),
    "data.list": ("fragment", "List"),
    "data.maybe": ("fragment", "Option"),
}

def audit(path: pathlib.Path) -> dict:
    with path.open(encoding="utf-8", newline="") as handle:
        reader = csv.DictReader(handle, delimiter="\t", strict=True)
        if tuple(reader.fieldnames or ()) != SCHEMA:
            raise ValueError("Foundational mapping schema differs from pinned contract")
        rows = list(reader)
    if len(rows) < 40:
        raise ValueError("Foundational mapping lacks full core coverage")
    by_id = {}
    gap_ids = {gap: [] for gap in GAPS}
    counts = {kind: 0 for kind in KINDS}
    for n, row in enumerate(rows, start=2):
        if None in row or any(value is None for value in row.values()):
            raise ValueError(f"Malformed tabular row {n}")
        key = row["id"]
        if not re.fullmatch(r"[a-z][a-z0-9.-]+", key):
            raise ValueError(f"Malformed mapping ID in row {n}")
        if key in by_id:
            raise ValueError(f"Duplicate mapping ID {key}")
        by_id[key] = row
        if any(not row[k].strip() for k in SCHEMA if k != "upstream_gap"):
            raise ValueError(f"Missing required cell in row {n}")
        if row["correspondence"] not in KINDS:
            raise ValueError(f"Unreviewed correspondence kind: {key}")
        if row["target_profiles"] not in PROFILES:
            raise ValueError(f"Unreviewed Agda profile: {key}")
        if row["certification"] != "candidate-only":
            raise ValueError(f"Mapping cannot assert proof/certification: {key}")
        if any(gate not in {"M03", "M04", "M05", "M06", "M10"}
               for gate in row["proof_obligations"].split(",")):
            raise ValueError(f"Unknown proof obligation: {key}")
        counts[row["correspondence"]] += 1
        gap_tokens = row["upstream_gap"].split(",") if row["upstream_gap"] else []
        if len(gap_tokens) != len(set(gap_tokens)):
            raise ValueError(f"Repeated upstream foundation gap for {key}")
        for gap in gap_tokens:
            if gap not in GAPS:
                raise ValueError(f"Unknown upstream foundational gap: {key}: {gap}")
            gap_ids[gap].append(key)
    missing = GAPS - {key for key, ids in gap_ids.items() if ids}
    if missing:
        raise ValueError("Uncovered upstream foundation gap(s): " +
                         ", ".join(sorted(missing)))
    for key, (kind, lean_token) in REQUIRED_ANCHORS.items():
        row = by_id.get(key)
        if not row or row["correspondence"] != kind or lean_token not in row["lean_construct"]:
            raise ValueError(f"Required foundational boundary is missing/changed: {key}")
    if by_id["sort.set"]["lean_construct"].strip() == "Prop":
        raise ValueError("Proof-relevant Agda Set must not map directly to Lean Prop")
    if counts["conflict"] < 8 or counts["no-direct"] < 2:
        raise ValueError("Negative foundational cases cannot be silently omitted")
    return {
        "authority": "taxonomy-only-not-translation-proof",
        "source": str(path),
        "total": len(rows),
        "kinds": {k: counts[k] for k in sorted(KINDS)},
        "upstream_gap_coverage": {
            gap: sorted(gap_ids[gap]) for gap in sorted(GAPS)
        },
        "certified": 0,
        "statement_correspondence_proved": False,
        "axiom_closure_proved": False,
        "dependency_closure_proved": False,
        "computation_preservation_proved": False,
    }

def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument(
        "--mapping", type=pathlib.Path,
        default=pathlib.Path(__file__).resolve().parents[1] /
                "docs/agda_lean_foundational_mapping.tsv",
    )
    args = ap.parse_args()
    print(json.dumps(audit(args.mapping), indent=2, sort_keys=True))
    return 0

if __name__ == "__main__":
    raise SystemExit(main())
