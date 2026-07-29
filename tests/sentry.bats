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

@test "empty Oracle output is never posted" {
  export ORACLE_EMPTY_OUTPUT=1
  invoke_sentry

  [ "$status" -ne 0 ]
  [ "$(review_count)" -eq 0 ]
  [[ "$output" == *"empty or invalid Markdown"* ]]
}

@test "a head change during Oracle execution discards the stale review" {
  export GH_RACE_HEAD=1
  invoke_sentry

  [ "$status" -ne 0 ]
  [ "$(review_count)" -eq 0 ]
  [[ "$output" == *"discarding stale review"* ]]
}

@test "a post followed by an atomic state failure recovers from its marker" {
  export ORACLE_REVIEW_TEXT='<!-- oracle-pr-sentry:v1 identity=oracle-pr-sentry fingerprint=dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd head=aaaaaaaa -->'
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
