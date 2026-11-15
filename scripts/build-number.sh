#!/usr/bin/env bash
# Prints the CFBundleVersion for a stable X.Y.Z release version:
# X * 1000000 + Y * 1000 + Z. Deriving it from the version keeps it the same
# across reruns and re-pushed tags and makes it grow with every release,
# whatever happens to the workflow's run counter. Y and Z must stay below
# 1000.
#
# Usage: scripts/build-number.sh 1.2.3   # prints 1002003
set -euo pipefail

main() {
  if (( $# != 1 )); then
    echo "usage: $0 X.Y.Z" >&2
    exit 2
  fi
  local version="$1"
  if [[ ! "${version}" =~ ^(0|[1-9][0-9]{0,5})\.(0|[1-9][0-9]{0,2})\.(0|[1-9][0-9]{0,2})$ ]]; then
    echo "error: ${version} is not X.Y.Z with X below 1000000 and Y and Z below 1000," \
      "without leading zeros" >&2
    exit 1
  fi
  local major="${BASH_REMATCH[1]}" minor="${BASH_REMATCH[2]}" patch="${BASH_REMATCH[3]}"
  local build=$(( major * 1000000 + minor * 1000 + patch ))
  if (( build == 0 )); then
    echo "error: version 0.0.0 has no positive build number" >&2
    exit 1
  fi
  echo "${build}"
}

main "$@"
