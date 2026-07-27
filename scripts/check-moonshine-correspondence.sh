#!/usr/bin/env bash
set -euo pipefail

root_dir="$(git rev-parse --show-toplevel)"
comparison_dir="${root_dir}/comparison"
lake_bin="${root_dir}/.elan/toolchains/leanprover--lean4---v4.28.0/bin/lake"

# shellcheck source=scripts/lib/progress.sh
source "${root_dir}/scripts/lib/progress.sh"

if [[ ! -x "${lake_bin}" ]]; then
  lake_bin="lake"
fi

if [[ ! -f "${comparison_dir}/Moonshine.lean" ]]; then
  "${root_dir}/scripts/stage-comparison.sh"
fi

cd "${comparison_dir}"

progress_run "moonshine / lake update" "${lake_bin}" update
progress_run "moonshine / lake build" "${lake_bin}" build

generated_manifest="$(mktemp)"
handwritten_manifest="$(mktemp)"
normalized_generated="$(mktemp)"
normalized_handwritten="$(mktemp)"

cleanup() {
  rm -f \
    "${generated_manifest}" \
    "${handwritten_manifest}" \
    "${normalized_generated}" \
    "${normalized_handwritten}"
}

trap cleanup EXIT

generated_constants=(
  'Moonshine.moonshine'
  'Moonshine.«rep-dim-check»'
  'Moonshine.mckay'
  'Moonshine.«observer-is-j-fixed»'
  'Moonshine.embedding'
)

handwritten_constants=(
  'AgdaMirror.Moonshine.moonshine'
  'AgdaMirror.Moonshine.rep_dim_check'
  'AgdaMirror.Moonshine.mckay'
  'AgdaMirror.Moonshine.observer_is_j_fixed'
  'AgdaMirror.Moonshine.embedding'
)

progress_run "moonshine / generated manifest" \
  "${lake_bin}" env lean --run "${root_dir}/lean/Agda2Lean/Manifest.lean" \
    --module Moonshine \
    "${generated_constants[@]}" > "${generated_manifest}"

progress_run "moonshine / handwritten manifest" \
  "${lake_bin}" env lean --run "${root_dir}/lean/Agda2Lean/Manifest.lean" \
    --module AgdaMirror.Moonshine \
    "${handwritten_constants[@]}" > "${handwritten_manifest}"

normalize_manifest() {
  awk -F'\t' -v OFS='\t' '
    function canonical(name,    normalized) {
      normalized = name
      gsub(/«|»/, "", normalized)
      sub(/^AgdaMirror\./, "", normalized)
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
      } else if (normalized == "Moonshine.the_observer") {
        normalized = "Moonshine.the-observer"
      } else if (normalized == "Moonshine.is_j_fixed") {
        normalized = "Moonshine.is-j-fixed"
      } else if (normalized == "Moonshine.observer_is_j_fixed") {
        normalized = "Moonshine.observer-is-j-fixed"
      } else if (normalized == "Moonshine.rep_dim_check") {
        normalized = "Moonshine.rep-dim-check"
      }
      return normalized
    }
    NR == 1 { next }
    $2 == "type-direct" || $2 == "value-direct" || $2 == "axiom-closure" {
      $1 = canonical($1)
      if ($3 != "") {
        $3 = canonical($3)
      }
      print
    }
  ' "$1" | sort -u
}

normalize_manifest "${generated_manifest}" > "${normalized_generated}"
normalize_manifest "${handwritten_manifest}" > "${normalized_handwritten}"

relation_values() {
  local file="$1"
  local declaration="$2"
  local relation="$3"
  awk -F'\t' -v decl="${declaration}" -v relation="${relation}" '
    $1 == decl && $2 == relation {
      print $3
    }
  ' "${file}" | sort -u
}

