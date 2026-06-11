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

missing_flock_path="$tmpdir/no-flock-bin"
mkdir -p "$missing_flock_path"
ln -s "$(command -v readlink)" "$missing_flock_path/readlink"
missing_flock_err="$tmpdir/missing-flock.err"
if PATH="$missing_flock_path" /bin/bash "$remote_deploy" \
  --docroot "$tmpdir/no-flock-docroot" \
  --deployment-id site-prod \
  --release-id no-flock-release \
  --keep-releases 1 \
  2>"$missing_flock_err"; then
  fail "deploy should fail when flock is unavailable"
fi
grep -Fq "flock is required" "$missing_flock_err" || fail "missing flock failure should be explicit"

flock_shim_dir="$tmpdir/bin"
mkdir -p "$flock_shim_dir"
cat >"$flock_shim_dir/flock" <<'SH'
#!/usr/bin/env bash
set -euo pipefail

operation="lock"
if [[ "${1:-}" == "-x" ]]; then
  shift
elif [[ "${1:-}" == "-u" ]]; then
  operation="unlock"
  shift
fi

fd="${1:-}"
[[ "$fd" =~ ^[0-9]+$ ]] || {
  echo "test flock shim: fd argument required" >&2
  exit 64
}

python3 - "$operation" "$fd" <<'PY'
import fcntl
import sys

operation = sys.argv[1]
fd = int(sys.argv[2])
flag = fcntl.LOCK_UN if operation == "unlock" else fcntl.LOCK_EX
fcntl.flock(fd, flag)
PY
SH
chmod +x "$flock_shim_dir/flock"
export PATH="$flock_shim_dir:$PATH"

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
assert_symlink_target "$base/current" "releases/20260611010404-d"
[[ ! -e "$base/incoming/20260611010404-d" ]] || fail "locked deploy did not promote release"

mkdir -p "$base/incoming/z-release" "$base/incoming/a-release"
printf 'zulu\n' >"$base/incoming/z-release/index.php"
printf 'active\n' >"$base/incoming/a-release/index.php"

run_remote_deploy z-release 1
run_remote_deploy a-release 1
assert_symlink_target "$base/current" "releases/a-release"
[[ -d "$base/releases/a-release" ]] || fail "active release should not be pruned"
