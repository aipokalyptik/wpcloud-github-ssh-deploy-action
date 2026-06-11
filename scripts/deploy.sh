#!/usr/bin/env bash
set -euo pipefail

readonly VERSION="0.2.0-transport"

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
    --skeleton)
      die "--skeleton is no longer supported; run deploy.sh without arguments"
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

  [[ "$port" =~ ^[0-9]+$ ]] && (( 10#$port >= 1 && 10#$port <= 65535 )) || die "port must be an integer from 1 to 65535"
  [[ -n "$docroot" ]] || die "docroot must not be empty"
  [[ -n "$source" ]] || die "source must not be empty"
  [[ "$keep_releases" =~ ^[0-9]+$ ]] && (( 10#$keep_releases >= 1 )) || die "keep-releases must be a positive integer"

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

  local remote_base="$docroot/.github-ssh-deploy/deployments/$deployment_id"
  local remote_release="$remote_base/incoming/$release_id"
  local remote_script="$remote_base/remote-deploy.sh"
  local remote_post_deploy="$remote_base/post-deploy/$release_id.sh"
  local local_post_deploy=""
  local local_script_dir
  local_script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  local source_path="$source"
  if [[ "$source_path" != */ ]]; then
    source_path="$source_path/"
  fi

  local ssh_options=(
    -o "BatchMode=no"
    -o "UserKnownHostsFile=$known_hosts_file"
    -o "StrictHostKeyChecking=yes"
    -p "$port"
  )
  local ssh_command
  ssh_command="$(shell_join ssh "${ssh_options[@]}")"

  info "port=$port"
  info "docroot=$docroot"
  info "source=$source"
  info "keep_releases=$keep_releases"
  info "deployment_id=$deployment_id"
  info "release_id=$release_id"
  info "remote_release=$remote_release"
  info "remote_script=$remote_script"
  if [[ -n "$(trim "$post_deploy")" ]]; then
    local_post_deploy="$tmpdir/post-deploy.sh"
    printf '%s' "$post_deploy" >"$local_post_deploy"
    info "post_deploy=provided"
    info "remote_post_deploy=$remote_post_deploy"
  fi

  run_or_print "mkdir" \
    env "SSHPASS=$password" sshpass -e ssh "${ssh_options[@]}" "$username@$host" "mkdir -p $(printf '%q' "$remote_release") $(printf '%q' "${remote_post_deploy%/*}")"

  run_or_print "rsync" \
    env "SSHPASS=$password" sshpass -e rsync -az --delete -e "$ssh_command" "$source_path" "$username@$host:$remote_release/"

  run_or_print "remote-script-upload" \
    env "SSHPASS=$password" sshpass -e rsync -az -e "$ssh_command" "$local_script_dir/remote-deploy.sh" "$username@$host:$remote_script"

  run_or_print "remote-script-chmod" \
    env "SSHPASS=$password" sshpass -e ssh "${ssh_options[@]}" "$username@$host" "chmod 700 $(printf '%q' "$remote_script")"

  if [[ -n "$local_post_deploy" ]]; then
    run_or_print "post-deploy-upload" \
      env "SSHPASS=$password" sshpass -e rsync -az -e "$ssh_command" "$local_post_deploy" "$username@$host:$remote_post_deploy"

    run_or_print "post-deploy-chmod" \
      env "SSHPASS=$password" sshpass -e ssh "${ssh_options[@]}" "$username@$host" "chmod 600 $(printf '%q' "$remote_post_deploy")"
  fi

  local remote_deploy_command="bash $(printf '%q' "$remote_script") --docroot $(printf '%q' "$docroot") --deployment-id $(printf '%q' "$deployment_id") --release-id $(printf '%q' "$release_id") --keep-releases $(printf '%q' "$keep_releases")"
  if [[ -n "$local_post_deploy" ]]; then
    remote_deploy_command+=" --post-deploy-file $(printf '%q' "$remote_post_deploy")"
  fi

  run_or_print "remote-deploy $deployment_id $release_id" \
    env "SSHPASS=$password" sshpass -e ssh "${ssh_options[@]}" "$username@$host" \
      "$remote_deploy_command"
}

password=""
DEPLOY_TMPDIR=""
main "$@"
