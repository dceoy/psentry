# Architecture and data contracts

## One-pass flow

Each timer activation runs exactly one process:

1. validate trusted configuration and required commands;
2. acquire the non-blocking global `flock`;
3. identify the authenticated GitHub account;
4. load and validate the local state document;
5. search open, non-archived pull requests with the configured owner/author
   filters;
6. collect and normalize each pull request independently;
7. compare its deterministic fingerprint with the last GitHub-accepted review;
8. invoke Oracle only for a meaningful update;
9. re-read the PR state and head;
10. publish a comment-only review and atomically record success.

Errors for one pull request are logged and do not prevent remaining candidates
from being processed. The pass still exits non-zero so systemd records a
failure.

The sentry performs two bounded searches, ordered by most recent update so
newly active pull requests cannot remain behind a fixed set of older results:
`draft:false` supplies eligible work, while `draft:true` supplies observations
needed to recognize a later draft-to-ready transition. Drafts are never passed
to Oracle.

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
  "base": {"ref": "main"},
  "head": {"ref": "feature", "sha": "40-character-sha"},
  "checks": [
    {
      "name": "test",
      "workflow": "CI",
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
  "external_activity": [],
  "publications": [],
  "files": [
    {"path": "src/file", "additions": 3, "deletions": 1}
  ]
}
```

Reviews, issue comments, and inline review comments share a normalized activity
shape with `kind`, `id`, `author`, created/updated times, review state, optional
path/line/commit, and body. They are sorted by creation time, kind, and stable
ID. Changed files are sorted by path; checks are sorted by workflow, name, and
details URL.

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
canonicalized with `jq -cS` and hashed with SHA-256.

The final fingerprint is the SHA-256 of canonical JSON containing:

```json
{
  "schema_version": 1,
  "head_sha": "...",
  "ready": true,
  "ci_digest": "...",
  "external_digest": "..."
}
```

A differing fingerprint is reviewed only when it represents first observation,
draft readiness, a new head, a newly added relevant current-head CI failure, or
changed external activity. Comparing the normalized current and previously
observed failure sets prevents either a transition back to success or a
shrinking failure set from scheduling a review by itself.

Every scheduled review receives an event fingerprint that hashes its input
fingerprint, trigger reason, and the next event sequence recovered from trusted
GitHub markers. The GitHub-observable sequence distinguishes repeated
transitions, including a head returning to an older commit, without depending
on resettable local state.

The pull request title, body, files, checks, and discussion remain in the
metadata supplied to Oracle. Code changes are represented by the head SHA;
labels, assignees, milestones, and generic GitHub `updatedAt` are intentionally
absent from the trigger projection.

## State schema

One JSON document stores entries under canonical `owner/repository#number`
keys:

```json
{
  "version": 1,
  "prs": {
    "owner/repository#123": {
      "url": "https://github.com/owner/repository/pull/123",
      "observed": {
        "head_sha": "...",
        "draft": false,
        "ci_digest": "...",
        "ci_failures": [],
        "last_seen_at": "2026-07-29T12:00:00Z"
      },
      "reviewed": {
        "fingerprint": "...",
        "head_sha": "...",
        "draft": false,
        "ci_digest": "...",
        "external_digest": "...",
        "successful_at": "2026-07-29T12:00:00Z",
        "marker": "<!-- oracle-pr-sentry:v2 ... -->",
        "publication_status": "published"
      }
    }
  }
}
```

`observed` may advance for a draft or unchanged PR and records both the latest
normalized CI failure set and its digest. A review is triggered only when the
set gains a failure, while an intervening successful observation allows the
same failure to trigger again later. When an observation changes without
requiring a review, the sentry posts a hidden baseline marker so that a later
state loss cannot erase the intervening success or draft transition. Event
identity comes from the durable sequence shared by baseline and review markers,
so state loss or retention pruning cannot reuse an older transition
fingerprint.
`reviewed` advances only after GitHub accepts the comment-only review or when
an already-published exact marker is recovered. Oracle and GitHub failures
never advance it.

Writes use `mktemp` in the state file's directory, complete JSON validation,
mode `0600`, and `mv` on the same filesystem. This prevents partial documents.
An absent file is a valid first run; malformed or unsupported state fails
closed.

Entries not seen by the configured searches are pruned after the retention
window. This eventually removes closed PRs and PRs made ineligible by filter
changes without requiring a separate database or full closed-PR scan.

## Publication and races

Every review ends with:

```text
<!-- oracle-pr-sentry:v2 identity=IDENTITY fingerprint=SHA256 input=INPUT_SHA256 head=HEAD_SHA event=SEQUENCE -->
```

Before Oracle, the latest trusted marker can reconcile missing local state when
its input fingerprint and head match the current snapshot.
Immediately before publication, the sentry collects a fresh snapshot and
requires:

- state is still open;
- the PR is still ready;
- head SHA is unchanged;
- the input fingerprint and next event sequence are unchanged;
- no exact trusted marker already exists.

A stale Oracle result is discarded. Publication always uses
`gh pr review --comment --body-file`; approval and request-changes modes are
not exposed. GitHub acceptance is the commit point. If the following local
state write fails, the exact marker restores idempotency on the next pass.

## Explicit non-goals

- webhook delivery or an internal daemon loop;
- repository cloning or full-tree semantic context;
- databases, Redis, queues, containers, or Kubernetes;
- a GitHub REST/GraphQL client outside `gh`;
- YAML/TOML configuration or plugins;
- automated approval or request-changes reviews;
- guarantees against ChatGPT Web UI or login instability.
