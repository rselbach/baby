#!/usr/bin/env bash
# Publishes one uploaded snapshot and restores the previous site on failure.
set -euo pipefail
umask 022

phase="preparing"
release=""
previous=""

activate() {
  local target="$1"
  local link="${WEB_ROOT}/.current-${release##*/}"
  rm -f -- "${link}" || return 1
  ln -s "${target}" "${link}" || return 1
  mv -Tf -- "${link}" "${WEB_ROOT}/current"
}

restore() {
  sudo cp -p "${UPLOAD}/server.conf" "${SERVER_CONF}" || return 1
  if [[ -f "${UPLOAD}/snippet.conf" ]]; then
    sudo cp -p "${UPLOAD}/snippet.conf" "${SNIPPET}" || return 1
  else
    sudo rm -f -- "${SNIPPET}" || return 1
  fi
  case "${phase}" in
    activating|activated)
      if [[ -n "${previous}" ]]; then
        activate "${previous}" || return 1
      else
        rm -f -- "${WEB_ROOT}/current" || return 1
      fi
      sudo systemctl reload nginx || return 1
      ;;
  esac
}

cleanup() {
  local status=$?
  trap - EXIT
  if (( status != 0 )); then
    if [[ "${phase}" != "preparing" ]] && ! restore; then
      echo "rollback failed; recovery files remain in ${UPLOAD}" >&2
      exit "${status}"
    fi
    if [[ -n "${release}" ]]; then
      rm -f -- "${WEB_ROOT}/.current-${release##*/}"
      rm -r -- "${release}"
    fi
  elif [[ -n "${previous}" && "${previous}" != "${release}" &&
    "${previous%/*}" == "${WEB_ROOT}/releases" &&
    "${previous##*/}" =~ ^release\.[[:alnum:]]+$ &&
    -d "${previous}" && ! -L "${previous}" ]]; then
    if ! rm -r -- "${previous}"; then
      echo "could not remove the previous release at ${previous}" >&2
    fi
  fi
  rm -r -- "${UPLOAD}"
  exit "${status}"
}

verify() {
  local headers location file
  local curl_flags=(-fsS --connect-timeout 10 --max-time 30)
  headers="$(curl "${curl_flags[@]}" -I \
    "${URL}?deployment=${release##*/}")"
  headers="${headers//$'\r'/}"
  grep -qi '^content-security-policy:.*connect-src https://rselbach.github.io' \
    <<<"${headers}"
  grep -Eiq '^x-content-type-options:[[:space:]]*nosniff[[:space:]]*$' \
    <<<"${headers}"
  grep -Eiq '^referrer-policy:[[:space:]]*strict-origin-when-cross-origin[[:space:]]*$' \
    <<<"${headers}"
  location="$(curl "${curl_flags[@]}" -o /dev/null -w '%{redirect_url}' \
    "${URL%/}")"
  [[ "${location}" == "${URL}" ]]
  for file in index.html site.js icon.png awake.png; do
    curl "${curl_flags[@]}" -H 'Cache-Control: no-cache' \
      -o "${UPLOAD}/live" "${URL}${file}?deployment=${release##*/}"
    cmp -s "${release}/baby/${file}" "${UPLOAD}/live"
  done
  curl "${curl_flags[@]}" -o /dev/null https://rselbach.com/
}

main() {
  if (( $# != 5 )); then
    echo "usage: deploy-site-remote UPLOAD WEB_ROOT SNIPPET SERVER_CONF URL" >&2
    exit 1
  fi
  readonly UPLOAD="$1" WEB_ROOT="$2" SNIPPET="$3" SERVER_CONF="$4" URL="$5"
  trap cleanup EXIT
  trap 'exit 129' HUP
  trap 'exit 130' INT
  trap 'exit 143' TERM
  [[ -f "${UPLOAD}/site/index.html" && -f "${UPLOAD}/nginx.conf" ]]
  sudo install -d -o "$(id -u)" -g "$(id -g)" -m 755 "${WEB_ROOT}"
  exec 9>"${WEB_ROOT}/deploy.lock"
  flock -x 9
  mkdir -p "${WEB_ROOT}/releases"
  release="$(mktemp -d "${WEB_ROOT}/releases/release.XXXXXXXX")"
  mkdir "${release}/baby"
  cp -R "${UPLOAD}/site/." "${release}/baby/"
  chmod -R u=rwX,go=rX "${release}"
  if [[ -L "${WEB_ROOT}/current" ]]; then
    previous="$(readlink "${WEB_ROOT}/current")"
  elif [[ -e "${WEB_ROOT}/current" ]]; then
    echo "refusing to replace a non-symlink site" >&2
    exit 1
  fi

  sudo cp -p "${SERVER_CONF}" "${UPLOAD}/server.conf"
  if [[ -f "${SNIPPET}" ]]; then
    sudo cp -p "${SNIPPET}" "${UPLOAD}/snippet.conf"
  fi
  phase="configuring"
  sudo install -m 644 "${UPLOAD}/nginx.conf" "${SNIPPET}"
  if ! grep -qF "include ${SNIPPET};" "${SERVER_CONF}"; then
    local pattern='^[[:space:]]*server_name rselbach[.]com;[[:space:]]*$'
    if (( $(grep -c "${pattern}" "${SERVER_CONF}") != 1 )); then
      echo "expected one rselbach.com server block in ${SERVER_CONF}" >&2
      exit 1
    fi
    awk -v pattern="${pattern}" -v snippet="${SNIPPET}" \
      '{ print; if ($0 ~ pattern) print "    include " snippet ";" }' \
      "${SERVER_CONF}" >"${UPLOAD}/server.next"
    sudo install -m 644 "${UPLOAD}/server.next" "${SERVER_CONF}"
  fi
  sudo nginx -t
  phase="activating"
  activate "${release}"
  phase="activated"
  sudo systemctl reload nginx
  verify
  phase="committed"
  echo "deployed ${URL}"
}

main "$@"
