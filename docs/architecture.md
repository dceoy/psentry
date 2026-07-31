# Architecture and data contracts

## One-pass flow

Each `psentry` invocation runs exactly one pass:

1. validate trusted configuration and required commands;
2. acquire the non-blocking global `flock`;
3. identify the authenticated GitHub account;
4. search open, non-archived pull requests with the configured owner/author
   filters;
5. collect and normalize each pull request independently;
6. reduce the current facts and latest trusted GitHub marker to one action;
7. invoke Oracle only for a meaningful update;
8. re-read the PR state and head;
9. publish a comment-only review, making GitHub acceptance the commit point.

Errors for one pull request are logged and do not prevent remaining candidates
from being processed. The pass still exits non-zero so its caller can record
the failure. The container entrypoint logs it, waits, and starts another pass.

The sentry performs two bounded searches, ordered by most recent update so
newly active pull requests cannot remain behind a fixed set of older results:
`draft:false` supplies eligible work, while `draft:true` supplies observations
needed to recognize a later draft-to-ready transition. Drafts are never passed
to Oracle. The normalized list keeps that deterministic most-recently-updated
order on every pass and is not rotated through local persistence.

This stateless order does not starve later candidates within a single search
window: unchanged PRs with valid markers are skipped, each Oracle attempt has
a bounded runtime, and a failed attempt does not stop the remaining
candidates. More eligible PRs make a pass longer rather than imposing a
per-pass work budget. Repeated container restarts recompute the same order
from current GitHub data; a restart during the first review can delay later
candidates, but once a pass is allowed to run, the bounded attempt proceeds to
them. Concurrent manual passes exit through the global `flock`, and
fixed-delay polling never overlaps passes.

