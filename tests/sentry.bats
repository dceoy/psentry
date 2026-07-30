#!/usr/bin/env bats

load test_helper

setup() {
  setup_sentry_test
}

@test "an empty first-run state schedules and records a new eligible PR" {
  invoke_sentry

  [ "$status" -eq 0 ]
  [ "$(review_count)" -eq 1 ]
  jq -e '
    .version == 1
    and .prs["octo/example#1"].reviewed.fingerprint != null
    and .prs["octo/example#1"].reviewed.publication_status == "published"
  ' "$ORACLE_PR_SENTRY_STATE_FILE"
}

@test "an unchanged fingerprint never invokes Oracle or posts twice" {
  invoke_sentry
  [ "$status" -eq 0 ]

  invoke_sentry
  [ "$status" -eq 0 ]
  [ "$(review_count)" -eq 1 ]
  [ "$(oracle_count)" -eq 1 ]
}

@test "a changed head SHA schedules a new review" {
  invoke_sentry
  [ "$status" -eq 0 ]

  export GH_FIXTURE="$TEST_ROOT/tests/fixtures/pr-head-changed.json"
  invoke_sentry

  [ "$status" -eq 0 ]
  [ "$(review_count)" -eq 2 ]
  [[ "$output" == *"head-sha-changed"* ]]
}

@test "a head transition back to an older reviewed SHA schedules a new review" {
  invoke_sentry
  [ "$status" -eq 0 ]

  export GH_FIXTURE="$TEST_ROOT/tests/fixtures/pr-head-changed.json"
  invoke_sentry
  [ "$status" -eq 0 ]

  export GH_FIXTURE="$TEST_ROOT/tests/fixtures/pr-ready.json"
  invoke_sentry

  [ "$status" -eq 0 ]
  [ "$(review_count)" -eq 3 ]
  [ "$(oracle_count)" -eq 3 ]
  [[ "$output" == *"head-sha-changed"* ]]
}

@test "a draft-to-ready transition is observed and reviewed" {
  export GH_READY_NUMBERS=
  export GH_DRAFT_NUMBERS=1
  export GH_FIXTURE="$TEST_ROOT/tests/fixtures/pr-draft.json"
  invoke_sentry

  [ "$status" -eq 0 ]
  [ "$(review_count)" -eq 0 ]
  jq -e '.prs["octo/example#1"].observed.draft == true' \
    "$ORACLE_PR_SENTRY_STATE_FILE"

  export GH_READY_NUMBERS=1
  export GH_DRAFT_NUMBERS=
  export GH_FIXTURE="$TEST_ROOT/tests/fixtures/pr-ready.json"
  invoke_sentry

  [ "$status" -eq 0 ]
  [ "$(review_count)" -eq 1 ]
  [[ "$output" == *"draft-to-ready"* ]]
}

@test "a reviewed PR becoming draft and ready again schedules another review" {
  invoke_sentry
  [ "$status" -eq 0 ]

  export GH_READY_NUMBERS=
  export GH_DRAFT_NUMBERS=1
  export GH_FIXTURE="$TEST_ROOT/tests/fixtures/pr-draft.json"
  invoke_sentry
  [ "$status" -eq 0 ]
  [ "$(review_count)" -eq 1 ]

  export GH_READY_NUMBERS=1
  export GH_DRAFT_NUMBERS=
  export GH_FIXTURE="$TEST_ROOT/tests/fixtures/pr-ready.json"
  invoke_sentry

  [ "$status" -eq 0 ]
  [ "$(review_count)" -eq 2 ]
  [[ "$output" == *"draft-to-ready"* ]]
}

@test "CI moving from pending to failure changes the meaningful fingerprint" {
  export GH_FIXTURE="$TEST_ROOT/tests/fixtures/pr-ci-pending.json"
  invoke_sentry
  [ "$status" -eq 0 ]

  export GH_FIXTURE="$TEST_ROOT/tests/fixtures/pr-ci-failure.json"
  invoke_sentry

  [ "$status" -eq 0 ]
  [ "$(review_count)" -eq 2 ]
  [[ "$output" == *"ci-failure"* ]]
}

