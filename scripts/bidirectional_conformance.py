#!/usr/bin/env python3
"""Deterministic cross-translator support intersection and round-trip referee.

Uses agda2lean's existing conformance TSV and (optionally) lean2agda's
corpus manifest. A feature/name match is a *candidate*, never proof.
A round-trip is accepted only with independent checker and correspondence
receipts for both directions. No LLM, network, orchestration, external writes.
"""
from __future__ import annotations

import argparse
import csv
import hashlib
import json
from pathlib import Path

A2L_STATES = {"supported-correspondence", "reconstruction-boundary",
              "deliberately-unsupported", "unclassified"}
REQUIRED = ("source_agda_checked", "lean_checked", "lean_back_checked",
            "agda_back_checked", "forward_correspondence_checked",
            "backward_correspondence_checked", "assumptions_preserved",
            "dependencies_preserved", "computation_preserved",
            "source_identity_preserved", "no_new_axioms",
            "no_sorry", "no_unresolved_obligations")
PROFILES = {"K", "CC", "CU"}
TIERS = {"T0", "T1", "T2", "T3"}

def canonical(value):
    return json.dumps(value, sort_keys=True, ensure_ascii=False,
                      separators=(",", ":"))

def fingerprint(value):
    return hashlib.sha256(canonical(value).encode("utf-8")).hexdigest()

def read_tsv(path, expected):
    with Path(path).open(newline="", encoding="utf-8") as handle:
        reader = csv.DictReader(handle, delimiter="\t")
        if not reader.fieldnames or not set(expected) <= set(reader.fieldnames):
            raise ValueError(f"Wrong TSV schema: {path}")
        rows = list(reader)
    return rows

def read_agda_manifest(path):
    rows=read_tsv(path, {"id","source","expected","phase","features","oracle"})
    seen=set()
    for row in rows:
        ident=row["id"]
        if not ident or ident in seen or row["expected"] not in A2L_STATES:
            raise ValueError(f"Duplicate/bad agda2lean entry: {ident}")
        seen.add(ident)
        row["feature_set"]=frozenset(
            x.strip() for x in row["features"].split(",") if x.strip())
        if not row["feature_set"]:
            raise ValueError(f"No Agda feature tags: {ident}")
        if row["expected"]=="supported-correspondence" and row["oracle"]=="-":
            raise ValueError("Positive support without Lean oracle")
    return rows

def read_lean_corpus(path):
    raw=json.loads(Path(path).read_text(encoding="utf-8"))
    if not isinstance(raw,list):
        raise ValueError("lean2agda manifest must be an array")
    result=[]
    seen=set()
    for row in raw:
        if not isinstance(row,dict):
            raise ValueError("Malformed lean2agda corpus row")
        key=row.get("id")
        features=row.get("features")
        if not isinstance(key,str) or not key or key in seen:
            raise ValueError("Duplicate/invalid lean2agda entry")
        seen.add(key)
        if not isinstance(features,list) or not features or not all(isinstance(x,str) and x for x in features):
            raise ValueError("Missing lean2agda feature list")
        if row.get("tier") not in TIERS:
            raise ValueError("Unknown Lean axiom tier")
        if row.get("status") not in {"planned","translated"}:
            raise ValueError("Unknown lean2agda status")
        agda_files=row.get("agda_files",[])
        if not isinstance(agda_files,list):
            raise ValueError("Invalid target profile records")
        profiles=[]
        for f in agda_files:
            if not isinstance(f,dict) or f.get("profile") not in PROFILES:
                raise ValueError("Invalid Agda target profile")
            profiles.append(f["profile"])
        result.append({"id":key,"lean_name":row.get("lean_name"),
          "status":row["status"],"tier":row["tier"],
          "features":sorted(set(features)),"profiles":sorted(set(profiles)),
          "candidate_only":True})
    return result

def read_feature_crosswalk(path):
    if path is None:
        return {}
    rows=read_tsv(path, {"agda2lean_feature","lean2agda_feature","relation","status"})
    relations={}
    for row in rows:
        a,b=row["agda2lean_feature"],row["lean2agda_feature"]
        if not a or not b or row["status"]!="candidate-only":
            raise ValueError("Crosswalk can only contain attributed candidate coordinates")
        if (a,b) in relations:
            raise ValueError("Duplicate taxonomy edge")
        relations[(a,b)]=row["relation"]
    return relations


def crosswalk(a2l_rows, l2a_rows, relation_map=None):
    """Return capabilities and source-aware candidates, never semantic equivalence."""
    candidates=[]
    relation_map=relation_map or {}
    for a in a2l_rows:
        a_tokens=set(a["feature_set"])
        for l in l2a_rows:
            # Lexical tag overlap is intentionally weak: do not invent a
            # vocabulary mapping between two different feature taxonomies.
            overlap=sorted(a_tokens & set(l["features"]))
            mediated=sorted((a_feat,l_feat,why) for (a_feat,l_feat),why in relation_map.items()
                            if a_feat in a_tokens and l_feat in l["features"])
            if overlap or mediated:
                candidates.append({
                    "a2l_case":a["id"],"l2a_case":l["id"],
                    "shared_literal_feature_tags":overlap,
                    "reviewed_taxonomy_candidates":[{"agda_feature":f,"lean_feature":g,
                        "relation":kind} for f,g,kind in mediated],
                    "a2l_status":a["expected"],"l2a_status":l["status"],
                    "l2a_tier":l["tier"],
                    "requires_foundational_review":any(
                        kind=="foundational-conflict" for _,_,kind in mediated),
                    "candidate_only":True,"establishes_correspondence":False,
                })
    return sorted(candidates,key=lambda x:(x["a2l_case"],x["l2a_case"]))

