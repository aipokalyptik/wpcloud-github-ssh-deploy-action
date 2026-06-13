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
    export INPUT_PRIVATE_KEY="${INPUT_PRIVATE_KEY-}"
    export INPUT_PRIVATE_KEY_PASSPHRASE="${INPUT_PRIVATE_KEY_PASSPHRASE-}"
    export GITHUB_REPOSITORY="${TEST_GITHUB_REPOSITORY-Owner/Example Repo}"
    export GITHUB_SSH_DEPLOY_RELEASE_ID="${GITHUB_SSH_DEPLOY_RELEASE_ID-release-test}"
    "$deploy" "$@"
  ) >"$stdout_file" 2>"$stderr_file"
}

make_fake_git() {
  local bin_dir="$1"
  mkdir -p "$bin_dir"
  cat >"$bin_dir/git" <<'SH'
#!/usr/bin/env bash
set -euo pipefail

log_call() {
  if [[ -n "${FAKE_GIT_LOG:-}" ]]; then
    printf '%s\n' "git $*" >>"$FAKE_GIT_LOG"
  fi
}

if [[ "${1:-}" == "-C" ]]; then
  shift 2
fi

log_call "$@"

case "${1:-}" in
  rev-parse)
    case "${2:-}" in
      --is-inside-work-tree)
        [[ "${FAKE_GIT_INSIDE_WORKTREE:-1}" == "1" ]] && { printf 'true\n'; exit 0; }
        printf 'false\n'
        exit 1
        ;;
      --show-toplevel)
        printf '%s\n' "${FAKE_GIT_WORKTREE:?}"
        exit 0
        ;;
    esac
    ;;
  config)
    if [[ "${2:-}" == "--bool" && "${3:-}" == "core.sparseCheckout" ]]; then
      if [[ "${FAKE_GIT_SPARSE:-0}" == "1" ]]; then
        printf 'true\n'
      else
        printf 'false\n'
      fi
      exit 0
    fi
    ;;
  lfs)
    case "${2:-}" in
      version)
        [[ "${FAKE_GIT_LFS_AVAILABLE:-1}" == "1" ]] && { printf 'git-lfs/3.0.0\n'; exit 0; }
        exit 1
        ;;
      install|pull)
        exit 0
        ;;
    esac
    ;;
  submodule)
    case "${2:-}" in
      update)
        exit 0
        ;;
      status)
        printf '%s\n' "${FAKE_GIT_SUBMODULE_STATUS:-}"
        exit 0
        ;;
    esac
    ;;
esac

exit 0
SH
  chmod +x "$bin_dir/git"
}

tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT

stdout="$tmpdir/stdout"
stderr="$tmpdir/stderr"

# Dry-run skips ssh-agent setup, so this local mechanism test covers the
# non-interactive encrypted-key path without needing a remote SSH server.
if command -v ssh-keygen >/dev/null 2>&1 && command -v ssh-agent >/dev/null 2>&1 && command -v ssh-add >/dev/null 2>&1; then
  agent_tmp="$tmpdir/agent"
  mkdir -p "$agent_tmp"
  agent_key="$agent_tmp/key"
  askpass="$agent_tmp/askpass"
  ssh_keygen_output="$agent_tmp/ssh-keygen.out"
  ssh_add_stderr="$agent_tmp/ssh-add.stderr"
  if ! ssh-keygen -q -t ed25519 -N "test-passphrase" -C "github-ssh-deploy-test" -f "$agent_key" >"$ssh_keygen_output" 2>&1; then
    cat "$ssh_keygen_output" >&2
    fail "ssh-keygen should create encrypted test key"
  fi
  cat >"$askpass" <<'SH'
#!/bin/sh
printf '%s\n' "${TEST_KEY_PASSPHRASE:?}"
SH
  chmod 700 "$askpass"
  agent_output="$(ssh-agent -s)"
  eval "$agent_output" >/dev/null
  agent_pid="$SSH_AGENT_PID"
  kill_test_agent() {
    SSH_AGENT_PID="$agent_pid" ssh-agent -k >/dev/null 2>&1 || true
  }
  if ! DISPLAY=none SSH_ASKPASS="$askpass" SSH_ASKPASS_REQUIRE=force TEST_KEY_PASSPHRASE="test-passphrase" ssh-add "$agent_key" </dev/null >/dev/null 2>"$ssh_add_stderr"; then
    cat "$ssh_add_stderr" >&2
    kill_test_agent
    fail "ssh-add should load encrypted key through SSH_ASKPASS"
  fi
  if ! ssh-add -l | grep -Fq "github-ssh-deploy-test"; then
    kill_test_agent
    fail "ssh-agent should contain encrypted test key"
  fi
  kill_test_agent
  unset SSH_AUTH_SOCK SSH_AGENT_PID
