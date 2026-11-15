#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
lean_bin="${A2L_LEAN_BIN:-$(command -v lean || true)}"
if [[ -z "${lean_bin}" || ! -x "${lean_bin}" ]]; then
  echo "Lean 4.28 executable required (set A2L_LEAN_BIN or enter pinned Nix shell)" >&2
  exit 127
fi
version="$("${lean_bin}" --version)"
if [[ "${version}" != *"version 4.28.0"* ]]; then
  printf 'Expected pinned Lean 4.28.0; got %s\n' "${version}" >&2
  exit 2
fi
"${lean_bin}" "${root}/lean/Agda2Lean/TranslationQuality.lean"
echo "quality logical-relation kernel check passed (compiler instantiation NOT established)"
