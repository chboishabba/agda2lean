#!/usr/bin/env bash
set -euo pipefail

root_dir="$(git rev-parse --show-toplevel)"
comparison_dir="${root_dir}/comparison"
dashi_agda_root="${root_dir}/../dashi_agda"
dashi_lean_root="${root_dir}/../dashi_lean4"
cabal_wrapper="${root_dir}/scripts/cabal-agda-2.9.sh"
lake_bin="${root_dir}/.elan/toolchains/leanprover--lean4---v4.28.0/bin/lake"

# shellcheck source=scripts/lib/progress.sh
source "${root_dir}/scripts/lib/progress.sh"

if [[ ! -x "${lake_bin}" ]]; then
  lake_bin="lake"
fi

if [[ ! -f "${comparison_dir}/Moonshine.lean" ]]; then
  "${root_dir}/scripts/stage-comparison.sh"
fi

shadow_agda="$(mktemp -d)"
lakefile_backup="$(mktemp)"
lakefile_template="$(mktemp)"
generated_monsterstate="${comparison_dir}/generated/MonsterState.lean"
generated_list="${comparison_dir}/generated/Agda/Builtin/List.lean"
generated_root="${comparison_dir}/MonsterState.lean"
generated_list_root="${comparison_dir}/Agda/Builtin/List.lean"
handwritten_monsterwalk="${comparison_dir}/fixtures/handwritten/AgdaMirror/MonsterWalk.lean"
handwritten_ultrametric="${comparison_dir}/fixtures/handwritten/AgdaMirror/Ultrametric.lean"
handwritten_monsterwalk_root="${comparison_dir}/AgdaMirror/MonsterWalk.lean"
handwritten_ultrametric_root="${comparison_dir}/AgdaMirror/Ultrametric.lean"

cleanup() {
  rm -rf "${shadow_agda}"
  rm -f \
    "${generated_monsterstate}" \
    "${generated_list}" \
    "${generated_root}" \
    "${generated_list_root}" \
    "${handwritten_monsterwalk}" \
    "${handwritten_ultrametric}" \
    "${handwritten_monsterwalk_root}" \
    "${handwritten_ultrametric_root}"
  if [[ -f "${lakefile_backup}" ]]; then
    mv "${lakefile_backup}" "${comparison_dir}/lakefile.toml"
  fi
  rm -f "${lakefile_template}"
}

trap cleanup EXIT

mkdir -p "${shadow_agda}"
cp "${dashi_agda_root}/MonsterState.agda" "${shadow_agda}/MonsterState.agda"
printf 'name: shadow\ninclude: .\n' > "${shadow_agda}/shadow.agda-lib"

"${cabal_wrapper}" build --flag agda-backend exe:agda2lean-agda
backend_bin="$("${cabal_wrapper}" list-bin --flag agda-backend exe:agda2lean-agda)"

"${backend_bin}" \
  --lean-ir \
  --compile-dir "${shadow_agda}/out" \
  -i "${shadow_agda}" \
  "${shadow_agda}/MonsterState.agda"

generated_ir="${shadow_agda}/out/MonsterState/module.a2l.cbor"

mkdir -p "${comparison_dir}/generated/Agda/Builtin" "${comparison_dir}/fixtures/handwritten/AgdaMirror" "${comparison_dir}/Agda/Builtin" "${comparison_dir}/AgdaMirror"

cat > "${generated_list}" <<'EOF'
-- Temporary builtin shim for MonsterState correspondence checking.
-- This mirrors the imported Agda.Builtin.List module just enough for the
-- generated MonsterState Lean file to compile in the comparison workspace.

set_option autoImplicit false

namespace Agda.Builtin.List

abbrev List := _root_.List

def «[]» {α : Type} : List α := []

def «_∷_» {α : Type} (x : α) (xs : List α) : List α := x :: xs

def nil {α : Type} : List α := []

def cons {α : Type} (x : α) (xs : List α) : List α := x :: xs

end Agda.Builtin.List
EOF

cp "${dashi_lean_root}/MonsterWalk.lean" "${handwritten_monsterwalk}"
cp "${dashi_lean_root}/Ultrametric.lean" "${handwritten_ultrametric}"

ln -sfn "generated/MonsterState.lean" "${generated_root}"
ln -sfn "../../generated/Agda/Builtin/List.lean" "${generated_list_root}"
ln -sfn "../fixtures/handwritten/AgdaMirror/MonsterWalk.lean" "${handwritten_monsterwalk_root}"
ln -sfn "../fixtures/handwritten/AgdaMirror/Ultrametric.lean" "${handwritten_ultrametric_root}"

"${cabal_wrapper}" run agda2lean -- emit-lean \
  --input "${generated_ir}" \
  --lean-output "${generated_monsterstate}" \
  --diagnostics "${shadow_agda}/MonsterState.diag.tsv" \
  >/dev/null

