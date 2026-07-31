#!/usr/bin/env bats

bats_require_minimum_version 1.5.0

setup() {
  TEST_ROOT="$(cd -- "$BATS_TEST_DIRNAME/.." && pwd)"
  ENTRYPOINT_TMP="$BATS_TEST_TMPDIR/entrypoint"
  ENTRYPOINT_HOME="$ENTRYPOINT_TMP/home"
  ENTRYPOINT_LOG="$ENTRYPOINT_TMP/events.log"
  SYSTEM_SLEEP="$(command -v sleep)"
  mkdir -p -- "$ENTRYPOINT_HOME"
  : > "$ENTRYPOINT_LOG"

  export TEST_ROOT ENTRYPOINT_TMP ENTRYPOINT_HOME ENTRYPOINT_LOG SYSTEM_SLEEP
  export PATH="$TEST_ROOT/tests/container-shims:$PATH"
  export HOME="$ENTRYPOINT_HOME"
  USER_NAME="$(id -un)"
  export USER_NAME
  export DISPLAY=:1
  export VNC_GEOMETRY=1440x900
  export VNC_DEPTH=24
  export VNC_PASSWORD=test-password
  export NOVNC_PORT=6080
  export PSENTRY_POLL_INTERVAL=1s
  export ENTRYPOINT_BLOCK_SLEEP=1
  unset ENTRYPOINT_FAIL_FIRST ENTRYPOINT_BLOCK_PSENTRY ENTRYPOINT_SLEEP_RELEASES
  unset ENTRYPOINT_WEBSOCKIFY_EXIT_AFTER_PSENTRY

  ENTRYPOINT_PID=
}

teardown() {
  if [[ -n "${ENTRYPOINT_PID}" ]] && kill -0 "${ENTRYPOINT_PID}" 2> /dev/null; then
    kill -TERM "${ENTRYPOINT_PID}" 2> /dev/null || true
    wait "${ENTRYPOINT_PID}" 2> /dev/null || true
  fi
}

start_entrypoint() {
  env "$@" "$TEST_ROOT/container/entrypoint.sh" > "$ENTRYPOINT_TMP/stdout" \
    2> "$ENTRYPOINT_TMP/stderr" &
  ENTRYPOINT_PID=$!
}

wait_for_event() {
  local pattern=$1
  local attempt

  for attempt in {1..100}; do
    grep -q -- "$pattern" "$ENTRYPOINT_LOG" && return 0
    kill -0 "$ENTRYPOINT_PID" 2> /dev/null || return 1
    "$SYSTEM_SLEEP" 0.05
  done
  return 1
}

wait_for_log() {
  local pattern=$1
  local attempt

  attempt=0
  while ((attempt < 20)); do
    ((attempt += 1))
    grep -q -- "$pattern" "$ENTRYPOINT_LOG" && return 0
    "$SYSTEM_SLEEP" 0.05
  done
  return 1
}

stop_entrypoint() {
  local signal=$1

  kill -s "$signal" "$ENTRYPOINT_PID"
  if wait "$ENTRYPOINT_PID"; then
    ENTRYPOINT_STATUS=0
  else
    ENTRYPOINT_STATUS=$?
  fi
  ENTRYPOINT_PID=
}

wait_entrypoint() {
  if wait "$ENTRYPOINT_PID"; then
    ENTRYPOINT_STATUS=0
  else
    ENTRYPOINT_STATUS=$?
  fi
  ENTRYPOINT_PID=
}

@test "the polling loop runs immediately and waits after each pass" {
  start_entrypoint
  wait_for_event '^sleep-start:1:'

  mapfile -t events < <(grep -E '^(psentry-start|sleep-start):' "$ENTRYPOINT_LOG")
  [[ "${events[0]}" == psentry-start:1:* ]]
  [[ "${events[1]}" == sleep-start:1:* ]]
}

@test "the polling loop defaults to a 15 minute fixed delay" {
  unset PSENTRY_POLL_INTERVAL
  start_entrypoint
  wait_for_event '^sleep-start:1:-- 15m$'
}

@test "the polling loop continues after a failed pass" {
  export ENTRYPOINT_FAIL_FIRST=1
  export ENTRYPOINT_SLEEP_RELEASES=1
  start_entrypoint
  wait_for_event '^psentry-start:2:'

  grep -q '^psentry-fail:1$' "$ENTRYPOINT_LOG"
  grep -q 'psentry pass failed; retrying after 1s' "$ENTRYPOINT_TMP/stderr"
}

@test "SIGTERM is forwarded during a psentry pass" {
  export ENTRYPOINT_BLOCK_PSENTRY=1
  start_entrypoint
  wait_for_event '^psentry-start:1:'
  stop_entrypoint TERM

  [ "$ENTRYPOINT_STATUS" -eq 143 ]
  wait_for_log '^psentry-signal:TERM$'
}

