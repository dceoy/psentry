setup_sentry_test() {
  TEST_ROOT="$(cd -- "$BATS_TEST_DIRNAME/.." && pwd)"
  TEST_HOME="$BATS_TEST_TMPDIR/home"
  GH_SHIM_STATE_DIR="$BATS_TEST_TMPDIR/shim-state"
  TEST_STATE_DIR="$BATS_TEST_TMPDIR/state"
  TEST_RUNTIME_DIR="$BATS_TEST_TMPDIR/runtime"
  TEST_CACHE_DIR="$BATS_TEST_TMPDIR/cache"

  mkdir -p -- \
    "$TEST_HOME" \
    "$GH_SHIM_STATE_DIR" \
    "$TEST_STATE_DIR" \
    "$TEST_RUNTIME_DIR" \
    "$TEST_CACHE_DIR"

  export TEST_ROOT TEST_HOME GH_SHIM_STATE_DIR
  export HOME="$TEST_HOME"
  export PATH="$TEST_ROOT/tests/shims:$PATH"
  export GH_FIXTURE="$TEST_ROOT/tests/fixtures/pr-ready.json"
  export GH_DIFF_FIXTURE="$TEST_ROOT/tests/fixtures/pr.diff"
  export GH_READY_NUMBERS=1
  export GH_DRAFT_NUMBERS=
  export ORACLE_PR_SENTRY_GITHUB_OWNER=octo
  export ORACLE_PR_SENTRY_GITHUB_AUTHOR=octo
  export ORACLE_PR_SENTRY_PROMPT_PATH="$TEST_ROOT/share/oracle-pr-sentry/review-prompt.md"
  export ORACLE_PR_SENTRY_STATE_FILE="$TEST_STATE_DIR/state.json"
  export ORACLE_PR_SENTRY_RUNTIME_DIR="$TEST_RUNTIME_DIR"
  export ORACLE_PR_SENTRY_CACHE_DIR="$TEST_CACHE_DIR"
  export ORACLE_PR_SENTRY_MAX_REVIEW_RUNTIME=5
  export ORACLE_PR_SENTRY_RETENTION_DAYS=30
  export SENTRY_UNDER_TEST="$TEST_ROOT/bin/oracle-pr-sentry"

  unset \
    FAIL_STATE_MV \
    FLOCK_BUSY \
    GH_DRAFT_FIXTURE \
    GH_FAIL_PR \
    GH_FIXTURE_1 \
    GH_FIXTURE_2 \
    GH_INCLUDE_POSTED_MARKER \
    GH_READY_SEARCH_FIXTURE \
    GH_RACE_HEAD \
    GH_REVIEW_FAIL \
    ORACLE_EMPTY_OUTPUT \
    ORACLE_EXIT_STATUS \
    ORACLE_PR_SENTRY_ORACLE_ARGS_FILE \
    ORACLE_REVIEW_TEXT \
    ORACLE_SLEEP
}

invoke_sentry() {
  run "$SENTRY_UNDER_TEST" "$@"
}

review_count() {
  local count_file="$GH_SHIM_STATE_DIR/review-count"
  if [[ -f "$count_file" ]]; then
    cat "$count_file"
  else
    printf '0\n'
  fi
}

oracle_count() {
  local log_file="$GH_SHIM_STATE_DIR/oracle.log"
  if [[ -f "$log_file" ]]; then
    wc -l <"$log_file" | tr -d ' '
  else
    printf '0\n'
  fi
}
