#!/usr/bin/env bash

set -euo pipefail

validate_poll_interval() {
  local status

  # Delegate duration parsing to GNU sleep itself (via timeout) instead of
  # maintaining a second, custom duration grammar: if sleep is still running
  # when the minimum elapses, timeout kills it and returns 124 (valid and
  # long enough); if sleep finishes on its own, the value was either
  # malformed (non-zero, non-124 status) or shorter than the minimum
  # (status 0).
  if PSENTRY_INTERNAL_SLEEP=1 timeout --foreground \
    "${POLL_INTERVAL_MINIMUM_SECONDS}" sleep "${PSENTRY_POLL_INTERVAL}" \
    2> /dev/null; then
    status=0
  else
    status=$?
  fi

  if ((status == 124)); then
    return 0
  fi
  if ((status == 0)); then
    printf 'ERROR: invalid PSENTRY_POLL_INTERVAL: %s (must be longer than 100ms)\n' \
      "${PSENTRY_POLL_INTERVAL}" >&2
  else
    printf 'ERROR: invalid PSENTRY_POLL_INTERVAL: %s\n' \
      "${PSENTRY_POLL_INTERVAL}" >&2
  fi
  return 2
}

cleanup() {
  if [[ -n "${active_pid}" ]]; then
    kill -TERM -- "-${active_pid}" 2> /dev/null || true
    wait "${active_pid}" 2> /dev/null || true
  fi
  kill -TERM "${WEBSOCKIFY_PID}" 2> /dev/null || true
  wait "${WEBSOCKIFY_PID}" 2> /dev/null || true
  vncserver -kill "${DISPLAY}" > /dev/null 2>&1 || true
}

forward_signal() {
  shutdown_signal=$1
  if [[ -n "${active_pid}" ]]; then
    kill -s "${shutdown_signal}" -- "-${active_pid}" 2> /dev/null || true
  else
    # Nothing is running to signal, e.g. between one workload finishing and
    # the next starting; exit now instead of leaving the signal unhandled
    # until the next workload completes on its own (up to a full poll
    # interval later).
    finish_shutdown
  fi
}

finish_shutdown() {
  case "${shutdown_signal}" in
    INT) exit 130 ;;
    TERM) exit 143 ;;
  esac
}

reap_active() {
  # forward_signal already signaled the active process group; wait here for
  # it to actually exit (a foreground descendant may take time, or ignore
  # the signal) instead of returning immediately, so the caller does not
  # exit while it is still unreaped. The backgrounded killer force-kills the
  # group if it outlives the bounded timeout, then this waits for whichever
  # of the two actually ends the workload.
  local killer_pid

  (
    PSENTRY_INTERNAL_SLEEP=1 sleep "${ACTIVE_SHUTDOWN_TIMEOUT_SECONDS}"
    kill -KILL -- "-${active_pid}" 2> /dev/null || true
  ) &
  killer_pid=$!

  wait "${active_pid}" 2> /dev/null || true
  kill -- "-${killer_pid}" 2> /dev/null || true
  wait "${killer_pid}" 2> /dev/null || true
  active_pid=''
}

run_active() {
  local completed_pid='' status

  "${@}" &
  active_pid=$!
  if wait -n -p completed_pid "${active_pid}" "${WEBSOCKIFY_PID}"; then
    status=0
  else
    status=$?
  fi

  if [[ -z "${completed_pid:-}" ]]; then
    reap_active
    finish_shutdown
    return "${status}"
  fi

  if [[ "${completed_pid}" == "${WEBSOCKIFY_PID}" ]]; then
    printf 'ERROR: noVNC proxy exited unexpectedly.\n' >&2
    kill -TERM -- "-${active_pid}" 2> /dev/null || true
    reap_active
    return 1
  fi
  active_pid=''
  finish_shutdown
  return "${status}"
}

require_websockify() {
  if ! kill -0 "${WEBSOCKIFY_PID}" 2> /dev/null; then
    printf 'ERROR: noVNC proxy exited unexpectedly.\n' >&2
    exit 1
  fi
}

main() {
  : "${HOME:?HOME must be set}"
  : "${USER_NAME:?USER_NAME must be set}"
  PSENTRY_POLL_INTERVAL="${PSENTRY_POLL_INTERVAL:-15m}"
  readonly HOME USER_NAME PSENTRY_POLL_INTERVAL POLL_INTERVAL_MINIMUM_SECONDS=0.1 \
    ACTIVE_SHUTDOWN_TIMEOUT_SECONDS="${ACTIVE_SHUTDOWN_TIMEOUT_SECONDS:-10}"

  if (("$(id -u)" == 0)); then
    local user_uid user_gid
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

  # Job control puts each backgrounded command in its own process group so a
  # workload's foreground descendants (e.g. bin/psentry's Oracle subprocess)
  # can be signaled directly instead of relying on bash to forward a trap.
  set -m

  websockify \
    --web=/usr/share/novnc \
    "0.0.0.0:${NOVNC_PORT}" \
    localhost:5901 &
  readonly WEBSOCKIFY_PID=$!

  active_pid=''
  shutdown_signal=''

  trap cleanup EXIT
  trap 'forward_signal INT' INT
  trap 'forward_signal TERM' TERM

  while true; do
    require_websockify
    printf 'Starting psentry pass.\n' >&2
    if ! run_active psentry; then
      printf 'WARNING: psentry pass failed; retrying after %s.\n' \
        "${PSENTRY_POLL_INTERVAL}" >&2
    fi
    require_websockify
    printf 'Waiting %s before the next psentry pass.\n' \
      "${PSENTRY_POLL_INTERVAL}" >&2
    if ! run_active sleep -- "${PSENTRY_POLL_INTERVAL}"; then
      printf 'ERROR: polling sleep failed.\n' >&2
      exit 1
    fi
  done
}

# Guard the imperative startup/loop behind a sourced-vs-executed check so
# tests can source this file to exercise forward_signal/finish_shutdown/
# run_active directly, without running vncserver or entering the poll loop.
if ! (return 0 2> /dev/null); then
  main "${@}"
fi