@test "the same CI failure recurring after success schedules another review" {
  export GH_FIXTURE="$TEST_ROOT/tests/fixtures/pr-ci-failure.json"
  invoke_sentry
  [ "$status" -eq 0 ]

  export GH_FIXTURE="$TEST_ROOT/tests/fixtures/pr-ready.json"
  invoke_sentry
  [ "$status" -eq 0 ]
  [ "$(review_count)" -eq 1 ]

  export GH_FIXTURE="$TEST_ROOT/tests/fixtures/pr-ci-failure.json"
  invoke_sentry

  [ "$status" -eq 0 ]
  [ "$(review_count)" -eq 2 ]
  [[ "$output" == *"ci-failure"* ]]
}

@test "a repeated CI transition stays unique after marker recovery" {
  export GH_FIXTURE="$TEST_ROOT/tests/fixtures/pr-ci-failure.json"
  invoke_sentry
  [ "$status" -eq 0 ]

  export GH_FIXTURE="$TEST_ROOT/tests/fixtures/pr-ready.json"
  invoke_sentry
  [ "$status" -eq 0 ]

  export GH_FIXTURE="$TEST_ROOT/tests/fixtures/pr-ci-failure.json"
  invoke_sentry
  [ "$status" -eq 0 ]
  [ "$(review_count)" -eq 2 ]

  rm -f -- "$ORACLE_PR_SENTRY_STATE_FILE"
  invoke_sentry
  [ "$status" -eq 0 ]
  [ "$(review_count)" -eq 2 ]
  [ "$(oracle_count)" -eq 2 ]

  export GH_FIXTURE="$TEST_ROOT/tests/fixtures/pr-ready.json"
  invoke_sentry
  [ "$status" -eq 0 ]

  export GH_FIXTURE="$TEST_ROOT/tests/fixtures/pr-ci-failure.json"
  invoke_sentry

  [ "$status" -eq 0 ]
  [ "$(review_count)" -eq 3 ]
  [ "$(oracle_count)" -eq 3 ]
  [[ "$output" == *"ci-failure"* ]]
}

@test "a CI baseline survives state loss before the same failure recurs" {
  export GH_FIXTURE="$TEST_ROOT/tests/fixtures/pr-ci-failure.json"
  invoke_sentry
  [ "$status" -eq 0 ]

  export GH_FIXTURE="$TEST_ROOT/tests/fixtures/pr-ready.json"
  invoke_sentry
  [ "$status" -eq 0 ]
  [ "$(review_count)" -eq 1 ]
  [ "$(baseline_count)" -eq 1 ]

  rm -f -- "$ORACLE_PR_SENTRY_STATE_FILE"
  invoke_sentry
  [ "$status" -eq 0 ]
  [ "$(review_count)" -eq 1 ]
  [ "$(baseline_count)" -eq 1 ]

  export GH_FIXTURE="$TEST_ROOT/tests/fixtures/pr-ci-failure.json"
  invoke_sentry

  [ "$status" -eq 0 ]
  [ "$(review_count)" -eq 2 ]
  [ "$(oracle_count)" -eq 2 ]
  [[ "$output" == *"ci-failure"* ]]
}

@test "CI recovery after state loss does not schedule a new review" {
  export GH_FIXTURE="$TEST_ROOT/tests/fixtures/pr-ci-failure.json"
  invoke_sentry
  [ "$status" -eq 0 ]

  rm -f -- "$ORACLE_PR_SENTRY_STATE_FILE"
  export GH_FIXTURE="$TEST_ROOT/tests/fixtures/pr-ready.json"
  invoke_sentry

  [ "$status" -eq 0 ]
  [ "$(review_count)" -eq 1 ]
  [ "$(oracle_count)" -eq 1 ]
  [ "$(baseline_count)" -eq 1 ]
  [[ "$output" == *"no meaningful update"* ]]
}

@test "partial CI recovery after state loss does not schedule a new review" {
  two_failures="$BATS_TEST_TMPDIR/two-failures.json"
  one_failure="$BATS_TEST_TMPDIR/one-failure.json"
  make_ci_failure_fixture "$two_failures" lint test
  make_ci_failure_fixture "$one_failure" test

  export GH_FIXTURE="$two_failures"
  invoke_sentry
  [ "$status" -eq 0 ]

  rm -f -- "$ORACLE_PR_SENTRY_STATE_FILE"
  export GH_FIXTURE="$one_failure"
  invoke_sentry

  [ "$status" -eq 0 ]
  [ "$(review_count)" -eq 1 ]
  [ "$(oracle_count)" -eq 1 ]
  [ "$(baseline_count)" -eq 1 ]
  [[ "$output" == *"no meaningful update"* ]]
}

