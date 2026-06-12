#!/usr/bin/env bash
set -euo pipefail

readonly VERSION="0.3.0-claim-compression"

usage() {
  cat <<'USAGE'
Usage: remote-deploy.sh --docroot PATH --deployment-id ID --release-id ID --keep-releases N [--exchange-helper PATH] [--post-deploy-file PATH] [--print-claims]
       remote-deploy.sh --docroot PATH --deployment-id ID --rollback-to RELEASE_ID [--exchange-helper PATH]

Promote an uploaded incoming release into the deployment namespace and update current.

Options:
  --post-deploy-file PATH
                  Run this bash command file from the docroot after current is
                  updated and stale symlinks are cleaned up. Failure exits
                  nonzero without rolling back the active release.
  --print-claims  Print compressed claims for the incoming release and exit without
                  promoting the release or changing current.
  --rollback-to RELEASE_ID
                  Re-point current to an existing release and reconcile managed
                  public symlinks. Post-deploy commands are not run.
  --exchange-helper PATH
                  Helper binary that atomically swaps two paths with
                  renameat2(RENAME_EXCHANGE). Defaults to the uploaded helper in
                  the deployment namespace.
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

RUN_SCRATCH_DIR=""

cleanup_run_scratch() {
  if [[ -n "$RUN_SCRATCH_DIR" ]]; then
    rm -rf -- "$RUN_SCRATCH_DIR" 2>/dev/null || true
  fi
}

require_remote_capabilities() {
  local command_name
  local probe_dir

  for command_name in readlink flock find sort comm cut ln rm mv mkdir mktemp; do
    command -v "$command_name" >/dev/null 2>&1 || die "$command_name is required"
  done

  probe_dir="$(mktemp -d "${TMPDIR:-/tmp}/github-ssh-deploy-mv.XXXXXX")" || die "mktemp is required"
  : >"$probe_dir/source"
  if ! mv -T "$probe_dir/source" "$probe_dir/dest" 2>/dev/null; then
    rm -rf -- "$probe_dir"
    die "atomic replacement requires mv -T"
  fi
  rm -rf -- "$probe_dir"
}

create_scratch_dir() {
  local base="$1"

  cleanup_run_scratch
  RUN_SCRATCH_DIR="$(mktemp -d "$base/.tmp.XXXXXX")" || die "could not create scratch directory under $base"
  printf '%s\n' "$RUN_SCRATCH_DIR"
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

  rm -f "$tmp_current"
  die "atomic current replacement requires mv -T"
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

  { find "$releases_dir" -mindepth 1 -maxdepth 1 -type d -printf '%T@\t%p\n' 2>/dev/null || true; } |
  sort -rn |
  while IFS=$'\t' read -r _ release_path; do
    release_name="${release_path##*/}"
    [[ "$release_name" == "$active_release" ]] && continue

    if ((retained < keep_non_active)); then
      retained=$((retained + 1))
      continue
    fi

    rm -rf -- "$release_path"
  done
}

run_post_deploy() {
  local docroot="$1"
  local post_deploy_file="$2"

  [[ -n "$post_deploy_file" ]] || return 0
  [[ -f "$post_deploy_file" ]] || die "post-deploy file does not exist: $post_deploy_file"

  (cd "$docroot" && bash -e "$post_deploy_file")
}

public_symlink_target() {
  local deployment_id="$1"
  local claim="$2"
  local parent="$claim"
  local prefix=""

  if [[ "$parent" == */* ]]; then
    parent="${parent%/*}"
    while [[ -n "$parent" ]]; do
      prefix="../$prefix"
      if [[ "$parent" == */* ]]; then
        parent="${parent%/*}"
      else
        parent=""
      fi
    done
  fi

  printf '%s.github-ssh-deploy/deployments/%s/current/%s\n' "$prefix" "$deployment_id" "$claim"
}

reconcile_new_claims() {
  local docroot="$1"
  local deployment_id="$2"
  local claims_file="$3"
  local exchange_helper="$4"
  local exchanged_paths_file="$5"
  local claim
  local public_path
  local parent_dir
  local target
  local tmp_link

  while IFS= read -r claim || [[ -n "$claim" ]]; do
    [[ -n "$claim" ]] || continue

    public_path="$docroot/$claim"
    parent_dir="${public_path%/*}"
    target="$(public_symlink_target "$deployment_id" "$claim")"
    tmp_link="$parent_dir/.${public_path##*/}.github-ssh-deploy.$$"

    reject_foreign_deployment_ancestor_claim "$docroot" "$deployment_id" "$claim"
    mkdir -p -- "$parent_dir"
    reject_foreign_deployment_claim "$deployment_id" "$claim" "$public_path"
    reject_foreign_deployment_descendant_claim "$deployment_id" "$claim" "$public_path"
    rm -f -- "$tmp_link"
    ln -s "$target" "$tmp_link"

    if [[ ! -e "$public_path" && ! -L "$public_path" ]]; then
      mv -T -- "$tmp_link" "$public_path"
      continue
    fi

    [[ -x "$exchange_helper" ]] || die "exchange helper is required to reclaim existing path: $claim"
    if ! "$exchange_helper" "$tmp_link" "$public_path"; then
      rm -f -- "$tmp_link"
      die "exchange helper failed to reclaim path: $claim"
    fi
    printf '%s\n' "$tmp_link" >>"$exchanged_paths_file"
  done <"$claims_file"
}

cleanup_exchanged_paths() {
  local exchanged_paths_file="$1"
  local path

  [[ -f "$exchanged_paths_file" ]] || return 0
  while IFS= read -r path || [[ -n "$path" ]]; do
    [[ -n "$path" ]] || continue
    rm -rf -- "$path"
  done <"$exchanged_paths_file"
}

compute_removed_claims() {
  local old_claims_file="$1"
  local new_claims_file="$2"
  local removed_claims_file="$3"
  local old_sorted="$removed_claims_file.old.$$"
  local new_sorted="$removed_claims_file.new.$$"

  rm -f -- "$old_sorted" "$new_sorted"
  sort -u "$old_claims_file" >"$old_sorted"
  sort -u "$new_claims_file" >"$new_sorted"
  comm -23 "$old_sorted" "$new_sorted" >"$removed_claims_file"
  rm -f -- "$old_sorted" "$new_sorted"
}

deployment_owner_from_target() {
  local target="$1"

  if [[ "$target" =~ (^|/)\.github-ssh-deploy/deployments/([^/]+)/current($|/) ]]; then
    printf '%s\n' "${BASH_REMATCH[2]}"
    return 0
  fi

  return 1
}

reject_foreign_deployment_claim() {
  local deployment_id="$1"
  local claim="$2"
  local public_path="$3"
  local target
  local owner

  [[ -L "$public_path" ]] || return 0

  target="$(readlink "$public_path")"
  if owner="$(deployment_owner_from_target "$target")" && [[ "$owner" != "$deployment_id" ]]; then
    die "claim owned by another deployment: $claim"
  fi
}

reject_foreign_deployment_ancestor_claim() {
  local docroot="$1"
  local deployment_id="$2"
  local claim="$3"
  local ancestor="$docroot"
  local remainder="$claim"
  local component
  local target
  local owner

  while [[ "$remainder" == */* ]]; do
    component="${remainder%%/*}"
    remainder="${remainder#*/}"
    ancestor="$ancestor/$component"

    if [[ -L "$ancestor" ]]; then
      target="$(readlink "$ancestor")"
      if owner="$(deployment_owner_from_target "$target")" && [[ "$owner" != "$deployment_id" ]]; then
        die "claim owned by another deployment: $claim"
      fi
    fi
  done
}

reject_foreign_deployment_descendant_claim() {
  local deployment_id="$1"
  local claim="$2"
  local public_path="$3"
  local link_path
  local target
  local owner

  [[ -d "$public_path" && ! -L "$public_path" ]] || return 0

  { find "$public_path" -mindepth 1 -type l -print0 2>/dev/null || true; } |
  while IFS= read -r -d '' link_path; do
    target="$(readlink "$link_path")"
    if owner="$(deployment_owner_from_target "$target")" && [[ "$owner" != "$deployment_id" ]]; then
      die "claim contains another deployment: $claim"
    fi
  done
}

remove_exact_claim_symlink() {
  local docroot="$1"
  local deployment_id="$2"
  local claim="$3"
  local public_path="$docroot/$claim"
  local target
  local expected_target

  [[ -L "$public_path" ]] || return 0

  target="$(readlink "$public_path")"
  expected_target="$(public_symlink_target "$deployment_id" "$claim")"
  if [[ "$target" == "$expected_target" ]]; then
    rm -f -- "$public_path"
  fi
}

cleanup_removed_claims() {
  local docroot="$1"
  local deployment_id="$2"
  local removed_claims_file="$3"
  local claim

  while IFS= read -r claim || [[ -n "$claim" ]]; do
    [[ -n "$claim" ]] || continue
    remove_exact_claim_symlink "$docroot" "$deployment_id" "$claim"
  done <"$removed_claims_file"
}

claims_overlap() {
  local left="$1"
  local right="$2"

  [[ "$left" == "$right" || "$left" == "$right/"* || "$right" == "$left/"* ]]
}

cleanup_overlapping_removed_claims() {
  local docroot="$1"
  local deployment_id="$2"
  local removed_claims_file="$3"
  local new_claims_file="$4"
  local removed_claim
  local new_claim

  while IFS= read -r removed_claim || [[ -n "$removed_claim" ]]; do
    [[ -n "$removed_claim" ]] || continue

    while IFS= read -r new_claim || [[ -n "$new_claim" ]]; do
      [[ -n "$new_claim" ]] || continue

      if claims_overlap "$removed_claim" "$new_claim"; then
        remove_exact_claim_symlink "$docroot" "$deployment_id" "$removed_claim"
        break
      fi
    done <"$new_claims_file"
  done <"$removed_claims_file"
}

discover_materialized_public_claims() {
  local docroot="$1"
  local deployment_id="$2"
  local output_file="$3"
  local claims_tmp="$output_file.tmp.$$"
  local link_path
  local claim
  local target
  local expected_target

  rm -f -- "$claims_tmp"
  : >"$claims_tmp"

  # shellcheck disable=SC2094
  { find "$docroot" -path "$docroot/.github-ssh-deploy" -prune -o -type l -print0 2>/dev/null || true; } |
  while IFS= read -r -d '' link_path; do
    claim="${link_path#"$docroot"/}"

    if [[ "$claim" == *$'\n'* ]]; then
      rm -f -- "$claims_tmp"
      die "unsupported newline in public symlink path"
    fi

    target="$(readlink "$link_path")"
    expected_target="$(public_symlink_target "$deployment_id" "$claim")"
    if [[ "$target" == "$expected_target" ]]; then
      printf '%s\n' "$claim"
    fi
  done >"$claims_tmp"

  sort -u "$claims_tmp" >"$output_file"
  rm -f -- "$claims_tmp"
}

combine_claims() {
  local output_file="$1"
  shift
  local combined_tmp="$output_file.tmp.$$"

  rm -f -- "$combined_tmp"
  cat "$@" | sort -u >"$combined_tmp"
  mv "$combined_tmp" "$output_file"
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
    { find "$docroot" -type d \( -uid 0 -or -gid 0 \) -and -perm -1000 2>/dev/null || true; } |
    while IFS= read -r boundary; do
      if [[ "$boundary" == "$docroot" ]]; then
        normalized=""
      else
        normalized="$(normalize_public_path "${boundary#"$docroot"/}")"
      fi
      printf '%s\n' "$normalized"
    done
  fi | sort -u >"$output_file"
}

discover_protected_anchors() {
  local docroot="$1"
  local output_file="$2"
  local anchor
  local normalized

  : >"$output_file"

  if [[ -n "${GITHUB_SSH_DEPLOY_PROTECTED_ANCHORS_FILE:-}" ]]; then
    [[ -f "$GITHUB_SSH_DEPLOY_PROTECTED_ANCHORS_FILE" ]] || die "protected anchors override file does not exist: $GITHUB_SSH_DEPLOY_PROTECTED_ANCHORS_FILE"
    while IFS= read -r anchor || [[ -n "$anchor" ]]; do
      normalized="$(normalize_public_path "$anchor")"
      printf '%s\n' "$normalized"
    done <"$GITHUB_SSH_DEPLOY_PROTECTED_ANCHORS_FILE"
  else
    { find "$docroot" \( -uid 0 -or -gid 0 \) -and -not -writable 2>/dev/null || true; } |
    while IFS= read -r anchor; do
      if [[ "$anchor" == "$docroot" ]]; then
        normalized=""
      else
        normalized="$(normalize_public_path "${anchor#"$docroot"/}")"
      fi
      printf '%s\n' "$normalized"
    done
  fi | sort -u >"$output_file"
}

validate_claims_not_protected() {
  local claims_file="$1"
  local protected_anchors_file="$2"
  local claim
  local ancestor
  local pair
  local tmp_prefix
  local ancestor_pairs_file
  local ancestor_keys_file
  local claim_keys_file
  local protected_ancestor_pairs_file
  local protected_ancestor_keys_file
  local protected_keys_file
  local blocked_anchors_file
  local blocked_claim

  tmp_prefix="${claims_file}.protected.$$"
  ancestor_pairs_file="$tmp_prefix.ancestor-pairs"
  ancestor_keys_file="$tmp_prefix.ancestor-keys"
  claim_keys_file="$tmp_prefix.claim-keys"
  protected_ancestor_pairs_file="$tmp_prefix.protected-ancestor-pairs"
  protected_ancestor_keys_file="$tmp_prefix.protected-ancestor-keys"
  protected_keys_file="$tmp_prefix.protected-keys"
  blocked_anchors_file="$tmp_prefix.blocked-anchors"
  rm -f -- "$ancestor_pairs_file" "$ancestor_keys_file" "$claim_keys_file" "$protected_ancestor_pairs_file" "$protected_ancestor_keys_file" "$protected_keys_file" "$blocked_anchors_file"

  while IFS= read -r claim || [[ -n "$claim" ]]; do
    ancestor="$claim"
    while true; do
      printf '%s\t%s\n' "$ancestor" "$claim"
      [[ -z "$ancestor" ]] && break

      if [[ "$ancestor" == */* ]]; then
        ancestor="${ancestor%/*}"
      else
        ancestor=""
      fi
    done
  done <"$claims_file" >"$ancestor_pairs_file"

  cut -f1 "$ancestor_pairs_file" | sort -u >"$ancestor_keys_file"
  sort -u "$claims_file" >"$claim_keys_file"
  sort -u "$protected_anchors_file" >"$protected_keys_file"
  comm -12 "$protected_keys_file" "$ancestor_keys_file" >"$blocked_anchors_file"

  while IFS= read -r claim || [[ -n "$claim" ]]; do
    ancestor="$claim"
    while true; do
      printf '%s\t%s\n' "$ancestor" "$claim"
      [[ -z "$ancestor" ]] && break

      if [[ "$ancestor" == */* ]]; then
        ancestor="${ancestor%/*}"
      else
        ancestor=""
      fi
    done
  done <"$protected_keys_file" >"$protected_ancestor_pairs_file"

  cut -f1 "$protected_ancestor_pairs_file" | sort -u >"$protected_ancestor_keys_file"
  comm -12 "$claim_keys_file" "$protected_ancestor_keys_file" >>"$blocked_anchors_file"
  sort -u "$blocked_anchors_file" -o "$blocked_anchors_file"

  if [[ -s "$blocked_anchors_file" ]]; then
    blocked_claim="$(
      while IFS= read -r pair || [[ -n "$pair" ]]; do
        if grep -Fxq -- "${pair%%$'\t'*}" "$blocked_anchors_file"; then
          printf '%s\n' "${pair#*$'\t'}"
          break
        fi
      done <"$ancestor_pairs_file"
    )"
    rm -f -- "$ancestor_pairs_file" "$ancestor_keys_file" "$claim_keys_file" "$protected_ancestor_pairs_file" "$protected_ancestor_keys_file" "$protected_keys_file" "$blocked_anchors_file"
    die "protected path: $blocked_claim"
  fi

  rm -f -- "$ancestor_pairs_file" "$ancestor_keys_file" "$claim_keys_file" "$protected_ancestor_pairs_file" "$protected_ancestor_keys_file" "$protected_keys_file" "$blocked_anchors_file"
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
  local claims_tmp="$output_file.tmp.$$"
  local sorted_tmp="$output_file.sorted.$$"

  rm -f -- "$claims_tmp" "$sorted_tmp"
  if [[ ! -d "$release_tree" ]]; then
    : >"$output_file"
    return 0
  fi

  # shellcheck disable=SC2094
  find "$release_tree" \( -type f -or -type l \) -print0 |
  while IFS= read -r -d '' release_file; do
    public_path="${release_file#"$release_tree"/}"

    if [[ "$public_path" == *$'\n'* ]]; then
      rm -f -- "$claims_tmp" "$sorted_tmp"
      die "unsupported newline in release path"
    fi

    case "$public_path" in
      .git|.git/*|.github-ssh-deploy|.github-ssh-deploy/*)
        continue
        ;;
    esac

    claim_for_path "$public_path" "$boundaries_file"
  done >"$claims_tmp"

  sort -u "$claims_tmp" >"$sorted_tmp"
  mv "$sorted_tmp" "$output_file"
  rm -f -- "$claims_tmp"
}

prepare_claim_transition() {
  local docroot="$1"
  local deployment_id="$2"
  local base="$3"
  local target_release_dir="$4"
  local scratch_dir="$5"
  local boundaries_file="$scratch_dir/boundaries"
  local protected_anchors_file="$scratch_dir/protected_anchors"
  local old_release_claims_file="$scratch_dir/old_release_claims"
  local materialized_claims_file="$scratch_dir/materialized_claims"
  local old_claims_file="$scratch_dir/old_claims"
  local new_claims_file="$scratch_dir/new_claims"
  local removed_claims_file="$scratch_dir/removed_claims"
  local current_target=""

  discover_boundary_claims "$docroot" "$boundaries_file"
  discover_protected_anchors "$docroot" "$protected_anchors_file"

  if [[ -L "$base/current" ]]; then
    current_target="$(readlink "$base/current")"
    compute_claims "$base/$current_target" "$boundaries_file" "$old_release_claims_file"
  else
    : >"$old_release_claims_file"
  fi

  discover_materialized_public_claims "$docroot" "$deployment_id" "$materialized_claims_file"
  combine_claims "$old_claims_file" "$old_release_claims_file" "$materialized_claims_file"
  compute_claims "$target_release_dir" "$boundaries_file" "$new_claims_file"
  validate_claims_not_protected "$new_claims_file" "$protected_anchors_file"
  compute_removed_claims "$old_claims_file" "$new_claims_file" "$removed_claims_file"
}

apply_claim_transition() {
  local docroot="$1"
  local deployment_id="$2"
  local base="$3"
  local release_id="$4"
  local exchange_helper="$5"
  local scratch_dir="$6"
  local new_claims_file="$scratch_dir/new_claims"
  local removed_claims_file="$scratch_dir/removed_claims"
  local exchanged_paths_file="$base/exchanged_paths"

  : >"$exchanged_paths_file"
  cleanup_overlapping_removed_claims "$docroot" "$deployment_id" "$removed_claims_file" "$new_claims_file"
  reconcile_new_claims "$docroot" "$deployment_id" "$new_claims_file" "$exchange_helper" "$exchanged_paths_file"
  switch_current "$base" "$release_id"
  [[ "$(readlink "$base/current")" == "releases/$release_id" ]] || die "current does not point to releases/$release_id"
  cleanup_exchanged_paths "$exchanged_paths_file"
  rm -f -- "$exchanged_paths_file"
  cleanup_removed_claims "$docroot" "$deployment_id" "$removed_claims_file"
}

rollback_release() {
  local docroot="$1"
  local deployment_id="$2"
  local rollback_to="$3"
  local exchange_helper="$4"

  local base="$docroot/.github-ssh-deploy/deployments/$deployment_id"
  local releases_dir="$base/releases"
  local release_dir="$releases_dir/$rollback_to"
  local lock_file="$base/deploy.lock"
  local exchanged_paths_file="$base/exchanged_paths"
  local scratch_dir

  mkdir -p "$releases_dir"

  acquire_lock "$lock_file"

  [[ -d "$release_dir" ]] || die "rollback release does not exist: $release_dir"
  cleanup_exchanged_paths "$exchanged_paths_file"
  rm -f -- "$exchanged_paths_file"

  scratch_dir="$(create_scratch_dir "$base")"
  prepare_claim_transition "$docroot" "$deployment_id" "$base" "$release_dir" "$scratch_dir"
  apply_claim_transition "$docroot" "$deployment_id" "$base" "$rollback_to" "$exchange_helper" "$scratch_dir"

  echo "remote-deploy.sh: current=releases/$rollback_to" >&2
}

main() {
  local docroot=""
  local deployment_id=""
  local release_id=""
  local rollback_to=""
  local keep_releases=""
  local post_deploy_file=""
  local exchange_helper=""
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
      --rollback-to)
        (($# >= 2)) || die "--rollback-to requires a value"
        rollback_to="$2"
        shift 2
        ;;
      --keep-releases)
        (($# >= 2)) || die "--keep-releases requires a value"
        keep_releases="$2"
        shift 2
        ;;
      --post-deploy-file)
        (($# >= 2)) || die "--post-deploy-file requires a value"
        post_deploy_file="$2"
        shift 2
        ;;
      --exchange-helper)
        (($# >= 2)) || die "--exchange-helper requires a value"
        exchange_helper="$2"
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
  rollback_to="$(trim "$rollback_to")"
  keep_releases="$(trim "$keep_releases")"
  post_deploy_file="$(trim "$post_deploy_file")"
  exchange_helper="$(trim "$exchange_helper")"

  [[ -n "$docroot" ]] || die "docroot is required"
  require_id "deployment-id" "$deployment_id"
  if [[ -z "$exchange_helper" ]]; then
    exchange_helper="$docroot/.github-ssh-deploy/deployments/$deployment_id/exchange-rename"
  fi

  trap cleanup_run_scratch EXIT
  require_remote_capabilities

  if [[ -n "$rollback_to" ]]; then
    [[ -z "$release_id" ]] || die "--release-id cannot be used with --rollback-to"
    if [[ -n "$keep_releases" ]]; then
      if [[ ! "$keep_releases" =~ ^[0-9]+$ ]] || ((10#$keep_releases < 1)); then
        die "keep-releases must be a positive integer"
      fi
    fi
    [[ -z "$post_deploy_file" ]] || die "--post-deploy-file cannot be used with --rollback-to"
    ((print_claims == 0)) || die "--print-claims cannot be used with --rollback-to"
    require_id "rollback-to" "$rollback_to"
    rollback_release "$docroot" "$deployment_id" "$rollback_to" "$exchange_helper"
    return
  fi

  require_id "release-id" "$release_id"
  if [[ ! "$keep_releases" =~ ^[0-9]+$ ]] || ((10#$keep_releases < 1)); then
    die "keep-releases must be a positive integer"
  fi

  local base="$docroot/.github-ssh-deploy/deployments/$deployment_id"
  local incoming_dir="$base/incoming"
  local releases_dir="$base/releases"
  local incoming_release="$incoming_dir/$release_id"
  local release_dir="$releases_dir/$release_id"
  local lock_file="$base/deploy.lock"
  local exchanged_paths_file="$base/exchanged_paths"
  local scratch_dir
  local boundaries_file
  local new_claims_file

  mkdir -p "$incoming_dir" "$releases_dir"

  acquire_lock "$lock_file"

  [[ -d "$incoming_release" ]] || die "incoming release does not exist: $incoming_release"
  cleanup_exchanged_paths "$exchanged_paths_file"
  rm -f -- "$exchanged_paths_file"

  scratch_dir="$(create_scratch_dir "$base")"
  boundaries_file="$scratch_dir/boundaries"
  new_claims_file="$scratch_dir/new_claims"
  discover_boundary_claims "$docroot" "$boundaries_file"

  if ((print_claims)); then
    compute_claims "$incoming_release" "$boundaries_file" "$new_claims_file"
    cat "$new_claims_file"
    exit 0
  fi

  [[ ! -e "$release_dir" ]] || die "release already exists: $release_dir"

  prepare_claim_transition "$docroot" "$deployment_id" "$base" "$incoming_release" "$scratch_dir"
  mv "$incoming_release" "$release_dir"
  touch "$release_dir"
  apply_claim_transition "$docroot" "$deployment_id" "$base" "$release_id" "$exchange_helper" "$scratch_dir"
  run_post_deploy "$docroot" "$post_deploy_file"
  prune_releases "$releases_dir" "$keep_releases" "$release_id"

  echo "remote-deploy.sh: current=releases/$release_id" >&2
}

main "$@"
