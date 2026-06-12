#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
remote_deploy="$repo_root/scripts/remote-deploy.sh"
. "$repo_root/tests/lib.sh"

write_boundaries() {
  local file="$1"
  shift
  printf '%s\n' "$@" >"$file"
}

write_protected_anchors() {
  local file="$1"
  shift
  printf '%s\n' "$@" >"$file"
}

run_print_claims() {
  GITHUB_SSH_DEPLOY_BOUNDARIES_FILE="$boundaries" \
    "$remote_deploy" \
      --docroot "$docroot" \
      --deployment-id site-prod \
      --release-id "$1" \
      --keep-releases 2 \
      --print-claims
}

validator_body="$(awk '/^validate_claims_not_protected\(\)/,/^}/' "$remote_deploy")"
grep -Eq '(^|[^[:alnum:]_])comm([^[:alnum:]_]|$)' <<<"$validator_body" || fail "protected-claim validation should use standard set comparison"

tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT

exchange_helper="$(make_exchange_helper "$tmpdir" "$repo_root")"

flock_shim_dir="$tmpdir/bin"
install_flock_shim "$flock_shim_dir"
install_mv_t_shim "$flock_shim_dir"
install_find_printf_shim "$flock_shim_dir"
export PATH="$flock_shim_dir:$PATH"

docroot="$tmpdir/docroot"
base="$docroot/.github-ssh-deploy/deployments/site-prod"
boundaries="$tmpdir/boundaries"
protected_anchors="$tmpdir/protected-anchors"
mkdir -p "$base/incoming/claim-test"

mkdir -p \
  "$base/incoming/claim-test/assets" \
  "$base/incoming/claim-test/wp-content/plugins/foo" \
  "$base/incoming/claim-test/wp-content/themes/site" \
  "$base/incoming/claim-test/wp-content/uploads" \
  "$base/incoming/claim-test/.github-ssh-deploy/private" \
  "$base/incoming/claim-test/.git/objects"
printf 'index\n' >"$base/incoming/claim-test/index.php"
printf 'css\n' >"$base/incoming/claim-test/assets/app.css"
printf 'js\n' >"$base/incoming/claim-test/assets/app.js"
printf 'plugin\n' >"$base/incoming/claim-test/wp-content/plugins/foo/foo.php"
printf 'theme\n' >"$base/incoming/claim-test/wp-content/themes/site/style.css"
printf 'upload\n' >"$base/incoming/claim-test/wp-content/uploads/a.jpg"
printf 'internal\n' >"$base/incoming/claim-test/.github-ssh-deploy/private/state"
printf 'git\n' >"$base/incoming/claim-test/.git/objects/object"

write_boundaries "$boundaries" \
  "." \
  "./wp-content" \
  "./wp-content/plugins" \
  "./wp-content/themes"

actual="$tmpdir/claims.actual"
expected="$tmpdir/claims.expected"
run_print_claims claim-test >"$actual"
cat >"$expected" <<'EOF'
assets
index.php
wp-content/plugins/foo
wp-content/themes/site
wp-content/uploads
EOF
assert_file_equals "$expected" "$actual"
[[ ! -e "$base/current" ]] || fail "--print-claims should not update current"
[[ -d "$base/incoming/claim-test" ]] || fail "--print-claims should not promote incoming release"

mkdir -p "$base/incoming/newline-release/bad"
printf 'bad\n' >"$base/incoming/newline-release/bad/"$'unsupported\npath.txt'
newline_stdout="$tmpdir/newline.stdout"
newline_stderr="$tmpdir/newline.stderr"
if run_print_claims newline-release >"$newline_stdout" 2>"$newline_stderr"; then
  fail "--print-claims should reject release paths containing newlines"
fi
grep -F "unsupported newline in release path" "$newline_stderr" >/dev/null || fail "missing clear newline path error"
[[ ! -s "$newline_stdout" ]] || fail "newline path rejection should not emit stdout claims"
assert_no_durable_claim_scratch "$base"

write_boundaries "$boundaries" \
  "." \
  "./wp-content"

run_print_claims claim-test >"$actual"
cat >"$expected" <<'EOF'
assets
index.php
wp-content/plugins
wp-content/themes
wp-content/uploads
EOF
assert_file_equals "$expected" "$actual"

write_boundaries "$boundaries" \
  "." \
  "./wp-content" \
  "./wp-content/plugins"

