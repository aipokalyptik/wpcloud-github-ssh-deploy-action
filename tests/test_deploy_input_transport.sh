#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
deploy="$repo_root/scripts/deploy.sh"
. "$repo_root/tests/lib.sh"

run_deploy() {
  local stdout_file="$1"
  local stderr_file="$2"
  shift 2

  (
    export GITHUB_SSH_DEPLOY_DRY_RUN=1
    export INPUT_HOST="${INPUT_HOST-example.com}"
    export INPUT_USERNAME="${INPUT_USERNAME-deploy}"
    export INPUT_PASSWORD="${INPUT_PASSWORD-secret-password}"
    export GITHUB_REPOSITORY="${TEST_GITHUB_REPOSITORY-Owner/Example Repo}"
    export GITHUB_SSH_DEPLOY_RELEASE_ID="${GITHUB_SSH_DEPLOY_RELEASE_ID-release-test}"
    "$deploy" "$@"
  ) >"$stdout_file" 2>"$stderr_file"
}

tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT

stdout="$tmpdir/stdout"
stderr="$tmpdir/stderr"

if INPUT_HOST="" run_deploy "$stdout" "$stderr"; then
  fail "missing host should fail"
fi
assert_contains "missing required input: host" "$stderr"
unset INPUT_HOST

if INPUT_USERNAME="" run_deploy "$stdout" "$stderr"; then
  fail "missing username should fail"
fi
assert_contains "missing required input: username" "$stderr"
unset INPUT_USERNAME

if INPUT_PASSWORD="" run_deploy "$stdout" "$stderr"; then
  fail "missing password should fail"
fi
assert_contains "missing required input: password" "$stderr"
unset INPUT_PASSWORD

run_deploy "$stdout" "$stderr"
assert_contains "::add-mask::secret-password" "$stdout"
assert_contains "port=22" "$stderr"
assert_contains "docroot=/srv/htdocs" "$stderr"
assert_contains "source=." "$stderr"
assert_contains "exclude_source=default" "$stderr"
assert_contains "keep_releases=2" "$stderr"
assert_contains "deployment_id=owner-example-repo" "$stderr"
assert_contains "ssh-keyscan -p 22 example.com" "$stderr"
assert_contains "/srv/htdocs/.github-ssh-deploy/deployments/owner-example-repo/incoming/release-test/" "$stderr"
assert_contains "rsync -az --delete --exclude-from=" "$stderr"
assert_contains "remote_script=/srv/htdocs/.github-ssh-deploy/deployments/owner-example-repo/remote-deploy.sh" "$stderr"
assert_contains "remote_exchange_helper=/srv/htdocs/.github-ssh-deploy/deployments/owner-example-repo/exchange-rename" "$stderr"
assert_contains "remote_arch=x86_64" "$stderr"
assert_contains "scripts/remote-deploy.sh" "$stderr"
assert_contains "helpers/bin/linux-amd64/exchange-rename" "$stderr"
assert_contains "exchange-helper-upload" "$stderr"
assert_contains "exchange-helper-chmod" "$stderr"
assert_contains "remote-deploy owner-example-repo release-test" "$stderr"
assert_contains "--exchange-helper\\ /srv/htdocs/.github-ssh-deploy/deployments/owner-example-repo/exchange-rename" "$stderr"
assert_contains "env SSHPASS=REDACTED sshpass -e" "$stderr"
assert_not_contains "secret-password" "$stderr"

default_exclude_tmp="$tmpdir/default-excludes"
GITHUB_SSH_DEPLOY_TMPDIR="$default_exclude_tmp" \
GITHUB_SSH_DEPLOY_KEEP_TEMP=1 \
run_deploy "$stdout" "$stderr"
assert_contains ".git/" "$default_exclude_tmp/rsync-excludes"
assert_contains ".github/" "$default_exclude_tmp/rsync-excludes"
assert_contains ".env.*" "$default_exclude_tmp/rsync-excludes"
assert_contains ".DS_Store" "$default_exclude_tmp/rsync-excludes"

INPUT_EXCLUDE=none run_deploy "$stdout" "$stderr"
assert_contains "exclude_source=none" "$stderr"
assert_not_contains "--exclude-from=" "$stderr"
unset INPUT_EXCLUDE

custom_exclude_tmp="$tmpdir/custom-excludes"
INPUT_EXCLUDE=$'wp-content/uploads/\nlocal-config.php\n' \
GITHUB_SSH_DEPLOY_TMPDIR="$custom_exclude_tmp" \
GITHUB_SSH_DEPLOY_KEEP_TEMP=1 \
run_deploy "$stdout" "$stderr"
assert_contains "exclude_source=input" "$stderr"
assert_contains "--exclude-from=" "$stderr"
[[ "$(cat "$custom_exclude_tmp/rsync-excludes")" == $'wp-content/uploads/\nlocal-config.php' ]] || fail "custom excludes should replace defaults exactly"
assert_not_contains ".git/" "$custom_exclude_tmp/rsync-excludes"
unset INPUT_EXCLUDE

