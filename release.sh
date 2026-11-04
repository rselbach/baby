#!/usr/bin/env bash
# Builds a release Baby.app with build.sh, notarizes and staples it, and
# packages it as build/Baby-<version>-macos-arm64.zip for the in-app updater
# and a signed, notarized DMG for manual installation. The ZIP is unpacked
# and checked the way the updater checks it.
#
# Needs uv (unless DMGBUILD is set), VERSION, and BUILD. Notarization
# authenticates with APPLE_ID, APPLE_TEAM_ID, and APPLE_APP_PASSWORD when all
# are set, else with the notarytool keychain profile NOTARY_PROFILE
# (default "baby-notary").
#
# Usage: VERSION=1.2.0 BUILD=42 ./release.sh [--skip-notarize]
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly ROOT
readonly APP="${ROOT}/build/Baby.app"
STAGING=""

die() {
  echo "error: $*" >&2
  exit 1
}

# keeps the failing status: macOS's bash 3.2 otherwise exits with the trap's
# last status, so a failed build would report success
cleanup() {
  local status=$?
  if [[ -n "${STAGING}" ]]; then
    rm -rf "${STAGING}"
  fi
  exit "${status}"
}

uses_apple_id() {
  [[ -n "${APPLE_ID:-}" && -n "${APPLE_TEAM_ID:-}" \
    && -n "${APPLE_APP_PASSWORD:-}" ]]
}

# the submission's status decides, not notarytool's exit code
notarize() {
  local submission="$1"
  local target="$2"
  local result="${STAGING}/notary.json"
  local auth=(--keychain-profile "${NOTARY_PROFILE:-baby-notary}")
  if uses_apple_id; then
    auth=(--apple-id "${APPLE_ID}" --team-id "${APPLE_TEAM_ID}"
      --password "${APPLE_APP_PASSWORD}")
  fi
  if ! xcrun notarytool submit "${submission}" "${auth[@]}" --wait \
    --timeout "${NOTARY_TIMEOUT:-30m}" --output-format json >"${result}"; then
    echo "notarytool submit failed" >&2
  fi
  local status=""
  status="$(plutil -extract status raw -o - "${result}")" || true
  if [[ "${status}" != "Accepted" ]]; then
    local id=""
    id="$(plutil -extract id raw -o - "${result}")" || true
    if [[ -z "${id}" ]]; then
      cat "${result}" >&2
      die "notarization did not complete"
    fi
    echo "notarization ${status} (submission ${id}); log:" >&2
    xcrun notarytool log "${id}" "${auth[@]}" >&2 || true
    exit 1
  fi
  xcrun stapler staple "${target}"
  xcrun stapler validate "${target}"
}

dmgbuild_bin() {
  if [[ -n "${DMGBUILD:-}" ]]; then
    echo "${DMGBUILD}"
    return
  fi
  local venv="${STAGING}/dmgbuild-venv"
  uv venv --quiet "${venv}"
  uv pip install --quiet --python "${venv}" --require-hashes --no-deps \
    -r "${ROOT}/Resources/DMG/requirements.txt"
  echo "${venv}/bin/dmgbuild"
}

package_dmg() {
  local dmg="$1"
  local notarized="$2"
  local identity="$3"
  local artwork="${ROOT}/Resources/DMG/background.png"
  local builder
  builder="$(dmgbuild_bin)"
  sips -z 512 768 "${artwork}" --out "${STAGING}/background.png" >/dev/null
  sips -s dpiWidth 144 -s dpiHeight 144 "${artwork}" \
    --out "${STAGING}/background@2x.png" >/dev/null
  tiffutil -cathidpicheck "${STAGING}/background.png" \
    "${STAGING}/background@2x.png" -out "${STAGING}/background.tiff"
  rm -f "${dmg}"
  "${builder}" \
    -s "${ROOT}/Resources/DMG/settings.py" -D "app=${APP}" \
    -D "background=${STAGING}/background.tiff" Baby "${dmg}"
  if [[ "${notarized}" == "true" ]]; then
    codesign --sign "${identity}" --timestamp "${dmg}"
    codesign --verify --strict "${dmg}"
    notarize "${dmg}" "${dmg}"
  fi
  hdiutil verify "${dmg}"
}

