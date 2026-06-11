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
  local deployment_id="$1"
  local release_id="$2"

  GITHUB_SSH_DEPLOY_BOUNDARIES_FILE="$boundaries" \
    "$remote_deploy" \
      --docroot "$docroot" \
      --deployment-id "$deployment_id" \
      --release-id "$release_id" \
      --keep-releases 3
}

tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT

flock_shim_dir="$tmpdir/bin"
mkdir -p "$flock_shim_dir"
printf '#!/usr/bin/env bash\nset -euo pipefail\nexit 0\n' >"$flock_shim_dir/flock"
chmod +x "$flock_shim_dir/flock"
export PATH="$flock_shim_dir:$PATH"

docroot="$tmpdir/docroot"
boundaries="$tmpdir/boundaries"
base="$docroot/.github-ssh-deploy/deployments/site-prod"
other_base="$docroot/.github-ssh-deploy/deployments/other-prod"
printf '.\n./wp-content\n./wp-content/plugins\n' >"$boundaries"

mkdir -p \
  "$base/incoming/first/assets" \
  "$base/incoming/first/wp-content/plugins/foo" \
  "$base/incoming/second/assets" \
  "$base/incoming/second/wp-content/plugins/foo" \
  "$base/incoming/removed/assets" \
  "$base/incoming/removed-again/assets" \
  "$base/incoming/real-dir/assets" \
  "$base/incoming/real-file/index.php" \
  "$base/incoming/no-unmanaged/index.php" \
  "$base/incoming/no-other/index.php" \
  "$other_base/incoming/other-release/other"

printf 'first css\n' >"$base/incoming/first/assets/app.css"
printf 'first plugin\n' >"$base/incoming/first/wp-content/plugins/foo/foo.php"
printf 'second css\n' >"$base/incoming/second/assets/app.css"
printf 'second plugin\n' >"$base/incoming/second/wp-content/plugins/foo/foo.php"
printf 'removed css\n' >"$base/incoming/removed/assets/app.css"
printf 'removed again css\n' >"$base/incoming/removed-again/assets/app.css"
printf 'dir reclaim\n' >"$base/incoming/real-dir/assets/app.css"
printf 'file reclaim\n' >"$base/incoming/real-file/index.php/index.php"
printf 'kept file\n' >"$base/incoming/no-unmanaged/index.php/index.php"
printf 'other check\n' >"$base/incoming/no-other/index.php/index.php"
printf 'other\n' >"$other_base/incoming/other-release/other/file.txt"

run_remote_deploy site-prod first >/dev/null
assert_symlink_target "$docroot/assets" ".github-ssh-deploy/deployments/site-prod/current/assets"
assert_symlink_target "$docroot/wp-content/plugins/foo" "../../.github-ssh-deploy/deployments/site-prod/current/wp-content/plugins/foo"
assert_file_contains "$docroot/assets/app.css" "first css"

run_remote_deploy site-prod second >/dev/null
assert_symlink_target "$docroot/assets" ".github-ssh-deploy/deployments/site-prod/current/assets"
assert_file_contains "$docroot/assets/app.css" "second css"
assert_file_contains "$docroot/wp-content/plugins/foo/foo.php" "second plugin"

ln -s "tampered-target" "$docroot/assets.tmp"
mv -f "$docroot/assets.tmp" "$docroot/assets"
run_remote_deploy site-prod removed >/dev/null
assert_symlink_target "$docroot/assets" ".github-ssh-deploy/deployments/site-prod/current/assets"
assert_file_contains "$docroot/assets/app.css" "removed css"
[[ ! -e "$docroot/wp-content/plugins/foo" ]] || fail "removed managed claim should be cleaned up"

rm -f "$docroot/assets"
mkdir -p "$docroot/assets"
printf 'unmanaged dir\n' >"$docroot/assets/manual.txt"
run_remote_deploy site-prod real-dir >/dev/null
assert_symlink_target "$docroot/assets" ".github-ssh-deploy/deployments/site-prod/current/assets"
assert_file_contains "$docroot/assets/app.css" "dir reclaim"

rm -f "$docroot/assets"
ln -s ".github-ssh-deploy/deployments/other-prod/current/assets" "$docroot/assets"
rm -f "$docroot/index.php"
printf 'unmanaged\n' >"$docroot/index.php"
run_remote_deploy site-prod real-file >/dev/null
assert_symlink_target "$docroot/assets" ".github-ssh-deploy/deployments/other-prod/current/assets"
assert_symlink_target "$docroot/index.php" ".github-ssh-deploy/deployments/site-prod/current/index.php"
assert_file_contains "$docroot/index.php/index.php" "file reclaim"

rm -f "$docroot/index.php"
printf 'manual\n' >"$docroot/index.php"
run_remote_deploy site-prod no-unmanaged >/dev/null
rm -f "$docroot/index.php"
printf 'manual replacement\n' >"$docroot/index.php"
rm -f "$docroot/assets"
run_remote_deploy site-prod removed-again >/dev/null
[[ -f "$docroot/index.php" ]] || fail "removed unmanaged real file should not be deleted"
assert_file_contains "$docroot/index.php" "manual replacement"

