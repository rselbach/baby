#!/usr/bin/env bash
# Gives Baby's update feed a signing key of its own, replacing the
# SPARKLE_EDDSA_PRIVATE_KEY shared with other uses. Run once, on a Mac, from
# a checkout with `gh` signed in to the repository:
#
#   scripts/rotate-feed-key.sh ~/baby-feed-key.txt
#
# It generates a new Ed25519 key, writes its seed to the file you name (which
# must not exist yet), stores the seed as the BABY_FEED_SIGNING_KEY Actions
# secret, and makes the app and the website trust the new key instead of the
# shared one. Commit the result and release as usual. Feeds keep a signature
# by the shared key, so builds released before this keep updating; builds
# released after it trust only the new key.
#
# Keep the seed file in a password manager, then delete it: without the
# seed, builds that trust the new key can never update again.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly ROOT
readonly FEED="${ROOT}/Sources/BabyUpdate/Feed.swift"
readonly SITE="${ROOT}/site/site.js"
readonly UNROTATED='  public static let publicKeys = [legacyPublicKey]'

die() {
  echo "error: $*" >&2
  exit 1
}

main() {
  (( $# == 1 )) || die "usage: $0 SEED_FILE"
  local seed_file="$1"
  [[ ! -e "${seed_file}" ]] || die "${seed_file} already exists"
  grep -qxF "${UNROTATED}" "${FEED}" \
    || die "Feed.swift already trusts a dedicated key; rotating again needs a transition"
  command -v gh >/dev/null || die "gh is not installed"
  gh auth status >/dev/null 2>&1 || die "gh is not signed in"

  swift build -c release --package-path "${ROOT}" --product baby-update-tool
  local tool
  tool="$(swift build -c release --package-path "${ROOT}" --show-bin-path)/baby-update-tool"
  local key
  key="$("${tool}" generate-key --seed-out "${seed_file}")"
  [[ "${key}" =~ ^[A-Za-z0-9+/]{43}=$ ]] || die "unexpected public key: ${key}"

  (cd "${ROOT}" && gh secret set BABY_FEED_SIGNING_KEY <"${seed_file}")

  local updated="${FEED}.rotating"
  awk -v unrotated="${UNROTATED}" -v key="${key}" \
    '$0 == unrotated { print "  public static let publicKeys = [\"" key "\"]"; next } { print }' \
    "${FEED}" >"${updated}"
  mv "${updated}" "${FEED}"
  updated="${SITE}.rotating"
  awk -v key="${key}" \
    '/^  const PUBLIC_KEY = "[^"]+";$/ { print "  const PUBLIC_KEY = \"" key "\";"; next } { print }' \
    "${SITE}" >"${updated}"
  mv "${updated}" "${SITE}"
  grep -qF "\"${key}\"" "${FEED}" || die "could not update ${FEED}"
  grep -qF "\"${key}\"" "${SITE}" || die "could not update ${SITE}"

  cat <<DONE
The feed now has its own key: ${key}
Its seed is in ${seed_file} and in the BABY_FEED_SIGNING_KEY secret.

Next:
  1. Save ${seed_file} in your password manager, then delete it.
  2. Commit Feed.swift and site.js, and release as usual.
  3. Deploy the website after that release, once the live feed carries the
     new key's signature; until then the download button falls back to the
     latest release page.
DONE
}

main "$@"