comparison_values() {
  local file="$1"
  local declaration="$2"
  local relation="$3"
  case "${relation}" in
    type-direct)
      relation_values "${file}" "${declaration}" "${relation}" | grep -Ev '^(Nat$|inst|Moonshine\.observer$)' || true
      ;;
    *)
      relation_values "${file}" "${declaration}" "${relation}"
      ;;
  esac
}

join_lines() {
  if [[ -n "$1" ]]; then
    printf '%s\n' "$1" | paste -sd, -
  fi
}

has_sorry_axiom() {
  local file="$1"
  local declaration="$2"
  relation_values "${file}" "${declaration}" "axiom-closure" | grep -qx 'Lean.sorryAx'
}

compare_sets() {
  local left="$1"
  local right="$2"
  diff -u <(printf '%s\n' "${left}" | sed '/^$/d') <(printf '%s\n' "${right}" | sed '/^$/d') >/dev/null
}

printf 'declaration\tfacet\tstatus\tdetails\n'

overall_status=0
declarations=(
  'Moonshine.moonshine'
  'Moonshine.rep-dim-check'
  'Moonshine.mckay'
  'Moonshine.observer-is-j-fixed'
  'Moonshine.embedding'
)

for declaration in "${declarations[@]}"; do
  generated_type_direct="$(comparison_values "${normalized_generated}" "${declaration}" "type-direct")"
  handwritten_type_direct="$(comparison_values "${normalized_handwritten}" "${declaration}" "type-direct")"
  generated_value_direct="$(relation_values "${normalized_generated}" "${declaration}" "value-direct")"
  handwritten_value_direct="$(relation_values "${normalized_handwritten}" "${declaration}" "value-direct")"
  generated_axioms="$(relation_values "${normalized_generated}" "${declaration}" "axiom-closure")"
  handwritten_axioms="$(relation_values "${normalized_handwritten}" "${declaration}" "axiom-closure")"

  printf '%s\tstatement\tpass\tgenerated and handwritten declarations elaborated\n' "${declaration}"

  if compare_sets "${generated_type_direct}" "${handwritten_type_direct}" >/dev/null; then
    printf '%s\ttype-dependencies\tpass\tgenerated=%s; handwritten=%s\n' \
      "${declaration}" \
      "$(join_lines "${generated_type_direct}")" \
      "$(join_lines "${handwritten_type_direct}")"
  else
    printf '%s\ttype-dependencies\tfail\tgenerated=%s; handwritten=%s\n' \
      "${declaration}" \
      "$(join_lines "${generated_type_direct}")" \
      "$(join_lines "${handwritten_type_direct}")"
    overall_status=1
  fi

  if has_sorry_axiom "${normalized_generated}" "${declaration}" || \
      has_sorry_axiom "${normalized_handwritten}" "${declaration}"; then
    printf '%s\taxioms\tfail\tLean.sorryAx detected in the axiom closure\n' "${declaration}"
    overall_status=1
  else
    printf '%s\taxioms\tpass\tgenerated=%s; handwritten=%s\n' \
      "${declaration}" \
      "$(join_lines "${generated_axioms}")" \
      "$(join_lines "${handwritten_axioms}")"
  fi

  printf '%s\tcomputation\tinfo\tgenerated=%s; handwritten=%s\n' \
    "${declaration}" \
    "$(join_lines "${generated_value_direct}")" \
    "$(join_lines "${handwritten_value_direct}")"

  if compare_sets "${generated_type_direct}" "${handwritten_type_direct}" >/dev/null && \
      ! has_sorry_axiom "${normalized_generated}" "${declaration}" && \
      ! has_sorry_axiom "${normalized_handwritten}" "${declaration}"; then
    printf '%s\tpromotion\tready\ttype and axiom checks passed\n' "${declaration}"
  else
    printf '%s\tpromotion\tblocked\twaiting on type or axiom correspondence\n' "${declaration}"
  fi
done

if [[ ${overall_status} -eq 0 ]]; then
  printf 'moonshine correspondence gate passed\n'
else
  printf 'moonshine correspondence gate failed\n' >&2
fi

exit "${overall_status}"