run_remote_deploy other-prod other-release >/dev/null
assert_symlink_target "$docroot/other" ".github-ssh-deploy/deployments/other-prod/current/other"
run_remote_deploy site-prod no-other >/dev/null
assert_symlink_target "$docroot/other" ".github-ssh-deploy/deployments/other-prod/current/other"
assert_symlink_target "$docroot/index.php" ".github-ssh-deploy/deployments/site-prod/current/index.php"

docroot="$tmpdir/boundary-docroot"
boundaries="$tmpdir/boundary-boundaries"
base="$docroot/.github-ssh-deploy/deployments/site-prod"
mkdir -p "$base/incoming/parent-release/wp-content/plugins/foo"
mkdir -p "$base/incoming/child-release/wp-content/plugins/foo"
printf 'parent claim\n' >"$base/incoming/parent-release/wp-content/plugins/foo/foo.php"
printf 'child claim\n' >"$base/incoming/child-release/wp-content/plugins/foo/foo.php"

printf '.\n./wp-content\n' >"$boundaries"
run_remote_deploy site-prod parent-release >/dev/null
assert_symlink_target "$docroot/wp-content/plugins" "../.github-ssh-deploy/deployments/site-prod/current/wp-content/plugins"

printf '.\n./wp-content\n./wp-content/plugins\n' >"$boundaries"
run_remote_deploy site-prod child-release >/dev/null
[[ ! -L "$docroot/wp-content/plugins" ]] || fail "parent claim symlink should be removed before child claim is created"
assert_symlink_target "$docroot/wp-content/plugins/foo" "../../.github-ssh-deploy/deployments/site-prod/current/wp-content/plugins/foo"
assert_file_contains "$docroot/wp-content/plugins/foo/foo.php" "child claim"

docroot="$tmpdir/reverse-boundary-docroot"
boundaries="$tmpdir/reverse-boundary-boundaries"
base="$docroot/.github-ssh-deploy/deployments/site-prod"
mkdir -p "$base/incoming/child-release/wp-content/plugins/foo"
mkdir -p "$base/incoming/parent-release/wp-content/plugins/foo"
printf 'child claim\n' >"$base/incoming/child-release/wp-content/plugins/foo/foo.php"
printf 'parent claim\n' >"$base/incoming/parent-release/wp-content/plugins/foo/foo.php"

printf '.\n./wp-content\n./wp-content/plugins\n' >"$boundaries"
run_remote_deploy site-prod child-release >/dev/null
assert_symlink_target "$docroot/wp-content/plugins/foo" "../../.github-ssh-deploy/deployments/site-prod/current/wp-content/plugins/foo"

printf '.\n./wp-content\n' >"$boundaries"
run_remote_deploy site-prod parent-release >/dev/null
[[ ! -L "$docroot/wp-content/plugins/foo" ]] || fail "child claim symlink should be removed after parent claim is created"
assert_symlink_target "$docroot/wp-content/plugins" "../.github-ssh-deploy/deployments/site-prod/current/wp-content/plugins"
assert_file_contains "$docroot/wp-content/plugins/foo/foo.php" "parent claim"

docroot="$tmpdir/nonexact-cleanup-docroot"
boundaries="$tmpdir/nonexact-cleanup-boundaries"
base="$docroot/.github-ssh-deploy/deployments/site-prod"
mkdir -p "$base/incoming/with-assets/assets" "$base/incoming/no-assets/index.php"
printf 'asset\n' >"$base/incoming/with-assets/assets/app.css"
printf 'index\n' >"$base/incoming/no-assets/index.php/index.php"

printf '.\n' >"$boundaries"
run_remote_deploy site-prod with-assets >/dev/null
rm -f "$docroot/assets"
ln -s ".github-ssh-deploy/deployments/site-prod/current/assets-extra" "$docroot/assets"
run_remote_deploy site-prod no-assets >/dev/null
assert_symlink_target "$docroot/assets" ".github-ssh-deploy/deployments/site-prod/current/assets-extra"

docroot="$tmpdir/foreign-owner-docroot"
boundaries="$tmpdir/foreign-owner-boundaries"
base="$docroot/.github-ssh-deploy/deployments/site-prod"
other_base="$docroot/.github-ssh-deploy/deployments/other-prod"
mkdir -p "$base/incoming/prior/index.php" "$base/incoming/claim-assets/assets" "$other_base/current/assets"
printf 'prior\n' >"$base/incoming/prior/index.php/index.php"
printf 'wanted\n' >"$base/incoming/claim-assets/assets/app.css"
printf 'other\n' >"$other_base/current/assets/app.css"

printf '.\n' >"$boundaries"
run_remote_deploy site-prod prior >/dev/null
rm -rf "$docroot/assets"
ln -s ".github-ssh-deploy/deployments/other-prod/current/assets" "$docroot/assets"
foreign_stderr="$tmpdir/foreign-owner.stderr"
if run_remote_deploy site-prod claim-assets 2>"$foreign_stderr"; then
  fail "deploy should reject claim owned by another deployment"
fi
grep -F "claim owned by another deployment: assets" "$foreign_stderr" >/dev/null || fail "missing foreign owner error"
assert_symlink_target "$base/current" "releases/prior"
assert_symlink_target "$docroot/assets" ".github-ssh-deploy/deployments/other-prod/current/assets"