# extracts the SHA-1 fingerprint of Baby.app's leaf signing certificate so DMG
# signing uses the exact certificate even when two share a Common Name
app_leaf_sha1() {
  local certs="${STAGING}/certs"
  mkdir -p "${certs}"
  (cd "${certs}" && codesign --display --extract-certificates "${APP}" 2>/dev/null)
  shasum -a 1 "${certs}/codesign0" | awk '{print toupper($1)}'
}

# unpacks the ZIP the way the updater does and checks what it checks
verify_zip() {
  local zip="$1"
  local notarized="$2"
  local tool="$3"
  local unpacked="${STAGING}/unpacked"
  local check=(verify-app "${unpacked}/Baby.app" --version "${VERSION}"
    --build "${BUILD}")
  mkdir -p "${unpacked}"
  ditto -x -k "${zip}" "${unpacked}"
  if [[ "${notarized}" == "true" ]]; then
    "${tool}" "${check[@]}"
    xcrun stapler validate "${unpacked}/Baby.app"
    spctl --assess --type execute --verbose=2 "${unpacked}/Baby.app"
  else
    "${tool}" "${check[@]}" --ad-hoc
  fi
}

main() {
  local notarized="true"
  case "${1:-}" in
    "") ;;
    --skip-notarize) notarized="false" ;;
    *) die "usage: VERSION=X.Y.Z BUILD=N $0 [--skip-notarize]" ;;
  esac
  if [[ -z "${VERSION:-}" || -z "${BUILD:-}" ]]; then
    die "set VERSION and BUILD"
  fi
  local partial="${APPLE_ID:-}${APPLE_TEAM_ID:-}${APPLE_APP_PASSWORD:-}"
  if [[ -n "${partial}" ]] && ! uses_apple_id; then
    die "set all of APPLE_ID, APPLE_TEAM_ID, and APPLE_APP_PASSWORD"
  fi

  STAGING="$(mktemp -d)"
  trap cleanup EXIT

  VERSION="${VERSION}" BUILD="${BUILD}" "${ROOT}/build.sh"
  local authority
  authority="$(codesign --display --verbose=2 "${APP}" 2>&1 \
    | sed -n 's/^Authority=//p' | head -n 1)"
  local dmg_identity=""
  if [[ "${notarized}" == "true" ]]; then
    if [[ "${authority}" != "Developer ID Application:"* ]]; then
      die "Baby.app is not signed with a Developer ID Application identity"
    fi
    dmg_identity="$(app_leaf_sha1)"
    local submission="${STAGING}/Baby-notarize.zip"
    ditto -c -k --keepParent "${APP}" "${submission}"
    notarize "${submission}" "${APP}"
  fi

  swift build -c release --package-path "${ROOT}" --product baby-update-tool
  local bin_dir
  bin_dir="$(swift build -c release --package-path "${ROOT}" --show-bin-path)"
  local zip="${ROOT}/build/Baby-${VERSION}-macos-arm64.zip"
  rm -f "${zip}"
  ditto -c -k --sequesterRsrc --keepParent "${APP}" "${zip}"
  verify_zip "${zip}" "${notarized}" "${bin_dir}/baby-update-tool"
  local dmg="${ROOT}/build/Baby-${VERSION}-macos-arm64.dmg"
  package_dmg "${dmg}" "${notarized}" "${dmg_identity}"
  cp "${bin_dir}/baby-update-tool" "${ROOT}/build/baby-update-tool"
  echo "built ${zip}"
  echo "built ${dmg}"
}

main "$@"
