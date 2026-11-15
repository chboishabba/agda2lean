#!/usr/bin/env python3
"""Run user-selected pinned Lean/Agda translation and checker steps, without LLM.

The executable step plan is supplied by the user and normally includes:
Lean export, lean2agda translation, Agda check, agda2lean translation,
Lean check, and semantic digest extraction. It can equally begin with Agda.

Crucial: successful commands and matching artifact hashes provide observations
but NOT proof of theorem/type correspondence. Only actual independent kernel
and proof-translation receipts can pay the formal max-cut.
"""
from __future__ import annotations
import argparse
import hashlib
import json
import os
import re
import subprocess
from pathlib import Path

SHA = re.compile(r"[0-9a-f]{40}\Z")
STAGES={"lean-extract","lean2agda","agda-check","agda-extract",
        "agda2lean","lean-check","correspondence","normalize"}
MAX_STEPS=32
# A strict plan is still an *observation*, never a kernel certificate.
# Seven stages require a return object, not just two successful commands.
CYCLE_ROLES = {
    "agda-first": ("agda-check", "agda-extract", "agda2lean",
                   "lean-check", "lean2agda", "agda-check", "correspondence"),
    "lean-first": ("lean-check", "lean-extract", "lean2agda",
                   "agda-check", "agda2lean", "lean-check", "correspondence"),
}

def confined(base: Path, relative: str) -> Path:
    if not isinstance(relative, str) or not relative or os.path.isabs(relative):
        raise ValueError("Expected a nonempty relative path")
    root = base.resolve()
    target = (root / relative).resolve()
    if not target.is_relative_to(root):
        raise ValueError("Path escapes its declared checkout")
    return target

def check_source(plan: dict, base: Path) -> dict | None:
    """Bind strict cycles to the bytes of an actual tracked source file."""
    if "cycle_origin" not in plan:
        return None
    source = plan["source"]
    checkout = confined(base, source["cwd"])
    path = confined(checkout, source["path"])
    if not path.is_file() or (checkout / source["path"]).is_symlink():
        raise ValueError("Source must be a regular tracked file")
    expected = source["sha256"]
    if not isinstance(expected, str) or not re.fullmatch(r"[0-9a-f]{64}", expected):
        raise ValueError("Source requires a full SHA256")
    if sha256(path) != expected:
        raise ValueError("Source byte SHA256 mismatch")
    tracked = subprocess.run(
        ["git", "ls-files", "--error-unmatch", "--", source["path"]],
        cwd=checkout, capture_output=True, text=True, check=False)
    if tracked.returncode:
        raise ValueError("Source file is not tracked at the checked-out pin")
    return {"cwd": source["cwd"], "path": source["path"], "sha256": expected}

def check_artifact_chain(receipts: list[dict], base: Path) -> None:
    """Reject post-hoc artifact mutation before any next stage can consume it."""
    for prior in receipts:
        checkout = confined(base, prior["cwd"])
        for artifact in prior["artifacts"]:
            path = confined(checkout, artifact["path"])
            if not path.is_file() or sha256(path) != artifact["sha256"]:
                raise ValueError("A prior stage artifact changed or disappeared")


def sha256(path: Path) -> str:
    h=hashlib.sha256()
    with path.open("rb") as stream:
        while chunk:=stream.read(1<<20):
            h.update(chunk)
    return h.hexdigest()

def validate_plan(obj: dict) -> dict:
    if not isinstance(obj,dict) or obj.get("schema")!="jmd-roundtrip-exec-v1":
        raise ValueError("Wrong plan schema")
    steps=obj.get("steps")
    if not isinstance(steps,list) or not 2<=len(steps)<=MAX_STEPS:
        raise ValueError("Must provide a bounded 2..32-step cycle")
    for step in steps:
        if not isinstance(step,dict) or step.get("role") not in STAGES:
            raise ValueError("Unknown step role")
        cmd=step.get("argv")
        if not isinstance(cmd,list) or not cmd or not all(isinstance(x,str) and x for x in cmd):
            raise ValueError("Command must be an explicit argv list; no shell")
        if any("\x00" in x for x in cmd):
            raise ValueError("NUL argument forbidden")
        if not isinstance(step.get("cwd"),str) or not step["cwd"]:
            raise ValueError("Step needs pinned local checkout cwd")
        if not isinstance(step.get("expected_artifacts",[]),list):
            raise ValueError("Artifact list must be explicit")
        if int(step.get("timeout_seconds",120)) not in range(1,901):
            raise ValueError("Each command must be bounded to <=900 seconds")
    if "cycle_origin" in obj:
        origin = obj["cycle_origin"]
        if origin not in CYCLE_ROLES:
            raise ValueError("Unknown strict cycle origin")
        if tuple(step["role"] for step in steps) != CYCLE_ROLES[origin]:
            raise ValueError("Strict cycle must include the complete ordered return path")
        if not isinstance(obj.get("case_id"), str) or not obj["case_id"]:
            raise ValueError("Strict cycle requires a case identity")
        source = obj.get("source")
        if not isinstance(source, dict) or not all(
            isinstance(source.get(k), str) and source[k]
            for k in ("cwd", "path", "sha256")
        ):
            raise ValueError("Strict cycle requires exact source path and digest")
        if source["cwd"] != steps[0]["cwd"]:
            raise ValueError("Source checkout must match the first checker")
        for i, step in enumerate(steps):
            artifacts = step.get("expected_artifacts", [])
            if not artifacts or not all(isinstance(p, str) and p for p in artifacts):
                raise ValueError("Every strict stage needs an expected artifact")
            if len(artifacts) != len(set(artifacts)):
                raise ValueError("Duplicate strict stage artifacts")
            if i:
                links = step.get("consumes")
                if not isinstance(links, list) or not links:
                    raise ValueError("Strict stages must declare input artifact lineage")
                for link in links:
                    if (not isinstance(link, dict)
                        or type(link.get("from_step")) is not int
                        or link["from_step"] < 0 or link["from_step"] >= i
                        or link.get("artifact") not in steps[link["from_step"]]["expected_artifacts"]):
                        raise ValueError("Invalid strict input artifact lineage")
    return obj

