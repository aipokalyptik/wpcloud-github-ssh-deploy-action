#!/usr/bin/env bash
set -euo pipefail

readonly VERSION="0.2.0-transport"

password=""
private_key=""
private_key_passphrase=""
auth_mode=""
DEPLOY_TMPDIR=""
REMOTE_LOGIN=""
SSH_COMMAND=""
RSYNC_SSH_COMMAND=""
PASSWORD_ASKPASS_FILE=""
SSH_OPTIONS=()
SSH_AGENT_PID_TO_CLEAN=""

usage() {
  cat <<'USAGE'
Usage: deploy.sh [--help|--version]

Upload a repository snapshot to a remote staging path over SSH/rsync.
Optional INPUT_POST_DEPLOY content is uploaded as a bash hook and run from the
remote docroot after the new release becomes current.
USAGE
}

die() {
  echo "deploy.sh: $*" >&2
  exit 64
}

info() {
  echo "deploy.sh: $*" >&2
}

trim() {
  local value="$1"
  value="${value#"${value%%[![:space:]]*}"}"
  value="${value%"${value##*[![:space:]]}"}"
  printf '%s' "$value"
}

require_input() {
  local name="$1"
  local value="$2"
  [[ -n "$(trim "$value")" ]] || die "missing required input: $name"
}

normalize_id() {
  local value
  value="$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9]+/-/g; s/^-+//; s/-+$//; s/-+/-/g')"
  [[ -n "$value" ]] || die "deployment-id must contain at least one letter or number after normalization"
  printf '%s' "$value"
}

shell_join() {
  local out=""
  local arg
  for arg in "$@"; do
    printf -v arg '%q' "$arg"
    out+=" $arg"
  done
  printf '%s' "${out# }"
}

ensure_sshpass() {
  command -v sshpass >/dev/null 2>&1 && return 0

  # Password auth is the only mode that needs sshpass. On GitHub Actions Linux
  # runners with apt-get we can install it for convenience; elsewhere we fail
  # early so users do not discover the missing dependency halfway through a deploy.
  if [[ "${GITHUB_ACTIONS:-}" == "true" ]] && [[ "${RUNNER_OS:-}" == "Linux" ]] && command -v apt-get >/dev/null 2>&1; then
    info "sshpass not found; installing with apt-get"
    local sudo_cmd=()
    if (( EUID != 0 )); then
      command -v sudo >/dev/null 2>&1 || die "sudo is required to install sshpass on this runner"
      sudo_cmd=(sudo)
    fi
    "${sudo_cmd[@]}" apt-get update
    "${sudo_cmd[@]}" apt-get install -y sshpass
    command -v sshpass >/dev/null 2>&1 || die "sshpass installation did not provide sshpass"
    return 0
  fi

  die "sshpass is required for deployment; install sshpass or run with GITHUB_SSH_DEPLOY_DRY_RUN=1 for command validation"
}

mask_secret() {
  local value="$1"
  local dry_run_redaction="${2:-REDACTED}"

  [[ -n "$value" ]] || return 0

  # Dry-run output is test-fixture data. Preserve the legacy password mask
  # assertion, but never emit private key material to the mask channel there.
  if [[ "${GITHUB_SSH_DEPLOY_DRY_RUN:-}" == "1" ]]; then
    if [[ "$dry_run_redaction" == "__RAW__" ]]; then
      echo "::add-mask::$value"
    else
      echo "::add-mask::$dry_run_redaction"
    fi
    return 0
  fi

  [[ "${GITHUB_ACTIONS:-}" == "true" ]] || return 0

  # GitHub masks exact strings, not multiline blobs. Emit each non-empty line of
  # private key material separately so accidental later output is still covered.
  local line
  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ -n "$line" ]] || continue
    echo "::add-mask::$line"
  done <<<"$value"
}

