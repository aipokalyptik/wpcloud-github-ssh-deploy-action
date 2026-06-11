#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
remote_deploy="$repo_root/scripts/remote-deploy.sh"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

assert_file_equals() {
  local expected="$1"
  local actual="$2"
  if ! diff -u "$expected" "$actual"; then
    fail "unexpected file content: $actual"
  fi
}

write_boundaries() {
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

tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT

flock_shim_dir="$tmpdir/bin"
mkdir -p "$flock_shim_dir"
cat >"$flock_shim_dir/flock" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
exit 0
SH
chmod +x "$flock_shim_dir/flock"
export PATH="$flock_shim_dir:$PATH"

docroot="$tmpdir/docroot"
base="$docroot/.github-ssh-deploy/deployments/site-prod"
boundaries="$tmpdir/boundaries"
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
    --keep-releases 2 >/dev/null

cat >"$expected" <<'EOF'
assets
EOF
assert_file_equals "$expected" "$base/new_claims"
: >"$expected"
assert_file_equals "$expected" "$base/old_claims"

GITHUB_SSH_DEPLOY_BOUNDARIES_FILE="$boundaries" \
  "$remote_deploy" \
    --docroot "$docroot" \
    --deployment-id site-prod \
    --release-id new-release \
    --keep-releases 2 >/dev/null

cat >"$expected" <<'EOF'
assets
EOF
assert_file_equals "$expected" "$base/old_claims"
cat >"$expected" <<'EOF'
wp-content/plugins/foo
EOF
assert_file_equals "$expected" "$base/new_claims"
