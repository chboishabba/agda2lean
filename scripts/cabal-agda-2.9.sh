#!/usr/bin/env bash
set -euo pipefail

# All Agda-backend Cabal operations must use the pinned Agda 2.9 project.
# This wrapper is intentionally transparent: every argument is passed through
# to Cabal after selecting the repository-local project file.
root_dir="$(git rev-parse --show-toplevel)"

if ! command -v cabal >/dev/null 2>&1; then
  echo "cabal is not on PATH; run this from 'nix develop' or install Cabal" >&2
  exit 127
fi

cd "${root_dir}"
exec cabal --project-file=cabal.project.agda-2.9 "$@"
