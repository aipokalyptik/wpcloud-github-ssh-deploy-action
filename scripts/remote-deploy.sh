#!/usr/bin/env bash
set -euo pipefail

readonly VERSION="0.1.0-skeleton"

usage() {
  cat <<'USAGE'
Usage: remote-deploy.sh [--help|--version|--skeleton]

Remote deploy placeholder for the WP Cloud SSH Deploy action.
Remote release, claim, symlink, and pruning behavior are intentionally not implemented yet.
USAGE
}

case "${1:-}" in
  --help|-h)
    usage
    exit 0
    ;;
  --version)
    echo "$VERSION"
    exit 0
    ;;
  --skeleton|"")
    echo "remote-deploy.sh: skeleton only; remote deploy behavior is not implemented yet." >&2
    exit 64
    ;;
  *)
    echo "remote-deploy.sh: unknown argument: $1" >&2
    usage >&2
    exit 64
    ;;
esac
