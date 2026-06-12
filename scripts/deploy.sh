#!/usr/bin/env bash
set -euo pipefail

readonly VERSION="0.2.0-transport"

password=""
DEPLOY_TMPDIR=""
REMOTE_LOGIN=""
SSH_COMMAND=""
SSH_OPTIONS=()

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

  if [[ "${GITHUB_ACTIONS:-}" == "true" ]] && [[ "${RUNNER_OS:-}" == "Linux" ]] && command -v apt-get >/dev/null 2>&1; then
    info "sshpass not found; installing with apt-get"
    sudo apt-get update
    sudo apt-get install -y sshpass
    command -v sshpass >/dev/null 2>&1 || die "sshpass installation did not provide sshpass"
    return 0
  fi

  die "sshpass is required for deployment; install sshpass or run with GITHUB_SSH_DEPLOY_DRY_RUN=1 for command validation"
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
    info "dry-run: remote-arch: $(shell_join env "SSHPASS=REDACTED" sshpass -e ssh "${SSH_OPTIONS[@]}" "$REMOTE_LOGIN" uname -m)"
    printf '%s\n' "x86_64"
    return 0
  fi

  env "SSHPASS=$password" sshpass -e ssh "${SSH_OPTIONS[@]}" "$REMOTE_LOGIN" uname -m
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
      if [[ "$arg" == "$password" ]]; then
        redacted_args+=("REDACTED")
      elif [[ "$arg" == "SSHPASS=$password" ]]; then
        redacted_args+=("SSHPASS=REDACTED")
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

remote_ssh() {
  local label="$1"
  shift

  run_or_print "$label" \
    env "SSHPASS=$password" sshpass -e ssh "${SSH_OPTIONS[@]}" "$REMOTE_LOGIN" "$@"
}

remote_rsync() {
  local label="$1"
  local source_path_arg="$2"
  local remote_path_arg="$3"
  shift
  shift
  shift
  local rsync_options=()

  rsync_options=("$@")
  run_or_print "$label" \
    env "SSHPASS=$password" sshpass -e rsync "${rsync_options[@]}" -e "$SSH_COMMAND" "$source_path_arg" "$remote_path_arg"
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
  local docroot="${INPUT_DOCROOT:-/srv/htdocs}"
  local source="${INPUT_SOURCE:-.}"
  local exclude_input="${INPUT_EXCLUDE:-}"
  local keep_releases="${INPUT_KEEP_RELEASES:-2}"
  local post_deploy="${INPUT_POST_DEPLOY:-}"
  local deployment_id_input="${INPUT_DEPLOYMENT_ID:-}"
  local known_hosts_input="${INPUT_KNOWN_HOSTS:-}"

  require_input "host" "$host"
  require_input "username" "$username"
  require_input "password" "$password"

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
    ensure_sshpass
  fi

  echo "::add-mask::$password"

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

  SSH_OPTIONS=(
    -o "BatchMode=no"
    -o "UserKnownHostsFile=$known_hosts_file"
    -o "StrictHostKeyChecking=yes"
    -p "$port"
  )
  REMOTE_LOGIN="$username@$host"
  SSH_COMMAND="$(shell_join ssh "${SSH_OPTIONS[@]}")"

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