@test "a newly published CI baseline immediately preserves comparison state" {
  three_failures="$BATS_TEST_TMPDIR/three-failures.json"
  two_failures="$BATS_TEST_TMPDIR/two-failures.json"
  one_failure="$BATS_TEST_TMPDIR/one-failure.json"
  make_ci_failure_fixture "$three_failures" lint test typecheck
  make_ci_failure_fixture "$two_failures" lint test
  make_ci_failure_fixture "$one_failure" test

  export GH_FIXTURE="$three_failures"
  invoke_sentry
  [ "$status" -eq 0 ]

  rm -f -- "$ORACLE_PR_SENTRY_STATE_FILE"
  export GH_FIXTURE="$two_failures"
  invoke_sentry
  [ "$status" -eq 0 ]
  [ "$(review_count)" -eq 1 ]
  [ "$(baseline_count)" -eq 1 ]
  jq -e '
    .prs["octo/example#1"].comparison.source == "baseline"
    and (.prs["octo/example#1"] | has("reviewed") | not)
  ' "$ORACLE_PR_SENTRY_STATE_FILE"

  export GH_FIXTURE="$one_failure"
  invoke_sentry

  [ "$status" -eq 0 ]
  [ "$(review_count)" -eq 1 ]
  [ "$(oracle_count)" -eq 1 ]
  [[ "$output" == *"no meaningful update"* ]]
}

@test "a recovered CI baseline preserves partial-recovery comparison state" {
  three_failures="$BATS_TEST_TMPDIR/three-failures.json"
  two_failures="$BATS_TEST_TMPDIR/two-failures.json"
  one_failure="$BATS_TEST_TMPDIR/one-failure.json"
  make_ci_failure_fixture "$three_failures" lint test typecheck
  make_ci_failure_fixture "$two_failures" lint test
  make_ci_failure_fixture "$one_failure" test

  export GH_FIXTURE="$three_failures"
  invoke_sentry
  [ "$status" -eq 0 ]

  export GH_FIXTURE="$two_failures"
  invoke_sentry
  [ "$status" -eq 0 ]
  [ "$(review_count)" -eq 1 ]
  [ "$(baseline_count)" -eq 1 ]

  rm -f -- "$ORACLE_PR_SENTRY_STATE_FILE"
  invoke_sentry
  [ "$status" -eq 0 ]
  [ "$(review_count)" -eq 1 ]
  jq -e '
    .prs["octo/example#1"].comparison.source == "baseline"
    and (.prs["octo/example#1"] | has("reviewed") | not)
  ' "$ORACLE_PR_SENTRY_STATE_FILE"

  export GH_FIXTURE="$one_failure"
  invoke_sentry

  [ "$status" -eq 0 ]
  [ "$(review_count)" -eq 1 ]
  [ "$(oracle_count)" -eq 1 ]
  [[ "$output" == *"no meaningful update"* ]]
}

@test "a recovered CI baseline preserves success comparison state" {
  two_failures="$BATS_TEST_TMPDIR/two-failures.json"
  one_failure="$BATS_TEST_TMPDIR/one-failure.json"
  make_ci_failure_fixture "$two_failures" lint test
  make_ci_failure_fixture "$one_failure" test

  export GH_FIXTURE="$two_failures"
  invoke_sentry
  [ "$status" -eq 0 ]

  export GH_FIXTURE="$one_failure"
  invoke_sentry
  [ "$status" -eq 0 ]
  [ "$(review_count)" -eq 1 ]
  [ "$(baseline_count)" -eq 1 ]

  rm -f -- "$ORACLE_PR_SENTRY_STATE_FILE"
  invoke_sentry
  [ "$status" -eq 0 ]
  [ "$(review_count)" -eq 1 ]

  export GH_FIXTURE="$TEST_ROOT/tests/fixtures/pr-ready.json"
  invoke_sentry

  [ "$status" -eq 0 ]
  [ "$(review_count)" -eq 1 ]
  [ "$(oracle_count)" -eq 1 ]
  [[ "$output" == *"no meaningful update"* ]]
}

