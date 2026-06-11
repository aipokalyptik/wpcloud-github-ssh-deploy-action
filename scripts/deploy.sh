#!/usr/bin/env bash
set -euo pipefail

readonly VERSION="0.1.0-skeleton"

usage() {
  cat <<'USAGE'
Usage: deploy.sh [--help|--version|--skeleton]

Local wrapper placeholder for the WP Cloud SSH Deploy composite action.
Transport and deploy behavior are intentionally not implemented yet.
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
    echo "deploy.sh: skeleton only; SSH transport and deploy behavior are not implemented yet." >&2
    exit 64
    ;;
  *)
    echo "deploy.sh: unknown argument: $1" >&2
    usage >&2
    exit 64
    ;;
esac
