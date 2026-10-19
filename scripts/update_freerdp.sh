#!/usr/bin/env bash
set -euo pipefail
task_version="${1:?Usage: update_freerdp.sh 3.x.y}"
if [[ ! "$task_version" =~ ^3\.[0-9]+\.[0-9]+$ ]]; then
  printf '%s\n' 'Choose an explicit reviewed FreeRDP 3 release tag.' >&2; exit 1
fi
task_root="$(cd "$(dirname "$0")/.." && pwd)"
task_module="$task_root/third_party/FreeRDP"
if [[ -n "$(git -C "$task_module" status --porcelain)" ]]; then
  printf '%s\n' 'FreeRDP has local changes; preserve them before updating.' >&2; exit 1
fi
git -C "$task_module" fetch --depth 1 origin "refs/tags/$task_version:refs/tags/$task_version"
git -C "$task_module" checkout --detach "$task_version"
printf '%s\n' 'Submodule pointer updated. Rebuild and run the checks in docs/BUILDING.md, then review git diff and stage the pointer.'