@test "SIGTERM is forwarded during polling sleep" {
  start_entrypoint
  wait_for_event '^sleep-start:1:'
  stop_entrypoint TERM

  [ "$ENTRYPOINT_STATUS" -eq 143 ]
  wait_for_log '^sleep-signal:TERM$'
}

@test "a pending shutdown signal exits immediately when no workload is active" {
  # The real race (signal arriving between one run_active call returning and
  # the next starting) is a handful of bash builtins wide and cannot be hit
  # reliably by racing an external kill against a live process, so this
  # sources the script directly and drives forward_signal with active_pid
  # empty, which is exactly that gap.
  run bash -c '
    source "'"$TEST_ROOT"'/container/entrypoint.sh"
    WEBSOCKIFY_PID=$$
    active_pid=""
    shutdown_signal=""
    launching=""
    pending_signal=""
    forward_signal TERM
  '

  [ "$status" -eq 143 ]
}

@test "a signal during the launch window is queued instead of exiting immediately" {
  # Closes the race between "${@}" & backgrounding a workload and the
  # following active_pid=$! recording it: forward_signal must not conclude
  # nothing is running and exit while a workload is mid-launch.
  run bash -c '
    source "'"$TEST_ROOT"'/container/entrypoint.sh"
    WEBSOCKIFY_PID=$$
    active_pid=""
    shutdown_signal=""
    launching=1
    pending_signal=""
    forward_signal TERM
    printf "pending_signal=%s\n" "$pending_signal"
  '

  [ "$status" -eq 0 ]
  [[ "$output" == "pending_signal=TERM" ]]
}

@test "a signal queued during the launch window is forwarded to the workload" {
  # Pre-seeds pending_signal as if forward_signal had already deferred it
  # during the launch window, then confirms run_active's post-registration
  # check actually forwards it and kills the freshly launched workload,
  # rather than just recording that a signal arrived.
  run bash -c '
    source "'"$TEST_ROOT"'/container/entrypoint.sh"
    set -m
    "$SYSTEM_SLEEP" 30 &
    WEBSOCKIFY_PID=$!
    active_pid=""
    shutdown_signal=""
    launching=""
    pending_signal="TERM"
    run_active "$SYSTEM_SLEEP" 30
  '

  [ "$status" -eq 143 ]
}

@test "SIGTERM waits for the active workload to actually exit before shutting down" {
  start_entrypoint \
    ENTRYPOINT_BLOCK_PSENTRY=1 \
    ENTRYPOINT_TERM_DELAY=0.3
  wait_for_event '^psentry-start:1:'
  stop_entrypoint TERM

  [ "$ENTRYPOINT_STATUS" -eq 143 ]
  grep -q '^psentry-delayed-exit$' "$ENTRYPOINT_LOG"
}

@test "SIGTERM force-kills an active workload that outlives the shutdown timeout" {
  start_entrypoint \
    ENTRYPOINT_BLOCK_PSENTRY=1 \
    ENTRYPOINT_TERM_DELAY=5 \
    ACTIVE_SHUTDOWN_TIMEOUT_SECONDS=0.3
  wait_for_event '^psentry-start:1:'
  stop_entrypoint TERM

  [ "$ENTRYPOINT_STATUS" -eq 143 ]
  run grep -q '^psentry-delayed-exit$' "$ENTRYPOINT_LOG"
  [ "$status" -eq 1 ]
}

@test "a second SIGTERM while reaping does not leave the workload running" {
  start_entrypoint \
    ENTRYPOINT_BLOCK_PSENTRY=1 \
    ENTRYPOINT_TERM_DELAY=10 \
    ACTIVE_SHUTDOWN_TIMEOUT_SECONDS=1
  wait_for_event '^psentry-start:1:'
  local workload_pid
  read -r workload_pid < "$ENTRYPOINT_TMP/psentry.pid"

  # Send a second TERM while entrypoint is still reaping the first one, i.e.
  # before the psentry shim (which is sleeping out ENTRYPOINT_TERM_DELAY)
  # actually exits, so it interrupts the blocking `wait` in reap_active.
  kill -s TERM "$ENTRYPOINT_PID"
  wait_for_log '^psentry-signal:TERM$'
  kill -s TERM "$ENTRYPOINT_PID"
  wait_entrypoint

  [ "$ENTRYPOINT_STATUS" -eq 143 ]
  run grep -q '^psentry-delayed-exit$' "$ENTRYPOINT_LOG"
  [ "$status" -eq 1 ]
  run kill -0 "$workload_pid"
  [ "$status" -ne 0 ]
}

