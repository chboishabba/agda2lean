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

def sha256(path: Path) -> str:
    h=hashlib.sha256()
    with path.open("rb") as stream:
        while chunk:=stream.read(1<<20):
            h.update(chunk)
    return h.hexdigest()

def read_plan(path: Path) -> dict:
    obj=json.loads(path.read_text(encoding="utf-8"))
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
    return obj

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
    receipts=[]
    for number,step in enumerate(plan["steps"]):
        cwd=(base/step["cwd"]).resolve()
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
        artifacts=[]
        for rel in step.get("expected_artifacts",[]):
            if not isinstance(rel,str) or not rel or os.path.isabs(rel):
                raise ValueError("Expected artifacts must be relative to checkout")
            artifact=(cwd/rel).resolve()
            if not artifact.is_relative_to(cwd):
                raise ValueError("Path escape in expected artifacts")
            if artifact.is_file():
                artifacts.append({"path":rel,"sha256":sha256(artifact),"bytes":artifact.stat().st_size})
        if code==0 and len(artifacts)!=len(step.get("expected_artifacts",[])):
            reason="missing-artifact"
        receipts.append({"ordinal":number,"role":step["role"],
            "command_sha256":hashlib.sha256(json.dumps(step["argv"],separators=(",",":")).encode()).hexdigest(),
            "source_pin":pin["revision"],"artifacts":artifacts,
            "exit_code":code,"status":reason,"kernel_certified":False})
        if reason!="accepted":
            break
    success=len(receipts)==len(plan["steps"]) and all(
        r["status"]=="accepted" for r in receipts)
    return {"schema":"jmd-roundtrip-execution-receipt-v1",
       "plan_digest":hashlib.sha256(json.dumps(plan,sort_keys=True).encode()).hexdigest(),
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