@test "a draft baseline survives state loss before the PR becomes ready" {
  invoke_sentry
  [ "$status" -eq 0 ]

  export GH_READY_NUMBERS=
  export GH_DRAFT_NUMBERS=1
  export GH_FIXTURE="$TEST_ROOT/tests/fixtures/pr-draft.json"
  invoke_sentry
  [ "$status" -eq 0 ]
  [ "$(review_count)" -eq 1 ]
  [ "$(baseline_count)" -eq 1 ]

  rm -f -- "$ORACLE_PR_SENTRY_STATE_FILE"
  invoke_sentry
  [ "$status" -eq 0 ]
  [ "$(review_count)" -eq 1 ]
  [ "$(baseline_count)" -eq 1 ]

  export GH_READY_NUMBERS=1
  export GH_DRAFT_NUMBERS=
  export GH_FIXTURE="$TEST_ROOT/tests/fixtures/pr-ready.json"
  invoke_sentry

  [ "$status" -eq 0 ]
  [ "$(review_count)" -eq 2 ]
  [ "$(oracle_count)" -eq 2 ]
  [[ "$output" == *"draft-to-ready"* ]]
}

@test "a draft baseline survives state loss before and after draft observation" {
  invoke_sentry
  [ "$status" -eq 0 ]

  rm -f -- "$ORACLE_PR_SENTRY_STATE_FILE"
  export GH_READY_NUMBERS=
  export GH_DRAFT_NUMBERS=1
  export GH_FIXTURE="$TEST_ROOT/tests/fixtures/pr-draft.json"
  invoke_sentry
  [ "$status" -eq 0 ]
  [ "$(review_count)" -eq 1 ]
  [ "$(baseline_count)" -eq 1 ]

  rm -f -- "$ORACLE_PR_SENTRY_STATE_FILE"
  export GH_READY_NUMBERS=1
  export GH_DRAFT_NUMBERS=
  export GH_FIXTURE="$TEST_ROOT/tests/fixtures/pr-ready.json"
  invoke_sentry

  [ "$status" -eq 0 ]
  [ "$(review_count)" -eq 2 ]
  [ "$(oracle_count)" -eq 2 ]
  [[ "$output" == *"draft-to-ready"* ]]
}

@test "CI review triggers only when the observed failure set gains a check" {
  two_failures="$BATS_TEST_TMPDIR/two-failures.json"
  one_failure="$BATS_TEST_TMPDIR/one-failure.json"
  replacement_failure="$BATS_TEST_TMPDIR/replacement-failure.json"
  jq '
    .statusCheckRollup = [
      {
        name: "lint",
        workflowName: "CI",
        status: "COMPLETED",
        conclusion: "FAILURE",
        detailsUrl: "https://github.com/octo/example/actions/runs/lint"
      },
      {
        name: "test",
        workflowName: "CI",
        status: "COMPLETED",
        conclusion: "FAILURE",
        detailsUrl: "https://github.com/octo/example/actions/runs/test"
      }
    ]
  ' "$TEST_ROOT/tests/fixtures/pr-ready.json" >"$two_failures"
  jq '
    .statusCheckRollup = [.statusCheckRollup[] | select(.name == "test")]
  ' "$two_failures" >"$one_failure"
  jq '
    .statusCheckRollup += [
      {
        name: "typecheck",
        workflowName: "CI",
        status: "COMPLETED",
        conclusion: "FAILURE",
        detailsUrl: "https://github.com/octo/example/actions/runs/typecheck"
      }
    ]
  ' "$one_failure" >"$replacement_failure"

  export GH_FIXTURE="$two_failures"
  invoke_sentry
  [ "$status" -eq 0 ]
  [ "$(review_count)" -eq 1 ]

  export GH_FIXTURE="$one_failure"
  invoke_sentry
  [ "$status" -eq 0 ]
  [ "$(review_count)" -eq 1 ]
  [[ "$output" == *"no meaningful update"* ]]

  export GH_FIXTURE="$replacement_failure"
  invoke_sentry

  [ "$status" -eq 0 ]
  [ "$(review_count)" -eq 2 ]
  [[ "$output" == *"ci-failure"* ]]
}

@test "a rerun URL does not change the logical CI failure identity" {
  rerun_fixture="$BATS_TEST_TMPDIR/rerun.json"
  export GH_FIXTURE="$TEST_ROOT/tests/fixtures/pr-ci-failure.json"
  invoke_sentry
  [ "$status" -eq 0 ]

  jq '
    .statusCheckRollup[0].detailsUrl =
      "https://github.com/octo/example/actions/runs/retry"
  ' "$GH_FIXTURE" >"$rerun_fixture"
  export GH_FIXTURE="$rerun_fixture"
  invoke_sentry

  [ "$status" -eq 0 ]
  [ "$(review_count)" -eq 1 ]
  [ "$(oracle_count)" -eq 1 ]
  [[ "$output" == *"no meaningful update"* ]]
}

