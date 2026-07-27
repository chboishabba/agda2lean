#!/usr/bin/env bash
set -euo pipefail

# Derive the inventory from the pinned Agda source rather than maintaining a
# second hand-written list in this repository.  AGDA_SOURCE_DIR may point at
# an unpacked Agda checkout; otherwise use Cabal's local source cache.
root_dir="$(git rev-parse --show-toplevel)"
agda_source_dir="${AGDA_SOURCE_DIR:-}"

if [[ -z "${agda_source_dir}" ]]; then
  agda_builtin_file="$(find "${root_dir}/dist-newstyle/src" -path '*/src/full/Agda/Syntax/Builtin.hs' -type f -print 2>/dev/null | sort | tail -n 1 || true)"
else
  agda_builtin_file="${agda_source_dir}/src/full/Agda/Syntax/Builtin.hs"
fi

if [[ -z "${agda_builtin_file}" || ! -f "${agda_builtin_file}" ]]; then
  echo "Agda source not found; set AGDA_SOURCE_DIR or run the Agda-enabled Cabal build first" >&2
  exit 2
fi

output_path="${1:--}"
temporary_path="$(mktemp)"
cleanup() {
  rm -f "${temporary_path}"
}
trap cleanup EXIT

awk '
  /^data BuiltinId$/ { section = "builtin"; next }
  /^data PrimitiveId$/ { section = "primitive"; next }
  section != "" && /^  deriving / { section = ""; next }
  section != "" && /^  \| [A-Z][A-Za-z0-9_ω]*/ {
    name = $1
    name = $2
    print section "\t" name
  }
' "${agda_builtin_file}" | sort -k1,1 -k2,2 > "${temporary_path}"

printf 'source\t%s\n' "${agda_builtin_file}"
printf 'kind\tconstructor\tregistration\n'
while IFS=$'\t' read -r kind constructor; do
  agda_name="${constructor:0:1}
${constructor:1}"
  agda_name="$(printf '%s' "${agda_name}" | awk 'NR == 1 { printf tolower($0) } NR == 2 { print }')"
  if rg -q "AgdaBuiltin\\.${agda_name}([,)]|$)" "${root_dir}/agda-backend/Main.hs"; then
    registration="registered"
  else
    registration="unsupported-or-unmapped"
  fi
  printf '%s\t%s\t%s\n' "${kind}" "${constructor}" "${registration}"
done < "${temporary_path}" > "${temporary_path}.out"

if [[ "${output_path}" == "-" ]]; then
  cat "${temporary_path}.out"
else
  mkdir -p "$(dirname "${output_path}")"
  atomic_path="$(mktemp "$(dirname "${output_path}")/.builtin-inventory.XXXXXX")"
  cp "${temporary_path}.out" "${atomic_path}"
  mv "${atomic_path}" "${output_path}"
fi

total="$(wc -l < "${temporary_path}.out")"
registered="$(awk -F '\t' '$3 == "registered" { count++ } END { print count + 0 }' "${temporary_path}.out")"
printf 'inventory-summary\ttotal=%s\tregistered=%s\tunmapped=%s\n' "${total}" "${registered}" "$((total - registered))" >&2
