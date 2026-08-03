#!/usr/bin/env python3
"""Deterministic project driver for the Agda 2.9 -> Lean module pipeline.

The compiler backends remain responsible for semantics.  This driver owns the
project-scale mechanics: import discovery, dependency-frontier scheduling,
isolated Agda interface caches, and construction of a self-contained Lake
workspace.  It intentionally has no fixture- or project-name special cases.
"""

from __future__ import annotations

import argparse
import concurrent.futures
import dataclasses
import hashlib
import json
import os
import pathlib
import re
import shutil
import subprocess
import sys
import tempfile
from collections.abc import Iterable, Sequence


SCHEMA_VERSION = "1"
DEFAULT_PLATFORM_PREFIXES = ("Agda.Builtin.", "Agda.Primitive")


class ProjectError(RuntimeError):
    pass


@dataclasses.dataclass(frozen=True)
class Module:
    name: str
    path: pathlib.Path
    relative_path: pathlib.PurePosixPath
    imports: tuple[str, ...]


@dataclasses.dataclass(frozen=True)
class Plan:
    modules: dict[str, Module]
    entries: tuple[str, ...]
    closure: tuple[str, ...]
    frontiers: tuple[tuple[str, ...], ...]
    local_imports: dict[str, tuple[str, ...]]
    platform_imports: dict[str, tuple[str, ...]]


def strip_comments(source: str) -> str:
    """Remove nested Agda comments while preserving newlines for diagnostics."""
    out: list[str] = []
    index = 0
    block_depth = 0
    while index < len(source):
        pair = source[index : index + 2]
        if block_depth:
            if pair == "{-":
                block_depth += 1
                out.extend("  ")
                index += 2
            elif pair == "-}":
                block_depth -= 1
                out.extend("  ")
                index += 2
            else:
                out.append("\n" if source[index] == "\n" else " ")
                index += 1
        elif pair == "{-":
            block_depth = 1
            out.extend("  ")
            index += 2
        elif pair == "--":
            end = source.find("\n", index)
            if end < 0:
                out.extend(" " * (len(source) - index))
                break
            out.extend(" " * (end - index))
            out.append("\n")
            index = end + 1
        else:
            out.append(source[index])
            index += 1
    if block_depth:
        raise ProjectError("unterminated Agda block comment")
    return "".join(out)


MODULE_RE = re.compile(r"(?ms)^\s*module\s+([^\s]+).*?\bwhere(?:\s|$)")
IMPORT_RE = re.compile(
    r"(?m)^\s*(?:(?:private|public)\s+)?(?:open\s+)?import\s+([^\s]+)(?:\s|$)"
)


def parse_module(path: pathlib.Path, root: pathlib.Path) -> Module:
    source = strip_comments(path.read_text(encoding="utf-8"))
    match = MODULE_RE.search(source)
    if match is None:
        raise ProjectError(f"no top-level 'module ... where' declaration in {path}")
    name = match.group(1)
    imports = tuple(sorted(set(IMPORT_RE.findall(source))))
    relative = pathlib.PurePosixPath(path.relative_to(root).as_posix())
    expected_suffix = pathlib.PurePosixPath(*name.split(".")).with_suffix(".agda")
    if relative != expected_suffix and not str(relative).endswith(str(expected_suffix)):
        raise ProjectError(
            f"module {name} is stored at {relative}, expected a path ending in {expected_suffix}"
        )
    return Module(name, path, relative, imports)


def discover_modules(source_roots: Sequence[pathlib.Path]) -> dict[str, Module]:
    modules: dict[str, Module] = {}
    for root in source_roots:
        if not root.is_dir():
            raise ProjectError(f"source root is not a directory: {root}")
        for path in sorted(root.rglob("*.agda")):
            if path.name.endswith(".lagda.agda"):
                continue
            module = parse_module(path, root)
            previous = modules.get(module.name)
            if previous is not None and previous.path != module.path:
                raise ProjectError(
                    f"duplicate module {module.name}: {previous.path} and {module.path}"
                )
            modules[module.name] = module
    return modules