validate_auth_inputs() {
  # Auth is intentionally exclusive. Silently preferring one credential over
  # another makes stale secrets and misconfigured workflows hard to diagnose.
  if [[ -n "$(trim "$password")" && -n "$(trim "$private_key")" ]]; then
    die "password and private-key are mutually exclusive"
  fi

  if [[ -z "$(trim "$private_key")" && -n "$(trim "$private_key_passphrase")" ]]; then
    die "private-key-passphrase requires private-key"
  fi

  if [[ -n "$(trim "$private_key")" ]]; then
    auth_mode="private-key"
  elif [[ -n "$(trim "$password")" ]]; then
    auth_mode="password"
  else
    die "either password or private-key is required"
  fi
}

write_private_key() {
  local output_file="$1"

  # Dry-run often keeps temp directories for assertions. Write a placeholder so
  # command-shape tests can inspect permissions without persisting a real key.
  if [[ "${GITHUB_SSH_DEPLOY_DRY_RUN:-}" == "1" ]]; then
    printf '%s\n' "PRIVATE_KEY_REDACTED" >"$output_file"
  else
    printf '%s\n' "$private_key" >"$output_file"
  fi
  chmod 600 "$output_file"
}

start_key_agent() {
  local key_file="$1"
  local askpass_file="$2"

  command -v ssh-agent >/dev/null 2>&1 || die "ssh-agent is required for encrypted private-key authentication"
  command -v ssh-add >/dev/null 2>&1 || die "ssh-add is required for encrypted private-key authentication"

  # ssh itself must run with BatchMode=yes so deploys never hang on a prompt.
  # Encrypted keys are therefore unlocked once up front through ssh-agent, using
  # SSH_ASKPASS to feed the passphrase non-interactively to ssh-add.
  cat >"$askpass_file" <<'SH'
#!/bin/sh
printf '%s\n' "${GITHUB_SSH_DEPLOY_KEY_PASSPHRASE:?}"
SH
  chmod 700 "$askpass_file"

  local agent_output
  agent_output="$(ssh-agent -s)"
  eval "$agent_output" >/dev/null
  SSH_AGENT_PID_TO_CLEAN="${SSH_AGENT_PID:-}"

  local ssh_add_stderr="$askpass_file.ssh-add.stderr"
  if ! DISPLAY=none \
    SSH_ASKPASS="$askpass_file" \
    SSH_ASKPASS_REQUIRE=force \
    GITHUB_SSH_DEPLOY_KEY_PASSPHRASE="$private_key_passphrase" \
    ssh-add "$key_file" </dev/null >/dev/null 2>"$ssh_add_stderr"; then
    cat "$ssh_add_stderr" >&2
    die "ssh-add failed for private-key"
  fi
}

write_known_hosts() {
  local known_hosts_input="$1"
  local host="$2"
  local port="$3"
  local output_file="$4"

  if [[ -n "$(trim "$known_hosts_input")" ]]; then
    printf '%s\n' "$known_hosts_input" >"$output_file"
    info "known_hosts_source=input"
    return 0
  fi

  # We never disable host key checking. If callers do not pin known_hosts, use
  # ssh-keyscan for a per-run known_hosts file. This is trust-on-first-use;
  # pinned known-hosts input is the stronger option.
  if [[ "${GITHUB_SSH_DEPLOY_DRY_RUN:-}" == "1" ]]; then
    : >"$output_file"
    info "known_hosts_source=ssh-keyscan"
    info "dry-run: $(shell_join ssh-keyscan -p "$port" "$host") > $(printf '%q' "$output_file")"
    return 0
  fi

  info "known_hosts_source=ssh-keyscan"
  ssh-keyscan -p "$port" "$host" >"$output_file"
  [[ -s "$output_file" ]] || die "ssh-keyscan did not return a host key for $host:$port"
}

