#!/usr/bin/env bash

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

assert_contains() {
  local needle="$1"
  local file="$2"
  grep -Fq -- "$needle" "$file" || fail "expected '$needle' in $file"
}

assert_not_contains() {
  local needle="$1"
  local file="$2"
  if grep -Fq -- "$needle" "$file"; then
    fail "did not expect '$needle' in $file"
  fi
}

assert_file_contains() {
  local file="$1"
  local expected="$2"
  [[ -f "$file" ]] || fail "missing file: $file"
  grep -Fq -- "$expected" "$file" || fail "expected '$expected' in $file"
}

assert_file_equals() {
  local expected="$1"
  local actual="$2"
  if ! diff -u "$expected" "$actual"; then
    fail "unexpected file content: $actual"
  fi
}

assert_symlink_target() {
  local link="$1"
  local expected="$2"
  [[ -L "$link" ]] || fail "expected symlink: $link"
  local target
  target="$(readlink "$link")"
  [[ "$target" == "$expected" ]] || fail "expected $link -> $expected, got $target"
}

make_exchange_helper() {
  local tmpdir="$1"
  local repo_root="$2"
  local exchange_helper="$tmpdir/exchange-helper"

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

  printf '%s\n' "$exchange_helper"
}

install_flock_shim() {
  local bin_dir="$1"

  mkdir -p "$bin_dir"
  cat >"$bin_dir/flock" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
exit 0
SH
  chmod +x "$bin_dir/flock"
}

install_mv_t_shim() {
  local bin_dir="$1"

  mkdir -p "$bin_dir"
  cat >"$bin_dir/mv" <<'SH'
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
  chmod +x "$bin_dir/mv"
}

assert_no_durable_claim_scratch() {
  local base="$1"
  local scratch_name

  for scratch_name in boundaries protected_anchors old_claims new_claims removed_claims; do
    [[ ! -e "$base/$scratch_name" ]] || fail "durable scratch file should not remain: $base/$scratch_name"
  done
}
