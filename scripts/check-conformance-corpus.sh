#!/usr/bin/env bash
set -euo pipefail

root_dir="$(git rev-parse --show-toplevel)"
manifest="${root_dir}/test/conformance/manifest.tsv"
cabal_wrapper="${root_dir}/scripts/cabal-agda-2.9.sh"
workspace="$(mktemp -d)"
cleanup() {
  rm -rf "${workspace}"
}
trap cleanup EXIT

bash "${root_dir}/scripts/check-conformance-manifest.sh"
"${cabal_wrapper}" build --flag agda-backend exe:agda2lean-agda exe:agda2lean-support
backend_bin="$("${cabal_wrapper}" list-bin --flag agda-backend exe:agda2lean-agda)"
support_bin="$("${cabal_wrapper}" list-bin --flag agda-backend exe:agda2lean-support)"

# Boundary cases are retained as declared negative fixtures. They may need
# feature-specific libraries or flags, so this first cut does not silently
# reinterpret an elaboration failure as semantic detection.
tail -n +2 "${manifest}" |
  while IFS=$'\t' read -r id source expected phase features oracle rationale; do
    source_path="${root_dir}/${source}"

    if [[ "${phase}" == "boundary" ]]; then
      printf 'DECLARED\t%s\t%s\t%s\n' "${id}" "${expected}" "${source}"
      continue
    fi

    case_dir="${workspace}/${id}"
    mkdir -p "${case_dir}"
    if ! "${backend_bin}" \
      --lean-ir \
      --compile-dir="${case_dir}" \
      -i "${root_dir}/test/conformance" \
      "${source_path}" >"${case_dir}/backend.log" 2>&1; then
      printf 'FAIL\t%s\telaboration-or-extraction\t%s\n' "${id}" "${source}" >&2
      cat "${case_dir}/backend.log" >&2
      exit 1
    fi

    cbor_path="$(find "${case_dir}" -name 'module.a2l.cbor' -type f -print | sort | tail -n 1)"
    if [[ -z "${cbor_path}" ]]; then
      echo "no ModuleIR produced for ${id}" >&2
      exit 1
    fi

    report_path="${case_dir}/support.tsv"
    "${support_bin}" --input "${cbor_path}" --output "${report_path}"
    overall="$(awk -F '\t' '$1 == "# overall" { print $2 }' "${report_path}")"

    # A survey may be stricter than the manifest expectation as new unsupported
    # evidence is discovered. It may never silently be more permissive.
    if [[ "${expected}" == "deliberately-unsupported" && "${overall}" != "deliberately-unsupported" ]]; then
      printf 'FAIL\t%s\texpected=%s\tobserved=%s\n' "${id}" "${expected}" "${overall}" >&2
      exit 1
    fi

    printf 'SURVEY\t%s\texpected=%s\tobserved=%s\t%s\n' \
      "${id}" "${expected}" "${overall}" "${report_path}"
  done

echo "conformance corpus survey passed"