def resolve_entries(
    raw_entries: Sequence[str], modules: dict[str, Module]
) -> tuple[str, ...]:
    by_path = {module.path.resolve(): name for name, module in modules.items()}
    resolved: list[str] = []
    for entry in raw_entries:
        if entry in modules:
            resolved.append(entry)
            continue
        path = pathlib.Path(entry).resolve()
        if path in by_path:
            resolved.append(by_path[path])
            continue
        raise ProjectError(f"entry is neither a discovered module nor a source path: {entry}")
    if not resolved:
        raise ProjectError("at least one --entry is required")
    return tuple(sorted(set(resolved)))


def has_prefix(name: str, prefixes: Sequence[str]) -> bool:
    return any(
        name.startswith(prefix) if prefix.endswith(".") else name == prefix
        for prefix in prefixes
    )


def make_plan(
    modules: dict[str, Module],
    entries: Sequence[str],
    platform_prefixes: Sequence[str],
    external_prefixes: Sequence[str],
) -> Plan:
    closure: set[str] = set()
    local_imports: dict[str, tuple[str, ...]] = {}
    platform_imports: dict[str, tuple[str, ...]] = {}
    pending = list(reversed(sorted(entries)))
    while pending:
        name = pending.pop()
        if name in closure:
            continue
        closure.add(name)
        module = modules[name]
        local: list[str] = []
        platform: list[str] = []
        unresolved: list[str] = []
        for imported in module.imports:
            if imported in modules:
                local.append(imported)
            elif has_prefix(imported, platform_prefixes):
                platform.append(imported)
            elif has_prefix(imported, external_prefixes):
                # External imports remain Lean imports and must be supplied by
                # a Lake dependency. They are not part of the project cache.
                pass
            else:
                unresolved.append(imported)
        if unresolved:
            raise ProjectError(
                f"unresolved imports in {name}: {', '.join(sorted(unresolved))}; "
                "add a source root or an explicit --external-prefix"
            )
        local_imports[name] = tuple(sorted(local))
        platform_imports[name] = tuple(sorted(platform))
        pending.extend(reversed(sorted(local)))

    dependencies = {
        name: set(local_imports[name]).intersection(closure) for name in closure
    }
    remaining = set(closure)
    frontiers: list[tuple[str, ...]] = []
    completed: set[str] = set()
    while remaining:
        frontier = tuple(
            sorted(name for name in remaining if dependencies[name] <= completed)
        )
        if not frontier:
            cycle = ", ".join(sorted(remaining))
            raise ProjectError(f"cyclic project import graph involving: {cycle}")
        frontiers.append(frontier)
        completed.update(frontier)
        remaining.difference_update(frontier)

    return Plan(
        modules=modules,
        entries=tuple(entries),
        closure=tuple(sorted(closure)),
        frontiers=tuple(frontiers),
        local_imports=local_imports,
        platform_imports=platform_imports,
    )


def render_plan(plan: Plan) -> str:
    frontier_by_module = {
        name: index for index, frontier in enumerate(plan.frontiers) for name in frontier
    }
    rows = [
        f"# agda2lean-project-plan\t{SCHEMA_VERSION}",
        "module\tfrontier\tsource\tlocal-imports\tplatform-imports",
    ]
    for name in plan.closure:
        module = plan.modules[name]
        rows.append(
            "\t".join(
                [
                    name,
                    str(frontier_by_module[name]),
                    str(module.relative_path),
                    ",".join(plan.local_imports[name]),
                    ",".join(plan.platform_imports[name]),
                ]
            )
        )
    return "\n".join(rows) + "\n"


def hash_file(path: pathlib.Path, digest: "hashlib._Hash") -> None:
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)


def file_sha256(path: pathlib.Path) -> str:
    digest = hashlib.sha256()
    hash_file(path, digest)
    return digest.hexdigest()