def read_plan(path: Path) -> dict:
    return validate_plan(json.loads(path.read_text(encoding="utf-8")))

def check_pin(cwd: Path, expected: str) -> dict:
    if not SHA.fullmatch(expected):
        raise ValueError("Every step requires full pinned Git SHA")
    if not (cwd/".git").exists():
        raise ValueError("Checkout lacks .git")
    run=subprocess.run(["git","rev-parse","HEAD"],cwd=cwd,capture_output=True,text=True,check=True)
    sha=run.stdout.strip()
    if sha!=expected:
        raise ValueError("Checkout SHA mismatch")
    dirty=subprocess.run(["git","status","--porcelain","--untracked-files=no"],
                         cwd=cwd,capture_output=True,text=True,check=True).stdout.strip()
    if dirty:
        raise ValueError("Tracked source files modified; refuse proof-source pin")
    return {"revision":sha, "clean_tracked_checkout":True}

def execute(plan: dict, *, base: Path) -> dict:
    """Read-only runner wrt third-party sources: any generated artifact is explicit.

    Translators may write into their own declared build trees. This runner does
    not fetch, clone, commit, push, or silently invoke an agent.
    """
    plan = validate_plan(plan)
    base = base.resolve()
    source_identity = check_source(plan, base)
    receipts=[]
    for number,step in enumerate(plan["steps"]):
        cwd=confined(base, step["cwd"])
        if "cycle_origin" in plan:
            check_artifact_chain(receipts, base)
            for link in step.get("consumes", []):
                previous = receipts[link["from_step"]]
                if not any(a["path"] == link["artifact"] for a in previous["artifacts"]):
                    raise ValueError("Strict input lacks a produced artifact")
        if not cwd.is_dir():
            raise ValueError(f"Missing step checkout {cwd}")
        pin=check_pin(cwd,step.get("git_sha",""))
        # This tool deliberately does not use shell=True or command templates.
        # The caller must audit executables before running arbitrary code.
        try:
            completed=subprocess.run(step["argv"],cwd=cwd,capture_output=True,
                         text=True,timeout=int(step.get("timeout_seconds",120)),
                         stdin=subprocess.DEVNULL,check=False)
            code=completed.returncode
            reason="accepted" if code==0 else "command-failed"
        except subprocess.TimeoutExpired:
            code=-1
            reason="timeout"
        # Source mutation during execution invalidates the checked-out pin.
        check_pin(cwd, step.get("git_sha", ""))
        artifacts=[]
        for rel in step.get("expected_artifacts",[]):
            artifact=confined(cwd, rel)
            if artifact.is_file():
                artifacts.append({"path":rel,"sha256":sha256(artifact),"bytes":artifact.stat().st_size})
        if code==0 and len(artifacts)!=len(step.get("expected_artifacts",[])):
            reason="missing-artifact"
        receipts.append({"ordinal":number,"role":step["role"],
            "cwd":step["cwd"],
            "consumes":step.get("consumes", []),
            "command_sha256":hashlib.sha256(json.dumps(step["argv"],separators=(",",":")).encode()).hexdigest(),
            "source_pin":pin["revision"],"artifacts":artifacts,
            "exit_code":code,"status":reason,"kernel_certified":False})
        if reason!="accepted":
            break
    success=len(receipts)==len(plan["steps"]) and all(
        r["status"]=="accepted" for r in receipts)
    return {"schema":"jmd-roundtrip-execution-receipt-v1",
       "plan_digest":hashlib.sha256(json.dumps(plan,sort_keys=True).encode()).hexdigest(),
       "cycle_origin":plan.get("cycle_origin"),
       "case_id":plan.get("case_id"),
       "source_identity":source_identity,
       "ordered_cycle_complete":bool(plan.get("cycle_origin")) and success,
       "steps_requested":len(plan["steps"]),"steps_executed":len(receipts),
       "commands_succeeded":success,"receipts":receipts,
       "semantic_fixed_point_proved":False,
       "independent_correspondence_verified":False,
       "authority":"reproducible-local-execution-observation",
       "warning":"A successful command or hash match is not a kernel theorem correspondence"}

def main(argv=None):
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument("--plan",type=Path,required=True)
    p.add_argument("--base",type=Path,required=True)
    p.add_argument("--out",type=Path,required=True)
    args=p.parse_args(argv)
    plan=read_plan(args.plan)
    result=execute(plan,base=args.base.resolve())
    args.out.parent.mkdir(parents=True,exist_ok=True)
    args.out.write_text(json.dumps(result,indent=2,sort_keys=True)+"\n",encoding="utf-8")
    print(json.dumps({k:v for k,v in result.items() if k!="receipts"},indent=2,sort_keys=True))
    return 0 if result["commands_succeeded"] else 1

if __name__=="__main__":
    raise SystemExit(main())