else
  echo "ssh-keygen, ssh-agent, or ssh-add not found; skipping encrypted key askpass mechanism test" >&2
fi

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

if INPUT_PASSWORD="" INPUT_PRIVATE_KEY="" run_deploy "$stdout" "$stderr"; then
  fail "missing auth should fail"
fi
assert_contains "either password or private-key is required" "$stderr"
unset INPUT_PASSWORD

if INPUT_PASSWORD="secret-password" INPUT_PRIVATE_KEY="PRIVATE KEY" run_deploy "$stdout" "$stderr"; then
  fail "conflicting auth methods should fail"
fi
assert_contains "password and private-key are mutually exclusive" "$stderr"
unset INPUT_PASSWORD INPUT_PRIVATE_KEY

if INPUT_PASSWORD="" INPUT_PRIVATE_KEY_PASSPHRASE="something" run_deploy "$stdout" "$stderr"; then
  fail "private-key-passphrase without private-key should fail"
fi
assert_contains "private-key-passphrase requires private-key" "$stderr"
unset INPUT_PASSWORD INPUT_PRIVATE_KEY_PASSPHRASE

if run_deploy "$stdout" "$stderr" --skeleton; then
  fail "--skeleton should be rejected as an unknown argument"
fi
assert_contains "unknown argument: --skeleton" "$stderr"

if INPUT_DOCROOT=$'/tmp/site with spaces' run_deploy "$stdout" "$stderr"; then
  fail "docroot containing whitespace should fail"
fi
assert_contains "docroot must not contain whitespace" "$stderr"
unset INPUT_DOCROOT

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
assert_contains "auth_mode=password" "$stderr"
assert_contains "scripts/remote-deploy.sh" "$stderr"
assert_contains "helpers/bin/linux-amd64/exchange-rename" "$stderr"
assert_contains "exchange-helper-upload" "$stderr"
assert_contains "exchange-helper-chmod" "$stderr"
assert_contains "remote-deploy owner-example-repo release-test" "$stderr"
assert_contains "--exchange-helper\\ /srv/htdocs/.github-ssh-deploy/deployments/owner-example-repo/exchange-rename" "$stderr"
assert_contains "env SSHPASS=REDACTED sshpass -e" "$stderr"
assert_contains "rsync -az --delete" "$stderr"
assert_contains "GITHUB_SSH_DEPLOY_PASSWORD=REDACTED" "$stderr"
assert_not_contains "-e sshpass\\ -e\\ ssh" "$stderr"
assert_contains "-o PubkeyAuthentication=no" "$stderr"
assert_contains "-o PreferredAuthentications=password\\,keyboard-interactive" "$stderr"
assert_not_contains "PreferredAuthentications=password\\\\\\\\\\\\,keyboard-interactive" "$stderr"
assert_not_contains "secret-password" "$stderr"

private_key=$'-----BEGIN OPENSSH PRIVATE KEY-----\nfake-private-key-body\n-----END OPENSSH PRIVATE KEY-----'
key_tmp="$tmpdir/key-auth"
INPUT_PASSWORD="" \
INPUT_PRIVATE_KEY="$private_key" \
GITHUB_SSH_DEPLOY_TMPDIR="$key_tmp" \
GITHUB_SSH_DEPLOY_KEEP_TEMP=1 \
run_deploy "$stdout" "$stderr"
assert_contains "auth_mode=private-key" "$stderr"
assert_contains "-o IdentitiesOnly=yes" "$stderr"
assert_contains "-i $key_tmp/private-key" "$stderr"
assert_not_contains "sshpass" "$stderr"
assert_not_contains "fake-private-key-body" "$stdout"
assert_not_contains "fake-private-key-body" "$stderr"
[[ -f "$key_tmp/private-key" ]] || fail "private key file should be written"
if [[ "$(uname -s)" == "Darwin" ]]; then
  key_mode="$(stat -f %Lp "$key_tmp/private-key")"