def toolchain_fingerprint(backend: pathlib.Path, override: str | None) -> str:
    digest = hashlib.sha256()
    digest.update(b"agda2lean-toolchain-v1\0")
    if override is not None:
        digest.update(override.encode("utf-8"))
    else:
        if not backend.is_file():
            raise ProjectError(f"backend executable not found: {backend}")
        hash_file(backend, digest)
        try:
            result = subprocess.run(
                [str(backend), "--version"],
                check=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.STDOUT,
                text=True,
                timeout=30,
            )
        except (OSError, subprocess.SubprocessError) as error:
            raise ProjectError(f"could not identify Agda backend {backend}: {error}") from error
        digest.update(result.stdout.strip().encode("utf-8"))
    return digest.hexdigest()


def source_fingerprint(plan: Plan) -> str:
    digest = hashlib.sha256()
    digest.update(b"agda2lean-source-closure-v1\0")
    digest.update(render_plan(plan).encode("utf-8"))
    for name in plan.closure:
        module = plan.modules[name]
        digest.update(name.encode("utf-8"))
        digest.update(b"\0")
        hash_file(module.path, digest)
        digest.update(b"\0")
    return digest.hexdigest()


def atomic_write(path: pathlib.Path, content: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    descriptor, temporary = tempfile.mkstemp(prefix=f".{path.name}.", dir=path.parent)
    try:
        with os.fdopen(descriptor, "w", encoding="utf-8", newline="\n") as handle:
            handle.write(content)
        os.replace(temporary, path)
    except BaseException:
        try:
            os.unlink(temporary)
        except FileNotFoundError:
            pass
        raise


def prepare_cache(
    plan: Plan,
    cache_root: pathlib.Path,
    toolchain_key: str,
    source_key: str,
) -> pathlib.Path:
    cache = cache_root / "agda" / toolchain_key / source_key
    source = cache / "source"
    blob_root = cache_root / "agda" / "sources" / "sha256"
    source.mkdir(parents=True, exist_ok=True)
    source_rows = ["module\trelative-path\tsha256\tstorage"]
    for name in plan.closure:
        module = plan.modules[name]
        content_hash = file_sha256(module.path)
        blob = blob_root / content_hash[:2] / f"{content_hash}.agda"
        blob.parent.mkdir(parents=True, exist_ok=True)
        if not blob.exists():
            descriptor, temporary = tempfile.mkstemp(prefix=".source-", dir=blob.parent)
            try:
                with os.fdopen(descriptor, "wb") as handle, module.path.open("rb") as original:
                    shutil.copyfileobj(original, handle)
                os.chmod(temporary, 0o444)
                os.replace(temporary, blob)
            except BaseException:
                try:
                    os.unlink(temporary)
                except FileNotFoundError:
                    pass
                raise
        elif file_sha256(blob) != content_hash:
            raise ProjectError(f"content-addressed source blob is corrupt: {blob}")
        destination = source / pathlib.Path(module.relative_path)
        destination.parent.mkdir(parents=True, exist_ok=True)
        if destination.exists():
            if file_sha256(destination) != content_hash:
                raise ProjectError(f"cached closure source is corrupt: {destination}")
            try:
                storage = "hardlink" if os.path.samefile(blob, destination) else "copy"
            except OSError:
                storage = "copy"
        else:
            try:
                os.link(blob, destination)
                storage = "hardlink"
            except OSError:
                shutil.copyfile(blob, destination)
                os.chmod(destination, 0o444)
                storage = "copy"
        source_rows.append(
            f"{name}\t{module.relative_path}\t{content_hash}\t{storage}"
        )
    atomic_write(source / "agda2lean-cache.agda-lib", "name: agda2lean-cache\ninclude: .\n")
    atomic_write(cache / "plan.tsv", render_plan(plan))
    atomic_write(cache / "sources.tsv", "\n".join(source_rows) + "\n")
    atomic_write(
        cache / "identity.tsv",
        "key\tvalue\n"
        f"schema\t{SCHEMA_VERSION}\n"
        f"toolchain-sha256\t{toolchain_key}\n"
        f"source-sha256\t{source_key}\n",
    )
    return cache


def module_ir_path(ir_root: pathlib.Path, name: str) -> pathlib.Path:
    return ir_root.joinpath(*name.split("."), "module.a2l.cbor")


def run_logged(command: Sequence[str], log: pathlib.Path, cwd: pathlib.Path) -> None:
    log.parent.mkdir(parents=True, exist_ok=True)
    with log.open("wb") as handle:
        result = subprocess.run(command, cwd=cwd, stdout=handle, stderr=subprocess.STDOUT)
    if result.returncode:
        raise ProjectError(
            f"command failed with exit {result.returncode}; see {log}: {' '.join(command)}"
        )


def extract_frontiers(
    plan: Plan,
    cache: pathlib.Path,
    backend: pathlib.Path,
    include_dirs: Sequence[pathlib.Path],
    jobs: int,
) -> None:
    ir_root = cache / "ir"
    source_root = cache / "source"
    ir_root.mkdir(parents=True, exist_ok=True)
    includes = [source_root, *include_dirs]

    for frontier_index, frontier in enumerate(plan.frontiers):
        missing = [name for name in frontier if not module_ir_path(ir_root, name).is_file()]
        if not missing:
            print(f"[extract {frontier_index + 1}/{len(plan.frontiers)}] cache hit: {', '.join(frontier)}")
            continue
        print(
            f"[extract {frontier_index + 1}/{len(plan.frontiers)}] "
            f"{len(missing)} module(s), up to {jobs} parallel"
        )

        def extract(name: str) -> None:
            module = plan.modules[name]
            shadow_path = source_root / pathlib.Path(module.relative_path)
            command = [
                str(backend),
                "--lean-ir",
                "-j1",
                "--compile-dir",
                str(ir_root),
            ]
            for include in includes:
                command.extend(["-i", str(include)])
            command.append(str(shadow_path))
            run_logged(command, cache / "logs" / f"extract-{name}.log", source_root)

        with concurrent.futures.ThreadPoolExecutor(max_workers=jobs) as pool:
            futures = {pool.submit(extract, name): name for name in missing}
            errors: list[str] = []
            for future in concurrent.futures.as_completed(futures):
                try:
                    future.result()
                except BaseException as error:
                    errors.append(f"{futures[future]}: {error}")
            if errors:
                raise ProjectError("frontier extraction failed:\n  " + "\n  ".join(sorted(errors)))

    absent = [name for name in plan.closure if not module_ir_path(ir_root, name).is_file()]
    if absent:
        raise ProjectError("backend did not emit IR for: " + ", ".join(absent))


def module_lean_path(root: pathlib.Path, name: str) -> pathlib.Path:
    return root.joinpath(*name.split(".")).with_suffix(".lean")


def rewrite_platform_imports(source: str, platform_modules: set[str]) -> tuple[str, list[str]]:
    rewritten: list[str] = []
    replaced: list[str] = []
    for line in source.splitlines():
        match = re.fullmatch(r"import\s+([^\s]+)\s*", line)
        if match and (
            match.group(1) in platform_modules
            or has_prefix(match.group(1), DEFAULT_PLATFORM_PREFIXES)
        ):
            module = match.group(1)
            rewritten.append(f"-- agda2lean platform import: {module} -> Lean prelude")
            replaced.append(module)
        else:
            rewritten.append(line)
    return "\n".join(rewritten) + "\n", sorted(set(replaced))


def normalize_cache_paths(source: str, cache_source: pathlib.Path) -> str:
    """Remove machine-local cache roots from human artifacts and their hashes."""
    roots = {str(cache_source), cache_source.as_posix()}
    normalized = source
    for root in sorted(roots, key=len, reverse=True):
        normalized = normalized.replace(root.rstrip("/\\") + "/", "")
        normalized = normalized.replace(root.rstrip("/\\") + "\\", "")
    return normalized


def workspace_hashes(root: pathlib.Path) -> str:
    selected: list[pathlib.Path] = []
    for path in root.rglob("*"):
        if not path.is_file():
            continue
        relative = path.relative_to(root)
        if relative.parts[:1] == (".lake",) or relative == pathlib.Path(
            ".agda2lean/files.sha256"
        ):
            continue
        if path.suffix == ".lean" or relative.parts[:1] == (".agda2lean",) or path.name in {
            "lakefile.toml",
            "lean-toolchain",
        }:
            selected.append(path)
    rows: list[str] = []
    for path in sorted(selected):
        digest = hashlib.sha256(path.read_bytes()).hexdigest()
        rows.append(f"{digest}  {path.relative_to(root).as_posix()}")
    return "\n".join(rows) + "\n"


def emit_workspace(
    plan: Plan,
    cache: pathlib.Path,
    emitter: pathlib.Path,
    workspace: pathlib.Path,
    lean_toolchain: str,
    jobs: int,
    allow_reconstruction: bool,
    replace: bool,
) -> None:
    parent = workspace.parent.resolve()
    parent.mkdir(parents=True, exist_ok=True)
    stage = pathlib.Path(tempfile.mkdtemp(prefix=f".{workspace.name}.stage-", dir=parent))
    try:
        (stage / ".agda2lean").mkdir()
        atomic_write(stage / ".agda2lean/workspace", "agda2lean-generated-workspace-v1\n")
        ir_root = cache / "ir"
        platform_modules = {
            imported for name in plan.closure for imported in plan.platform_imports[name]
        }

        def emit(name: str) -> None:
            lean_path = module_lean_path(stage, name)
            diagnostic = module_lean_path(stage / ".agda2lean/diagnostics", name).with_suffix(
                ".tsv"
            )
            receipt = module_lean_path(stage / ".agda2lean/receipts", name).with_suffix(
                ".tsv"
            )
            lean_path.parent.mkdir(parents=True, exist_ok=True)
            command = [
                str(emitter),
                "emit-lean",
                "--input",
                str(module_ir_path(ir_root, name)),
                "--lean-output",
                str(lean_path),
                "--diagnostics",
                str(diagnostic),
                "--builtin-receipt",
                str(receipt),
            ]
            if allow_reconstruction:
                command.append("--allow-reconstruction")
            run_logged(command, cache / "logs" / f"emit-{name}.log", cache)
            for artifact in (lean_path, diagnostic, receipt):
                atomic_write(
                    artifact,
                    normalize_cache_paths(
                        artifact.read_text(encoding="utf-8"), cache / "source"
                    ),
                )
            rewritten, replaced = rewrite_platform_imports(
                lean_path.read_text(encoding="utf-8"), platform_modules
            )
            atomic_write(lean_path, rewritten)
            atomic_write(
                module_lean_path(stage / ".agda2lean/platform-imports", name).with_suffix(
                    ".tsv"
                ),
                "agda-module\tlean-import\tpolicy\n"
                + "".join(f"{item}\tLean prelude\tdrop-native\n" for item in replaced),
            )

        for frontier_index, frontier in enumerate(plan.frontiers):
            print(
                f"[emit {frontier_index + 1}/{len(plan.frontiers)}] "
                f"{len(frontier)} module(s), up to {jobs} parallel"
            )
            with concurrent.futures.ThreadPoolExecutor(max_workers=jobs) as pool:
                futures = {pool.submit(emit, name): name for name in frontier}
                errors: list[str] = []
                for future in concurrent.futures.as_completed(futures):
                    try:
                        future.result()
                    except BaseException as error:
                        errors.append(f"{futures[future]}: {error}")
                if errors:
                    raise ProjectError("frontier emission failed:\n  " + "\n  ".join(sorted(errors)))

        globs = ", ".join(json.dumps(name) for name in plan.closure)
        atomic_write(
            stage / "lakefile.toml",
            'name = "Agda2LeanGenerated"\n'
            'defaultTargets = ["Agda2LeanGenerated"]\n\n'
            "[[lean_lib]]\n"
            'name = "Agda2LeanGenerated"\n'
            f"globs = [{globs}]\n",
        )
        atomic_write(stage / "lean-toolchain", lean_toolchain.strip() + "\n")
        atomic_write(stage / ".agda2lean/plan.tsv", render_plan(plan))
        atomic_write(stage / ".agda2lean/files.sha256", workspace_hashes(stage))

        if workspace.exists():
            marker = workspace / ".agda2lean/workspace"
            if not replace or not marker.is_file():
                raise ProjectError(
                    f"refusing to replace {workspace}; pass --replace and use an existing generated workspace"
                )
            shutil.rmtree(workspace)
        os.replace(stage, workspace)
    except BaseException:
        shutil.rmtree(stage, ignore_errors=True)
        raise


def run_lake(workspace: pathlib.Path, lake: str) -> None:
    subprocess.run([lake, "update"], cwd=workspace, check=True)
    subprocess.run([lake, "build"], cwd=workspace, check=True)


def common_parser(parser: argparse.ArgumentParser) -> None:
    parser.add_argument("--source-root", action="append", required=True, type=pathlib.Path)
    parser.add_argument("--entry", action="append", required=True)
    parser.add_argument("--platform-prefix", action="append", default=[])
    parser.add_argument("--external-prefix", action="append", default=[])


def build_plan(args: argparse.Namespace) -> Plan:
    roots = tuple(path.resolve() for path in args.source_root)
    modules = discover_modules(roots)
    entries = resolve_entries(args.entry, modules)
    prefixes = tuple(DEFAULT_PLATFORM_PREFIXES) + tuple(args.platform_prefix)
    return make_plan(modules, entries, prefixes, tuple(args.external_prefix))


def main(argv: Sequence[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    subparsers = parser.add_subparsers(dest="command", required=True)
    plan_parser = subparsers.add_parser("plan", help="print a deterministic closure/frontier plan")
    common_parser(plan_parser)
    plan_parser.add_argument("--output", type=pathlib.Path)

    build_parser = subparsers.add_parser(
        "build", help="extract a project closure and emit a self-contained Lake workspace"
    )
    common_parser(build_parser)
    build_parser.add_argument("--backend", required=True, type=pathlib.Path)
    build_parser.add_argument("--emitter", required=True, type=pathlib.Path)
    build_parser.add_argument("--workspace", required=True, type=pathlib.Path)
    build_parser.add_argument("--cache-root", type=pathlib.Path, default=pathlib.Path("build/cache"))
    build_parser.add_argument("--include-dir", action="append", default=[], type=pathlib.Path)
    build_parser.add_argument("--jobs", type=int, default=max(1, min(4, os.cpu_count() or 1)))
    build_parser.add_argument("--toolchain-id")
    build_parser.add_argument("--lean-toolchain", default="leanprover/lean4:v4.28.0")
    build_parser.add_argument(
        "--allow-reconstruction",
        action="store_true",
        help="legacy/testing only: opt into sorry-backed reconstruction; default is fail-closed",
    )
    build_parser.add_argument("--replace", action="store_true")
    build_parser.add_argument("--lake", help="run this Lake executable after workspace generation")

    args = parser.parse_args(argv)
    try:
        plan = build_plan(args)
        if args.command == "plan":
            rendered = render_plan(plan)
            if args.output:
                atomic_write(args.output, rendered)
            else:
                sys.stdout.write(rendered)
            return 0

        if args.jobs < 1:
            raise ProjectError("--jobs must be positive")
        backend = args.backend.resolve()
        emitter = args.emitter.resolve()
        toolchain_key = toolchain_fingerprint(backend, args.toolchain_id)
        source_key = source_fingerprint(plan)
        cache = prepare_cache(plan, args.cache_root.resolve(), toolchain_key, source_key)
        print(f"cache: {cache}")
        extract_frontiers(
            plan,
            cache,
            backend,
            tuple(path.resolve() for path in args.include_dir),
            args.jobs,
        )
        emit_workspace(
            plan,
            cache,
            emitter,
            args.workspace.resolve(),
            args.lean_toolchain,
            args.jobs,
            args.allow_reconstruction,
            args.replace,
        )
        if args.lake:
            run_lake(args.workspace.resolve(), args.lake)
        print(f"workspace: {args.workspace.resolve()}")
        return 0
    except (ProjectError, OSError, subprocess.SubprocessError) as error:
        print(f"a2l-project: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
