setup_sentry_test() {
  TEST_ROOT="$(cd -- "$BATS_TEST_DIRNAME/.." && pwd)"
  TEST_HOME="$BATS_TEST_TMPDIR/home"
  GH_SHIM_STATE_DIR="$BATS_TEST_TMPDIR/shim-state"
  TEST_RUNTIME_DIR="$BATS_TEST_TMPDIR/runtime"
  TEST_CACHE_DIR="$BATS_TEST_TMPDIR/cache"
  SYSTEM_FLOCK="$(command -v flock)"

  mkdir -p -- \
    "$TEST_HOME" \
    "$GH_SHIM_STATE_DIR" \
    "$TEST_RUNTIME_DIR" \
    "$TEST_CACHE_DIR"

  export TEST_ROOT TEST_HOME GH_SHIM_STATE_DIR SYSTEM_FLOCK
  export HOME="$TEST_HOME"
  export PATH="$TEST_ROOT/tests/shims:$PATH"
  READY_FIXTURE="$TEST_ROOT/tests/fixtures/pr-ready.json"
  DRAFT_FIXTURE="$BATS_TEST_TMPDIR/pr-draft.json"
  CI_PENDING_FIXTURE="$BATS_TEST_TMPDIR/pr-ci-pending.json"
  CI_FAILURE_FIXTURE="$BATS_TEST_TMPDIR/pr-ci-failure.json"
  EXTERNAL_ACTIVITY_FIXTURE="$BATS_TEST_TMPDIR/pr-external-activity.json"
  jq '.isDraft = true | .body = "Work in progress."' \
    "$READY_FIXTURE" > "$DRAFT_FIXTURE"
  jq '
    .statusCheckRollup = [{
      name: "test",
      workflowName: "CI",
      status: "IN_PROGRESS",
      conclusion: null,
      startedAt: "2026-07-29T10:00:00Z",
      completedAt: null,
      detailsUrl: "https://github.com/octo/example/actions/runs/1"
    }]
  ' "$READY_FIXTURE" > "$CI_PENDING_FIXTURE"
  jq '
    .statusCheckRollup = [{
      name: "test",
      workflowName: "CI",
      status: "COMPLETED",
      conclusion: "FAILURE",
      startedAt: "2026-07-29T10:00:00Z",
      completedAt: "2026-07-29T10:05:00Z",
      detailsUrl: "https://github.com/octo/example/actions/runs/1"
    }]
  ' "$READY_FIXTURE" > "$CI_FAILURE_FIXTURE"
  jq '
    .comments = [{
      id: "IC_kwDOexample",
      author: {login: "reviewer"},
      createdAt: "2026-07-29T11:00:00Z",
      updatedAt: "2026-07-29T11:00:00Z",
      body: "Could you double-check the failure path?"
    }]
  ' "$READY_FIXTURE" > "$EXTERNAL_ACTIVITY_FIXTURE"

  export READY_FIXTURE DRAFT_FIXTURE
  export CI_PENDING_FIXTURE CI_FAILURE_FIXTURE EXTERNAL_ACTIVITY_FIXTURE
  export GH_FIXTURE="$READY_FIXTURE"
  export GH_DIFF_FIXTURE="$TEST_ROOT/tests/fixtures/pr.diff"
  export GH_READY_NUMBERS=1
  export GH_DRAFT_NUMBERS=
  export PSENTRY_GITHUB_OWNER=octo
  export PSENTRY_GITHUB_AUTHOR=octo
  export PSENTRY_PROMPT_PATH="$TEST_ROOT/share/psentry/review-prompt.md"
  export PSENTRY_RUNTIME_DIR="$TEST_RUNTIME_DIR"
  export PSENTRY_CACHE_DIR="$TEST_CACHE_DIR"
  export PSENTRY_MAX_REVIEW_RUNTIME=5
  export SENTRY_UNDER_TEST="$TEST_ROOT/bin/psentry"

  unset \
    FLOCK_BUSY \
    GH_FAIL_PR \
    GH_RACE_DIFF \
    GH_RACE_REQUIREMENTS \
    GH_FIXTURE_1 \
    GH_FIXTURE_2 \
    GH_INCLUDE_POSTED_MARKER \
    GH_INLINE_COMMENTS_JSON \
    GH_ISSUE_COMMENT_PAGES_JSON \
    GH_REVIEW_THREAD_RESOLVED \
    GH_REVIEW_THREAD_REVIEW_STATE \
    GH_READY_SEARCH_FIXTURE \
    GH_RACE_ACTIVITY \
    GH_RACE_HEAD \
    GH_REVIEW_FAIL \
    GH_TRUNCATE_PR_VIEW_REVIEWS \
    ORACLE_EMPTY_OUTPUT \
    ORACLE_EXIT_STATUS \
    PSENTRY_REATTACH_DELAY \
    PSENTRY_REATTACH_INTERVAL \
    PSENTRY_REATTACH_TIMEOUT \
    ORACLE_REVIEW_TEXT \
    ORACLE_SLEEP \
    ORACLE_SLEEP_PR_NUMBER
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
    wc -l < "$log_file" | tr -d ' '
  else
    printf '0\n'
  fi
}

baseline_count() {
  local count_file="$GH_SHIM_STATE_DIR/baseline-count"
  if [[ -f "$count_file" ]]; then
    cat "$count_file"
  else
    printf '0\n'
  fi
}

make_ci_failure_fixture() {
  local output=$1
  shift
  local names

  names=$(printf '%s\n' "$@" \
    | jq -Rsc 'split("\n") | map(select(length > 0))')
  jq --argjson names "$names" '
    .statusCheckRollup = [
      $names[] | {
        name: .,
        workflowName: "CI",
        status: "COMPLETED",
        conclusion: "FAILURE",
        detailsUrl: ("https://github.com/octo/example/actions/runs/" + .)
      }
    ]
  ' "$READY_FIXTURE" > "$output"
}