write_excludes() {
  local exclude_input="$1"
  local output_file="$2"
  local trimmed_input
  trimmed_input="$(trim "$exclude_input")"

  # Empty input means "use safe defaults"; the literal value "none" is the
  # explicit escape hatch for repositories that really want every path uploaded.
  if [[ -z "$trimmed_input" ]]; then
    cat >"$output_file" <<'EXCLUDES'
.git/
.github/
.svn/
.hg/
.bzr/
.aws/
.ssh/
.env
.env.*
.npmrc
.pypirc
.netrc
.DS_Store
EXCLUDES
    info "exclude_source=default"
    printf '%s\n' "1"
  elif [[ "$trimmed_input" == "none" ]]; then
    : >"$output_file"
    info "exclude_source=none"
    printf '%s\n' "0"
  else
    printf '%s' "$exclude_input" >"$output_file"
    info "exclude_source=input"
    printf '%s\n' "1"
  fi
}

remote_arch() {
  if [[ "${GITHUB_SSH_DEPLOY_DRY_RUN:-}" == "1" ]]; then
    # Dry-run cannot query the remote, but later upload planning needs an arch
    # value to render the exchange-helper commands.
    run_authenticated "remote-arch" ssh "${SSH_OPTIONS[@]}" "$REMOTE_LOGIN" uname -m
    printf '%s\n' "x86_64"
    return 0
  fi

  run_authenticated "remote-arch" ssh "${SSH_OPTIONS[@]}" "$REMOTE_LOGIN" uname -m
}

exchange_helper_for_arch() {
  local arch="$1"
  local repo_root="$2"

  case "$arch" in
    x86_64|amd64)
      printf '%s\n' "$repo_root/helpers/bin/linux-amd64/exchange-rename"
      ;;
    *)
      die "unsupported remote architecture for exchange helper: $arch"
      ;;
  esac
}

cleanup() {
  # Only kill the agent we started. A runner may already have an agent, and the
  # action should not disturb credentials outside this deploy.
  if [[ -n "${SSH_AGENT_PID_TO_CLEAN:-}" ]]; then
    SSH_AGENT_PID="$SSH_AGENT_PID_TO_CLEAN" ssh-agent -k >/dev/null 2>&1 || true
  fi

  if [[ -n "${DEPLOY_TMPDIR:-}" && -z "${GITHUB_SSH_DEPLOY_KEEP_TEMP:-}" && -z "${GITHUB_SSH_DEPLOY_TMPDIR:-}" ]]; then
    rm -rf "$DEPLOY_TMPDIR"
  fi
}

run_or_print() {
  local label="$1"
  shift

  if [[ "${GITHUB_SSH_DEPLOY_DRY_RUN:-}" == "1" ]]; then
    local redacted_args=()
    local arg
    for arg in "$@"; do
      if [[ -n "$password" && "$arg" == "$password" ]]; then
        redacted_args+=("REDACTED")
      elif [[ -n "$password" && "$arg" == "SSHPASS=$password" ]]; then
        redacted_args+=("SSHPASS=REDACTED")
      elif [[ -n "$password" && "$arg" == "GITHUB_SSH_DEPLOY_PASSWORD=$password" ]]; then
        redacted_args+=("GITHUB_SSH_DEPLOY_PASSWORD=REDACTED")
      # The passphrase should never cross argv today. Keep this as a tripwire
      # for future command-shape changes in dry-run logging.
      elif [[ -n "$private_key_passphrase" && "$arg" == "GITHUB_SSH_DEPLOY_KEY_PASSPHRASE=$private_key_passphrase" ]]; then
        redacted_args+=("GITHUB_SSH_DEPLOY_KEY_PASSPHRASE=REDACTED")
      else
        redacted_args+=("$arg")
      fi
    done
    local rendered
    rendered="$(shell_join "${redacted_args[@]}")"
    info "dry-run: $label: $rendered"
    return 0
  fi

  "$@"
}

