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
  GITHUB_SSH_DEPLOY_BOUNDARIES_FILE="$boundaries" \
    "$remote_deploy" \
      --docroot "$docroot" \
      --deployment-id site-prod \
      --release-id "$1" \
      --exchange-helper "$exchange_helper" \
      --keep-releases 5
}

run_rollback() {
  GITHUB_SSH_DEPLOY_BOUNDARIES_FILE="$boundaries" \
    "$remote_deploy" \
      --docroot "$docroot" \
      --deployment-id site-prod \
      --exchange-helper "$exchange_helper" \
      --rollback-to "$1"
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

flock_shim_dir="$tmpdir/bin"
mkdir -p "$flock_shim_dir"
printf '#!/usr/bin/env bash\nset -euo pipefail\nexit 0\n' >"$flock_shim_dir/flock"
cat >"$flock_shim_dir/mv" <<'SH'
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
chmod +x "$flock_shim_dir/flock"
chmod +x "$flock_shim_dir/mv"
export PATH="$flock_shim_dir:$PATH"

docroot="$tmpdir/docroot"
boundaries="$tmpdir/boundaries"
base="$docroot/.github-ssh-deploy/deployments/site-prod"
printf '.\n./wp-content\n./wp-content/plugins\n' >"$boundaries"

mkdir -p \
  "$base/incoming/release-a/assets" \
  "$base/incoming/release-a/wp-content/plugins/foo" \
  "$base/incoming/release-b/wp-content/plugins/bar"
printf 'release a asset\n' >"$base/incoming/release-a/assets/app.css"
printf 'release a plugin\n' >"$base/incoming/release-a/wp-content/plugins/foo/foo.php"
printf 'release b plugin\n' >"$base/incoming/release-b/wp-content/plugins/bar/bar.php"

run_remote_deploy release-a >/dev/null
run_remote_deploy release-b >/dev/null
assert_symlink_target "$base/current" "releases/release-b"
assert_symlink_target "$docroot/wp-content/plugins/bar" "../../.github-ssh-deploy/deployments/site-prod/current/wp-content/plugins/bar"

run_rollback release-a >/dev/null
assert_symlink_target "$base/current" "releases/release-a"
assert_symlink_target "$docroot/assets" ".github-ssh-deploy/deployments/site-prod/current/assets"
assert_symlink_target "$docroot/wp-content/plugins/foo" "../../.github-ssh-deploy/deployments/site-prod/current/wp-content/plugins/foo"
assert_file_contains "$docroot/assets/app.css" "release a asset"
assert_file_contains "$docroot/wp-content/plugins/foo/foo.php" "release a plugin"
[[ ! -e "$docroot/wp-content/plugins/bar" ]] || fail "rollback should clean stale release-b claim"

missing_err="$tmpdir/missing.err"
if run_rollback missing-release 2>"$missing_err"; then
  fail "rollback should fail for a missing release"
fi
grep -F "rollback release does not exist:" "$missing_err" >/dev/null || fail "missing release error should be explicit"
assert_symlink_target "$base/current" "releases/release-a"

protected_docroot="$tmpdir/protected-docroot"
protected_boundaries="$tmpdir/protected-boundaries"
protected_anchors="$tmpdir/protected-anchors"
docroot="$protected_docroot"
boundaries="$protected_boundaries"
base="$docroot/.github-ssh-deploy/deployments/site-prod"
printf '.\n./wp-content\n./wp-content/plugins\n' >"$boundaries"
printf 'assets\n' >"$protected_anchors"
mkdir -p "$base/incoming/protected-a/assets" "$base/incoming/protected-b/index.php"
printf 'blocked asset\n' >"$base/incoming/protected-a/assets/app.css"
printf 'current file\n' >"$base/incoming/protected-b/index.php/index.php"
run_remote_deploy protected-a >/dev/null
run_remote_deploy protected-b >/dev/null
protected_err="$tmpdir/protected.err"
if GITHUB_SSH_DEPLOY_BOUNDARIES_FILE="$boundaries" \
  GITHUB_SSH_DEPLOY_PROTECTED_ANCHORS_FILE="$protected_anchors" \
  "$remote_deploy" \
    --docroot "$docroot" \
    --deployment-id site-prod \
    --exchange-helper "$exchange_helper" \
    --rollback-to protected-a \
    2>"$protected_err"; then
  fail "rollback should reject protected target claims"
fi
grep -F "protected path: assets" "$protected_err" >/dev/null || fail "missing protected rollback error"
assert_symlink_target "$base/current" "releases/protected-b"

if find "$tmpdir" -name '*manifest*' -print | grep -q .; then
  fail "rollback should not create manifest files"
fi
