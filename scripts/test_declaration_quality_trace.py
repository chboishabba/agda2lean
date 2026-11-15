"""Adversarial tests for declaration-level mapping observations (no proof claims)."""
import copy
import importlib.util
import json
import pathlib
import shutil
import tempfile
import unittest

HERE = pathlib.Path(__file__).resolve().parent
ROOT = HERE.parent
SPEC = importlib.util.spec_from_file_location("declaration_quality_trace", HERE / "declaration_quality_trace.py")
trace = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(trace)

CASE = ROOT / "fixtures" / "bidirectional" / "identity_mapping_case.json"
SOURCE = ROOT / "test" / "agda" / "Identity.agda"
REGISTRY = ROOT / "docs" / "agda_lean_foundational_mapping.tsv"
EMITTED = """import Lean
-- Agda: Identity.identity
-- Mapping: Native
-- Direct dependencies: (none)
def Identity.identity (A : Type) (a : A) := a
-- Agda: Identity.identity-law
-- Mapping: Reconstruct
-- Direct dependencies: Identity.identity, Agda.Builtin.Equality._≡_
theorem Identity.«identity-law» : True := trivial
"""

class DeclarationQualityTraceTests(unittest.TestCase):
    def setUp(self):
        self.work = tempfile.TemporaryDirectory()
        self.addCleanup(self.work.cleanup)
        self.root = pathlib.Path(self.work.name)
        self.source = self.root / "Identity.agda"
        self.source.write_bytes(SOURCE.read_bytes())
        self.emitted = self.root / "Identity.lean"
        self.emitted.write_text(EMITTED, encoding="utf-8")
        self.case = self.root / "case.json"
        self.case.write_bytes(CASE.read_bytes())
        self.manifest = self.root / "manifest.tsv"
        self.manifest.write_text(
            "Identity.identity\ttype-direct\t\n"
            "Identity.identity\tvalue-direct\t\n"
            "Identity.identity\taxiom-closure\t\n"
            "Identity.«identity-law»\ttype-direct\tIdentity.identity\n"
            "Identity.«identity-law»\tvalue-direct\t\n"
            "Identity.«identity-law»\taxiom-closure\t\n",
            encoding="utf-8")

    def run_trace(self, manifest=False):
        return trace.build_trace(case_path=self.case, source=self.source,
                                  emitted=self.emitted, registry_path=REGISTRY,
                                  manifest=self.manifest if manifest else None)

    def change_case(self, f):
        case = json.loads(self.case.read_text(encoding="utf-8"))
        f(case)
        self.case.write_text(json.dumps(case, ensure_ascii=False), encoding="utf-8")

    def test_two_declarations_bound_to_original_source_bytes(self):
        result = self.run_trace()
        self.assertEqual(result["declaration_count"], 2)
        self.assertEqual(result["source_sha256"],
                         json.loads(self.case.read_text())["source_sha256"])
        self.assertEqual(result["authority"],
                         "source-bound-compiler-annotation-observation-only")
        self.assertFalse(result["semantic_correspondence_proved"])
        self.assertEqual(result["certified_roundtrips"], 0)
        self.assertTrue(all(not r["kernel_correspondence_certified"]
                            for r in result["declarations"]))

    def test_unicode_lean_quoted_identifier_and_observation(self):
        result = self.run_trace(manifest=True)
        r = next(row for row in result["declarations"]
                 if row["agda_declaration"] == "Identity.identity-law")
        self.assertEqual(r["lean_expected_constant"], "Identity.«identity-law»")
        self.assertEqual(r["observed_emitter_annotation"], "Reconstruct")
        self.assertEqual(r["observed_agda_direct_dependencies"],
                         ["Agda.Builtin.Equality._≡_", "Identity.identity"])
        self.assertEqual(r["lean_manifest_observation"]["type-direct"],
                         ["Identity.identity"])
        self.assertFalse(r["kernel_correspondence_certified"])

    def test_source_changed_since_review_fails(self):
        self.source.write_bytes(self.source.read_bytes() + b"-- changed\n")
        with self.assertRaisesRegex(trace.TraceError, "source SHA256"):
            self.run_trace()

    def test_missing_source_tag_fails(self):
        self.emitted.write_text(EMITTED.replace("Identity.identity-law", "Unknown.other"),
                                encoding="utf-8")
        with self.assertRaisesRegex(trace.TraceError, "Missing emitted declaration"):
            self.run_trace()

    def test_duplicate_source_tag_fails(self):
        self.emitted.write_text(EMITTED + "\n-- Agda: Identity.identity\n",
                                encoding="utf-8")
        with self.assertRaisesRegex(trace.TraceError, "Duplicate/empty"):
            self.run_trace()

    def test_unknown_feature_id_fails(self):
        self.change_case(lambda c: c["declarations"][0]["registry_ids"].append("fake.feature"))
        with self.assertRaisesRegex(trace.TraceError, "Unknown or duplicate"):
            self.run_trace()

    def test_invalid_module_namespace_fails(self):
        self.change_case(lambda c: c["declarations"][0].update(agda="Other.identity"))
        with self.assertRaisesRegex(trace.TraceError, "outside the selected"):
            self.run_trace()

    def test_duplicate_declaration_fails(self):
        self.change_case(lambda c: c["declarations"].append(copy.deepcopy(c["declarations"][0])))
        with self.assertRaisesRegex(trace.TraceError, "Duplicate declaration"):
            self.run_trace()

    def test_conflicting_mapping_never_promotes(self):
        self.change_case(lambda c: c["declarations"][0]["registry_ids"].append("sort.proof"))
        result = self.run_trace()
        self.assertEqual(result["declarations"][0]["status"],
                         "quarantined-foundational-conflict")
        self.assertFalse(result["declarations"][0]["kernel_correspondence_certified"])

    def test_absent_emitter_mapping_is_observation_not_certification(self):
        self.emitted.write_text(EMITTED.replace("-- Mapping: Native\n", ""),
                                encoding="utf-8")
        result = self.run_trace()
        self.assertIsNone(result["declarations"][0]["observed_emitter_annotation"])
        self.assertFalse(result["semantic_correspondence_proved"])

    def test_malformed_manifest_fails_closed(self):
        self.manifest.write_text("Identity.identity\ttype-direct\n", encoding="utf-8")
        with self.assertRaisesRegex(trace.TraceError, "wrong TSV width"):
            self.run_trace(manifest=True)

    def test_forged_authority_flag_not_allowed(self):
        self.change_case(lambda c: c.update(certified_roundtrips=999,
                                             semantic_correspondence_proved=True))
        report = self.run_trace()
        self.assertEqual(report["certified_roundtrips"], 0)
        self.assertFalse(report["semantic_correspondence_proved"])

if __name__ == "__main__":
    unittest.main()
