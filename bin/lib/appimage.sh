#!/usr/bin/env bash
# cspell:ignore fusermount ltrimstr ABRT
# reusable helpers to fetch ansible AppImage from raven428/container-images
# releases with retries, digest verification and fallback to existing binary.
# usage:
#   source bin/lib/appimage.sh
#   fetch_ansible_appimage "${ANSIBLE_VER}"    # e.g. "11" -> ansible-11-001.AppImage
#   "${APPIMAGE_BIN}" ansible-playbook ...
: "${APPIMAGE_RELEASE:="latest"}"
: "${APPIMAGE_BUILD:="001"}"
: "${RETRY_MAX:=5}"
: "${RETRY_SLEEP_MAX:=10}"
: "${CURL_CONNECT_TIMEOUT:=11}"
: "${CURL_STALL_TIMEOUT:=30}"
: "${APT_LOCK_FILE:="/var/lock/apt-get.lock"}"
_appimage_gh_api='https://api.github.com/repos/raven428/container-images/releases'
_appimage_gh_base='https://github.com/raven428/container-images/releases'
ensure_packages() {
  local -a missing=()
  for pkg in "$@"; do
    echo -n "==> package [${pkg}]… "
    # shellcheck disable=2016
    if /usr/bin/env dpkg-query -W -f='${Status}' "${pkg}" 2>/dev/null |
      /usr/bin/env grep -q 'install ok installed'; then
      echo "exist"
    else
      echo "install"
      missing+=("${pkg}")
    fi
  done
  [[ "${#missing[@]}" -eq 0 ]] && return 0
  /usr/bin/env sudo install -m 0666 /dev/null "${APT_LOCK_FILE}" 2>/dev/null || true
  {
    /usr/bin/env flock 9
    /usr/bin/env sudo apt-get update
    /usr/bin/env sudo apt-get install --no-install-recommends -y "${missing[@]}"
  } 9>"${APT_LOCK_FILE}"
}
# _retry_with_backoff <label> <action> <callback_fn>
# Calls callback_fn up to RETRY_MAX times with exponential backoff.
# callback_fn must return 0 on success. label and action are used in log messages.
_retry_with_backoff() {
  local _label="${1:?label required}" _action="${2:?action required}" \
    _cb="${3:?callback required}"
  local _retry_sleep=1 _retry _next
  for ((_retry = 1; _retry <= RETRY_MAX; _retry++)); do
    "${_cb}" && return 0
    if [[ "${_retry}" -lt "${RETRY_MAX}" ]]; then
      echo "==> ${_label}: ${_action} failed," \
        "retry ${_retry}/${RETRY_MAX}, sleep ${_retry_sleep}s" >&2
      sleep "${_retry_sleep}"
      _next=$((_retry_sleep * 2))
      _retry_sleep=$((_next > RETRY_SLEEP_MAX ? RETRY_SLEEP_MAX : _next))
    fi
  done
  return 1
}
fetch_ansible_appimage() {
  local _ver="${1:?ansible version required, e.g. 11}"
  local _name="ansible-${_ver}-${APPIMAGE_BUILD}.AppImage"
  local _bin="${HOME}/bin/${_name}"
  local _api_url
  if [[ "${APPIMAGE_RELEASE}" == 'latest' ]]; then
    _api_url="${_appimage_gh_api}/latest"
  else
    _api_url="${_appimage_gh_api}/tags/${APPIMAGE_RELEASE}"
  fi
  ensure_packages jq fuse3
  local _remote_digest=''
  # shellcheck disable=2016,2329
  _fetch_digest() {
    local _d
    _d=$(
      /usr/bin/env curl -fsSL \
        --connect-timeout "${CURL_CONNECT_TIMEOUT}" \
        --speed-time "${CURL_STALL_TIMEOUT}" --speed-limit 1 \
        "${_api_url}" | /usr/bin/env jq -r --arg name "${_name}" \
        '.assets[] | select(.name == $name) | .digest | ltrimstr("sha256:")'
    ) && [[ -n "${_d}" ]] || return 1
    _remote_digest="${_d}"
  }
  _retry_with_backoff "${_name}" 'API' _fetch_digest || true
  if [[ -z "${_remote_digest}" ]]; then
    if [[ -x "${_bin}" ]]; then
      echo "==> ${_name}: API unavailable, using existing binary" >&2
      export APPIMAGE_BIN="${_bin}"
      return 0
    fi
    echo "error: digest for ${_name} not found in release API" >&2
    return 1
  fi
  local _need_download=1
  local _local_digest
  if [[ -x "${_bin}" ]]; then
    # shellcheck disable=2016
    _local_digest=$(/usr/bin/env sha256sum "${_bin}" | /usr/bin/env awk '{print $1}')
    if [[ "${_local_digest}" == "${_remote_digest}" ]]; then
      _need_download=0
    fi
  fi
  if [[ "${_need_download}" -eq 0 ]]; then
    echo "==> ${_name}: up to date, skipping download"
    export APPIMAGE_BIN="${_bin}"
    return 0
  fi
  local _url
  if [[ "${APPIMAGE_RELEASE}" == 'latest' ]]; then
    _url="${_appimage_gh_base}/latest/download/${_name}"
  else
    _url="${_appimage_gh_base}/download/${APPIMAGE_RELEASE}/${_name}"
  fi
  /usr/bin/env mkdir -p "${HOME}/bin"
  local _tmp_bin
  _tmp_bin=$(/usr/bin/env mktemp "${HOME}/bin/.ansible-current.XXXXXX")
  local _prev_trap _cleanup_done=0
  _prev_trap=$(trap -p EXIT INT QUIT ABRT TERM)
  # _appimage_restore removes the temp file and restores caller traps. It is
  # idempotent and must be called before every return so no stale trap leaks
  # out referencing local variables that die with this function.
  # shellcheck disable=2329,2317
  _appimage_restore() {
    [[ "${_cleanup_done}" -eq 0 ]] || return 0
    _cleanup_done=1
    /usr/bin/env rm -vf "${_tmp_bin}"
    eval "${_prev_trap:-trap - EXIT INT QUIT ABRT TERM}"
  }
  # shellcheck disable=2329,2317
  _appimage_cleanup() {
    local _sig="${1:-}"
    _appimage_restore
    if [[ -n "${_sig}" ]]; then
      # drop our own handler for this signal to avoid recursion, then re-raise
      trap - "${_sig}"
      kill -"${_sig}" "$$"
      # fallback if the re-raised signal did not terminate us
      exit $((128 + $(/usr/bin/env kill -l "${_sig}")))
    fi
  }
  trap '_appimage_cleanup' EXIT
  local _sig
  for _sig in INT QUIT ABRT TERM; do
    # shellcheck disable=2064
    trap "_appimage_cleanup ${_sig}" "${_sig}"
  done
  local _ok=0
  # shellcheck disable=2329
  _download_binary() {
    /usr/bin/env curl -fSL --progress-bar \
      --connect-timeout "${CURL_CONNECT_TIMEOUT}" \
      --speed-time "${CURL_STALL_TIMEOUT}" --speed-limit 1 \
      -o "${_tmp_bin}" "${_url}" && _ok=1
  }
  _retry_with_backoff "${_name}" 'download' _download_binary || true
  if [[ "${_ok}" -ne 1 ]]; then
    _appimage_restore
    if [[ -x "${_bin}" ]]; then
      echo "==> ${_name}: download failed, using existing binary" >&2
      export APPIMAGE_BIN="${_bin}"
      return 0
    fi
    echo "error: download failed and no existing binary found" >&2
    return 1
  fi
  local _downloaded_digest
  # shellcheck disable=2016
  _downloaded_digest=$(/usr/bin/env sha256sum "${_tmp_bin}" |
    /usr/bin/env awk '{print $1}')
  if [[ "${_downloaded_digest}" != "${_remote_digest}" ]]; then
    echo "error: digest mismatch after download" >&2
    echo "  expected: ${_remote_digest}" >&2
    echo "  received: ${_downloaded_digest}" >&2
    _appimage_restore
    return 1
  fi
  /usr/bin/env chmod 755 "${_tmp_bin}"
  /usr/bin/env mv -f "${_tmp_bin}" "${_bin}"
  # _tmp_bin is gone after mv; drop it from the guard so restore only resets traps
  _tmp_bin=''
  _appimage_restore
  export APPIMAGE_BIN="${_bin}"
}