else
  key_mode="$(stat -c %a "$key_tmp/private-key")"
fi
[[ "$key_mode" == "600" ]] || fail "private key file should be mode 600"
assert_contains "PRIVATE_KEY_REDACTED" "$key_tmp/private-key"
assert_not_contains "fake-private-key-body" "$key_tmp/private-key"
unset INPUT_PASSWORD INPUT_PRIVATE_KEY

passphrase_tmp="$tmpdir/key-passphrase-auth"
INPUT_PASSWORD="" \
INPUT_PRIVATE_KEY="$private_key" \
INPUT_PRIVATE_KEY_PASSPHRASE="something" \
GITHUB_SSH_DEPLOY_TMPDIR="$passphrase_tmp" \
GITHUB_SSH_DEPLOY_KEEP_TEMP=1 \
run_deploy "$stdout" "$stderr"
assert_contains "auth_mode=private-key" "$stderr"
assert_contains "private_key_passphrase=provided" "$stderr"
assert_not_contains "something" "$stdout"
assert_not_contains "something" "$stderr"
assert_not_contains "sshpass" "$stderr"
unset INPUT_PASSWORD INPUT_PRIVATE_KEY INPUT_PRIVATE_KEY_PASSPHRASE

default_exclude_tmp="$tmpdir/default-excludes"
GITHUB_SSH_DEPLOY_TMPDIR="$default_exclude_tmp" \
GITHUB_SSH_DEPLOY_KEEP_TEMP=1 \
run_deploy "$stdout" "$stderr"
assert_contains ".git" "$default_exclude_tmp/rsync-excludes"
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
  mkdir -p "$rsync_source/.github" "$rsync_source/.well-known" "$rsync_dest"
  printf 'gitdir: /tmp/local-worktree\n' >"$rsync_source/.git"
  printf 'workflow\n' >"$rsync_source/.github/deploy.yml"
  printf 'env\n' >"$rsync_source/.env"
  printf 'apache\n' >"$rsync_source/.htaccess"
  printf 'challenge\n' >"$rsync_source/.well-known/acme-challenge"
  printf 'public\n' >"$rsync_source/index.php"

  rsync -a --delete --exclude-from="$default_exclude_tmp/rsync-excludes" "$rsync_source/" "$rsync_dest/"
  [[ ! -e "$rsync_dest/.git" ]] || fail "default excludes should omit .git files and directories"
  [[ ! -e "$rsync_dest/.github/deploy.yml" ]] || fail "default excludes should omit .github/"
  [[ ! -e "$rsync_dest/.env" ]] || fail "default excludes should omit .env"
  [[ -f "$rsync_dest/.htaccess" ]] || fail "default excludes should allow .htaccess"
  [[ -f "$rsync_dest/.well-known/acme-challenge" ]] || fail "default excludes should allow .well-known/"
  [[ -f "$rsync_dest/index.php" ]] || fail "default excludes should allow normal files"
fi

git_prep_tmp="$tmpdir/git-prep"
mkdir -p "$git_prep_tmp/source"
fake_git_bin="$git_prep_tmp/bin"
fake_git_log="$git_prep_tmp/git.log"
make_fake_git "$fake_git_bin"

FAKE_GIT_INSIDE_WORKTREE=0 \
FAKE_GIT_WORKTREE="$git_prep_tmp/source" \
FAKE_GIT_LOG="$fake_git_log" \
PATH="$fake_git_bin:$PATH" \
INPUT_SOURCE="$git_prep_tmp/source" \
run_deploy "$stdout" "$stderr"
assert_contains "prepare_git=skipped non-git-source" "$stderr"

: >"$fake_git_log"
FAKE_GIT_INSIDE_WORKTREE=1 \
FAKE_GIT_WORKTREE="$git_prep_tmp/source" \
FAKE_GIT_LOG="$fake_git_log" \
PATH="$fake_git_bin:$PATH" \
INPUT_PREPARE_GIT=false \
INPUT_SOURCE="$git_prep_tmp/source" \
run_deploy "$stdout" "$stderr"
assert_contains "prepare_git=disabled" "$stderr"
assert_not_contains "rev-parse" "$fake_git_log"
unset INPUT_PREPARE_GIT INPUT_SOURCE

