#!/usr/bin/env bash
set -euo pipefail

root_dir="$(git rev-parse --show-toplevel)"
cabal_wrapper="${root_dir}/scripts/cabal-agda-2.9.sh"
driver="${root_dir}/scripts/a2l_project.py"
gate_root="${A2L_JFIXEDPOINT_BUILD_DIR:-${root_dir}/build/jfixedpoint-gate}"
cache_root="${A2L_CACHE_DIR:-${root_dir}/build/cache}"
jobs="${A2L_JOBS:-2}"
lake_bin="${root_dir}/.elan/toolchains/leanprover--lean4---v4.28.0/bin/lake"

# shellcheck source=scripts/lib/progress.sh
source "${root_dir}/scripts/lib/progress.sh"

if [[ ! -x "${lake_bin}" ]]; then
  lake_bin="$(command -v lake || true)"
fi
if [[ -z "${lake_bin}" ]]; then
  echo "Lean 4.28 Lake is required; run from nix develop or install the pinned lean-toolchain" >&2
  exit 127
fi

progress_run "jfixedpoint / build compilers" \
  "${cabal_wrapper}" build --flag agda-backend exe:agda2lean-agda exe:agda2lean
backend_bin="$("${cabal_wrapper}" list-bin --flag agda-backend exe:agda2lean-agda)"
emitter_bin="$("${cabal_wrapper}" list-bin --flag agda-backend exe:agda2lean)"

generate() {
  local workspace="$1"
  progress_run "jfixedpoint / generate $(basename "${workspace}")" \
    "${driver}" build \
      --source-root "${root_dir}/test/agda" \
      --entry JFixedPoint \
      --backend "${backend_bin}" \
      --emitter "${emitter_bin}" \
      --workspace "${workspace}" \
      --cache-root "${cache_root}" \
      --jobs "${jobs}" \
      --lean-toolchain leanprover/lean4:v4.28.0 \
      --replace
}

workspace_one="${gate_root}/generated-one"
workspace_two="${gate_root}/generated-two"
generate "${workspace_one}"
generate "${workspace_two}"

progress_run "jfixedpoint / deterministic regeneration" \
  diff -u \
    "${workspace_one}/.agda2lean/files.sha256" \
    "${workspace_two}/.agda2lean/files.sha256"

jfixedpoint_source="${workspace_one}/JFixedPoint.lean"
if [[ ! -f "${jfixedpoint_source}" ]]; then
  echo "generated JFixedPoint.lean is missing" >&2
  exit 1
fi
if rg -n '(^|[[:space:]])(sorry|Lean\.sorryAx)([[:space:]]|$)|^axiom[[:space:]]' \
    "${jfixedpoint_source}"; then
  echo "generated JFixedPoint contains a forbidden sorry or axiom" >&2
  exit 1
fi

progress_run "jfixedpoint / lake update" bash -c \
  'cd "$1" && "$2" update' _ "${workspace_one}" "${lake_bin}"
progress_run "jfixedpoint / lake build" bash -c \
  'cd "$1" && "$2" build' _ "${workspace_one}" "${lake_bin}"
progress_run "jfixedpoint / computation reduction" bash -c \
  'cd "$1" && "$2" env lean "$3"' _ "${workspace_one}" "${lake_bin}" \
    "${root_dir}/test/lean/JFixedPointCheck.lean"

manifest="${gate_root}/jfixedpoint.manifest.tsv"
constants=(
  'JFixedPoint.Observation'
  'JFixedPoint.Observation.e47'
  'JFixedPoint.Observation.e59'
  'JFixedPoint.Observation.e71'
  'JFixedPoint.contract'
  'JFixedPoint.«unit-obs»'
  'JFixedPoint.«unit-converges»'
  'JFixedPoint.stack'
  'JFixedPoint.«fixed-0»'
  'JFixedPoint.«fixed-1»'
  'JFixedPoint.«fixed-2»'
  'JFixedPoint.«fixed-100»'
  'JFixedPoint.Tower'
  'JFixedPoint.expand'
  'JFixedPoint.«contract-all»'
  'JFixedPoint.«tower-1»'
  'JFixedPoint.«tower-3»'
  'JFixedPoint.«all-196884»'
)

progress_run "jfixedpoint / manifest and axiom closure" \
  bash -c 'cd "$1"; shift; exec "$@"' _ "${workspace_one}" \
    "${lake_bin}" env lean --run "${root_dir}/lean/Agda2Lean/Manifest.lean" \
      --module JFixedPoint "${constants[@]}" > "${manifest}"

unexpected_axioms="$(awk -F '\t' '$2 == "axiom-closure" && $3 != "" { print }' "${manifest}")"
if [[ -n "${unexpected_axioms}" ]]; then
  printf '%s\n' "${unexpected_axioms}" >&2
  echo "generated JFixedPoint has an unexpected theorem axiom closure" >&2
  exit 1
fi

receipt="${gate_root}/jfixedpoint.correspondence.tsv"
progress_run "jfixedpoint / dependency correspondence receipt" \
  "${root_dir}/scripts/jfixedpoint_receipt.py" \
    --lean-source "${jfixedpoint_source}" \
    --manifest "${manifest}" \
    --expected "${root_dir}/comparison/receipts/jfixedpoint.project-dependencies.tsv" \
    --output "${receipt}"

printf 'jfixedpoint gate passed: executable definitions, original public surface, computation, no axioms, deterministic regeneration\n'
