#!/usr/bin/env bash
set -euo pipefail

root_dir="$(git rev-parse --show-toplevel)"
manifest="${root_dir}/test/conformance/manifest.tsv"

allowed='^(supported-correspondence|reconstruction-boundary|deliberately-unsupported|unclassified)$'
seen="$(mktemp)"
trap 'rm -f "${seen}"' EXIT

tail -n +2 "${manifest}" |
  while IFS=$'\t' read -r id source expected phase features oracle rationale; do
    [[ -n "${id}" && -n "${source}" && -n "${expected}" && -n "${phase}" && -n "${features}" && -n "${rationale}" ]] || {
      echo "incomplete conformance row: ${id}" >&2
      exit 1
    }
    [[ "${expected}" =~ ${allowed} ]] || {
      echo "invalid conformance classification for ${id}: ${expected}" >&2
      exit 1
    }
    [[ -f "${root_dir}/${source}" ]] || {
      echo "missing conformance source for ${id}: ${source}" >&2
      exit 1
    }
    if [[ "${expected}" == "supported-correspondence" ]]; then
      [[ "${oracle}" != "-" && -f "${root_dir}/${oracle}" ]] || {
        echo "supported case lacks a Lean oracle: ${id}" >&2
        exit 1
      }
    fi
    if grep -Fxq "${id}" "${seen}"; then
      echo "duplicate conformance case id: ${id}" >&2
      exit 1
    fi
    printf '%s\n' "${id}" >> "${seen}"
  done

echo "conformance manifest policy check passed"
