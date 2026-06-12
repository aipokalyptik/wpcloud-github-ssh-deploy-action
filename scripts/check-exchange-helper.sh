#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source_file="$repo_root/helpers/exchange-rename/main.go"
binary_file="$repo_root/helpers/bin/linux-amd64/exchange-rename"
tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

[[ -f "$source_file" ]] || fail "missing helper source: $source_file"
[[ -x "$binary_file" ]] || fail "missing executable helper binary: $binary_file"

grep -Fq "SYS_RENAMEAT2" "$source_file" || fail "helper must call renameat2 directly"
grep -Fq "RENAME_EXCHANGE = 0x2" "$source_file" || fail "helper must use RENAME_EXCHANGE"
if grep -Eq 'os\.Rename|exec\.Command|/bin/mv| mv ' "$source_file"; then
  fail "helper must not use non-atomic rename or shell mv fallback"
fi

rebuilt="$tmpdir/exchange-rename"
(
  cd "$repo_root/helpers/exchange-rename"
  GO111MODULE=off CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go build -trimpath -ldflags="-s -w -buildid=" -o "$rebuilt" .
)
cmp -s "$rebuilt" "$binary_file" || fail "committed linux-amd64 helper does not match deterministic rebuild"

file_output="$(file "$binary_file")"
case "$file_output" in
  *"ELF 64-bit"*x86-64*statically\ linked*) ;;
  *) fail "helper must be a statically linked linux-amd64 ELF: $file_output" ;;
esac

if [[ "$(uname -s)" == "Linux" && "$(uname -m)" == "x86_64" ]]; then
  left="$tmpdir/left"
  right="$tmpdir/right"
  printf 'left\n' >"$left"
  printf 'right\n' >"$right"
  "$binary_file" "$left" "$right"
  [[ "$(cat "$left")" == "right" ]] || fail "exchange smoke test did not move right content to left"
  [[ "$(cat "$right")" == "left" ]] || fail "exchange smoke test did not move left content to right"
fi
