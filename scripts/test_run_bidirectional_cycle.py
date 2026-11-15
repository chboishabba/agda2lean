"""Offline functional smoke for the pinned round-trip execution harness."""
import importlib.util
import json
import hashlib
import pathlib
import shutil
import subprocess
import sys
import tempfile
import unittest

PATH=pathlib.Path(__file__).with_name("run_bidirectional_cycle.py")
SPEC=importlib.util.spec_from_file_location("run_bidirectional_cycle",PATH)
m=importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(m)

@unittest.skipUnless(shutil.which("git"),"git not installed")
class LocalCycleTests(unittest.TestCase):
    def setUp(self):
        self.tmp=tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root=pathlib.Path(self.tmp.name)
        self.repo=self.root/"source"
        self.repo.mkdir()
        self.git("init")
        self.git("config","user.email","local@test.invalid")
        self.git("config","user.name","Local Test")
        (self.repo/"README").write_text("source\n")
        self.git("add","README")
        self.git("commit","-m","fixture")
        self.head=self.git("rev-parse","HEAD")

    def git(self,*args):
        return subprocess.run(["git",*args],cwd=self.repo,check=True,
              capture_output=True,text=True).stdout.strip()

    def step(self,role="lean-check"):
        return {"role":role,"cwd":"source","git_sha":self.head,
                "argv":[sys.executable,"-c","print('fixture source check')"],
                "timeout_seconds":10,"expected_artifacts":[]}

    def test_successful_commands_never_certify_semantics(self):
        plan={"schema":"jmd-roundtrip-exec-v1",
              "steps":[self.step("agda-check"),self.step("lean-check")]}
        result=m.execute(plan,base=self.root)
        self.assertTrue(result["commands_succeeded"])
        self.assertEqual(result["steps_executed"],2)
        self.assertFalse(result["semantic_fixed_point_proved"])
        self.assertFalse(result["independent_correspondence_verified"])
        self.assertTrue(all(not row["kernel_certified"] for row in result["receipts"]))

    def test_bad_pin_fails_closed(self):
        plan={"schema":"jmd-roundtrip-exec-v1",
              "steps":[self.step(),self.step()]}
        plan["steps"][0]["git_sha"]="a"*40
        with self.assertRaisesRegex(ValueError,"SHA mismatch"):
            m.execute(plan,base=self.root)

    def test_tracked_modification_fails_closed(self):
        (self.repo/"README").write_text("changed\n")
        plan={"schema":"jmd-roundtrip-exec-v1",
              "steps":[self.step(),self.step()]}
        with self.assertRaisesRegex(ValueError,"modified"):
            m.execute(plan,base=self.root)

    def test_missing_artifact_detected(self):
        step=self.step()
        step["expected_artifacts"]=["missing.out"]
        plan={"schema":"jmd-roundtrip-exec-v1",
              "steps":[step,self.step()]}
        result=m.execute(plan,base=self.root)
        self.assertFalse(result["commands_succeeded"])
        self.assertEqual(result["steps_executed"],1)
        self.assertEqual(result["receipts"][0]["status"],"missing-artifact")

    def test_malformed_plan_rejected(self):
        p=self.root/"plan.json"
        p.write_text(json.dumps({"schema":"jmd-roundtrip-exec-v1",
                                 "steps":[self.step("untrusted"),self.step()]}))
        with self.assertRaisesRegex(ValueError,"Unknown step"):
            m.read_plan(p)


    def strict_plan(self):
        roles = m.CYCLE_ROLES["agda-first"]
        steps = []
        for i, role in enumerate(roles):
            output = f"build/roundtrip-{i}.txt"
            command = ("from pathlib import Path; "
                       f"p=Path({output!r});p.parent.mkdir(exist_ok=True);"
                       f"p.write_text({role!r})")
            step = {
                "role": role, "cwd": "source", "git_sha": self.head,
                "argv": [sys.executable, "-c", command],
                "timeout_seconds": 10, "expected_artifacts": [output],
            }
            if i:
                step["consumes"] = [{
                    "from_step": i - 1,
                    "artifact": f"build/roundtrip-{i-1}.txt",
                }]
            steps.append(step)
        return {
            "schema": "jmd-roundtrip-exec-v1",
            "cycle_origin": "agda-first", "case_id": "pinned.fixture",
            "source": {"cwd": "source", "path": "README",
                       "sha256": hashlib.sha256(
                           (self.repo / "README").read_bytes()).hexdigest()},
            "steps": steps,
        }

    def test_strict_cycle_records_real_artifact_chain_but_not_proof(self):
        plan = self.strict_plan()
        result = m.execute(plan, base=self.root)
        self.assertTrue(result["commands_succeeded"])
        self.assertTrue(result["ordered_cycle_complete"])
        self.assertEqual(result["source_identity"]["sha256"],
                         plan["source"]["sha256"])
        self.assertEqual(len(result["receipts"]), 7)
        self.assertTrue(all(x["artifacts"] for x in result["receipts"]))
        self.assertFalse(result["semantic_fixed_point_proved"])
        self.assertFalse(result["independent_correspondence_verified"])
        self.assertFalse(any(x["kernel_certified"] for x in result["receipts"]))

    def test_strict_cycle_cannot_omit_return_translation(self):
        plan = self.strict_plan()
        plan["steps"] = plan["steps"][:4]
        with self.assertRaisesRegex(ValueError, "complete ordered return"):
            m.execute(plan, base=self.root)

    def test_strict_cycle_rejects_missing_stage_output(self):
        plan = self.strict_plan()
        plan["steps"][3]["expected_artifacts"] = []
        with self.assertRaisesRegex(ValueError, "expected artifact"):
            m.execute(plan, base=self.root)

    def test_strict_cycle_rejects_unbacked_input(self):
        plan = self.strict_plan()
        plan["steps"][3]["consumes"][0]["artifact"] = "never-produced"
        with self.assertRaisesRegex(ValueError, "lineage"):
            m.execute(plan, base=self.root)

    def test_strict_cycle_rejects_wrong_source_hash(self):
        plan = self.strict_plan()
        plan["source"]["sha256"] = "f" * 64
        with self.assertRaisesRegex(ValueError, "Source byte SHA256 mismatch"):
            m.execute(plan, base=self.root)

    def test_strict_cycle_rejects_untracked_source(self):
        plan = self.strict_plan()
        (self.repo / "untracked.agda").write_text("data X : Set where\n")
        plan["source"]["path"] = "untracked.agda"
        plan["source"]["sha256"] = hashlib.sha256(
            (self.repo / "untracked.agda").read_bytes()).hexdigest()
        with self.assertRaisesRegex(ValueError, "not tracked"):
            m.execute(plan, base=self.root)

    def test_strict_cycle_rejects_source_checkout_escape(self):
        plan = self.strict_plan()
        plan["source"]["cwd"] = ".."
        plan["steps"][0]["cwd"] = ".."
        with self.assertRaisesRegex(ValueError, "escapes"):
            m.execute(plan, base=self.root)

    def test_strict_cycle_rejects_prior_artifact_mutation(self):
        plan = self.strict_plan()
        original = plan["steps"][2]["argv"][2]
        plan["steps"][2]["argv"][2] = (
            "from pathlib import Path; "
            "Path('build/roundtrip-1.txt').write_text('tampered'); " + original
        )
        with self.assertRaisesRegex(ValueError, "prior stage artifact changed"):
            m.execute(plan, base=self.root)

    def test_strict_cycle_rejects_tracked_source_mutation(self):
        plan = self.strict_plan()
        original = plan["steps"][0]["argv"][2]
        plan["steps"][0]["argv"][2] = (
            "from pathlib import Path; "
            "Path('README').write_text('changed'); " + original
        )
        with self.assertRaisesRegex(ValueError, "modified"):
            m.execute(plan, base=self.root)

    def test_strict_cycle_is_never_minted_by_fake_kernel_commands(self):
        plan = self.strict_plan()
        result = m.execute(plan, base=self.root)
        self.assertTrue(result["ordered_cycle_complete"])
        self.assertEqual(result["authority"],
                         "reproducible-local-execution-observation")
        self.assertFalse(result["semantic_fixed_point_proved"])

if __name__=="__main__":
    unittest.main()