run_authenticated() {
  local label="$1"
  shift

  # Keep direct SSH password wrapping in one place so probes and remote commands
  # cannot drift. rsync is handled separately because its child SSH process must
  # be wrapped inside the rsync remote-shell command.
  if [[ "$auth_mode" == "password" ]]; then
    run_or_print "$label" env "SSHPASS=$password" sshpass -e "$@"
  else
    run_or_print "$label" "$@"
  fi
}

remote_ssh() {
  local label="$1"
  shift

  run_authenticated "$label" ssh "${SSH_OPTIONS[@]}" "$REMOTE_LOGIN" "$@"
}

remote_rsync() {
  local label="$1"
  local source_path_arg="$2"
  local remote_path_arg="$3"
  shift 3
  local rsync_options=("$@")

  if [[ "$auth_mode" == "password" ]]; then
    run_or_print "$label" env \
      "GITHUB_SSH_DEPLOY_PASSWORD=$password" \
      "DISPLAY=none" \
      "SSH_ASKPASS=$PASSWORD_ASKPASS_FILE" \
      "SSH_ASKPASS_REQUIRE=force" \
      rsync "${rsync_options[@]}" -e "$RSYNC_SSH_COMMAND" "$source_path_arg" "$remote_path_arg"
  else
    run_or_print "$label" rsync "${rsync_options[@]}" -e "$RSYNC_SSH_COMMAND" "$source_path_arg" "$remote_path_arg"
  fi
}

