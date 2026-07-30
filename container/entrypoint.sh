#!/usr/bin/env bash

set -euo pipefail

: "${HOME:?HOME must be set}"
: "${USER_NAME:?USER_NAME must be set}"
: "${WORKSPACE_DIR:?WORKSPACE_DIR must be set}"
readonly HOME USER_NAME WORKSPACE_DIR

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
    ORACLE_PR_SENTRY_SEED_HOME=1 \
    "${BASH_SOURCE[0]}" "${@}"
fi

if [[ "${ORACLE_PR_SENTRY_SEED_HOME:-0}" == 1 && -d /opt/home-skel ]]; then
  unset ORACLE_PR_SENTRY_SEED_HOME
  cp -an /opt/home-skel/. "${HOME}/"
fi

readonly VNC_CONFIG_DIR="${HOME}/.config/tigervnc"

if [[ -d "${WORKSPACE_DIR}" && ! -w "${WORKSPACE_DIR}" ]]; then
  printf 'WARNING: %s is not writable; the workspace may be read-only.\n' \
    "${WORKSPACE_DIR}" >&2
fi

if ((${#} > 0)); then
  exec "${@}"
fi

: "${VNC_PASSWORD:?VNC_PASSWORD must be set}"

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

exec websockify \
  --web=/usr/share/novnc \
  "0.0.0.0:${NOVNC_PORT}" \
  localhost:5901