git show HEAD:comparison/lakefile.toml > "${lakefile_template}"
cp "${lakefile_template}" "${comparison_dir}/lakefile.toml"
cp "${comparison_dir}/lakefile.toml" "${lakefile_backup}"
perl -0pi -e 's/globs = \["Moonshine", "Agda\.\+", "AgdaMirror\.\+"\]/globs = ["Moonshine", "MonsterState", "Agda.+", "AgdaMirror.+"]/;' \
  "${comparison_dir}/lakefile.toml"

cd "${comparison_dir}"

progress_run "monsterstate / lake update" "${lake_bin}" update
progress_run "monsterstate / lake build" "${lake_bin}" build

generated_manifest="$(mktemp)"
reference_manifest="$(mktemp)"
normalized_generated="$(mktemp)"
normalized_reference="$(mktemp)"

cleanup_manifests() {
  rm -f \
    "${generated_manifest}" \
    "${reference_manifest}" \
    "${normalized_generated}" \
    "${normalized_reference}"
}

trap 'cleanup_manifests; cleanup' EXIT

generated_constants=(
  'MonsterState.FactorCount'
  'MonsterState.Mask'
  'MonsterState.replicate'
  'MonsterState.fullMask'
  'MonsterState.emptyMask'
  'MonsterState.State'
  'MonsterState.State.mask'
  'MonsterState.State.window'
  'MonsterState.st'
  'MonsterState.Lens'
  'MonsterState.Lens.admissible'
  'MonsterState.Lens.constructor'
  'MonsterState.Candidates'
)

reference_constants=(
  'AgdaMirror.MonsterWalk.FactorCount'
  'AgdaMirror.MonsterWalk.Mask'
  'AgdaMirror.MonsterWalk.replicate'
  'AgdaMirror.MonsterWalk.fullMask'
  'AgdaMirror.MonsterWalk.emptyMask'
  'AgdaMirror.MonsterWalk.State'
  'AgdaMirror.MonsterWalk.State.mask'
  'AgdaMirror.MonsterWalk.State.window'
  'AgdaMirror.MonsterWalk.State.mk'
  'AgdaMirror.MonsterWalk.Lens'
  'AgdaMirror.MonsterWalk.Lens.admissible'
  'AgdaMirror.MonsterWalk.Lens.mk'
  'AgdaMirror.MonsterWalk.Candidates'
)

progress_run "monsterstate / generated manifest" \
  "${lake_bin}" env lean --run "${root_dir}/lean/Agda2Lean/Manifest.lean" \
    --module MonsterState \
    "${generated_constants[@]}" > "${generated_manifest}"

progress_run "monsterstate / reference manifest" \
  "${lake_bin}" env lean --run "${root_dir}/lean/Agda2Lean/Manifest.lean" \
    --module AgdaMirror.MonsterWalk \
    "${reference_constants[@]}" > "${reference_manifest}"

normalize_manifest() {
  awk -F'\t' -v OFS='\t' '
    function canonical(name,    normalized) {
      normalized = name
      gsub(/«|»/, "", normalized)
      sub(/^MonsterState\./, "", normalized)
      sub(/^AgdaMirror\.MonsterWalk\./, "", normalized)
      if (normalized == "Agda.Builtin.Bool.Bool") {
        normalized = "Bool"
      } else if (normalized == "Agda.Builtin.Bool.Bool.true") {
        normalized = "Bool.true"
      } else if (normalized == "Agda.Builtin.Bool.Bool.false") {
        normalized = "Bool.false"
      } else if (normalized == "Agda.Builtin.Equality._≡_") {
        normalized = "Eq"
      } else if (normalized == "Agda.Builtin.Equality._≡_.refl") {
        normalized = "Eq.refl"
      } else if (normalized == "Agda.Builtin.Nat.Nat") {
        normalized = "Nat"
      } else if (normalized == "Agda.Builtin.Nat.Nat.zero") {
        normalized = "Nat.zero"
      } else if (normalized == "Agda.Builtin.Nat.Nat.suc") {
        normalized = "Nat.succ"
      } else if (normalized == "Agda.Builtin.List.List") {
        normalized = "List"
      } else if (normalized == "Agda.Builtin.List.List.[]") {
        normalized = "List.nil"
      } else if (normalized == "Agda.Builtin.List.List._∷_") {
        normalized = "List.cons"
      } else if (normalized == "Agda.Builtin.List.[]") {
        normalized = "List.nil"
      } else if (normalized == "Agda.Builtin.List._∷_") {
        normalized = "List.cons"
      } else if (normalized == "st") {
        normalized = "State.mk"
      } else if (normalized == "Lens.constructor") {
        normalized = "Lens.mk"
      }
      return normalized
    }
    NR == 1 { next }
    $2 == "type-direct" || $2 == "value-direct" {
      $1 = canonical($1)
      print $1 "\t" $2
    }
  ' "$1" | sort -u
}

normalize_manifest "${generated_manifest}" > "${normalized_generated}"
normalize_manifest "${reference_manifest}" > "${normalized_reference}"

if ! diff -u "${normalized_reference}" "${normalized_generated}"; then
  echo "monsterstate correspondence receipt mismatch" >&2
  exit 1
fi

echo "monsterstate correspondence check passed"
