#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

"$repo_root/tests/test_action_metadata.sh"
"$repo_root/tests/test_deploy_input_transport.sh"
"$repo_root/tests/test_remote_deploy_layout.sh"
"$repo_root/tests/test_remote_deploy_claims.sh"

for script in "$repo_root"/scripts/*.sh; do
  [[ -e "$script" ]] || continue
  bash -n "$script"
done

if command -v shellcheck >/dev/null 2>&1; then
  shellcheck "$repo_root"/scripts/*.sh "$repo_root"/tests/*.sh
else
  echo "shellcheck not found; skipping shell lint" >&2
fi