if command -v rsync >/dev/null 2>&1; then
  rsync_source="$tmpdir/rsync-source"
  rsync_dest="$tmpdir/rsync-dest"
  mkdir -p "$rsync_source/.git" "$rsync_source/.github" "$rsync_source/.well-known" "$rsync_dest"
  printf 'git\n' >"$rsync_source/.git/config"
  printf 'workflow\n' >"$rsync_source/.github/deploy.yml"
  printf 'env\n' >"$rsync_source/.env"
  printf 'apache\n' >"$rsync_source/.htaccess"
  printf 'challenge\n' >"$rsync_source/.well-known/acme-challenge"
  printf 'public\n' >"$rsync_source/index.php"

  rsync -a --delete --exclude-from="$default_exclude_tmp/rsync-excludes" "$rsync_source/" "$rsync_dest/"
  [[ ! -e "$rsync_dest/.git/config" ]] || fail "default excludes should omit .git/"
  [[ ! -e "$rsync_dest/.github/deploy.yml" ]] || fail "default excludes should omit .github/"
  [[ ! -e "$rsync_dest/.env" ]] || fail "default excludes should omit .env"
  [[ -f "$rsync_dest/.htaccess" ]] || fail "default excludes should allow .htaccess"
  [[ -f "$rsync_dest/.well-known/acme-challenge" ]] || fail "default excludes should allow .well-known/"
  [[ -f "$rsync_dest/index.php" ]] || fail "default excludes should allow normal files"
fi

INPUT_POST_DEPLOY=$'printf "one|two\\n" > post-marker\nprintf "done\\n" >> post-marker' \
run_deploy "$stdout" "$stderr"
assert_contains "post_deploy=provided" "$stderr"
assert_contains "remote_post_deploy=/srv/htdocs/.github-ssh-deploy/deployments/owner-example-repo/post-deploy/release-test.sh" "$stderr"
assert_contains "post-deploy-upload" "$stderr"
assert_contains "post-deploy-chmod" "$stderr"
assert_contains "--post-deploy-file\\ /srv/htdocs/.github-ssh-deploy/deployments/owner-example-repo/post-deploy/release-test.sh" "$stderr"
assert_not_contains 'printf "one|two' "$stderr"
unset INPUT_POST_DEPLOY

INPUT_PASSWORD='p@ss word!*' run_deploy "$stdout" "$stderr"
assert_contains "::add-mask::p@ss word!*" "$stdout"
assert_contains "env SSHPASS=REDACTED sshpass -e" "$stderr"
assert_not_contains 'p@ss word!*' "$stderr"
unset INPUT_PASSWORD

INPUT_PORT=2222 \
INPUT_DOCROOT=/tmp/site \
INPUT_SOURCE=dist \
INPUT_KEEP_RELEASES=5 \
INPUT_DEPLOYMENT_ID=" My_App--Prod!! " \
run_deploy "$stdout" "$stderr"
assert_contains "port=2222" "$stderr"
assert_contains "docroot=/tmp/site" "$stderr"
assert_contains "source=dist" "$stderr"
assert_contains "keep_releases=5" "$stderr"
assert_contains "deployment_id=my-app-prod" "$stderr"
assert_contains "ssh-keyscan -p 2222 example.com" "$stderr"
assert_contains "deploy@example.com:/tmp/site/.github-ssh-deploy/deployments/my-app-prod/incoming/release-test/" "$stderr"

known_hosts_tmp="$tmpdir/known-hosts"
INPUT_KNOWN_HOSTS="example.com ssh-ed25519 AAAATEST" \
GITHUB_SSH_DEPLOY_TMPDIR="$known_hosts_tmp" \
GITHUB_SSH_DEPLOY_KEEP_TEMP=1 \
run_deploy "$stdout" "$stderr"
assert_contains "known_hosts_source=input" "$stderr"
assert_not_contains "ssh-keyscan" "$stderr"
assert_contains "example.com ssh-ed25519 AAAATEST" "$known_hosts_tmp/known_hosts"

if INPUT_PORT=not-a-port run_deploy "$stdout" "$stderr"; then
  fail "invalid port should fail"
fi
assert_contains "port must be an integer from 1 to 65535" "$stderr"

if INPUT_KEEP_RELEASES=zero run_deploy "$stdout" "$stderr"; then
  fail "invalid keep-releases should fail"
fi
assert_contains "keep-releases must be a positive integer" "$stderr"
