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
grep -Fxq "//go:build linux && amd64" "$source_file" || fail "helper source must only build for linux amd64"
if grep -Eq 'os\.Rename|exec\.Command|/bin/mv| mv ' "$source_file"; then
  fail "helper must not use non-atomic rename or shell mv fallback"
fi

rebuilt="$tmpdir/exchange-rename"
GO111MODULE=off CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go build -trimpath -buildvcs=false -ldflags="-s -w -buildid=" -o "$rebuilt" "$source_file"

file_output="$(file "$binary_file")"
case "$file_output" in
  *"ELF 64-bit"*x86-64*statically\ linked*) ;;
  *) fail "helper must be a statically linked linux-amd64 ELF: $file_output" ;;
esac

rebuilt_file_output="$(file "$rebuilt")"
case "$rebuilt_file_output" in
  *"ELF 64-bit"*x86-64*statically\ linked*) ;;
  *) fail "rebuilt helper must be a statically linked linux-amd64 ELF: $rebuilt_file_output" ;;
esac

cmp -s "$binary_file" "$rebuilt" || fail "committed helper binary does not match rebuilt source"

smoke_exchange() {
  local helper="$1"
  local label="$2"
  local left="$tmpdir/$label-left"
  local right="$tmpdir/$label-right"

  printf 'left\n' >"$left"
  printf 'right\n' >"$right"
  "$helper" "$left" "$right"
  [[ "$(cat "$left")" == "right" ]] || fail "$label exchange smoke test did not move right content to left"
  [[ "$(cat "$right")" == "left" ]] || fail "$label exchange smoke test did not move left content to right"
}

if [[ "$(uname -s)" == "Linux" && "$(uname -m)" == "x86_64" ]]; then
  smoke_exchange "$binary_file" committed
  smoke_exchange "$rebuilt" rebuilt
fi
