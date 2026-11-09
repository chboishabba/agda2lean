"""Round-trip cross-translator fail-closed acceptance tests (stdlib only)."""
import importlib.util
import json
import pathlib
import tempfile
import unittest

FILE = pathlib.Path(__file__).parent / "bidirectional_conformance.py"
SPEC = importlib.util.spec_from_file_location("bidirectional_conformance", FILE)
mod = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(mod)

class ConformanceTests(unittest.TestCase):
    def setUp(self):
        self.tmp=tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root=pathlib.Path(self.tmp.name)
        self.agda=self.root/"manifest.tsv"
        self.agda.write_text(
            "id\tsource\texpected\tphase\tfeatures\toracle\trationale\n"
            "case.nat\tNat.agda\treconstruction-boundary\tstructural\t"
            "datatype,constructors\t-\tunpaid\n",encoding="utf-8")
        self.lean=self.root/"manifest.json"
        self.lean.write_text(json.dumps([
            {"id":"lean-nat","features":["datatype","impredicative-prop","nested-and-mutual-inductives"],
             "tier":"T0","status":"planned","lean_name":"Nat.zero",
             "agda_files":[{"profile":"CC"}]},
            {"id":"lean-choice","features":["axioms"],"tier":"T2",
             "status":"planned","lean_name":"Classical.choice",
             "agda_files":[{"profile":"K"}]}
        ]),encoding="utf-8")

    def test_crosswalk_is_candidate_only(self):
        report=mod.audit(self.agda,self.lean,[])
        self.assertEqual(report["agda2lean_cases"],1)
        self.assertEqual(report["lean2agda_corpus_entries"],2)
        self.assertEqual(report["crosswalk_candidate_pairs"],1)
        self.assertEqual(report["crosswalk_literal_candidates"],1)
        self.assertEqual(report["verified_roundtrips"],0)
        self.assertFalse(report["candidate_crosswalk"][0]["establishes_correspondence"])

    def test_positive_without_oracle_is_rejected(self):
        self.agda.write_text(
            "id\tsource\texpected\tphase\tfeatures\toracle\n"
            "case.nat\tNat.agda\tsupported-correspondence\tstructural\t"
            "datatype\t-\n")
        with self.assertRaisesRegex(ValueError,"without Lean oracle"):
            mod.read_agda_manifest(self.agda)

    def test_duplicate_case_rejected(self):
        content=self.agda.read_text()
        self.agda.write_text(content+content.splitlines()[-1]+"\n")
        with self.assertRaisesRegex(ValueError,"Duplicate"):
            mod.read_agda_manifest(self.agda)

    def test_fake_checks_do_not_mint_proof(self):
        row={"case_id":"fake","checks":{k:True for k in mod.REQUIRED},
             "checker_receipts":[{"gate":k,"status":"accepted",
               "checker":"lean","source_digest":"a"*64,
               "artifact_digest":"b"*64,"checker_revision":"v0"}
              for k in mod.REQUIRED],
             "authenticated_referee":True}
        result=mod.validate_roundtrip(row)
        self.assertTrue(result["receipt_complete"])
        self.assertFalse(result["stable_verified"])
        self.assertEqual(result["authority"],"untrusted-observation-only")

    def test_missing_computation_receipt_rejected(self):
        checks={k:True for k in mod.REQUIRED}
        row={"case_id":"incomplete","checks":checks,
             "checker_receipts":[{"gate":k,"status":"accepted","checker":"lean",
               "source_digest":"a"*64,"artifact_digest":"b"*64,
               "checker_revision":"v0"} for k in mod.REQUIRED
                 if k!="computation_preserved"]}
        result=mod.validate_roundtrip(row)
        self.assertIn("computation_preserved",result["missing_or_unwitnessed"])
        self.assertFalse(result["eligible_for_independent_referee"])

    def test_wrong_axiom_tier_rejected(self):
        rows=json.loads(self.lean.read_text())
        rows[0]["tier"]="T9"
        self.lean.write_text(json.dumps(rows))
        with self.assertRaisesRegex(ValueError,"axiom tier"):
            mod.read_lean_corpus(self.lean)

    def test_unknown_profile_rejected(self):
        rows=json.loads(self.lean.read_text())
        rows[0]["agda_files"]=[{"profile":"unsafe"}]
        self.lean.write_text(json.dumps(rows))
        with self.assertRaisesRegex(ValueError,"target profile"):
            mod.read_lean_corpus(self.lean)

    def test_reviewed_taxonomy_is_still_candidate_only(self):
        path=self.root/"crosswalk.tsv"
        path.write_text(
            "agda2lean_feature\tlean2agda_feature\trelation\tstatus\n"
            "datatype\tnested-and-mutual-inductives\tpartial-overlap\tcandidate-only\n")
        output=mod.audit(self.agda,self.lean,[],path)
        self.assertEqual(output["crosswalk_candidate_pairs"],1)
        self.assertEqual(output["crosswalk_literal_candidates"],1)
        self.assertEqual(len(output["candidate_crosswalk"][0]["reviewed_taxonomy_candidates"]),1)
        self.assertTrue(all(not c["establishes_correspondence"] for c in
                            output["candidate_crosswalk"]))

    def test_crosswalk_cannot_assert_proof(self):
        path=self.root/"crosswalk.tsv"
        path.write_text(
            "agda2lean_feature\tlean2agda_feature\trelation\tstatus\n"
            "record\tstructure-eta\tsame-theorem\tproved\n")
        with self.assertRaisesRegex(ValueError,"candidate"):
            mod.read_feature_crosswalk(path)

    def test_canonical_order_independent(self):
        self.assertEqual(mod.fingerprint({"a":1,"b":2}),
                         mod.fingerprint({"b":2,"a":1}))

if __name__=="__main__":
    unittest.main()
