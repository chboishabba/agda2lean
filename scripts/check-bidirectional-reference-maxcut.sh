#!/usr/bin/env bash
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${root}"

# This gate checks the semantic reference mathematics and safety controls.
# It does NOT execute a real two-translator cycle or close M01–M07.
PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s scripts \
  -p 'test_bidirectional_conformance.py' -v
PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s scripts \
  -p 'test_run_bidirectional_cycle.py' -v

bash scripts/check-translation-quality.sh
backend="$(scripts/cabal-agda-2.9.sh list-bin --flag agda-backend exe:agda2lean-agda)"
if [[ -z "${backend}" || ! -x "${backend}" ]]; then
  echo "Pinned Agda 2.9 backend missing; build it before certification" >&2
  exit 127
fi
"${backend}" -j2 test/agda/TranslationQuality.agda
echo "Reference-only max-cut passed; real emitted-code correspondence remains OPEN"