mkdir -p "$base/incoming/old-release/assets" "$base/incoming/new-release/wp-content/plugins/foo"
printf 'old\n' >"$base/incoming/old-release/assets/old.css"
printf 'new\n' >"$base/incoming/new-release/wp-content/plugins/foo/foo.php"

GITHUB_SSH_DEPLOY_BOUNDARIES_FILE="$boundaries" \
  "$remote_deploy" \
    --docroot "$docroot" \
    --deployment-id site-prod \
    --release-id old-release \
    --exchange-helper "$exchange_helper" \
    --keep-releases 2 >/dev/null

assert_no_durable_claim_scratch "$base"

GITHUB_SSH_DEPLOY_BOUNDARIES_FILE="$boundaries" \
  "$remote_deploy" \
    --docroot "$docroot" \
    --deployment-id site-prod \
    --release-id new-release \
    --exchange-helper "$exchange_helper" \
    --keep-releases 2 >/dev/null

assert_no_durable_claim_scratch "$base"

assert_protected_failure() {
  local release_id="$1"
  local expected_path="$2"
  local stderr_file="$tmpdir/$release_id.stderr"

  if GITHUB_SSH_DEPLOY_BOUNDARIES_FILE="$boundaries" \
    GITHUB_SSH_DEPLOY_PROTECTED_ANCHORS_FILE="$protected_anchors" \
    "$remote_deploy" \
      --docroot "$docroot" \
      --deployment-id site-prod \
      --release-id "$release_id" \
      --exchange-helper "$exchange_helper" \
      --keep-releases 2 \
      2>"$stderr_file"; then
    fail "deploy should reject protected path for $release_id"
  fi

  grep -F "protected path: $expected_path" "$stderr_file" >/dev/null || fail "missing protected path error for $expected_path"
  [[ -d "$base/incoming/$release_id" ]] || fail "protected path failure should leave incoming release in place"
  assert_symlink_target "$base/current" "releases/new-release"
}

write_boundaries "$boundaries" \
  "." \
  "./wp-content" \
  "./wp-content/plugins"

write_protected_anchors "$protected_anchors" "index.php"
mkdir -p "$base/incoming/protected-file"
printf 'blocked\n' >"$base/incoming/protected-file/index.php"
assert_protected_failure protected-file "index.php"

write_protected_anchors "$protected_anchors" "wp-content/plugins"
mkdir -p "$base/incoming/protected-directory-descendant/wp-content/plugins/bar"
printf 'blocked\n' >"$base/incoming/protected-directory-descendant/wp-content/plugins/bar/bar.php"
assert_protected_failure protected-directory-descendant "wp-content/plugins/bar"

write_protected_anchors "$protected_anchors" "wp-content/plugins/akismet"
mkdir -p "$base/incoming/protected-plugin/wp-content/plugins/akismet"
printf 'blocked\n' >"$base/incoming/protected-plugin/wp-content/plugins/akismet/akismet.php"
assert_protected_failure protected-plugin "wp-content/plugins/akismet"

write_boundaries "$boundaries" "."
write_protected_anchors "$protected_anchors" "wp-content/advanced-cache.php"
mkdir -p "$base/incoming/protected-engulfed-file/wp-content"
printf 'blocked\n' >"$base/incoming/protected-engulfed-file/wp-content/plugin.php"
assert_protected_failure protected-engulfed-file "wp-content"

write_boundaries "$boundaries" "."
write_protected_anchors "$protected_anchors" "assets/managed/config.php"
mkdir -p "$base/incoming/protected-engulfed-directory/assets/js"
printf 'blocked\n' >"$base/incoming/protected-engulfed-directory/assets/js/app.js"
assert_protected_failure protected-engulfed-directory "assets"

write_boundaries "$boundaries" \
  "." \
  "./wp-content" \
  "./wp-content/plugins"

mkdir -p "$base/incoming/writable-sibling/wp-content/plugins/hello"
printf 'allowed\n' >"$base/incoming/writable-sibling/wp-content/plugins/hello/hello.php"
GITHUB_SSH_DEPLOY_BOUNDARIES_FILE="$boundaries" \
  GITHUB_SSH_DEPLOY_PROTECTED_ANCHORS_FILE="$protected_anchors" \
  "$remote_deploy" \
    --docroot "$docroot" \
    --deployment-id site-prod \
    --release-id writable-sibling \
    --exchange-helper "$exchange_helper" \
    --keep-releases 2 >/dev/null
assert_symlink_target "$base/current" "releases/writable-sibling"
