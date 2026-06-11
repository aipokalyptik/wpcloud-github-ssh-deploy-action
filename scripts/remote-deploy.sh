#!/usr/bin/env bash
set -euo pipefail

readonly VERSION="0.2.0-layout-locking"

usage() {
  cat <<'USAGE'
Usage: remote-deploy.sh --docroot PATH --deployment-id ID --release-id ID --keep-releases N

Promote an uploaded incoming release into the deployment namespace and update current.
USAGE
}

die() {
  echo "remote-deploy.sh: $*" >&2
  exit 64
}

trim() {
  local value="$1"
  value="${value#"${value%%[![:space:]]*}"}"
  value="${value%"${value##*[![:space:]]}"}"
  printf '%s' "$value"
}

require_id() {
  local name="$1"
  local value="$2"

  [[ "$value" =~ ^[a-z0-9][a-z0-9-]*$ ]] || die "$name must be a normalized id"
}

switch_current() {
  local base="$1"
  local release_id="$2"
  local current="$base/current"
  local tmp_current="$base/.current.$release_id.$$"

  rm -f "$tmp_current"
  ln -s "releases/$release_id" "$tmp_current"

  if mv -T "$tmp_current" "$current" 2>/dev/null; then
    return 0
  fi

  # macOS/BSD mv has no -T. This fallback is intentionally local-testable only:
  # it replaces a file/symlink current pointer, but refuses a real directory.
  if [[ -d "$current" && ! -L "$current" ]]; then
    rm -f "$tmp_current"
    die "current exists as a directory; cannot replace without mv -T"
  fi
  rm -f "$current"
  mv "$tmp_current" "$current"
}

fallback_lock_dir=""

release_fallback_lock() {
  if [[ -n "$fallback_lock_dir" ]]; then
    rmdir "$fallback_lock_dir" 2>/dev/null || true
  fi
}

acquire_lock() {
  local lock_file="$1"

  if command -v flock >/dev/null 2>&1; then
    exec 9>"$lock_file"
    flock -x 9
    return 0
  fi

  : >"$lock_file"
  fallback_lock_dir="$lock_file.dir"
  until mkdir "$fallback_lock_dir" 2>/dev/null; do
    sleep 0.1
  done
  trap release_fallback_lock EXIT
}

prune_releases() {
  local releases_dir="$1"
  local keep_releases="$2"
  local releases=()
  local release

  shopt -s nullglob
  for release in "$releases_dir"/*; do
    [[ -d "$release" ]] || continue
    releases+=("$(basename "$release")")
  done
  shopt -u nullglob

  ((${#releases[@]} > keep_releases)) || return 0

  local sorted
  sorted="$(printf '%s\n' "${releases[@]}" | LC_ALL=C sort -r)"

  local index=0
  local release_name
  while IFS= read -r release_name; do
    index=$((index + 1))
    if ((index > keep_releases)); then
      rm -rf -- "$releases_dir/$release_name"
    fi
  done <<<"$sorted"
}

main() {
  local docroot=""
  local deployment_id=""
  local release_id=""
  local keep_releases=""

  while (($#)); do
    case "$1" in
      --help|-h)
        usage
        exit 0
        ;;
      --version)
        echo "$VERSION"
        exit 0
        ;;
      --docroot)
        (($# >= 2)) || die "--docroot requires a value"
        docroot="$2"
        shift 2
        ;;
      --deployment-id)
        (($# >= 2)) || die "--deployment-id requires a value"
        deployment_id="$2"
        shift 2
        ;;
      --release-id)
        (($# >= 2)) || die "--release-id requires a value"
        release_id="$2"
        shift 2
        ;;
      --keep-releases)
        (($# >= 2)) || die "--keep-releases requires a value"
        keep_releases="$2"
        shift 2
        ;;
      *)
        die "unknown argument: $1"
        ;;
    esac
  done

  docroot="$(trim "$docroot")"
  deployment_id="$(trim "$deployment_id")"
  release_id="$(trim "$release_id")"
  keep_releases="$(trim "$keep_releases")"

  [[ -n "$docroot" ]] || die "docroot is required"
  require_id "deployment-id" "$deployment_id"
  require_id "release-id" "$release_id"
  [[ "$keep_releases" =~ ^[0-9]+$ ]] && ((10#$keep_releases >= 1)) || die "keep-releases must be a positive integer"

  command -v readlink >/dev/null 2>&1 || die "readlink is required"

  local base="$docroot/.github-ssh-deploy/deployments/$deployment_id"
  local incoming_dir="$base/incoming"
  local releases_dir="$base/releases"
  local incoming_release="$incoming_dir/$release_id"
  local release_dir="$releases_dir/$release_id"
  local lock_file="$base/deploy.lock"

  mkdir -p "$incoming_dir" "$releases_dir"

  acquire_lock "$lock_file"

  [[ -d "$incoming_release" ]] || die "incoming release does not exist: $incoming_release"
  [[ ! -e "$release_dir" ]] || die "release already exists: $release_dir"

  mv "$incoming_release" "$release_dir"
  switch_current "$base" "$release_id"
  [[ "$(readlink "$base/current")" == "releases/$release_id" ]] || die "current does not point to releases/$release_id"
  prune_releases "$releases_dir" "$keep_releases"

  echo "remote-deploy.sh: current=releases/$release_id" >&2
}

main "$@"
