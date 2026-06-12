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

  if [[ "$(uname -s)" == "Linux" && "$(uname -m)" == "x86_64" ]]; then
    printf '%s\n' "$repo_root/helpers/bin/linux-amd64/exchange-rename"
    return 0
  fi

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

install_find_printf_shim() {
  local bin_dir="$1"

  if [[ -x "$bin_dir/find" ]]; then
    return 0
  fi

  mkdir -p "$bin_dir"
  # Linux/GNU hosts should exercise the real find path. Only non-GNU local
  # machines get the small -printf emulation used by pruning tests.
  if /usr/bin/find . -maxdepth 0 -printf '' >/dev/null 2>&1; then
    ln -sf /usr/bin/find "$bin_dir/find"
    return 0
  fi

  cat >"$bin_dir/find" <<'SH'
#!/bin/bash
set -euo pipefail

mtime_for_path() {
  if stat -c %Y "$1" >/dev/null 2>&1; then
    stat -c %Y "$1"
  else
    stat -f %m "$1"
  fi
}

for arg in "$@"; do
  if [[ "$arg" == "-printf" ]]; then
    root="$1"
    shopt -s nullglob
    for child in "$root"/*; do
      [[ -d "$child" ]] || continue
      printf '%s\t%s\n' "$(mtime_for_path "$child")" "$child"
    done
    exit 0
  fi
done
/usr/bin/find "$@"
SH
  chmod +x "$bin_dir/find"
}

assert_no_durable_claim_scratch() {
  local base="$1"
  local scratch_name

  for scratch_name in boundaries protected_anchors old_claims new_claims removed_claims; do
    [[ ! -e "$base/$scratch_name" ]] || fail "durable scratch file should not remain: $base/$scratch_name"
  done
}
