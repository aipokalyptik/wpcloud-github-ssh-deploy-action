#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
remote_deploy="$repo_root/scripts/remote-deploy.sh"
. "$repo_root/tests/lib.sh"

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

exchange_helper="$(make_exchange_helper "$tmpdir" "$repo_root")"

mv_shim_dir="$tmpdir/mv-shim-bin"
install_mv_t_shim "$mv_shim_dir"
install_find_printf_shim "$mv_shim_dir"
export PATH="$mv_shim_dir:$PATH"
original_path="$PATH"

switch_current_body="$(awk '/^switch_current\(\)/,/^}/' "$remote_deploy")"
# shellcheck disable=SC2016
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

for missing_command in grep cat touch; do
  missing_command_path="$tmpdir/no-$missing_command-bin"
  mkdir -p "$missing_command_path"
  install_flock_shim "$missing_command_path"
  install_find_printf_shim "$missing_command_path"
  for required_command in readlink sort comm cut ln rm mv mkdir mktemp grep cat touch; do
    [[ "$required_command" == "$missing_command" ]] && continue
    ln -sf "$(command -v "$required_command")" "$missing_command_path/$required_command"
  done
  missing_command_err="$tmpdir/missing-$missing_command.err"
  if PATH="$missing_command_path" /bin/bash "$remote_deploy" \
    --docroot "$tmpdir/no-$missing_command-docroot" \
    --deployment-id site-prod \
    --release-id "no-$missing_command-release" \
    --keep-releases 1 \
    2>"$missing_command_err"; then
    fail "deploy should fail when $missing_command is unavailable"
  fi
  grep -Fq "$missing_command is required" "$missing_command_err" || fail "missing $missing_command failure should be explicit"
done

missing_mv_t_path="$tmpdir/no-mv-t-bin"
mkdir -p "$missing_mv_t_path"
install_find_printf_shim "$missing_mv_t_path"
for required_command in readlink sort comm cut ln rm mkdir mktemp grep cat touch; do
  ln -s "$(command -v "$required_command")" "$missing_mv_t_path/$required_command"
done
install_flock_shim "$missing_mv_t_path"
cat >"$missing_mv_t_path/mv" <<'SH'
#!/bin/bash
set -euo pipefail
for arg in "$@"; do
  if [[ "$arg" == "-T" || "$arg" == "--no-target-directory" ]]; then
    echo "mv: unsupported option $arg" >&2
    exit 1
  fi
done
/bin/mv "$@"
SH
chmod +x "$missing_mv_t_path/mv"
missing_mv_t_err="$tmpdir/missing-mv-t.err"
if PATH="$missing_mv_t_path" /bin/bash "$remote_deploy" \
  --docroot "$tmpdir/no-mv-t-docroot" \
  --deployment-id site-prod \
  --release-id no-mv-t-release \
  --keep-releases 1 \
  2>"$missing_mv_t_err"; then
  fail "deploy should fail when mv -T is unavailable"
fi
grep -Fq "atomic replacement requires mv -T" "$missing_mv_t_err" || fail "missing mv -T failure should be explicit"

non_gnu_find_path="$tmpdir/non-gnu-find-bin"
mkdir -p "$non_gnu_find_path"
install_flock_shim "$non_gnu_find_path"
for required_command in readlink sort comm cut grep cat ln rm mv mkdir mktemp touch; do
  ln -sf "$(command -v "$required_command")" "$non_gnu_find_path/$required_command"
done
cat >"$non_gnu_find_path/find" <<'SH'
#!/bin/bash
for arg in "$@"; do
  if [[ "$arg" == "-printf" ]]; then
    echo "find: -printf: unknown primary or operator" >&2
    exit 1
  fi
done
/usr/bin/find "$@"
SH
chmod +x "$non_gnu_find_path/find"
non_gnu_find_err="$tmpdir/non-gnu-find.err"
if PATH="$non_gnu_find_path" /bin/bash "$remote_deploy" \
  --docroot "$tmpdir/non-gnu-find-docroot" \
  --deployment-id site-prod \
  --release-id non-gnu-find-release \
  --keep-releases 1 \
  2>"$non_gnu_find_err"; then
  fail "deploy should fail when find -printf is unavailable"
fi
grep -Fq "GNU find with -printf is required" "$non_gnu_find_err" || fail "missing GNU find failure should be explicit"

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

mkdir -p "$base/.tmp.stale-before-next-run"
run_remote_deploy 20260611010202-b 2
assert_symlink_target "$base/current" "releases/20260611010202-b"
[[ -d "$base/releases/20260611010101-a" ]] || fail "previous release should be retained"
[[ ! -e "$base/.tmp.stale-before-next-run" ]] || fail "stale scratch directory should be cleaned on the next deploy"

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
