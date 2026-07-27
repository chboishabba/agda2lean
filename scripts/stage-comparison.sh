#!/usr/bin/env bash
set -euo pipefail

root_dir="$(git rev-parse --show-toplevel)"
generated_src="${root_dir}/build/moonshine-lean"
handwritten_src="${root_dir}/../dashi_lean4"
comparison_dir="${root_dir}/comparison"
generated_dir="${comparison_dir}/generated"
handwritten_dir="${comparison_dir}/fixtures/handwritten"

if [[ ! -d "${generated_src}" ]]; then
  echo "missing generated Lean tree: ${generated_src}" >&2
  exit 1
fi

if [[ ! -f "${generated_src}/Moonshine.lean" ]]; then
  echo "missing Moonshine generated Lean output: ${generated_src}/Moonshine.lean" >&2
  exit 1
fi

if [[ ! -f "${handwritten_src}/Moonshine.lean" ]]; then
  echo "missing handwritten Lean mirror: ${handwritten_src}/Moonshine.lean" >&2
  exit 1
fi

mkdir -p "${generated_dir}" "${handwritten_dir}/AgdaMirror" "${comparison_dir}/Agda" "${comparison_dir}/AgdaMirror"

rsync -a --delete "${generated_src}/" "${generated_dir}/"
install -m 0644 "${handwritten_src}/Moonshine.lean" "${handwritten_dir}/AgdaMirror/Moonshine.lean"

ln -sfn "generated/Moonshine.lean" "${comparison_dir}/Moonshine.lean"
mkdir -p "${comparison_dir}/Agda/Builtin"
ln -sfn "../generated/Agda/Primitive.lean" "${comparison_dir}/Agda/Primitive.lean"
ln -sfn "../../generated/Agda/Builtin/Bool.lean" "${comparison_dir}/Agda/Builtin/Bool.lean"
ln -sfn "../../generated/Agda/Builtin/Equality.lean" "${comparison_dir}/Agda/Builtin/Equality.lean"
ln -sfn "../../generated/Agda/Builtin/Nat.lean" "${comparison_dir}/Agda/Builtin/Nat.lean"
ln -sfn "../fixtures/handwritten/AgdaMirror/Moonshine.lean" "${comparison_dir}/AgdaMirror/Moonshine.lean"

echo "staged Moonshine comparison workspace under ${comparison_dir}"