@test "new external discussion activity schedules a new review" {
  invoke_sentry
  [ "$status" -eq 0 ]

  export GH_FIXTURE="$TEST_ROOT/tests/fixtures/pr-external-activity.json"
  invoke_sentry

  [ "$status" -eq 0 ]
  [ "$(review_count)" -eq 2 ]
  [[ "$output" == *"external-activity"* ]]
}

@test "reordered equivalent GitHub arrays keep the same fingerprint" {
  ordered_fixture="$BATS_TEST_TMPDIR/ordered.json"
  reordered_fixture="$BATS_TEST_TMPDIR/reordered.json"
  jq '
    .statusCheckRollup = [
      {
        name: "lint",
        workflowName: "CI",
        status: "COMPLETED",
        conclusion: "SUCCESS",
        detailsUrl: "https://github.com/octo/example/actions/runs/2"
      },
      {
        name: "test",
        workflowName: "CI",
        status: "COMPLETED",
        conclusion: "FAILURE",
        detailsUrl: "https://github.com/octo/example/actions/runs/1"
      }
    ]
    | .comments = [
      {
        id: "comment-1",
        author: {login: "reviewer"},
        createdAt: "2026-07-29T10:00:00Z",
        updatedAt: "2026-07-29T10:00:00Z",
        body: "First"
      },
      {
        id: "comment-2",
        author: {login: "reviewer"},
        createdAt: "2026-07-29T11:00:00Z",
        updatedAt: "2026-07-29T11:00:00Z",
        body: "Second"
      }
    ]
    | .files += [{path: "src/another.sh", additions: 1, deletions: 0}]
  ' "$GH_FIXTURE" >"$ordered_fixture"
  jq '
    .statusCheckRollup |= reverse
    | .comments |= reverse
    | .files |= reverse
  ' "$ordered_fixture" >"$reordered_fixture"

  export GH_FIXTURE="$ordered_fixture"
  invoke_sentry
  [ "$status" -eq 0 ]

  export GH_FIXTURE="$reordered_fixture"
  invoke_sentry

  [ "$status" -eq 0 ]
  [ "$(review_count)" -eq 1 ]
  [ "$(oracle_count)" -eq 1 ]
}

@test "the sentry marker is ignored as external activity and recovers lost state" {
  invoke_sentry
  [ "$status" -eq 0 ]
  rm -f -- "$ORACLE_PR_SENTRY_STATE_FILE"

  invoke_sentry

  [ "$status" -eq 0 ]
  [ "$(review_count)" -eq 1 ]
  [ "$(oracle_count)" -eq 1 ]
  jq -e '
    .prs["octo/example#1"].reviewed.publication_status == "recovered"
  ' "$ORACLE_PR_SENTRY_STATE_FILE"
}

@test "an Oracle non-zero exit leaves the review retryable" {
  export ORACLE_EXIT_STATUS=7
  invoke_sentry

  [ "$status" -ne 0 ]
  [ "$(review_count)" -eq 0 ]
  jq -e '.prs["octo/example#1"].reviewed == null' \
    "$ORACLE_PR_SENTRY_STATE_FILE"

  unset ORACLE_EXIT_STATUS
  invoke_sentry
  [ "$status" -eq 0 ]
  [ "$(review_count)" -eq 1 ]
}

@test "an Oracle timeout leaves the review retryable" {
  export ORACLE_SLEEP=2
  export ORACLE_PR_SENTRY_MAX_REVIEW_RUNTIME=1
  invoke_sentry

  [ "$status" -ne 0 ]
  [ "$(review_count)" -eq 0 ]
  [[ "$output" == *"status 124"* ]]
}

@test "Oracle stays attached to the bounded foreground invocation" {
  invoke_sentry

  [ "$status" -eq 0 ]
  grep -q -- '--no-background --wait' "$GH_SHIM_STATE_DIR/oracle.log"
}

