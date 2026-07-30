#!/usr/bin/env bash

set -euo pipefail

if [[ "${#}" -gt 0 && "${1}" == '--debug' ]]; then
  set -x
  shift
fi

readonly CONTAINERFILE="${CONTAINERFILE:-Containerfile}"
readonly IMAGE="${IMAGE:-oracle-pr-sentry:local}"
readonly NAME="${NAME:-oracle-pr-sentry}"
readonly HOST_IP="${HOST_IP:-127.0.0.1}"
readonly PORT="${PORT:-6080}"
readonly CPUS="${CPUS:-4}"
readonly MEMORY="${MEMORY:-4G}"
readonly VNC_GEOMETRY="${VNC_GEOMETRY:-1440x900}"
readonly VNC_DEPTH="${VNC_DEPTH:-24}"
if [[ -n "${VNC_PASSWORD:-}" ]]; then
  readonly VNC_PASSWORD VNC_PASSWORD_GENERATED=0
else
  printf -v VNC_PASSWORD '%04x%04x' "${RANDOM}" "${RANDOM}"
  readonly VNC_PASSWORD VNC_PASSWORD_GENERATED=1
fi
readonly CONTAINER_HOME='/home/agent'
readonly HOME_VOLUME="${HOME_VOLUME:-oracle-pr-sentry-home}"
readonly CONTAINER_WORKSPACE='/workspace'
readonly WORKSPACE_DIR="${WORKSPACE_DIR:-$(pwd)}"
readonly MIN_MACOS_MAJOR="${MIN_MACOS_MAJOR:-26}"
NOVNC_HOST="${HOST_IP}"
if [[ "${HOST_IP}" == '0.0.0.0' ]]; then
  NOVNC_HOST='localhost'
fi
readonly NOVNC_HOST
readonly NOVNC_URL="http://${NOVNC_HOST}:${PORT}/vnc.html"
readonly SENTRY_ORACLE_HOME="${CONTAINER_HOME}/.local/share/oracle-pr-sentry/oracle-home"

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

validate_workspace_dir() {
  [[ -d "${WORKSPACE_DIR}" ]] || {
    printf "ERROR: WORKSPACE_DIR does not exist or is not a directory: '%s'.\n" \
      "${WORKSPACE_DIR}" >&2
    return 2
  }
}

require_running() {
  container_running || {
    printf "ERROR: container '%s' is not running. Run 'make up' first.\n" "${NAME}" >&2
    return 1
  }
}

build() {
  validate_containerfile
  check
  start_container_system
  container build --platform linux/arm64 --file "${CONTAINERFILE}" --tag "${IMAGE}" .
}

pull() {
  check
  start_container_system
  printf "Pulling image '%s'...\n" "${IMAGE}"
  container image pull --platform linux/arm64 "${IMAGE}"
}

up() {
  local -a container_args

  check
  validate_workspace_dir
  start_container_system
  if container_running; then
    printf "Container '%s' is already running.\n" "${NAME}"
    printf 'noVNC:  %s\n' "${NOVNC_URL}"
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
    --volume "${HOME_VOLUME}:${CONTAINER_HOME}"
    --volume "${WORKSPACE_DIR}:${CONTAINER_WORKSPACE}"
  )
  container run "${container_args[@]}" "${IMAGE}" > /dev/null
  printf "Container '%s' started.\n" "${NAME}"
  if ((VNC_PASSWORD_GENERATED)); then
    printf 'VNC password (randomly generated): %s\n' "${VNC_PASSWORD}"
  fi
  printf 'noVNC:  %s\n' "${NOVNC_URL}"
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
  check
  start_container_system
  printf 'Container: %s\n' "${NAME}"
  if container_running; then
    printf 'Status:    running\nnoVNC:     %s\n' "${NOVNC_URL}"
  elif container_exists; then
    printf 'Status:    stopped (stale container present)\n'
    return 1
  else
    printf 'Status:    not running\n'
    return 1
  fi
}

shell() {
  check
  start_container_system
  require_running
  exec container exec --interactive --tty \
    "${NAME}" /usr/local/bin/oracle-pr-sentry-entrypoint bash --login
}

gh_login() {
  check
  start_container_system
  require_running
  exec container exec --interactive --tty \
    "${NAME}" /usr/local/bin/oracle-pr-sentry-entrypoint gh auth login
}

oracle_login() {
  check
  start_container_system
  require_running
  printf 'Complete the ChatGPT login in noVNC: %s\n' "${NOVNC_URL}"
  exec container exec --interactive --tty \
    "${NAME}" /usr/local/bin/oracle-pr-sentry-entrypoint \
    env -u ORACLE_BROWSER_PROFILE_DIR \
    "ORACLE_HOME_DIR=${SENTRY_ORACLE_HOME}" \
    oracle \
    --engine browser \
    --browser-manual-login \
    --browser-manual-login-profile-dir "${SENTRY_ORACLE_HOME}/browser-profile" \
    --browser-keep-browser \
    --browser-input-timeout 5m \
    --prompt 'Initialize the oracle-pr-sentry browser profile'
}

run() {
  check
  start_container_system
  require_running
  container exec \
    "${NAME}" /usr/local/bin/oracle-pr-sentry-entrypoint oracle-pr-sentry
}

dry_run() {
  check
  start_container_system
  require_running
  container exec \
    "${NAME}" /usr/local/bin/oracle-pr-sentry-entrypoint oracle-pr-sentry --dry-run
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
    printf "Removing volume '%s' (including credentials, browser state, and sentry state)...\n" \
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
  shell         Open an interactive shell as the unprivileged agent user
  gh-login      Authenticate GitHub CLI in the persistent home volume
  oracle-login  Authenticate ChatGPT Web through the noVNC desktop
  run           Run one oracle-pr-sentry pass
  dry-run       Discover and report decisions without writes
  pull          Pull IMAGE for linux/arm64
  build         Build IMAGE locally for linux/arm64
  clean         Remove the container, image, and persistent home volume
  check         Validate the Apple Container host requirements
  help          Show this help message

Common variables:
  CONTAINERFILE=Containerfile
  IMAGE=oracle-pr-sentry:local
  NAME=oracle-pr-sentry
  HOST_IP=127.0.0.1
  PORT=6080
  CPUS=4
  MEMORY=4G
  VNC_GEOMETRY=1440x900
  VNC_DEPTH=24
  VNC_PASSWORD=<generated for loopback use when empty>
  HOME_VOLUME=oracle-pr-sentry-home
  WORKSPACE_DIR=<current directory>
EOF
}

main() {
  local command="${1:-help}"

  if ((${#} > 1)); then
    printf 'ERROR: expected one command, got %s.\n' "${#}" >&2
    return 2
  fi

  case "${command}" in
    help | check | build | pull | up | down | status | shell | \
      gh-login | oracle-login | run | dry-run | clean)
      "${command//-/_}"
      ;;
    *)
      printf 'ERROR: unknown command: %s\n' "${command}" >&2
      return 2
      ;;
  esac
}

main "${@}"
