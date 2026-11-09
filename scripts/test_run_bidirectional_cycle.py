"""Offline functional smoke for the pinned round-trip execution harness."""
import importlib.util
import json
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

if __name__=="__main__":
    unittest.main()