def validate_roundtrip(row):
    """Receipt validation without trusting assertion flags alone.

    Each proof check must be grounded in a nonempty source-bound checker
    artifact hash and exact prover name. The independent checker remains
    the authority: caller-supplied JSON cannot itself authenticate success.
    """
    if not isinstance(row,dict) or not row.get("case_id"):
        raise ValueError("Missing case identity")
    checks=row.get("checks")
    if not isinstance(checks,dict):
        raise ValueError("Missing checks")
    statuses={name:checks.get(name) is True for name in REQUIRED}
    ledger=row.get("checker_receipts")
    if not isinstance(ledger,list):
        ledger=[]
    witnessed=set()
    for receipt in ledger:
        if not isinstance(receipt,dict):
            continue
        gate=receipt.get("gate")
        if gate not in REQUIRED or receipt.get("status")!="accepted":
            continue
        if receipt.get("checker") not in {"agda","lean","correspondence"}:
            continue
        if not isinstance(receipt.get("source_digest"),str) or len(receipt["source_digest"])!=64:
            continue
        if not isinstance(receipt.get("artifact_digest"),str) or len(receipt["artifact_digest"])!=64:
            continue
        if not isinstance(receipt.get("checker_revision"),str) or not receipt["checker_revision"]:
            continue
        witnessed.add(gate)
    # A manifest is *untrusted*. Proof flags are not enough. Only externally
    # authenticated checker receipts may turn these into verified claims.
    authenticated=row.get("authenticated_referee") is True
    missing=[name for name in REQUIRED if not statuses[name] or name not in witnessed]
    stable = not missing and authenticated
    return {"case_id":row["case_id"],"receipt_complete":not missing,
      "externally_authenticated":authenticated,
      "eligible_for_independent_referee":not missing,
      "stable_verified":False, # JSON must not mint kernel authority
      "reported_all_gates":stable,
      "missing_or_unwitnessed":missing,
      "authority":"untrusted-observation-only",
      "roundtrip_semantic_hash":fingerprint({
          "case_id":row["case_id"],"checks":statuses,
          "receipts":sorted(witnessed)})}

def audit(a2l, l2a, observations, feature_crosswalk=None):
    entries=read_agda_manifest(a2l)
    counterpart=read_lean_corpus(l2a) if l2a else []
    matches=crosswalk(entries,counterpart,read_feature_crosswalk(feature_crosswalk))
    receipts=[validate_roundtrip(r) for r in observations]
    return {
      "schema":"jmd-bidirectional-conformance-v1",
      "agda2lean_cases":len(entries),
      "agda2lean_positive_declared":sum(r["expected"]=="supported-correspondence" for r in entries),
      "lean2agda_corpus_entries":len(counterpart),
      "lean2agda_reported_translated":sum(r["status"]=="translated" for r in counterpart),
      "crosswalk_literal_candidates":len(matches),
      "direct_literal_feature_pairs":sum(bool(m["shared_literal_feature_tags"])
                                          for m in matches),
      "foundational_conflict_candidates":sum(
          m["requires_foundational_review"] for m in matches),
      "candidate_priority":sorted(matches,key=lambda m:(
          m["requires_foundational_review"],
          {"T0":0,"T1":1,"T2":2,"T3":3}[m["l2a_tier"]],
          m["a2l_status"]!="supported-correspondence",
          m["a2l_case"],m["l2a_case"])),
      "verified_roundtrips":0,
      "candidate_crosswalk":matches,
      "roundtrip_observations":receipts,
      "boundary":"No source-name/feature/JSON receipt promotes a cross-prover theorem",
    }

def main():
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument("--agda2lean-manifest",required=True,type=Path)
    p.add_argument("--lean2agda-manifest",type=Path)
    p.add_argument("--observations",type=Path)
    p.add_argument("--feature-crosswalk",type=Path)
    p.add_argument("--out",type=Path,required=True)
    args=p.parse_args()
    observations=[]
    if args.observations:
        for line in args.observations.read_text(encoding="utf-8").splitlines():
            if line.strip():
                observations.append(json.loads(line))
    result=audit(args.agda2lean_manifest,args.lean2agda_manifest,observations,
                 args.feature_crosswalk)
    args.out.parent.mkdir(parents=True,exist_ok=True)
    args.out.write_text(json.dumps(result,sort_keys=True,indent=2)+"\n",encoding="utf-8")
    print(json.dumps({k:v for k,v in result.items() if k not in {"candidate_crosswalk","roundtrip_observations"}},
                     sort_keys=True,indent=2))

if __name__=="__main__":
    main()
