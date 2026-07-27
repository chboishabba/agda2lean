#!/usr/bin/env bash
set -euo pipefail

root_dir="$(git rev-parse --show-toplevel)"
cabal_wrapper="${root_dir}/scripts/cabal-agda-2.9.sh"

"${cabal_wrapper}" build --flag agda-backend exe:agda2lean-agda
backend_bin="$("${cabal_wrapper}" list-bin --flag agda-backend exe:agda2lean-agda)"

# The backend writes reproducible .agdai/.cbor artifacts beside the fixture;
# both extensions are ignored by the repository. Keep the command identical
# to the normal Agda invocation so this is also an end-to-end smoke test.
"${backend_bin}" \
  --lean-ir \
  -i "${root_dir}/test/agda" \
  "${root_dir}/test/agda/Identity.agda"

echo "Agda 2.9 backend check passed"