@test "the SIGKILL backstop waits for a child that outlives the leader" {
  start_entrypoint \
    ENTRYPOINT_BLOCK_PSENTRY=1 \
    ENTRYPOINT_CHILD_IGNORES_TERM=1 \
    ACTIVE_SHUTDOWN_TIMEOUT_SECONDS=0.3
  wait_for_event '^psentry-start:1:'
  wait_for_log '^psentry-child-start$'
  local child_pid
  read -r child_pid < "$ENTRYPOINT_TMP/psentry-child.pid"
  [ -n "$child_pid" ]
  stop_entrypoint TERM

  [ "$ENTRYPOINT_STATUS" -eq 143 ]
  wait_for_log '^psentry-signal:TERM$'
  run kill -0 "$child_pid"
  [ "$status" -ne 0 ]
}

@test "the entrypoint stops when the noVNC proxy exits" {
  export ENTRYPOINT_WEBSOCKIFY_EXIT=1
  start_entrypoint
  local status
  if wait "$ENTRYPOINT_PID"; then
    status=0
  else
    status=$?
  fi
  ENTRYPOINT_PID=

  [ "$status" -eq 1 ]
  grep -q '^websockify-exit:1$' "$ENTRYPOINT_LOG"
  grep -q 'noVNC proxy exited unexpectedly' "$ENTRYPOINT_TMP/stderr"
}

@test "the entrypoint stops when the noVNC proxy exits during a psentry pass" {
  start_entrypoint \
    ENTRYPOINT_BLOCK_PSENTRY=1 \
    ENTRYPOINT_WEBSOCKIFY_EXIT_AFTER_PSENTRY=1
  wait_entrypoint

  [ "$ENTRYPOINT_STATUS" -eq 1 ]
  grep -q '^websockify-exit:1$' "$ENTRYPOINT_LOG"
  grep -q '^psentry-signal:TERM$' "$ENTRYPOINT_LOG"
  grep -q 'noVNC proxy exited unexpectedly' "$ENTRYPOINT_TMP/stderr"
}

@test "the noVNC exit path force-kills a psentry pass that outlives the shutdown timeout" {
  start_entrypoint \
    ENTRYPOINT_BLOCK_PSENTRY=1 \
    ENTRYPOINT_TERM_DELAY=5 \
    ENTRYPOINT_WEBSOCKIFY_EXIT_AFTER_PSENTRY=1 \
    ACTIVE_SHUTDOWN_TIMEOUT_SECONDS=0.3
  wait_entrypoint

  [ "$ENTRYPOINT_STATUS" -eq 1 ]
  grep -q '^websockify-exit:1$' "$ENTRYPOINT_LOG"
  grep -q '^psentry-signal:TERM$' "$ENTRYPOINT_LOG"
  run grep -q '^psentry-delayed-exit$' "$ENTRYPOINT_LOG"
  [ "$status" -eq 1 ]
}

@test "an invalid polling interval fails before services start" {
  run env PSENTRY_POLL_INTERVAL=not-a-duration "$TEST_ROOT/container/entrypoint.sh"

  [ "$status" -eq 2 ]
  [[ "$output" == *"invalid PSENTRY_POLL_INTERVAL"* ]]
  run grep -Eq '^(vncserver|websockify|psentry-start):' "$ENTRYPOINT_LOG"
  [ "$status" -eq 1 ]
}

@test "zero and sub-minimum polling intervals fail before services start" {
  for interval in 0 0.01s; do
    run env PSENTRY_POLL_INTERVAL="$interval" "$TEST_ROOT/container/entrypoint.sh"

    [ "$status" -eq 2 ]
    [[ "$output" == *"invalid PSENTRY_POLL_INTERVAL"* ]]
    run grep -Eq '^(vncserver|websockify|psentry-start):' "$ENTRYPOINT_LOG"
    [ "$status" -eq 1 ]
  done
}

@test "an explicit command remains a one-pass foreground command" {
  run "$TEST_ROOT/container/entrypoint.sh" psentry --dry-run

  [ "$status" -eq 0 ]
  grep -q '^psentry-start:1:--dry-run$' "$ENTRYPOINT_LOG"
  run grep -q '^vncserver:' "$ENTRYPOINT_LOG"
  [ "$status" -eq 1 ]
}

@test "container controls expose polling without a host workspace" {
  run "$TEST_ROOT/container.sh" help

  [ "$status" -eq 0 ]
  [[ "$output" == *"POLL_INTERVAL=15m"* ]]
  [[ "$output" != *"  shell "* ]]
  [[ "$output" != *"  pull "* ]]
  [[ "$output" != *"  check "* ]]

  run grep -F '/workspace' "$TEST_ROOT/Containerfile" "$TEST_ROOT/container.sh"
  [ "$status" -eq 1 ]
  grep -q "PSENTRY_POLL_INTERVAL=\${POLL_INTERVAL}" "$TEST_ROOT/container.sh"
}
