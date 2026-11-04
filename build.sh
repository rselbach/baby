#!/usr/bin/env bash
# Builds Baby.app into ./build from the Swift package and PNG artwork, with
# the baby command line tool in Contents/Helpers.
# Signs with our team's "Developer ID Application" identity when the keychain
# has one, otherwise ad hoc; override with SIGNING_IDENTITY. VERSION and BUILD,
# when set, replace CFBundleShortVersionString and CFBundleVersion.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly ROOT
readonly APP="${ROOT}/build/Baby.app"
readonly PLIST="${ROOT}/Resources/Info.plist"
readonly DEVELOPER_ID="Developer ID Application"
readonly TEAM_ID="LS8YD2TR79"
readonly CLI_IDENTIFIER="com.rselbach.baby.cli"

signing_identity() {
  if [[ -n "${SIGNING_IDENTITY:-}" ]]; then
    echo "${SIGNING_IDENTITY}"
    return
  fi
  local sha1
  sha1="$(security find-identity -v -p codesigning \
    | sed -n "s/^[[:space:]]*[0-9][0-9]*)[[:space:]]*\([0-9A-F]\{40\}\)[[:space:]]*\"${DEVELOPER_ID}: .* (${TEAM_ID})\".*/\1/p" \
    | head -n 1)"
  if [[ -n "${sha1}" ]]; then
    echo "${sha1}"
    return
  fi
  echo "-"
}

# build_binary builds a product and records the real SDK version: SwiftPM
# otherwise records the deployment target as the SDK, and newer macOS would
# run Baby in compatibility mode. Kept out of command substitutions, which
# would ignore a failed build.
build_binary() {
  local product="$1"
  local minimum
  local sdk
  minimum="$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' "${PLIST}")"
  sdk="$(xcrun --sdk macosx --show-sdk-version)"
  swift build -c release --package-path "${ROOT}" --arch arm64 --product "${product}" \
    -Xlinker -platform_version -Xlinker macos \
    -Xlinker "${minimum}" -Xlinker "${sdk}"
}

stamp_version() {
  local plist="$1"
  if [[ -n "${VERSION:-}" ]]; then
    if [[ ! "${VERSION}" =~ ^[0-9][A-Za-z0-9.+-]{0,63}$ ]]; then
      echo "error: VERSION must match [0-9][A-Za-z0-9.+-]{0,63}" >&2
      exit 1
    fi
    /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString ${VERSION}" \
      "${plist}"
  fi
  if [[ -n "${BUILD:-}" ]]; then
    if [[ ! "${BUILD}" =~ ^[1-9][0-9]*$ ]]; then
      echo "error: BUILD must be a positive integer" >&2
      exit 1
    fi
    /usr/libexec/PlistBuddy -c "Set :CFBundleVersion ${BUILD}" "${plist}"
  fi
}

sign() {
  local identity="$1"
  local flags=(--force --options runtime --sign "${identity}")
  if [[ "${identity}" == "-" ]]; then
    echo "no ${DEVELOPER_ID} (${TEAM_ID}) identity; signing ad hoc" >&2
    flags+=(--timestamp=none)
  else
    flags+=(--timestamp)
  fi
  # nested code is signed first; the app's signature seals it
  codesign "${flags[@]}" --identifier "${CLI_IDENTIFIER}" \
    "${APP}/Contents/Helpers/baby"
  codesign "${flags[@]}" "${APP}"
  codesign --verify --deep --strict "${APP}"
}

# make_icon builds AppIcon.icns from baby.png.
make_icon() {
  local iconset="${ROOT}/build/AppIcon.iconset"
  local size
  rm -rf "${iconset}"
  mkdir -p "${iconset}"
  for size in 16 32 128 256 512; do
    sips -z "${size}" "${size}" "${ROOT}/baby.png" \
      --out "${iconset}/icon_${size}x${size}.png" >/dev/null
    sips -z $((size * 2)) $((size * 2)) "${ROOT}/baby.png" \
      --out "${iconset}/icon_${size}x${size}@2x.png" >/dev/null
  done
  iconutil -c icns "${iconset}" -o "${APP}/Contents/Resources/AppIcon.icns"
  rm -rf "${iconset}"
}

# make_status_images scales the menu bar artwork to 18pt at 1x and 2x.
make_status_images() {
  local name
  for name in baby-on baby-off; do
    sips -z 18 18 "${ROOT}/${name}.png" \
      --out "${APP}/Contents/Resources/${name}.png" >/dev/null
    sips -z 36 36 "${ROOT}/${name}.png" \
      --out "${APP}/Contents/Resources/${name}@2x.png" >/dev/null
  done
}

main() {
  build_binary Baby
  build_binary BabyCLI
  local bin_dir
  bin_dir="$(swift build -c release --package-path "${ROOT}" --arch arm64 \
    --show-bin-path)"

  rm -rf "${APP}"
  mkdir -p "${APP}/Contents/MacOS" "${APP}/Contents/Helpers" \
    "${APP}/Contents/Resources"
  cp "${bin_dir}/Baby" "${APP}/Contents/MacOS/Baby"
  # not in MacOS, where "baby" would collide with "Baby" on
  # case-insensitive volumes
  cp "${bin_dir}/BabyCLI" "${APP}/Contents/Helpers/baby"
  cp "${PLIST}" "${APP}/Contents/Info.plist"
  stamp_version "${APP}/Contents/Info.plist"
  make_icon
  make_status_images
  local identity
  identity="$(signing_identity)"
  sign "${identity}"
  echo "Built ${APP}"
}

main "$@"