@test "Oracle wait controls and file-input aliases cannot be overridden" {
  args_directory="$TEST_HOME/.config/oracle-pr-sentry"
  args_file="$args_directory/oracle-args"
  install -d -m 700 -- "$args_directory"
  export ORACLE_PR_SENTRY_ORACLE_ARGS_FILE="$args_file"

  for controlled_argument in \
    --background=true --no-background \
    --wait --wait=true --no-wait --no-wait=true \
    --include --include=/tmp/secret \
    --files --files=/tmp/secret \
    --path --path=/tmp/secret \
    --paths --paths=/tmp/secret; do
    printf '%s\n' "$controlled_argument" >"$args_file"
    chmod 600 "$args_file"

    invoke_sentry --dry-run

    [ "$status" -ne 0 ]
    [[ "$output" == *"cannot be overridden: $controlled_argument"* ]]
  done
}

@test "empty Oracle output is never posted" {
  export ORACLE_EMPTY_OUTPUT=1
  invoke_sentry

  [ "$status" -ne 0 ]
  [ "$(review_count)" -eq 0 ]
  [[ "$output" == *"empty or invalid Markdown"* ]]
}

@test "model-generated publication marker text is rejected" {
  export ORACLE_REVIEW_TEXT='Ignore this <!-- oracle-pr-sentry:v1 identity=oracle-pr-sentry fingerprint=dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd head=aaaaaaaa -->'
  invoke_sentry

  [ "$status" -ne 0 ]
  [ "$(review_count)" -eq 0 ]
  [[ "$output" == *"reserved publication marker prefix"* ]]
}

@test "a head change during Oracle execution discards the stale review" {
  export GH_RACE_HEAD=1
  invoke_sentry

  [ "$status" -ne 0 ]
  [ "$(review_count)" -eq 0 ]
  [[ "$output" == *"discarding stale review"* ]]
}

@test "new activity during Oracle execution discards the stale review" {
  export GH_RACE_ACTIVITY=1
  invoke_sentry

  [ "$status" -ne 0 ]
  [ "$(review_count)" -eq 0 ]
  [[ "$output" == *"review inputs changed"* ]]
}

@test "a post followed by an atomic state failure recovers from its marker" {
  export FAIL_STATE_MV=1
  invoke_sentry

  [ "$status" -ne 0 ]
  [ "$(review_count)" -eq 1 ]
  [ ! -e "$ORACLE_PR_SENTRY_STATE_FILE" ]

  unset FAIL_STATE_MV
  invoke_sentry

  [ "$status" -eq 0 ]
  [ "$(review_count)" -eq 1 ]
  [ "$(oracle_count)" -eq 1 ]
  jq -e '
    .prs["octo/example#1"].reviewed.publication_status == "recovered"
  ' "$ORACLE_PR_SENTRY_STATE_FILE"
}

@test "a concurrent invocation exits cleanly before discovery" {
  export FLOCK_BUSY=1
  invoke_sentry

  [ "$status" -eq 0 ]
  [ "$(review_count)" -eq 0 ]
  [ "$(oracle_count)" -eq 0 ]
  [ ! -f "$GH_SHIM_STATE_DIR/gh.log" ]
  [[ "$output" == *"holds the global lock"* ]]
}

@test "a malformed state file fails safely" {
  printf '%s\n' '{"version":1,"prs":[]}' >"$ORACLE_PR_SENTRY_STATE_FILE"
  invoke_sentry

  [ "$status" -ne 0 ]
  [ "$(review_count)" -eq 0 ]
  [[ "$output" == *"malformed or unsupported state file"* ]]
}

@test "discovery applies owner author open archived and draft filters" {
  export GH_READY_NUMBERS=1
  export GH_DRAFT_NUMBERS=2
  export GH_FIXTURE_2="$TEST_ROOT/tests/fixtures/pr-draft.json"
  invoke_sentry --dry-run

  [ "$status" -eq 0 ]
  [ "$(review_count)" -eq 0 ]
  [[ "$output" == *"eligible octo/example#1"* ]]
  [[ "$output" == *"ineligible octo/example#2: draft observed"* ]]
  grep -q -- '--owner octo' "$GH_SHIM_STATE_DIR/gh.log"
  grep -q -- '--author octo' "$GH_SHIM_STATE_DIR/gh.log"
  grep -q -- '--state open' "$GH_SHIM_STATE_DIR/gh.log"
  grep -q -- '--archived=false' "$GH_SHIM_STATE_DIR/gh.log"
  grep -q -- 'draft:false' "$GH_SHIM_STATE_DIR/gh.log"
}

