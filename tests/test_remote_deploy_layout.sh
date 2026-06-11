#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
remote_deploy="$repo_root/scripts/remote-deploy.sh"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

assert_file_contains() {
  local file="$1"
  local expected="$2"
  [[ -f "$file" ]] || fail "missing file: $file"
  grep -Fq -- "$expected" "$file" || fail "expected '$expected' in $file"
}

assert_symlink_target() {
  local link="$1"
  local expected="$2"
  [[ -L "$link" ]] || fail "expected symlink: $link"
  local target
  target="$(readlink "$link")"
  [[ "$target" == "$expected" ]] || fail "expected $link -> $expected, got $target"
}

run_remote_deploy() {
  "$remote_deploy" \
    --docroot "$docroot" \
    --deployment-id site-prod \
    --release-id "$1" \
    --keep-releases "$2"
}

tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT

docroot="$tmpdir/docroot"
base="$docroot/.github-ssh-deploy/deployments/site-prod"
mkdir -p "$base/incoming/20260611010101-a" "$base/incoming/20260611010202-b" "$base/incoming/20260611010303-c"
printf 'alpha\n' >"$base/incoming/20260611010101-a/index.php"
printf 'bravo\n' >"$base/incoming/20260611010202-b/index.php"
printf 'charlie\n' >"$base/incoming/20260611010303-c/index.php"

run_remote_deploy 20260611010101-a 2

[[ -d "$base/releases/20260611010101-a" ]] || fail "release directory was not created"
[[ ! -e "$base/incoming/20260611010101-a" ]] || fail "incoming release should be promoted away"
assert_file_contains "$base/releases/20260611010101-a/index.php" "alpha"
assert_symlink_target "$base/current" "releases/20260611010101-a"
[[ -f "$base/deploy.lock" ]] || fail "deploy lock file should exist"

run_remote_deploy 20260611010202-b 2
assert_symlink_target "$base/current" "releases/20260611010202-b"
[[ -d "$base/releases/20260611010101-a" ]] || fail "previous release should be retained"

run_remote_deploy 20260611010303-c 2
assert_symlink_target "$base/current" "releases/20260611010303-c"
[[ -d "$base/releases/20260611010202-b" ]] || fail "newer retained release missing"
[[ -d "$base/releases/20260611010303-c" ]] || fail "current release missing"
[[ ! -e "$base/releases/20260611010101-a" ]] || fail "old release should be pruned"

mkdir -p "$base/incoming/20260611010404-d"
printf 'delta\n' >"$base/incoming/20260611010404-d/index.php"
if command -v flock >/dev/null 2>&1; then
  (
    exec 8>"$base/deploy.lock"
    flock -x 8
    "$remote_deploy" \
      --docroot "$docroot" \
      --deployment-id site-prod \
      --release-id 20260611010404-d \
      --keep-releases 2 &
    child=$!
    sleep 0.2
    [[ -d "$base/incoming/20260611010404-d" ]] || fail "deploy should wait while lock is held"
    flock -u 8
    wait "$child"
  )
else
  mkdir "$base/deploy.lock.dir"
  "$remote_deploy" \
    --docroot "$docroot" \
    --deployment-id site-prod \
    --release-id 20260611010404-d \
    --keep-releases 2 &
  child=$!
  sleep 0.2
  [[ -d "$base/incoming/20260611010404-d" ]] || fail "deploy should wait while lock is held"
  rmdir "$base/deploy.lock.dir"
  wait "$child"
fi
assert_symlink_target "$base/current" "releases/20260611010404-d"
[[ ! -e "$base/incoming/20260611010404-d" ]] || fail "locked deploy did not promote release"
