#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
action_file="$repo_root/action.yml"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

[[ -f "$action_file" ]] || fail "action.yml must exist"
[[ -f "$repo_root/scripts/deploy.sh" ]] || fail "scripts/deploy.sh must exist"
[[ -x "$repo_root/scripts/deploy.sh" ]] || fail "scripts/deploy.sh must be executable"
[[ -f "$repo_root/scripts/remote-deploy.sh" ]] || fail "scripts/remote-deploy.sh must exist"
[[ -x "$repo_root/scripts/remote-deploy.sh" ]] || fail "scripts/remote-deploy.sh must be executable"

for script in "$repo_root/scripts/deploy.sh" "$repo_root/scripts/remote-deploy.sh"; do
  "$script" --help >/dev/null
  "$script" --version >/dev/null
done

for input in host username password docroot source keep-releases post-deploy deployment-id; do
  grep -Eq "^[[:space:]]{2}${input}:" "$action_file" || fail "missing input: $input"
done

grep -Eq "^[[:space:]]{2}using:[[:space:]]+'?composite'?" "$action_file" || fail "action must use composite runs"
grep -Fq "scripts/deploy.sh" "$action_file" || fail "action must call scripts/deploy.sh"
