#!/usr/bin/env bash

set -euo pipefail

: "${HOME:?HOME must be set}"
: "${USER_NAME:?USER_NAME must be set}"
PSENTRY_POLL_INTERVAL="${PSENTRY_POLL_INTERVAL:-15m}"
readonly HOME USER_NAME PSENTRY_POLL_INTERVAL

if (("$(id -u)" == 0)); then
  user_uid="$(id -u "${USER_NAME}")"
  user_gid="$(id -g "${USER_NAME}")"
  mkdir -p /run/dbus
  if [[ ! -S /run/dbus/system_bus_socket ]]; then
    dbus-daemon --system --fork
  fi
  if [[ "$(stat -c '%u:%g' "${HOME}")" != "${user_uid}:${user_gid}" ]]; then
    chown "${USER_NAME}:${USER_NAME}" "${HOME}"
  fi
  exec setpriv --reuid="${USER_NAME}" --regid="${USER_NAME}" --init-groups \
    env \
    USER="${USER_NAME}" \
    LOGNAME="${USER_NAME}" \
    PSENTRY_SEED_HOME=1 \
    "${BASH_SOURCE[0]}" "${@}"
fi

if [[ "${PSENTRY_SEED_HOME:-0}" == 1 && -d /opt/home-skel ]]; then
  unset PSENTRY_SEED_HOME
  cp -an /opt/home-skel/. "${HOME}/"
fi

readonly VNC_CONFIG_DIR="${HOME}/.config/tigervnc"

if ((${#} > 0)); then
  exec "${@}"
fi

: "${VNC_PASSWORD:?VNC_PASSWORD must be set}"

validate_poll_interval() {
  local status

  if timeout --foreground 0.01s sleep -- "${PSENTRY_POLL_INTERVAL}"; then
    return 0
  else
    status=$?
  fi
  [[ "${status}" -eq 124 ]] || {
    printf 'ERROR: invalid PSENTRY_POLL_INTERVAL: %s\n' \
      "${PSENTRY_POLL_INTERVAL}" >&2
    return 2
  }
}

validate_poll_interval

mkdir -p "${VNC_CONFIG_DIR}"
printf '%s\n' "${VNC_PASSWORD}" | vncpasswd -f > "${VNC_CONFIG_DIR}/passwd"
chmod 600 "${VNC_CONFIG_DIR}/passwd"

cat > "${VNC_CONFIG_DIR}/xstartup" << 'EOF'
#!/usr/bin/env bash

unset SESSION_MANAGER
unset DBUS_SESSION_BUS_ADDRESS
exec dbus-run-session -- startxfce4
EOF
chmod +x "${VNC_CONFIG_DIR}/xstartup"

vncserver "${DISPLAY}" \
  -geometry "${VNC_GEOMETRY}" \
  -depth "${VNC_DEPTH}" \
  -localhost yes

websockify \
  --web=/usr/share/novnc \
  "0.0.0.0:${NOVNC_PORT}" \
  localhost:5901 &
readonly WEBSOCKIFY_PID=$!

active_pid=''
shutdown_signal=''

cleanup() {
  if [[ -n "${active_pid}" ]]; then
    kill -TERM "${active_pid}" 2> /dev/null || true
    wait "${active_pid}" 2> /dev/null || true
  fi
  kill -TERM "${WEBSOCKIFY_PID}" 2> /dev/null || true
  wait "${WEBSOCKIFY_PID}" 2> /dev/null || true
  vncserver -kill "${DISPLAY}" > /dev/null 2>&1 || true
}

forward_signal() {
  shutdown_signal=$1
  if [[ -n "${active_pid}" ]]; then
    kill -s "${shutdown_signal}" "${active_pid}" 2> /dev/null || true
  fi
}

finish_shutdown() {
  case "${shutdown_signal}" in
    INT) exit 130 ;;
    TERM) exit 143 ;;
  esac
}

run_active() {
  local status

  "${@}" &
  active_pid=$!
  if wait "${active_pid}"; then
    status=0
  else
    status=$?
  fi
  active_pid=''
  finish_shutdown
  return "${status}"
}

trap cleanup EXIT
trap 'forward_signal INT' INT
trap 'forward_signal TERM' TERM

while true; do
  printf 'Starting psentry pass.\n' >&2
  if ! run_active psentry; then
    printf 'WARNING: psentry pass failed; retrying after %s.\n' \
      "${PSENTRY_POLL_INTERVAL}" >&2
  fi
  printf 'Waiting %s before the next psentry pass.\n' \
    "${PSENTRY_POLL_INTERVAL}" >&2
  if ! run_active sleep -- "${PSENTRY_POLL_INTERVAL}"; then
    printf 'ERROR: polling sleep failed.\n' >&2
    exit 1
  fi
done
