#!/usr/bin/env bash

set -euo pipefail

if [[ "${#}" -gt 0 && "${1}" == '--debug' ]]; then
  set -x
  shift
fi

readonly CONTAINERFILE="${CONTAINERFILE:-Containerfile}"
readonly IMAGE="${IMAGE:-psentry:local}"
readonly NAME="${NAME:-psentry}"
readonly HOST_IP="${HOST_IP:-127.0.0.1}"
readonly PORT="${PORT:-6080}"
readonly CPUS="${CPUS:-4}"
readonly MEMORY="${MEMORY:-4G}"
readonly POLL_INTERVAL="${POLL_INTERVAL:-15m}"
readonly VNC_GEOMETRY="${VNC_GEOMETRY:-1440x900}"
readonly VNC_DEPTH="${VNC_DEPTH:-24}"
if [[ -n "${VNC_PASSWORD:-}" ]]; then
  readonly VNC_PASSWORD VNC_PASSWORD_GENERATED=0
else
  printf -v VNC_PASSWORD '%04x%04x' "${RANDOM}" "${RANDOM}"
  readonly VNC_PASSWORD VNC_PASSWORD_GENERATED=1
fi
readonly CONTAINER_HOME='/home/agent'
readonly HOME_VOLUME="${HOME_VOLUME:-psentry-home}"
readonly MIN_MACOS_MAJOR=26
readonly SENTRY_ORACLE_HOME="${CONTAINER_HOME}/.local/share/psentry/oracle-home"

container_running() {
  container list --quiet 2> /dev/null | grep -Fx "${NAME}" > /dev/null
}

container_exists() {
  container list --all --quiet 2> /dev/null | grep -Fx "${NAME}" > /dev/null
}

image_exists() {
  container image list --quiet 2> /dev/null | grep -Fx "${IMAGE}" > /dev/null
}

volume_exists() {
  container volume list --quiet 2> /dev/null | grep -Fx "${HOME_VOLUME}" > /dev/null
}

check() {
  local arch os version major

  arch="$(uname -m 2> /dev/null || printf unknown)"
  case "${arch}" in
    arm64 | aarch64) ;;
    *)
      printf 'ERROR: Apple silicon (arm64) is required; detected %s.\n' "${arch}" >&2
      return 1
      ;;
  esac

  os="$(uname -s 2> /dev/null || printf unknown)"
  if [[ "${os}" != Darwin ]]; then
    printf 'ERROR: macOS is required; detected %s.\n' "${os}" >&2
    return 1
  fi

  if command -v sw_vers > /dev/null 2>&1; then
    version="$(sw_vers -productVersion 2> /dev/null || printf unknown)"
    major="${version%%.*}"
    case "${major}" in
      '' | *[!0-9]*)
        printf 'WARNING: could not determine macOS version; continuing.\n' >&2
        ;;
      *)
        if ((major < MIN_MACOS_MAJOR)); then
          printf 'ERROR: macOS %s or later is required; detected %s.\n' \
            "${MIN_MACOS_MAJOR}" "${version}" >&2
          return 1
        fi
        ;;
    esac
  else
    printf 'WARNING: sw_vers is unavailable; continuing without macOS version validation.\n' >&2
  fi

  command -v container > /dev/null 2>&1 || {
    printf "ERROR: Apple 'container' CLI was not found in PATH.\n" >&2
    return 1
  }
}

start_container_system() {
  container system status > /dev/null 2>&1 || container system start
}

validate_containerfile() {
  [[ -f "${CONTAINERFILE}" ]] || {
    printf "ERROR: container definition does not exist: '%s'.\n" "${CONTAINERFILE}" >&2
    return 2
  }
}

require_running() {
  container_running || {
    printf "ERROR: container '%s' is not running. Run 'make up' first.\n" "${NAME}" >&2
    return 1
  }
}

