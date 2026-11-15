"""Foundational mapping acceptance: never trust a taxonomy as theorem evidence."""
import csv
import importlib.util
import pathlib
import tempfile
import unittest

SCRIPT = pathlib.Path(__file__).with_name("check_foundational_mapping.py")
SPEC = importlib.util.spec_from_file_location("check_foundational_mapping", SCRIPT)
mapping = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(mapping)
CANONICAL = pathlib.Path(__file__).resolve().parents[1] / \
    "docs/agda_lean_foundational_mapping.tsv"

class FoundationalMappingTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.dest = pathlib.Path(self.temp.name) / "mapping.tsv"
        self.dest.write_bytes(CANONICAL.read_bytes())

    def rewrite(self, mutator):
        with self.dest.open(encoding="utf-8", newline="") as source:
            reader = csv.DictReader(source, delimiter="\t")
            header, rows = reader.fieldnames, list(reader)
        mutator(rows)
        with self.dest.open("w", encoding="utf-8", newline="") as out:
            writer = csv.DictWriter(out, fieldnames=header, delimiter="\t",
                                    lineterminator="\n")
            writer.writeheader()
            writer.writerows(rows)

    @staticmethod
    def get(rows, key):
        return next(r for r in rows if r["id"] == key)

    def test_canonical_registry_covers_all_13_foundational_gaps(self):
        result = mapping.audit(self.dest)
        self.assertGreaterEqual(result["total"], 40)
        self.assertEqual(set(result["upstream_gap_coverage"]), mapping.GAPS)
        self.assertEqual(result["certified"], 0)
        self.assertEqual(result["authority"], "taxonomy-only-not-translation-proof")
        self.assertFalse(result["statement_correspondence_proved"])

    def test_candidate_cannot_be_promoted_in_manifest(self):
        self.rewrite(lambda rows: self.get(rows, "data.list").update(
            certification="kernel-certified"))
        with self.assertRaisesRegex(ValueError, "cannot assert proof"):
            mapping.audit(self.dest)

    def test_set_cannot_be_rewritten_as_prop(self):
        self.rewrite(lambda rows: self.get(rows, "sort.set").update(
            lean_construct="Prop"))
        with self.assertRaisesRegex(ValueError, "foundational boundary"):
            mapping.audit(self.dest)

    def test_subtype_proof_erasure_is_a_required_conflict(self):
        self.rewrite(lambda rows: self.get(rows, "subtype.proof").update(
            correspondence="fragment"))
        with self.assertRaisesRegex(ValueError, "foundational boundary"):
            mapping.audit(self.dest)

    def test_gap_omission_rejected(self):
        self.rewrite(lambda rows: self.get(rows, "decidable.dec").update(
            upstream_gap=""))
        with self.assertRaisesRegex(ValueError, "Uncovered upstream"):
            mapping.audit(self.dest)

    def test_unknown_gap_rejected(self):
        self.rewrite(lambda rows: self.get(rows, "sort.proof").update(
            upstream_gap="invented-foundation"))
        with self.assertRaisesRegex(ValueError, "Unknown upstream"):
            mapping.audit(self.dest)

    def test_duplicate_ids_rejected(self):
        self.rewrite(lambda rows: rows.append(dict(rows[0])))
        with self.assertRaisesRegex(ValueError, "Duplicate mapping"):
            mapping.audit(self.dest)

    def test_unsafe_profile_cannot_be_promoted(self):
        self.rewrite(lambda rows: self.get(rows, "sort.type-in-type").update(
            target_profiles="safe-univalent"))
        with self.assertRaisesRegex(ValueError, "Unreviewed Agda profile"):
            mapping.audit(self.dest)

    def test_missing_axiom_or_computation_obligation_rejected(self):
        self.rewrite(lambda rows: self.get(rows, "quotient").update(
            proof_obligations=""))
        with self.assertRaisesRegex(ValueError, "Missing required"):
            mapping.audit(self.dest)

    def test_foundation_conflict_cannot_vanish(self):
        self.rewrite(lambda rows: self.get(rows, "cubical.path").update(
            correspondence="fragment"))
        with self.assertRaisesRegex(ValueError, "foundational boundary"):
            mapping.audit(self.dest)

if __name__ == "__main__":
    unittest.main()
