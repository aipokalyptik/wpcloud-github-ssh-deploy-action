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
    --exchange-helper "$exchange_helper" \
    --keep-releases "$2"
}

run_remote_deploy_with_post_deploy() {
  "$remote_deploy" \
    --docroot "$docroot" \
    --deployment-id site-prod \
    --release-id "$1" \
    --exchange-helper "$exchange_helper" \
    --keep-releases "$2" \
    --post-deploy-file "$3"
}

tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT

exchange_helper="$tmpdir/exchange-helper"
cat >"$exchange_helper" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
old="$1"
new="$2"
tmp="${old}.swap.$$"
mv -T -- "$old" "$tmp"
mv -T -- "$new" "$old"
mv -T -- "$tmp" "$new"
SH
chmod +x "$exchange_helper"
if [[ "$(uname -s)" == "Linux" && "$(uname -m)" == "x86_64" ]]; then
  exchange_helper="$repo_root/helpers/bin/linux-amd64/exchange-rename"
fi

mv_shim_dir="$tmpdir/mv-shim-bin"
mkdir -p "$mv_shim_dir"
cat >"$mv_shim_dir/mv" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
args=()
no_target=0
for arg in "$@"; do
  case "$arg" in
    -T|--no-target-directory) no_target=1 ;;
    *) args+=("$arg") ;;
  esac
done
if ((no_target)) && ((${#args[@]} >= 2)); then
  dest="${args[$((${#args[@]} - 1))]}"
  rm -rf -- "$dest"
fi
/bin/mv "${args[@]}"
SH
chmod +x "$mv_shim_dir/mv"
export PATH="$mv_shim_dir:$PATH"
original_path="$PATH"

switch_current_body="$(awk '/^switch_current\(\)/,/^}/' "$remote_deploy")"
if grep -Fq 'rm -f "$current"' <<<"$switch_current_body"; then
  fail "switch_current must not remove current before replacing it"
fi

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

PATH="$original_path"
if ! command -v flock >/dev/null 2>&1; then
  echo "flock not found; skipping layout tests that require real flock" >&2
  exit 0
fi

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
    --exchange-helper "$exchange_helper" \
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

post_docroot="$tmpdir/post-docroot"
post_base="$post_docroot/.github-ssh-deploy/deployments/site-prod"
docroot="$post_docroot"
base="$post_base"
mkdir -p "$post_base/incoming/20260611020101-a"
printf 'alpha\n' >"$post_base/incoming/20260611020101-a/index.php"
empty_post="$tmpdir/empty-post.sh"
: >"$empty_post"
run_remote_deploy_with_post_deploy 20260611020101-a 2 "$empty_post"
[[ ! -e "$post_docroot/post-marker" ]] || fail "empty post-deploy file should run nothing"

mkdir -p "$post_base/incoming/20260611020202-b"
printf 'bravo\n' >"$post_base/incoming/20260611020202-b/index.php"
success_post="$tmpdir/success-post.sh"
cat >"$success_post" <<'SH'
printf '%s\n' "$PWD" > post-marker
readlink .github-ssh-deploy/deployments/site-prod/current > current-marker
SH
run_remote_deploy_with_post_deploy 20260611020202-b 2 "$success_post"
assert_file_contains "$post_docroot/post-marker" "$post_docroot"
assert_file_contains "$post_docroot/current-marker" "releases/20260611020202-b"

mkdir -p "$post_base/incoming/20260611020303-c"
printf 'charlie\n' >"$post_base/incoming/20260611020303-c/index.php"
ordered_post="$tmpdir/ordered-post.sh"
cat >"$ordered_post" <<'SH'
printf 'first\n' >> order-marker
printf 'second\n' >> order-marker
SH
run_remote_deploy_with_post_deploy 20260611020303-c 2 "$ordered_post"
[[ "$(cat "$post_docroot/order-marker")" == $'first\nsecond' ]] || fail "post-deploy commands should run in order"

mkdir -p "$post_base/incoming/20260611020404-d"
printf 'delta\n' >"$post_base/incoming/20260611020404-d/index.php"
failing_post="$tmpdir/failing-post.sh"
cat >"$failing_post" <<'SH'
printf 'before-failure\n' > failure-marker
false
printf 'after-failure\n' >> failure-marker
SH
failing_err="$tmpdir/failing-post.err"
if run_remote_deploy_with_post_deploy 20260611020404-d 2 "$failing_post" 2>"$failing_err"; then
  fail "failing post-deploy command should fail deploy"
fi
assert_symlink_target "$post_base/current" "releases/20260611020404-d"
assert_file_contains "$post_docroot/failure-marker" "before-failure"
if grep -Fq "after-failure" "$post_docroot/failure-marker"; then
  fail "post-deploy should stop after a failing command"
fi