container_novnc_url() {
  local container_port host port publication

  if ! publication="$(
    container inspect "${NAME}" 2> /dev/null \
      | plutil -extract '0.configuration.publishedPorts.0' json -o - -
  )"; then
    printf "ERROR: could not inspect the noVNC publication for container '%s'.\n" \
      "${NAME}" >&2
    return 1
  fi
  if ! host="$(plutil -extract hostAddress raw -o - - <<< "${publication}")" \
    || ! port="$(plutil -extract hostPort raw -o - - <<< "${publication}")" \
    || ! container_port="$(
      plutil -extract containerPort raw -o - - <<< "${publication}"
    )"; then
    printf "ERROR: container '%s' has an unreadable port publication.\n" "${NAME}" >&2
    return 1
  fi
  if [[ "${container_port}" != 6080 ]]; then
    printf "ERROR: container '%s' does not publish the expected noVNC port.\n" \
      "${NAME}" >&2
    return 1
  fi

  case "${host}" in
    0.0.0.0 | '::') host='localhost' ;;
    *:*) host="[${host}]" ;;
  esac
  printf 'http://%s:%s/vnc.html\n' "${host}" "${port}"
}

build() {
  validate_containerfile
  check
  start_container_system
  container build --platform linux/arm64 --file "${CONTAINERFILE}" --tag "${IMAGE}" .
}

up() {
  local novnc_url
  local -a container_args

  check
  start_container_system
  if container_running; then
    novnc_url="$(container_novnc_url)"
    printf "Container '%s' is already running.\n" "${NAME}"
    printf 'noVNC:  %s\n' "${novnc_url}"
    return
  fi
  if ! image_exists; then
    build
  fi
  if container_exists; then
    printf "Removing stale container '%s'...\n" "${NAME}"
    container delete "${NAME}" > /dev/null
  fi
  if ((VNC_PASSWORD_GENERATED)) && [[ "${HOST_IP}" != '127.0.0.1' ]]; then
    printf 'ERROR: set an explicit VNC_PASSWORD before binding noVNC beyond 127.0.0.1.\n' >&2
    return 2
  fi

  printf "Starting container '%s'...\n" "${NAME}"
  container_args=(
    --detach
    --rm
    --uid 0
    --gid 0
    --name "${NAME}"
    --cpus "${CPUS}"
    --memory "${MEMORY}"
    --publish "${HOST_IP}:${PORT}:6080"
    --env "VNC_GEOMETRY=${VNC_GEOMETRY}"
    --env "VNC_DEPTH=${VNC_DEPTH}"
    --env "VNC_PASSWORD=${VNC_PASSWORD}"
    --env "PSENTRY_POLL_INTERVAL=${POLL_INTERVAL}"
    --volume "${HOME_VOLUME}:${CONTAINER_HOME}"
  )
  container run "${container_args[@]}" "${IMAGE}" > /dev/null
  novnc_url="$(container_novnc_url)"
  printf "Container '%s' started.\n" "${NAME}"
  if ((VNC_PASSWORD_GENERATED)); then
    printf 'VNC password (randomly generated): %s\n' "${VNC_PASSWORD}"
  fi
  printf 'noVNC:  %s\n' "${novnc_url}"
}

down() {
  check
  start_container_system
  if container_running; then
    printf "Stopping container '%s'...\n" "${NAME}"
    container stop "${NAME}" > /dev/null 2>&1 || true
  else
    printf "Container '%s' is not running.\n" "${NAME}"
  fi
}

status() {
  local novnc_url

  check
  start_container_system
  printf 'Container: %s\n' "${NAME}"
  if container_running; then
    novnc_url="$(container_novnc_url)"
    printf 'Status:    running\nnoVNC:     %s\n' "${novnc_url}"
  elif container_exists; then
    printf 'Status:    stopped (stale container present)\n'
    return 1
  else
    printf 'Status:    not running\n'
    return 1
  fi
}

gh_login() {
  check
  start_container_system
  require_running
  # Acquire psentry's own global lock before driving gh auth login, so a
  # scheduled poll pass cannot read/write GitHub state while the credential
  # or selected account is being changed interactively. Fail fast rather
  # than blocking: a poll pass can run for as long as an Oracle review,
  # which is too long to leave an interactive login silently hanging.
  # shellcheck disable=SC2016 # expands inside the container-side `bash -c`, not here
  exec container exec --interactive --tty \
    "${NAME}" /usr/local/bin/psentry-entrypoint \
    bash -c '
      set -euo pipefail
      lock_file=$(psentry --print-lock-file)
      mkdir -p -- "$(dirname -- "${lock_file}")"
      exec {LOCK_FD}> "${lock_file}"
      if ! flock -n "${LOCK_FD}"; then
        printf "ERROR: a psentry pass is currently running; wait for it to finish, then retry gh-login.\n" >&2
        exit 1
      fi
      exec gh auth login
    ' bash
}