The window itself is bounded by `PSENTRY_PR_SEARCH_LIMIT` (default and
maximum `1000`, GitHub's own search API ceiling per query). If the number of
open pull requests matching the configured owner/author filters — ready and
draft combined — ever exceeds that limit, the oldest matches fall outside the
window and are excluded from every pass, not just the current one, because
the search is stateless and newest-first: nothing rotates them back in. This
repository does not expect that volume for a single owner/author and
therefore does not implement search partitioning or cursor rotation to cover
it; if it becomes a real constraint, partition the search deterministically
(for example by repository or by `updated`/`created` date windows) or
reintroduce bounded local rotation state.

## Normalized snapshot schema

The internal snapshot schema has `schema_version: 1`. Object keys are emitted
in sorted order. Collections that can arrive from GitHub in arbitrary order
are projected to stable fields and sorted deterministically.

```json
{
  "schema_version": 1,
  "repository": "owner/repository",
  "number": 123,
  "key": "owner/repository#123",
  "url": "https://github.com/owner/repository/pull/123",
  "title": "Pull request title",
  "body": "Pull request body",
  "author": "author-login",
  "state": "OPEN",
  "draft": false,
  "base": { "ref": "main" },
  "head": { "ref": "feature", "sha": "40-character-sha" },
  "diff": { "sha256": "sha256-of-the-exact-unified-diff" },
  "checks": [
    {
      "name": "test",
      "workflow": "CI",
      "producer": {
        "kind": "check_run",
        "workflow_id": "stable-workflow-node-id",
        "check_suite_id": "stable-check-suite-node-id",
        "app_id": "stable-app-node-id"
      },
      "status": "COMPLETED",
      "result": "FAILURE",
      "started_at": "ISO-8601 time",
      "completed_at": "ISO-8601 time",
      "details_url": "https://github.com/..."
    }
  ],
  "reviews": [],
  "comments": [],
  "review_comments": [],
  "review_threads": [
    {
      "kind": "review_thread",
      "id": "stable-graphql-node-id",
      "is_resolved": false,
      "is_outdated": false
    }
  ],
  "external_activity": [],
  "publications": [],
  "files": [{ "path": "src/file", "additions": 3, "deletions": 1 }]
}
```

Reviews, issue comments, and inline review comments share a normalized activity
shape with `kind`, `id`, `author`, created/updated times, review state, optional
path/line/commit, and body. They are sorted by creation time, kind, and stable
ID. Review threads add their stable GraphQL node ID and resolved/outdated
state to that activity projection, so resolving or reopening a conversation
changes the external-activity digest even when no comment is edited. Changed
files are sorted by path. Check identity includes stable GraphQL workflow,
check-suite, and app IDs so independent checks with the same display names do
not collapse; rerun-specific details URLs remain metadata only.

The `publications` collection contains only successfully parsed sentry markers
found in activity authored by the currently authenticated GitHub login with
the configured sentry identity. Those trusted marked activities are omitted
from `external_activity`. A marker written by any other account stays external
activity and cannot suppress work.

## Fingerprints and decisions

Relevant CI failures are the normalized conclusions:

- `FAILURE`
- `ERROR`
- `TIMED_OUT`
- `CANCELLED`
- `ACTION_REQUIRED`
- `STARTUP_FAILURE`
- `STALE`

Pending, neutral, skipped, and successful checks do not enter the CI digest.
The external activity array and relevant-failure array are independently
canonicalized with `jq -cS` and hashed with SHA-256. The exact unified diff
collected with the snapshot is also hashed; that same file is passed to Oracle.

The context fingerprint is the SHA-256 of canonical JSON containing:

```json
{
  "schema_version": 2,
  "base_ref": "main",
  "head_sha": "...",
  "diff_digest": "...",
  "external_digest": "...",
  "requirements": {
    "title": "Pull request title",
    "body": "Pull request body"
  }
}
```

The final input fingerprint hashes that context fingerprint together with the
CI digest and ready state. Consequently a title/body edit, base retarget, or
base-branch update that changes the effective PR diff schedules a new review
even when the head SHA is unchanged.

The side-effect-free `decision-reducer.jq` program receives only `current` and
`previous` facts and returns `{action, reason}`. Its actions are `review`,
`baseline`, and `none`. A review is selected for first ready observation,
draft readiness, a new head, a changed base/diff context, a newly added
relevant current-head CI failure, or changed external activity. CI recovery
and shrinking failure sets select `baseline`, preserving the comparison on
GitHub without invoking Oracle.

Every scheduled review receives an event fingerprint that hashes its input
fingerprint, trigger reason, and the next event sequence recovered from trusted
GitHub markers. The GitHub-observable sequence distinguishes repeated
transitions, including a head returning to an older commit, without depending
on resettable local state.

The pull request title, body, files, checks, and external discussion remain in
the metadata supplied to Oracle. Trusted sentry publications are removed from
the review, comment, and inline-comment arrays before upload so generated
reviews do not recursively become later model input. Code changes are
represented by the head SHA, base ref, and exact diff digest; labels,
assignees, milestones, and generic GitHub `updatedAt` are intentionally absent
from the trigger projection.

## Persistent state

There is no local scheduling or per-PR state. GitHub markers are the only
persistent event history, and candidate order is derived from each current
search response. Legacy cursor files are not read, so missing or malformed
legacy files cannot affect startup, ordering, or review decisions.

## Publication and races

Review and baseline events use the same versioned marker:

```text
<!-- psentry:v6 payload=BASE64_CANONICAL_JSON -->
```

The decoded payload contains the configured identity, event kind, event
sequence, review reason and fingerprint, input and context fingerprints, head
SHA, draft flag, normalized CI failure identities, and external-activity
digest. JSON is serialized with `jq -cS` and encoded with standard Base64.
Parsing extracts only the payload token, decodes it, validates the exact schema
and canonical representation, and trusts it only when its author is the
authenticated sentry account and its identity matches configuration.
Malformed, duplicated-key, non-canonical, spoofed-author, and foreign-identity
markers remain external activity.

Version 6 intentionally does not parse v5 markers or legacy per-PR local
state. Upgrades perform a documented one-time rebaseline of open PRs, after
which the executable has one steady-state parser.

Immediately before publication, the sentry collects a fresh snapshot and
requires:

- state is still open;
- the PR is still ready;
- head SHA is unchanged;
- the input fingerprint (including the exact diff digest) and next event
  sequence are unchanged;
- no exact trusted marker already exists.

A stale Oracle result is discarded. Publication always uses
`gh pr review --comment --body-file`; approval and request-changes modes are
not exposed. Exact-marker duplicate detection runs before Oracle and again
before publication. GitHub acceptance is the commit point, and the accepted
marker restores idempotency after process interruption or local data loss.

## Explicit non-goals

- webhook delivery or a polling loop inside the one-pass executable;
- repository cloning or full-tree semantic context;
- databases, Redis, queues, or Kubernetes;
- a GitHub REST/GraphQL client outside `gh`;
- YAML/TOML configuration or plugins;
- automated approval or request-changes reviews;
- guarantees against ChatGPT Web UI or login instability.
