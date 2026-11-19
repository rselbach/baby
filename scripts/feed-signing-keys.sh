#!/usr/bin/env bash
# Prints the Ed25519 signing seeds baby-update-tool needs for this checkout,
# one per line: LEGACY_SIGNING_KEY always, and FEED_SIGNING_KEY only once
# Sources/BabyUpdate/Feed.swift has been rotated away from [legacyPublicKey].
#
# Omitting FEED_SIGNING_KEY on unrotated checkouts lets
# scripts/rotate-feed-key.sh store BABY_FEED_SIGNING_KEY before the Feed.swift
# edit is pushed, and lets pre-rotation release tags rerun afterward.
#
# Usage:
#   LEGACY_SIGNING_KEY=... FEED_SIGNING_KEY=... scripts/feed-signing-keys.sh [FEED_SWIFT]
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly ROOT
readonly FEED="${ROOT}/Sources/BabyUpdate/Feed.swift"
readonly UNROTATED='^[[:space:]]*public static let publicKeys = \[legacyPublicKey\][[:space:]]*$'

main() {
  if (( $# > 1 )); then
    echo "usage: $0 [FEED_SWIFT]" >&2
    exit 2
  fi
  local feed="${1:-${FEED}}"
  if [[ ! -f "${feed}" ]]; then
    echo "error: ${feed} not found" >&2
    exit 1
  fi
  if [[ -z "${LEGACY_SIGNING_KEY:-}" ]]; then
    echo "error: LEGACY_SIGNING_KEY is not set" >&2
    exit 1
  fi
  local keys=("${LEGACY_SIGNING_KEY}")
  if ! grep -qE "${UNROTATED}" "${feed}"; then
    if [[ -z "${FEED_SIGNING_KEY:-}" ]]; then
      echo "error: FEED_SIGNING_KEY is not set" >&2
      exit 1
    fi
    keys+=("${FEED_SIGNING_KEY}")
  fi
  printf '%s\n' "${keys[@]}"
}

main "$@"
