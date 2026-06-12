#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
action_file="$repo_root/action.yml"
helper_source="$repo_root/helpers/exchange-rename/main.go"
helper_check="$repo_root/scripts/check-exchange-helper.sh"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

[[ -f "$action_file" ]] || fail "action.yml must exist"
[[ -f "$repo_root/scripts/deploy.sh" ]] || fail "scripts/deploy.sh must exist"
[[ -x "$repo_root/scripts/deploy.sh" ]] || fail "scripts/deploy.sh must be executable"
[[ -f "$repo_root/scripts/remote-deploy.sh" ]] || fail "scripts/remote-deploy.sh must exist"
[[ -x "$repo_root/scripts/remote-deploy.sh" ]] || fail "scripts/remote-deploy.sh must be executable"
[[ -f "$helper_check" ]] || fail "scripts/check-exchange-helper.sh must exist"
[[ -x "$helper_check" ]] || fail "scripts/check-exchange-helper.sh must be executable"
[[ -f "$helper_source" ]] || fail "exchange helper source must exist"
[[ -x "$repo_root/helpers/bin/linux-amd64/exchange-rename" ]] || fail "linux-amd64 exchange helper binary must be executable"

for script in "$repo_root/scripts/deploy.sh" "$repo_root/scripts/remote-deploy.sh"; do
  "$script" --help >/dev/null
  "$script" --version >/dev/null
done

for input in host port username password private-key private-key-passphrase docroot source exclude keep-releases post-deploy deployment-id known-hosts; do
  grep -Eq "^[[:space:]]{2}${input}:" "$action_file" || fail "missing input: $input"
done

grep -EA4 "^[[:space:]]{2}port:" "$action_file" | grep -Fq 'default: "22"' || fail "port must default to 22"
grep -EA5 "^[[:space:]]{2}docroot:" "$action_file" | grep -Fq 'default: /srv/htdocs' || fail "docroot must default to /srv/htdocs"
grep -EA5 "^[[:space:]]{2}password:" "$action_file" | grep -Fq 'required: false' || fail "password must be optional when private-key auth is available"
grep -EA5 "^[[:space:]]{2}private-key:" "$action_file" | grep -Fq 'required: false' || fail "private-key must be optional"
grep -Fq "INPUT_PRIVATE_KEY:" "$action_file" || fail "private-key input must be mapped to deploy.sh"
grep -Fq "INPUT_PRIVATE_KEY_PASSPHRASE:" "$action_file" || fail "private-key-passphrase input must be mapped to deploy.sh"

grep -Eq "^[[:space:]]{2}using:[[:space:]]+'?composite'?" "$action_file" || fail "action must use composite runs"
grep -Fq "scripts/deploy.sh" "$action_file" || fail "action must call scripts/deploy.sh"

if grep -Eq '<\(|>\(|/dev/fd' "$repo_root/scripts/remote-deploy.sh"; then
  fail "remote-deploy.sh must not require /dev/fd process substitution on remote hosts"
fi

grep -Fxq "//go:build linux && amd64" "$helper_source" || fail "exchange helper source must be constrained to linux amd64"
grep -Eq 'EXPECTED_GO_VERSION="go[0-9]+(\.[0-9]+)*"' "$helper_check" || fail "helper check must pin the expected Go version"

tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT
fake_bin="$tmpdir/bin"
mkdir -p "$fake_bin"
cat >"$fake_bin/go" <<'SH'
#!/usr/bin/env bash
printf 'go version go1.25.0 linux/amd64\n'
SH
chmod +x "$fake_bin/go"
version_stderr="$tmpdir/helper-version.stderr"
if PATH="$fake_bin:$PATH" "$helper_check" 2>"$version_stderr"; then
  fail "helper check should reject an unpinned Go version"
fi
grep -Fq "helper verification requires go1.26.3; found go1.25.0" "$version_stderr" || fail "helper check should explain Go version mismatch"
