import importlib.util
import pathlib
import sys
import tempfile
import textwrap
import unittest
from unittest import mock


ROOT = pathlib.Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location(
    "a2l_project", ROOT / "scripts" / "a2l_project.py"
)
assert SPEC is not None and SPEC.loader is not None
A2L = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = A2L
SPEC.loader.exec_module(A2L)


class ProjectPlanTests(unittest.TestCase):
    def write(self, root: pathlib.Path, module: str, body: str = "") -> pathlib.Path:
        path = root.joinpath(*module.split(".")).with_suffix(".agda")
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(f"module {module} where\n{body}", encoding="utf-8")
        return path

    def test_transitive_closure_and_dependency_frontiers_are_deterministic(self):
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            self.write(root, "Leaf")
            self.write(root, "Left", "open import Leaf\n")
            self.write(root, "Right", "import Leaf\n")
            self.write(
                root,
                "Root",
                "open import Left\nopen import Right\nopen import Agda.Builtin.Nat\n",
            )
            modules = A2L.discover_modules((root,))
            plan = A2L.make_plan(
                modules, ("Root",), A2L.DEFAULT_PLATFORM_PREFIXES, ()
            )

            self.assertEqual(plan.closure, ("Leaf", "Left", "Right", "Root"))
            self.assertEqual(plan.frontiers, (("Leaf",), ("Left", "Right"), ("Root",)))
            self.assertEqual(plan.platform_imports["Root"], ("Agda.Builtin.Nat",))
            self.assertEqual(A2L.render_plan(plan), A2L.render_plan(plan))

    def test_comments_do_not_create_import_edges(self):
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            self.write(root, "Root", "-- open import Missing\n{- import Also.Missing -}\n")
            modules = A2L.discover_modules((root,))
            plan = A2L.make_plan(
                modules, ("Root",), A2L.DEFAULT_PLATFORM_PREFIXES, ()
            )
            self.assertEqual(plan.closure, ("Root",))

    def test_unresolved_imports_fail_closed(self):
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            self.write(root, "Root", "open import Unknown.Module\n")
            modules = A2L.discover_modules((root,))
            with self.assertRaisesRegex(A2L.ProjectError, "unresolved imports"):
                A2L.make_plan(
                    modules, ("Root",), A2L.DEFAULT_PLATFORM_PREFIXES, ()
                )

    def test_cycles_fail_closed(self):
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            self.write(root, "A", "open import B\n")
            self.write(root, "B", "open import A\n")
            modules = A2L.discover_modules((root,))
            with self.assertRaisesRegex(A2L.ProjectError, "cyclic project import graph"):
                A2L.make_plan(modules, ("A",), A2L.DEFAULT_PLATFORM_PREFIXES, ())

    def test_platform_import_rewrite_is_explicit_and_stable(self):
        source = (
            "import Agda.Builtin.Nat\n"
            "import Agda.Primitive\n"
            "import Project.Module\n\nnamespace Root\n"
        )
        rewritten, receipt = A2L.rewrite_platform_imports(
            source, {"Agda.Builtin.Nat"}
        )
        self.assertEqual(receipt, ["Agda.Builtin.Nat", "Agda.Primitive"])
        self.assertIn("Agda.Builtin.Nat -> Lean prelude", rewritten)
        self.assertIn("Agda.Primitive -> Lean prelude", rewritten)
        self.assertIn("import Project.Module", rewritten)

    def test_build_reuses_isolated_cache_and_regenerates_identically(self):
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            source = root / "source"
            source.mkdir()
            self.write(source, "Root", "open import Agda.Builtin.Nat\n")
            calls = root / "backend-calls"
            backend = root / "fake-backend"
            backend.write_text(
                textwrap.dedent(
                    f"""\
                    #!/usr/bin/env python3
                    import pathlib, re, sys
                    if "--version" in sys.argv:
                        print("Agda version 2.9.0 / fake LeanIR backend")
                        raise SystemExit(0)
                    args = sys.argv[1:]
                    if "--local-interfaces" in args:
                        raise SystemExit("Agda 2.9 removed --local-interfaces")
                    out = pathlib.Path(args[args.index("--compile-dir") + 1])
                    source = pathlib.Path(args[-1])
                    name = re.search(r"(?m)^module\\s+(\\S+)\\s+where", source.read_text()).group(1)
                    target = out.joinpath(*name.split("."), "module.a2l.cbor")
                    target.parent.mkdir(parents=True, exist_ok=True)
                    target.write_bytes(b"fake-ir")
                    with pathlib.Path({str(calls)!r}).open("a") as handle:
                        handle.write(name + "\\n")
                    """
                ),
                encoding="utf-8",
            )
            backend.chmod(0o755)
            emitter = root / "fake-emitter"
            emitter.write_text(
                textwrap.dedent(
                    """\
                    #!/usr/bin/env python3
                    import pathlib, sys
                    args = sys.argv[2:]
                    def value(flag):
                        return pathlib.Path(args[args.index(flag) + 1])
                    lean = value("--lean-output")
                    diagnostic = value("--diagnostics")
                    receipt = value("--builtin-receipt")
                    for path in (lean, diagnostic, receipt):
                        path.parent.mkdir(parents=True, exist_ok=True)
                    lean.write_text("import Agda.Builtin.Nat\\n\\nnamespace Root\\n\\ndef answer : Nat := 42\\n\\nend Root\\n")
                    diagnostic.write_text("severity\\tcode\\n")
                    receipt.write_text("builtin\\tstatus\\n")
                    """
                ),
                encoding="utf-8",
            )
            emitter.chmod(0o755)

            common = [
                "build",
                "--source-root",
                str(source),
                "--entry",
                "Root",
                "--backend",
                str(backend),
                "--emitter",
                str(emitter),
                "--cache-root",
                str(root / "cache"),
                "--jobs",
                "2",
            ]
            first = root / "first"
            second = root / "second"
            self.assertEqual(A2L.main([*common, "--workspace", str(first)]), 0)
            self.assertEqual(A2L.main([*common, "--workspace", str(second)]), 0)

            self.assertEqual(calls.read_text(encoding="utf-8"), "Root\n")
            self.assertIn(
                "Agda.Builtin.Nat -> Lean prelude",
                (first / "Root.lean").read_text(encoding="utf-8"),
            )
            self.assertEqual(
                (first / ".agda2lean/files.sha256").read_bytes(),
                (second / ".agda2lean/files.sha256").read_bytes(),
            )

    def test_bulk_catalog_manifest_uses_hermetic_checked_source_hash(self):
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            source = root / "source"
            source.mkdir()
            original = self.write(source, "Root", "value : Set\nvalue = Set\n")

            modules = A2L.discover_modules((source,))
            plan = A2L.make_plan(
                modules,
                ("Root",),
                A2L.DEFAULT_PLATFORM_PREFIXES,
                (),
            )
            cache = A2L.prepare_cache(
                plan,
                root / "cache",
                "toolchain",
                A2L.source_fingerprint(plan),
            )
            ir = A2L.module_ir_path(cache / "ir", "Root")
            ir.parent.mkdir(parents=True, exist_ok=True)
            ir.write_bytes(b"fake-ir")

            cached_source = cache / "source" / "Root.agda"
            expected_hash = A2L.file_sha256(cached_source)

            # Mutate the worktree after the hermetic source tree has been
            # prepared. Catalog provenance must still describe what Agda saw.
            original.write_text(
                "module Root where\nvalue : Set\nvalue = (λ A → A) Set\n",
                encoding="utf-8",
            )

            with mock.patch.object(A2L, "run_logged") as run_logged:
                A2L.populate_catalog(
                    plan,
                    cache,
                    root / "agda2lean",
                    root / "semantic.sqlite",
                )

            manifest = cache / "catalog-manifest.tsv"
            rows = manifest.read_text(encoding="utf-8").splitlines()
            self.assertEqual(
                rows,
                [f"{ir}\t{expected_hash}"],
            )
            self.assertNotEqual(
                expected_hash,
                A2L.file_sha256(original),
            )

            run_logged.assert_called_once()
            command, log, cwd = run_logged.call_args.args
            self.assertEqual(
                command,
                [
                    str(root / "agda2lean"),
                    "put-modules",
                    "--database",
                    str(root / "semantic.sqlite"),
                    "--manifest",
                    str(manifest),
                ],
            )
            self.assertEqual(log, cache / "logs" / "catalog-ingest.log")
            self.assertEqual(cwd, cache)

    def test_promote_extracts_and_populates_catalog_without_workspace(self):
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            source = root / "source"
            source.mkdir()
            self.write(source, "Root", "value : Set\nvalue = Set\n")
            backend = root / "backend"
            emitter = root / "emitter"
            backend.write_text("#!/bin/sh\n", encoding="utf-8")
            emitter.write_text("#!/bin/sh\n", encoding="utf-8")
            backend.chmod(0o755)
            emitter.chmod(0o755)
            receipt = root / "promotion.json"

            fake_cache = root / "cache" / "prepared"
            fake_cache.mkdir(parents=True)

            with (
                mock.patch.object(
                    A2L,
                    "toolchain_fingerprint",
                    return_value="toolchain",
                ),
                mock.patch.object(
                    A2L,
                    "prepare_cache",
                    return_value=fake_cache,
                ),
                mock.patch.object(A2L, "extract_frontiers") as extract,
                mock.patch.object(A2L, "populate_catalog") as populate,
                mock.patch.object(A2L, "emit_workspace") as emit_workspace,
            ):
                status = A2L.main(
                    [
                        "promote",
                        "--source-root",
                        str(source),
                        "--entry",
                        "Root",
                        "--backend",
                        str(backend),
                        "--emitter",
                        str(emitter),
                        "--catalog",
                        str(root / "semantic.sqlite"),
                        "--cache-root",
                        str(root / "cache"),
                        "--jobs",
                        "2",
                        "--receipt",
                        str(receipt),
                    ]
                )

            self.assertEqual(status, 0)
            extract.assert_called_once()
            populate.assert_called_once()
            emit_workspace.assert_not_called()

            payload = json.loads(receipt.read_text(encoding="utf-8"))
            self.assertEqual(payload["status"], "promoted")
            self.assertEqual(payload["entries"], ["Root"])
            self.assertEqual(payload["modules"], 1)
            self.assertEqual(payload["frontiers"], 1)
            self.assertEqual(
                payload["catalog"],
                str((root / "semantic.sqlite").resolve()),
            )

    def test_parameterized_multiline_module_header_is_discovered(self):
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            path = root / "Parameterized.agda"
            path.write_text(
                "module Parameterized\n"
                "  {ℓ : Agda.Primitive.Level}\n"
                "  (A : Set ℓ)\n"
                "  where\n",
                encoding="utf-8",
            )
            modules = A2L.discover_modules((root,))
            self.assertIn("Parameterized", modules)

    def test_content_addressed_sources_reuse_unchanged_blobs(self):
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            source = root / "source"
            source.mkdir()
            self.write(source, "Leaf", "")
            self.write(source, "Root", "open import Leaf\n")

            def prepare():
                modules = A2L.discover_modules((source,))
                plan = A2L.make_plan(
                    modules, ("Root",), A2L.DEFAULT_PLATFORM_PREFIXES, ()
                )
                source_key = A2L.source_fingerprint(plan)
                return A2L.prepare_cache(
                    plan, root / "cache", "toolchain", source_key
                )

            first = prepare()
            self.write(source, "Root", "open import Leaf\nvalue : Set\nvalue = Set\n")
            second = prepare()
            blobs = list((root / "cache/agda/sources/sha256").rglob("*.agda"))

            self.assertNotEqual(first, second)
            self.assertEqual(len(blobs), 3)
            self.assertTrue((first / "sources.tsv").is_file())
            self.assertTrue((second / "sources.tsv").is_file())


if __name__ == "__main__":
    unittest.main()