if INPUT_PREPARE_GIT=maybe run_deploy "$stdout" "$stderr"; then
  fail "invalid prepare-git should fail"
fi
assert_contains "prepare-git must be true or false" "$stderr"
unset INPUT_PREPARE_GIT

if FAKE_GIT_INSIDE_WORKTREE=1 \
  FAKE_GIT_WORKTREE="$git_prep_tmp/source" \
  FAKE_GIT_SPARSE=1 \
  FAKE_GIT_LOG="$fake_git_log" \
  PATH="$fake_git_bin:$PATH" \
  INPUT_SOURCE="$git_prep_tmp/source" \
  run_deploy "$stdout" "$stderr"; then
  fail "sparse checkout should fail"
fi
assert_contains "sparse checkout is not supported for deployment; disable sparse checkout or set prepare-git: false intentionally" "$stderr"
unset INPUT_SOURCE

lfs_source="$git_prep_tmp/lfs-source"
mkdir -p "$lfs_source/assets"
printf '*.png filter=lfs diff=lfs merge=lfs -text\n' >"$lfs_source/.gitattributes"
cat >"$lfs_source/assets/logo.png" <<'LFS'
version https://git-lfs.github.com/spec/v1
oid sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
size 123
LFS

if FAKE_GIT_INSIDE_WORKTREE=1 \
  FAKE_GIT_WORKTREE="$lfs_source" \
  FAKE_GIT_LFS_AVAILABLE=0 \
  FAKE_GIT_LOG="$fake_git_log" \
  PATH="$fake_git_bin:$PATH" \
  INPUT_SOURCE="$lfs_source" \
  run_deploy "$stdout" "$stderr"; then
  fail "missing git-lfs should fail when LFS attributes are present"
fi
assert_contains "git-lfs is required to prepare Git LFS files" "$stderr"

: >"$fake_git_log"
if FAKE_GIT_INSIDE_WORKTREE=1 \
  FAKE_GIT_WORKTREE="$lfs_source" \
  FAKE_GIT_LFS_AVAILABLE=1 \
  FAKE_GIT_LOG="$fake_git_log" \
  PATH="$fake_git_bin:$PATH" \
  INPUT_SOURCE="$lfs_source" \
  run_deploy "$stdout" "$stderr"; then
  fail "unresolved LFS pointer should fail"
fi
assert_contains "dry-run: git-lfs-pull: git -C $lfs_source lfs pull" "$stderr"
assert_contains "Git LFS pointer file remains after preparation" "$stderr"
rm -f "$lfs_source/assets/logo.png"
printf 'real image bytes\n' >"$lfs_source/assets/logo.png"
unset INPUT_SOURCE

submodule_source="$git_prep_tmp/submodule-source"
mkdir -p "$submodule_source/vendor"
cat >"$submodule_source/.gitmodules" <<'MODULES'
[submodule "vendor/plugin"]
	path = vendor/plugin
	url = https://example.com/plugin.git
MODULES

: >"$fake_git_log"
if FAKE_GIT_INSIDE_WORKTREE=1 \
  FAKE_GIT_WORKTREE="$submodule_source" \
  FAKE_GIT_SUBMODULE_STATUS="-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa vendor/plugin" \
  FAKE_GIT_LOG="$fake_git_log" \
  PATH="$fake_git_bin:$PATH" \
  INPUT_SOURCE="$submodule_source" \
  run_deploy "$stdout" "$stderr"; then
  fail "unprepared submodule should fail"
fi
assert_contains "dry-run: git-submodule-update: git -C $submodule_source submodule update --init --recursive" "$stderr"
assert_contains "git submodule update --init --recursive did not prepare all submodules" "$stderr"

FAKE_GIT_INSIDE_WORKTREE=1 \
FAKE_GIT_WORKTREE="$submodule_source" \
FAKE_GIT_SUBMODULE_STATUS=" aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa vendor/plugin" \
FAKE_GIT_LOG="$fake_git_log" \
PATH="$fake_git_bin:$PATH" \
INPUT_SOURCE="$submodule_source" \
run_deploy "$stdout" "$stderr"
assert_contains "prepare_git=submodules-prepared" "$stderr"
unset INPUT_SOURCE

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