@test "bounded discovery selects the most recently updated pull requests" {
  export GH_READY_SEARCH_FIXTURE="$TEST_ROOT/tests/fixtures/pr-search-ready-many.json"
  export GH_DRAFT_NUMBERS=
  export ORACLE_PR_SENTRY_PR_SEARCH_LIMIT=2

  invoke_sentry --dry-run

  [ "$status" -eq 0 ]
  [[ "$output" == *"eligible octo/example#102"* ]]
  [[ "$output" == *"eligible octo/example#103"* ]]
  [[ "$output" != *"octo/example#101"* ]]
  grep -q -- '--limit 2' "$GH_SHIM_STATE_DIR/gh.log"
  grep -q -- '--sort updated' "$GH_SHIM_STATE_DIR/gh.log"
  grep -q -- '--order desc' "$GH_SHIM_STATE_DIR/gh.log"
}

@test "dry-run leaves configured storage and state permissions unchanged" {
  invoke_sentry
  [ "$status" -eq 0 ]

  chmod 640 "$ORACLE_PR_SENTRY_STATE_FILE"
  state_digest=$(sha256sum "$ORACLE_PR_SENTRY_STATE_FILE" | awk '{print $1}')
  dry_cache="$BATS_TEST_TMPDIR/dry-cache"
  dry_runtime="$BATS_TEST_TMPDIR/dry-runtime"
  dry_lock="$BATS_TEST_TMPDIR/dry-lock/sentry.lock"
  export ORACLE_PR_SENTRY_CACHE_DIR="$dry_cache"
  export ORACLE_PR_SENTRY_RUNTIME_DIR="$dry_runtime"
  export ORACLE_PR_SENTRY_LOCK_FILE="$dry_lock"

  invoke_sentry --dry-run

  [ "$status" -eq 0 ]
  [ ! -e "$dry_cache" ]
  [ ! -e "$dry_runtime" ]
  [ ! -e "$(dirname "$dry_lock")" ]
  [ "$(stat -c '%a' "$ORACLE_PR_SENTRY_STATE_FILE")" = 640 ]
  [ "$(sha256sum "$ORACLE_PR_SENTRY_STATE_FILE" | awk '{print $1}')" = "$state_digest" ]
}

@test "a transient error for one PR does not stop remaining candidates" {
  export GH_READY_NUMBERS=1,2
  export GH_FAIL_PR=1
  export GH_FIXTURE_2="$TEST_ROOT/tests/fixtures/pr-ready.json"
  invoke_sentry

  [ "$status" -ne 0 ]
  [ "$(review_count)" -eq 1 ]
  jq -e '.prs["octo/example#2"].reviewed.fingerprint != null' \
    "$ORACLE_PR_SENTRY_STATE_FILE"
  [[ "$output" == *"candidate failed; continuing"* ]]
}

@test "missing dependencies produce an actionable error" {
  export ORACLE_PR_SENTRY_ORACLE_BIN=not-an-oracle
  invoke_sentry --dry-run

  [ "$status" -ne 0 ]
  [[ "$output" == *"required command not found: not-an-oracle"* ]]
}

@test "systemd leaves trusted config loading to the executable" {
  run grep -F "EnvironmentFile=" \
    "$TEST_ROOT/systemd/oracle-pr-sentry.service"

  [ "$status" -eq 1 ]
}

@test "systemd keeps the X11 socket visible inside its private tmp" {
  run grep -Fx "BindReadOnlyPaths=-/tmp/.X11-unix" \
    "$TEST_ROOT/systemd/oracle-pr-sentry.service"

  [ "$status" -eq 0 ]
}

@test "an unsafe config file is rejected before it is sourced" {
  config_directory="$TEST_HOME/.config/oracle-pr-sentry"
  config_file="$config_directory/env"
  side_effect="$BATS_TEST_TMPDIR/config-was-sourced"
  mkdir -p -- "$config_directory"
  printf 'touch %q\n' "$side_effect" >"$config_file"
  chmod 666 "$config_file"
  export ORACLE_PR_SENTRY_CONFIG_FILE="$config_file"

  invoke_sentry --dry-run

  [ "$status" -ne 0 ]
  [ ! -e "$side_effect" ]
  [[ "$output" == *"trusted file must not be group- or world-writable"* ]]
}
