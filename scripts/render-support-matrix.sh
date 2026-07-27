#!/usr/bin/env bash
set -euo pipefail

root_dir="$(git rev-parse --show-toplevel)"
manifest="${1:-${root_dir}/test/conformance/manifest.tsv}"

if [[ ! -f "${manifest}" ]]; then
  echo "conformance manifest not found: ${manifest}" >&2
  exit 2
fi

printf '| Case | Phase | Expected classification | Features | Oracle |\n'
printf '|---|---|---|---|---|\n'
tail -n +2 "${manifest}" |
  while IFS=$'\t' read -r id source expected phase features oracle rationale; do
    printf '| `%s` | %s | `%s` | %s | %s |\n' \
      "${id}" "${phase}" "${expected}" "${features}" "${oracle}"
  done
