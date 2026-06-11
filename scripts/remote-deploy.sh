#!/usr/bin/env bash
set -euo pipefail

readonly VERSION="0.3.0-claim-compression"

usage() {
  cat <<'USAGE'
Usage: remote-deploy.sh --docroot PATH --deployment-id ID --release-id ID --keep-releases N [--print-claims]

Promote an uploaded incoming release into the deployment namespace and update current.

Options:
  --print-claims  Print compressed claims for the incoming release and exit without
                  promoting the release or changing current.
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

  # Some mv implementations do not provide -T. This fallback safely replaces a
  # file/symlink current pointer, but refuses a real directory.
  if [[ -d "$current" && ! -L "$current" ]]; then
    rm -f "$tmp_current"
    die "current exists as a directory; cannot replace without mv -T"
  fi
  rm -f "$current"
  mv "$tmp_current" "$current"
}

acquire_lock() {
  local lock_file="$1"

  exec 9>"$lock_file"
  flock -x 9
}

prune_releases() {
  local releases_dir="$1"
  local keep_releases="$2"
  local active_release="$3"
  local keep_non_active=$((keep_releases - 1))
  local retained=0
  local release_path
  local release_name

  while IFS= read -r release_path; do
    release_name="${release_path##*/}"
    [[ "$release_name" == "$active_release" ]] && continue

    if ((retained < keep_non_active)); then
      retained=$((retained + 1))
      continue
    fi

    rm -rf -- "$release_path"
  done < <(find "$releases_dir" -mindepth 1 -maxdepth 1 -type d -exec ls -dt {} + 2>/dev/null)
}

normalize_public_path() {
  local value="$1"

  value="${value#./}"
  while [[ "$value" == */ ]]; do
    value="${value%/}"
  done

  if [[ "$value" == "." ]]; then
    value=""
  fi

  printf '%s' "$value"
}

discover_boundary_claims() {
  local docroot="$1"
  local output_file="$2"
  local boundary
  local normalized

  : >"$output_file"

  if [[ -n "${GITHUB_SSH_DEPLOY_BOUNDARIES_FILE:-}" ]]; then
    [[ -f "$GITHUB_SSH_DEPLOY_BOUNDARIES_FILE" ]] || die "boundary override file does not exist: $GITHUB_SSH_DEPLOY_BOUNDARIES_FILE"
    while IFS= read -r boundary || [[ -n "$boundary" ]]; do
      normalized="$(normalize_public_path "$boundary")"
      printf '%s\n' "$normalized"
    done <"$GITHUB_SSH_DEPLOY_BOUNDARIES_FILE"
  else
    while IFS= read -r boundary; do
      if [[ "$boundary" == "$docroot" ]]; then
        normalized=""
      else
        normalized="$(normalize_public_path "${boundary#"$docroot"/}")"
      fi
      printf '%s\n' "$normalized"
    done < <(find "$docroot" -type d \( -uid 0 -or -gid 0 \) -and -perm -1000 2>/dev/null)
  fi | sort -u >"$output_file"
}

claim_for_path() {
  local public_path="$1"
  local boundaries_file="$2"
  local best_boundary=""
  local boundary
  local remainder
  local next_segment

  while IFS= read -r boundary || [[ -n "$boundary" ]]; do
    if [[ -z "$boundary" ]]; then
      continue
    fi

    if [[ "$public_path" == "$boundary/"* && ${#boundary} -gt ${#best_boundary} ]]; then
      best_boundary="$boundary"
    fi
  done <"$boundaries_file"

  if [[ -n "$best_boundary" ]]; then
    remainder="${public_path#"$best_boundary"/}"
    next_segment="${remainder%%/*}"
    printf '%s/%s\n' "$best_boundary" "$next_segment"
    return
  fi

  printf '%s\n' "${public_path%%/*}"
}

compute_claims() {
  local release_tree="$1"
  local boundaries_file="$2"
  local output_file="$3"
  local release_file
  local public_path

  : >"$output_file"
  [[ -d "$release_tree" ]] || return 0

  while IFS= read -r release_file; do
    public_path="${release_file#"$release_tree"/}"

    case "$public_path" in
      .git|.git/*|.github-ssh-deploy|.github-ssh-deploy/*)
        continue
        ;;
    esac

    claim_for_path "$public_path" "$boundaries_file"
  done < <(find "$release_tree" \( -type f -or -type l \) -print) | sort -u >"$output_file"
}

main() {
  local docroot=""
  local deployment_id=""
  local release_id=""
  local keep_releases=""
  local print_claims=0

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
      --print-claims)
        print_claims=1
        shift
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
  command -v flock >/dev/null 2>&1 || die "flock is required"

  local base="$docroot/.github-ssh-deploy/deployments/$deployment_id"
  local incoming_dir="$base/incoming"
  local releases_dir="$base/releases"
  local incoming_release="$incoming_dir/$release_id"
  local release_dir="$releases_dir/$release_id"
  local lock_file="$base/deploy.lock"
  local boundaries_file="$base/boundaries"
  local old_claims_file="$base/old_claims"
  local new_claims_file="$base/new_claims"
  local current_target=""

  mkdir -p "$incoming_dir" "$releases_dir"

  acquire_lock "$lock_file"

  [[ -d "$incoming_release" ]] || die "incoming release does not exist: $incoming_release"

  discover_boundary_claims "$docroot" "$boundaries_file"

  if ((print_claims)); then
    compute_claims "$incoming_release" "$boundaries_file" "$new_claims_file"
    cat "$new_claims_file"
    exit 0
  fi

  [[ ! -e "$release_dir" ]] || die "release already exists: $release_dir"

  if [[ -L "$base/current" ]]; then
    current_target="$(readlink "$base/current")"
    compute_claims "$base/$current_target" "$boundaries_file" "$old_claims_file"
  else
    : >"$old_claims_file"
  fi

  mv "$incoming_release" "$release_dir"
  touch "$release_dir"
  compute_claims "$release_dir" "$boundaries_file" "$new_claims_file"
  switch_current "$base" "$release_id"
  [[ "$(readlink "$base/current")" == "releases/$release_id" ]] || die "current does not point to releases/$release_id"
  prune_releases "$releases_dir" "$keep_releases" "$release_id"

  echo "remote-deploy.sh: current=releases/$release_id" >&2
}

main "$@"
