#!/usr/bin/env bash
# Uploads a private website snapshot and publishes it on the exe.dev VM.
set -euo pipefail

readonly HOST="rselbach.exe.xyz"
readonly WEB_ROOT="/var/www/baby-site"
readonly SNIPPET="/etc/nginx/snippets/baby.conf"
readonly SERVER_CONF="/etc/nginx/sites-enabled/default"
readonly URL="https://rselbach.com/baby/"
upload=""

cleanup() {
  local status=$?
  if [[ -n "${upload}" ]]; then
    ssh "${HOST}" rm -r -- "${upload}" || true
  fi
  exit "${status}"
}

main() {
  local repo
  repo="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  upload="$(ssh "${HOST}" mktemp -d /tmp/baby-site.XXXXXXXX)"
  if [[ ! "${upload}" =~ ^/tmp/baby-site\.[[:alnum:]]+$ ]]; then
    echo "unexpected upload directory: ${upload}" >&2
    exit 1
  fi
  trap cleanup EXIT
  rsync -rlt "${repo}/site/" "${HOST}:${upload}/site/"
  scp -q "${repo}/site-nginx.conf" "${HOST}:${upload}/nginx.conf"

  # The remote transaction retains its backups if rollback fails.
  local remote_upload="${upload}"
  upload=""
  if ! ssh "${HOST}" bash -s -- "${remote_upload}" "${WEB_ROOT}" \
    "${SNIPPET}" "${SERVER_CONF}" "${URL}" \
    <"${repo}/scripts/deploy-site-remote.sh"; then
    echo "deployment failed; recovery files may remain in ${remote_upload}" >&2
    exit 1
  fi
}

main "$@"
