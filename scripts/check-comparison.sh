#!/usr/bin/env bash
set -euo pipefail

root_dir="$(git rev-parse --show-toplevel)"
comparison_dir="${root_dir}/comparison"
lake_bin="${root_dir}/.elan/toolchains/leanprover--lean4---v4.28.0/bin/lake"

if [[ ! -x "${lake_bin}" ]]; then
  lake_bin="lake"
fi

if [[ ! -f "${comparison_dir}/Moonshine.lean" ]]; then
  "${root_dir}/scripts/stage-comparison.sh"
fi

cd "${comparison_dir}"
"${lake_bin}" update
"${lake_bin}" build

generated_receipt="$(mktemp)"
normalized_generated="$(mktemp)"
golden_receipt="${comparison_dir}/receipts/moonshine.receipt.tsv"

cleanup() {
  rm -f "${generated_receipt}" "${normalized_generated}"
}

trap cleanup EXIT

generated_constants=(
  'Moonshine.moonshine'
  'Moonshine.«rep-dim-check»'
  'Moonshine.mckay'
  'Moonshine.«observer-is-j-fixed»'
  'Moonshine.embedding'
)

"${lake_bin}" env lean --run "${root_dir}/lean/Agda2Lean/Manifest.lean" \
  --module Moonshine \
  "${generated_constants[@]}" > "${generated_receipt}"

normalize_receipt() {
  awk -F'\t' -v OFS='\t' '
    function canonical(name,    normalized) {
      normalized = name
      gsub(/«|»/, "", normalized)
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
      } else if (normalized == "Agda.Builtin.Nat._+_") {
        normalized = "HAdd.hAdd"
      } else if (normalized == "Agda.Builtin.Nat._-_") {
        normalized = "HSub.hSub"
      } else if (normalized == "Agda.Builtin.Nat._*_") {
        normalized = "HMul.hMul"
      } else if (normalized == "Agda.Builtin.Nat._==_") {
        normalized = "BEq.beq"
      } else if (normalized == "Agda.Builtin.Nat._<_") {
        normalized = "LT.lt"
      } else if (normalized == "Agda.Builtin.Nat.div-helper") {
        normalized = "Nat.divHelper"
      } else if (normalized == "Agda.Builtin.Nat.mod-helper") {
        normalized = "Nat.modHelper"
      } else if (normalized == "Agda.Builtin.Nat.instOfNatNat") {
        normalized = "instOfNatNat"
      }
      if (normalized == "Moonshine.trivectorProduct") {
        normalized = "Moonshine.trivector-product"
      } else if (normalized == "Moonshine.jCoefficient") {
        normalized = "Moonshine.j-coefficient"
      } else if (normalized == "Moonshine.repDim") {
        normalized = "Moonshine.rep-dim"
      } else if (normalized == "Moonshine.theObserver") {
        normalized = "Moonshine.the-observer"
      } else if (normalized == "Moonshine.isJFixed") {
        normalized = "Moonshine.is-j-fixed"
      } else if (normalized == "Moonshine.observerIsJFixed") {
        normalized = "Moonshine.observer-is-j-fixed"
      } else if (normalized == "Moonshine.rep_dim_check") {
        normalized = "Moonshine.rep-dim-check"
      }
      return normalized
    }
    NR == 1 { next }
    $2 == "type-direct" || $2 == "axiom-closure" {
      $1 = canonical($1)
      if ($3 != "") {
        $3 = canonical($3)
      }
      print
    }
  ' "$1" | sort
}

normalize_receipt "${generated_receipt}" > "${normalized_generated}"

if ! diff -u "${golden_receipt}" "${normalized_generated}"; then
  echo "comparison receipt mismatch" >&2
  exit 1
fi

echo "comparison receipt matched the Moonshine golden"