oracle_login() {
  local novnc_url

  check
  start_container_system
  require_running
  novnc_url="$(container_novnc_url)"
  printf 'Complete the ChatGPT login in noVNC: %s\n' "${novnc_url}"
  # Acquire psentry's own global lock (the same lock file bin/psentry
  # resolves) before driving the browser, so a scheduled poll pass cannot
  # run Oracle concurrently with this manual login against the same
  # Oracle/Chromium profile. Fail fast rather than blocking: an Oracle
  # review can run for the length of a poll pass, which is too long to
  # leave an interactive login silently hanging.
  # shellcheck disable=SC2016 # expands inside the container-side `bash -c`, not here
  exec container exec --interactive --tty \
    "${NAME}" /usr/local/bin/psentry-entrypoint \
    bash -c '
      set -euo pipefail
      oracle_home_dir=$1
      lock_file=$(psentry --print-lock-file)
      mkdir -p -- "$(dirname -- "${lock_file}")"
      exec {LOCK_FD}> "${lock_file}"
      if ! flock -n "${LOCK_FD}"; then
        printf "ERROR: a psentry pass is currently running; wait for it to finish, then retry oracle-login.\n" >&2
        exit 1
      fi
      exec env -u ORACLE_BROWSER_PROFILE_DIR "ORACLE_HOME_DIR=${oracle_home_dir}" \
        oracle \
        --engine browser \
        --browser-manual-login \
        --browser-manual-login-profile-dir "${oracle_home_dir}/browser-profile" \
        --browser-keep-browser \
        --browser-input-timeout 5m \
        --prompt "Initialize the psentry browser profile"
    ' bash "${SENTRY_ORACLE_HOME}"
}

run() {
  check
  start_container_system
  require_running
  container exec \
    "${NAME}" /usr/local/bin/psentry-entrypoint psentry
}

dry_run() {
  check
  start_container_system
  require_running
  container exec \
    "${NAME}" /usr/local/bin/psentry-entrypoint psentry --dry-run
}

clean() {
  check
  start_container_system
  if container_running; then
    container stop "${NAME}" > /dev/null
  fi
  if container_exists; then
    container delete "${NAME}" > /dev/null
  fi
  if image_exists; then
    container image delete "${IMAGE}" > /dev/null
  fi
  if volume_exists; then
    printf "Removing volume '%s' (including credentials, browser data, and configuration)...\n" \
      "${HOME_VOLUME}"
    container volume delete "${HOME_VOLUME}" > /dev/null
  fi
  printf 'Clean complete.\n'
}

help() {
  cat << EOF
Usage: make <target> [VARIABLE=value ...]

Targets:
  up            Build when needed and start the desktop container
  down          Stop the desktop container
  status        Show whether the container is running
  gh-login      Authenticate GitHub CLI in the persistent home volume
  oracle-login  Authenticate ChatGPT Web through the noVNC desktop
  run           Run one psentry pass
  dry-run       Discover and report decisions without writes
  build         Build IMAGE locally for linux/arm64
  clean         Remove the container, image, and persistent home volume
  help          Show this help message

Common variables:
  CONTAINERFILE=Containerfile
  IMAGE=psentry:local
  NAME=psentry
  HOST_IP=127.0.0.1
  PORT=6080
  CPUS=4
  MEMORY=4G
  POLL_INTERVAL=15m
  VNC_GEOMETRY=1440x900
  VNC_DEPTH=24
  VNC_PASSWORD=<generated for loopback use when empty>
  HOME_VOLUME=psentry-home
EOF
}

main() {
  local command="${1:-help}"

  if ((${#} > 1)); then
    printf 'ERROR: expected one command, got %s.\n' "${#}" >&2
    return 2
  fi

  case "${command}" in
    help | build | up | down | status | gh-login | oracle-login | run | \
      dry-run | clean)
      "${command//-/_}"
      ;;
    *)
      printf 'ERROR: unknown command: %s\n' "${command}" >&2
      return 2
      ;;
  esac
}

main "${@}"