main() {
  case "${1:-}" in
    --help|-h)
      usage
      exit 0
      ;;
    --version)
      echo "$VERSION"
      exit 0
      ;;
    "")
      ;;
    *)
      echo "deploy.sh: unknown argument: $1" >&2
      usage >&2
      exit 64
      ;;
  esac

  local host="${INPUT_HOST:-}"
  local port="${INPUT_PORT:-22}"
  local username="${INPUT_USERNAME:-}"
  password="${INPUT_PASSWORD:-}"
  private_key="${INPUT_PRIVATE_KEY:-}"
  private_key_passphrase="${INPUT_PRIVATE_KEY_PASSPHRASE:-}"
  local docroot="${INPUT_DOCROOT:-/srv/htdocs}"
  local source="${INPUT_SOURCE:-.}"
  local exclude_input="${INPUT_EXCLUDE:-}"
  local keep_releases="${INPUT_KEEP_RELEASES:-2}"
  local post_deploy="${INPUT_POST_DEPLOY:-}"
  local deployment_id_input="${INPUT_DEPLOYMENT_ID:-}"
  local known_hosts_input="${INPUT_KNOWN_HOSTS:-}"

  require_input "host" "$host"
  require_input "username" "$username"
  validate_auth_inputs

  host="$(trim "$host")"
  port="$(trim "$port")"
  username="$(trim "$username")"
  docroot="$(trim "$docroot")"
  source="$(trim "$source")"
  keep_releases="$(trim "$keep_releases")"

  if [[ ! "$port" =~ ^[0-9]+$ ]] || (( 10#$port < 1 || 10#$port > 65535 )); then
    die "port must be an integer from 1 to 65535"
  fi
  [[ -n "$docroot" ]] || die "docroot must not be empty"
  [[ "$docroot" != *[[:space:]]* ]] || die "docroot must not contain whitespace"
  [[ -n "$source" ]] || die "source must not be empty"
  if [[ ! "$keep_releases" =~ ^[0-9]+$ ]] || (( 10#$keep_releases < 1 )); then
    die "keep-releases must be a positive integer"
  fi

  if [[ -z "$(trim "$deployment_id_input")" ]]; then
    deployment_id_input="${GITHUB_REPOSITORY:-}"
    [[ -n "$(trim "$deployment_id_input")" ]] || die "deployment-id is required when GITHUB_REPOSITORY is not set"
  fi
  local deployment_id
  deployment_id="$(normalize_id "$deployment_id_input")"

  local release_id="${GITHUB_SSH_DEPLOY_RELEASE_ID:-}"
  if [[ -z "$release_id" ]]; then
    local sha_part="${GITHUB_SHA:-}"
    sha_part="${sha_part:0:12}"
    [[ -n "$sha_part" ]] || sha_part="manual"
    release_id="$(date -u +%Y%m%d%H%M%S)-$sha_part"
  fi
  release_id="$(normalize_id "$release_id")"

  if [[ "${GITHUB_SSH_DEPLOY_DRY_RUN:-}" != "1" ]]; then
    [[ -e "$source" ]] || die "source path does not exist: $source"
    command -v ssh >/dev/null 2>&1 || die "ssh is required"
    command -v ssh-keyscan >/dev/null 2>&1 || die "ssh-keyscan is required"
    command -v rsync >/dev/null 2>&1 || die "rsync is required"
    if [[ "$auth_mode" == "password" ]]; then
      ensure_sshpass
    fi
  fi

  mask_secret "$password" "__RAW__"
  mask_secret "$private_key" "PRIVATE_KEY_REDACTED"
  mask_secret "$private_key_passphrase" "PRIVATE_KEY_PASSPHRASE_REDACTED"

  local tmpdir
  if [[ -n "${GITHUB_SSH_DEPLOY_TMPDIR:-}" ]]; then
    tmpdir="$GITHUB_SSH_DEPLOY_TMPDIR"
    mkdir -p "$tmpdir"
  else
    tmpdir="$(mktemp -d)"
  fi
  DEPLOY_TMPDIR="$tmpdir"
  trap cleanup EXIT

  local known_hosts_file="$tmpdir/known_hosts"
  write_known_hosts "$known_hosts_input" "$host" "$port" "$known_hosts_file"
  local exclude_file="$tmpdir/rsync-excludes"
  local use_exclude_file
  use_exclude_file="$(write_excludes "$exclude_input" "$exclude_file")"
  if [[ "$auth_mode" == "password" ]]; then
    PASSWORD_ASKPASS_FILE="$tmpdir/password-askpass"
    cat >"$PASSWORD_ASKPASS_FILE" <<'SH'
#!/bin/sh
printf '%s\n' "${GITHUB_SSH_DEPLOY_PASSWORD:?}"
SH
    chmod 700 "$PASSWORD_ASKPASS_FILE"
  fi
  local private_key_file=""
  if [[ "$auth_mode" == "private-key" ]]; then
    private_key_file="$tmpdir/private-key"
    write_private_key "$private_key_file"
    if [[ -n "$(trim "$private_key_passphrase")" ]]; then
      info "private_key_passphrase=provided"
      if [[ "${GITHUB_SSH_DEPLOY_DRY_RUN:-}" != "1" ]]; then
        start_key_agent "$private_key_file" "$tmpdir/ssh-askpass"
      fi
    else
      info "private_key_passphrase=none"
    fi
  fi

  local remote_base="$docroot/.github-ssh-deploy/deployments/$deployment_id"
  local remote_release="$remote_base/incoming/$release_id"
  local remote_script="$remote_base/remote-deploy.sh"
  local remote_exchange_helper="$remote_base/exchange-rename"
  local remote_post_deploy="$remote_base/post-deploy/$release_id.sh"
  local local_post_deploy=""
  local local_script_dir
  local_script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  local repo_root
  repo_root="$(cd "$local_script_dir/.." && pwd)"
  local source_path="$source"
  if [[ "$source_path" != */ ]]; then
    source_path="$source_path/"
  fi

  SSH_OPTIONS=(-o "UserKnownHostsFile=$known_hosts_file" -o "StrictHostKeyChecking=yes" -p "$port")
  if [[ "$auth_mode" == "password" ]]; then
    # Password mode must not accidentally use a runner agent or default key
    # before sshpass has a chance to answer the password prompt.
    SSH_OPTIONS=(
      -o "BatchMode=no"
      -o "PubkeyAuthentication=no"
      -o "PreferredAuthentications=password,keyboard-interactive"
      "${SSH_OPTIONS[@]}"
    )
  else
    # Key mode stays non-interactive. For encrypted keys, ssh matches this key
    # file to the identity already loaded into the temporary agent.
    SSH_OPTIONS=(-o "BatchMode=yes" -o "IdentitiesOnly=yes" -i "$private_key_file" "${SSH_OPTIONS[@]}")
  fi
  REMOTE_LOGIN="$username@$host"
  SSH_COMMAND="$(shell_join ssh "${SSH_OPTIONS[@]}")"
  # rsync launches SSH as a child process, so password-mode uploads use
  # OpenSSH's askpass path. Direct SSH probes still use sshpass above.
  RSYNC_SSH_COMMAND="$SSH_COMMAND"

  info "auth_mode=$auth_mode"
  info "port=$port"
  info "docroot=$docroot"
  info "source=$source"
  info "keep_releases=$keep_releases"
  info "deployment_id=$deployment_id"
  info "release_id=$release_id"
  info "remote_release=$remote_release"
  info "remote_script=$remote_script"
  info "remote_exchange_helper=$remote_exchange_helper"
  if [[ -n "$(trim "$post_deploy")" ]]; then
    local_post_deploy="$tmpdir/post-deploy.sh"
    printf '%s' "$post_deploy" >"$local_post_deploy"
    info "post_deploy=provided"
    info "remote_post_deploy=$remote_post_deploy"
  fi

  local remote_mkdir_command
  remote_mkdir_command="mkdir -p $(printf '%q' "$remote_release")"
  if [[ -n "$local_post_deploy" ]]; then
    remote_mkdir_command+=" $(printf '%q' "${remote_post_deploy%/*}")"
  fi
  remote_ssh "mkdir" "$remote_mkdir_command"

  local arch
  arch="$(trim "$(remote_arch)")"
  info "remote_arch=$arch"
  local local_exchange_helper
  local_exchange_helper="$(exchange_helper_for_arch "$arch" "$repo_root")"
  [[ -f "$local_exchange_helper" ]] || die "exchange helper binary is missing: $local_exchange_helper"

  local rsync_args=(-az --delete)
  if (( use_exclude_file )); then
    rsync_args+=(--exclude-from="$exclude_file")
  fi

  remote_rsync "rsync" "$source_path" "$REMOTE_LOGIN:$remote_release/" "${rsync_args[@]}"

  remote_rsync "remote-script-upload" "$local_script_dir/remote-deploy.sh" "$REMOTE_LOGIN:$remote_script" -az

  remote_ssh "remote-script-chmod" "chmod 700 $(printf '%q' "$remote_script")"

  remote_rsync "exchange-helper-upload" "$local_exchange_helper" "$REMOTE_LOGIN:$remote_exchange_helper" -az

  remote_ssh "exchange-helper-chmod" "chmod 700 $(printf '%q' "$remote_exchange_helper")"

  if [[ -n "$local_post_deploy" ]]; then
    remote_rsync "post-deploy-upload" "$local_post_deploy" "$REMOTE_LOGIN:$remote_post_deploy" -az

    remote_ssh "post-deploy-chmod" "chmod 600 $(printf '%q' "$remote_post_deploy")"
  fi

  local remote_deploy_args=(
    bash "$remote_script"
    --docroot "$docroot"
    --deployment-id "$deployment_id"
    --release-id "$release_id"
    --keep-releases "$keep_releases"
    --exchange-helper "$remote_exchange_helper"
  )
  if [[ -n "$local_post_deploy" ]]; then
    remote_deploy_args+=(--post-deploy-file "$remote_post_deploy")
  fi
  local remote_deploy_command
  remote_deploy_command="$(shell_join "${remote_deploy_args[@]}")"

  remote_ssh "remote-deploy $deployment_id $release_id" "$remote_deploy_command"
}

main "$@"
