# oracle-pr-sentry

`oracle-pr-sentry` is a small Linux service that polls GitHub for pull requests
and asks [Oracle](https://github.com/steipete/oracle) to review meaningful
updates through a signed-in ChatGPT Web browser session. It posts only
comment-only GitHub reviews and remembers the exact fingerprints that GitHub
accepted.

The implementation deliberately stays close to shell glue:

- one Bash entrypoint;
- `gh` for every GitHub read and write;
- `jq` and SHA-256 for normalized snapshots and fingerprints;
- one atomic local JSON state file;
- `flock` for process-wide exclusion;
- a `systemd --user` oneshot service and timer;
- journald for operational logs.

There is no webhook server, database, queue, repository clone, container, or
custom GitHub client.

## Requirements

- Linux with Bash, systemd user services, util-linux, and GNU coreutils
- [GitHub CLI](https://cli.github.com/) authenticated as the account that will
  publish reviews
- `jq`
- [Oracle](https://github.com/steipete/oracle) and its supported Node.js
  runtime
- Chrome or Chromium available to the same unprivileged Linux user
- an active ChatGPT Web login in Oracle's persistent browser profile

Install Oracle using one of its documented methods. For example:

```console
npm install --global @steipete/oracle
```

Authenticate GitHub and confirm the active account:

```console
gh auth login
gh auth status
```

The GitHub credential needs read access to searched repositories and permission
to create pull request reviews. Private repositories normally require the
`repo` scope. The sentry does not read a token from its own configuration.

## Initial browser login

Run the first Oracle login from the user's graphical session:

```console
oracle --engine browser \
  --browser-manual-login \
  --browser-keep-browser \
  --browser-input-timeout 120000 \
  --prompt "Initialize the oracle-pr-sentry browser profile"
```

Complete the ChatGPT sign-in in the opened window. Oracle normally stores this
dedicated automation profile under `~/.oracle/browser-profile`. The timer must
run as this same Linux user.

Browser automation depends on the ChatGPT Web UI and login state. UI changes,
anti-bot challenges, subscription/model availability, and session expiry can
interrupt it even when the sentry itself is healthy.

## Install

From a checkout:

```console
bin/oracle-pr-sentry install
install -d -m 700 ~/.config/oracle-pr-sentry
install -m 600 config/env.example ~/.config/oracle-pr-sentry/env
${EDITOR:-vi} ~/.config/oracle-pr-sentry/env
```

The installer copies only these project-managed files:

- `~/.local/bin/oracle-pr-sentry`
- `~/.local/share/oracle-pr-sentry/review-prompt.md`
- `~/.config/systemd/user/oracle-pr-sentry.service`
- `~/.config/systemd/user/oracle-pr-sentry.timer`

It does not create credentials, configuration, state, or browser data.

Validate discovery before enabling automation:

```console
oracle-pr-sentry --dry-run
```

Dry-run mode performs live GitHub discovery and fingerprint decisions. It still
validates all required commands, but it does not invoke Oracle, post to GitHub,
or alter configured state, cache, runtime, or lock storage. Temporary discovery
files use an isolated workspace that is removed when the pass exits.

Enable the 15-minute timer:

```console
oracle-pr-sentry enable
systemctl --user list-timers oracle-pr-sentry.timer
```

## Configuration

The default configuration file is
`~/.config/oracle-pr-sentry/env`. The executable validates its owner and mode
before sourcing it as trusted Bash; the systemd unit does not load it into the
process environment. Keep it owned by the user and non-writable by group or
other users:

```console
chmod 600 ~/.config/oracle-pr-sentry/env
```

The sourced file takes precedence over exported environment values; the
`--dry-run` command-line option takes precedence over both.

| Variable | Default | Purpose |
| --- | --- | --- |
| `ORACLE_PR_SENTRY_GITHUB_OWNER` | authenticated `gh` login | Repository owner or organization filter |
| `ORACLE_PR_SENTRY_GITHUB_AUTHOR` | authenticated `gh` login | Pull request author filter |
| `ORACLE_PR_SENTRY_PR_SEARCH_LIMIT` | `50` | Maximum most-recently-updated ready and draft observations per search |
| `ORACLE_PR_SENTRY_ORACLE_BIN` | `oracle` | Oracle executable name or absolute path |
| `ORACLE_PR_SENTRY_ORACLE_MODEL` | `gpt-5.5-pro` | ChatGPT model requested from Oracle |
| `ORACLE_PR_SENTRY_ORACLE_THINKING_TIME` | `extended` | Oracle browser thinking level |
| `ORACLE_PR_SENTRY_ORACLE_MANUAL_LOGIN` | `1` | Reuse Oracle's persistent manual-login profile |
| `ORACLE_PR_SENTRY_ORACLE_ARGS_FILE` | unset | Optional file containing one literal Oracle argument per line |
| `ORACLE_PR_SENTRY_PROMPT_PATH` | installed prompt | Independently editable review instructions |
| `ORACLE_PR_SENTRY_MAX_REVIEW_RUNTIME` | `1800` | Oracle timeout in whole seconds |
| `ORACLE_PR_SENTRY_MAX_REVIEW_BODY_BYTES` | `60000` | Maximum generated review plus marker |
| `ORACLE_PR_SENTRY_STATE_FILE` | `$XDG_STATE_HOME/oracle-pr-sentry/state.json` | Persistent state document |
| `ORACLE_PR_SENTRY_RETENTION_DAYS` | `30` | Age before unseen/closed/ineligible entries are pruned |
| `ORACLE_PR_SENTRY_CACHE_DIR` | `$XDG_CACHE_HOME/oracle-pr-sentry` | Private cache directory |
| `ORACLE_PR_SENTRY_RUNTIME_DIR` | `$XDG_RUNTIME_DIR/oracle-pr-sentry-$UID` | Lock and secure temporary workspace |
| `ORACLE_PR_SENTRY_LOCK_FILE` | runtime directory `sentry.lock` | Global non-blocking lock |
| `ORACLE_PR_SENTRY_IDENTITY` | `oracle-pr-sentry` | Identity encoded in hidden review markers |
| `ORACLE_PR_SENTRY_DRY_RUN` | `0` | Environment equivalent of `--dry-run` |

The arguments file is not shell-parsed. Put each flag and value on separate
lines:

```text
--browser-auto-reattach-delay
30s
--browser-auto-reattach-interval
2m
```

The sentry rejects extra arguments that could replace its engine, prompt,
attachments (including Oracle's file-input aliases), output path,
background/wait behavior, or dry-run controls. The browser engine, single-tab
concurrency, attached bounded foreground execution, and write-output path
remain fixed by the executable.

If `ORACLE_PR_SENTRY_MAX_REVIEW_RUNTIME` is raised above 30 minutes, also raise
the service's `RuntimeMaxSec` and `TimeoutStartSec`, then reinstall the unit.
systemd ignores `RuntimeMaxSec` while a `Type=oneshot` service is activating,
so `TimeoutStartSec` supplies the effective 35-minute process bound; both are
declared to keep the intended runtime policy explicit.

## What causes a review

Ready, open pull requests in non-archived repositories are reviewed when:

- they are first observed;
- they transition from draft to ready;
- their head SHA changes;
- a check for the current head reaches a relevant failure conclusion;
- an external review, issue comment, or inline review comment changes.

Pending and successful checks do not trigger by themselves. Label, assignee,
milestone, and generic `updatedAt` changes are not part of the fingerprint.
Activities containing a valid sentry marker are ignored only when the
authenticated sentry account authored them, so another participant cannot
spoof a marker to suppress a review.

Oracle receives only the normalized pull request metadata, unified diff, and
the local review prompt. The MVP does not clone or inspect the full repository.
See [docs/architecture.md](docs/architecture.md) for the snapshot schema,
fingerprint, race handling, and state model.

## Timer and logs

Useful lifecycle commands:

```console
systemctl --user start oracle-pr-sentry.service
systemctl --user status oracle-pr-sentry.service
journalctl --user -u oracle-pr-sentry.service -n 100
journalctl --user -u oracle-pr-sentry.service -f
systemctl --user list-timers oracle-pr-sentry.timer

oracle-pr-sentry disable
oracle-pr-sentry enable
oracle-pr-sentry uninstall
```

`uninstall` removes only the four installed project files listed above. It
preserves configuration, state, cache, Oracle sessions, and browser profiles.

The executable uses a non-blocking global `flock`. If a timer activation
overlaps an existing pass, the new process logs that another invocation holds
the lock and exits successfully without opening another browser session.

### Unattended user services

To let the user's systemd manager continue after logout:

```console
loginctl enable-linger "$USER"
```

This may require administrator policy. Lingering keeps the user manager alive;
it does not create a graphical display or refresh an expired ChatGPT login.
Headful Chrome needs a reachable graphical session. Set `DISPLAY` and, where
needed, `XAUTHORITY` in the environment file using absolute values from that
session. Wayland environments may require their corresponding runtime
variables.

Do not expose a Chrome DevTools endpoint on a public interface. If attaching to
an already-running browser, bind remote debugging to loopback and protect the
local user session.

## Failure and recovery

The service exits non-zero when discovery, Oracle, publication, or state
persistence fails. systemd and journald retain that failure, and the next timer
activation retries because no successful fingerprint was advanced.

Common cases:

- **Missing command:** install the named dependency and rerun `--dry-run`.
- **GitHub authentication/permission error:** run `gh auth status`, refresh the
  credential, and verify repository access.
- **Oracle login or browser error:** stop the timer, rerun the initial browser
  login from a graphical session, confirm a small Oracle prompt succeeds, then
  re-enable the timer.
- **Oracle timeout:** inspect the journal and Oracle session state; increase
  the sentry timeout plus systemd `RuntimeMaxSec` and `TimeoutStartSec` only
  when longer runs are expected.
- **Malformed state:** the sentry fails closed and names the file. Preserve it
  for diagnosis, then replace it with `{"version":1,"prs":{}}` or remove it to
  start fresh. Existing GitHub markers still prevent duplicate publication.
- **Head changed during review:** the generated result is discarded without
  posting. The new head is reviewed on the next pass.
- **Review posted but state write failed:** the exact hidden marker is detected
  on the next pass and reconciled into local state without invoking Oracle or
  posting again.

## Security model

- The service runs only as the current unprivileged user and uses
  `NoNewPrivileges=true`.
- GitHub and ChatGPT credentials remain in `gh` and the local browser profile;
  they are never copied into project files or sentry state.
- Configuration is executable because it is sourced. The sentry rejects
  symlinks, unexpected owners, and group/world-writable trusted files or their
  immediate parent directories.
- State and runtime directories are user-owned mode `0700`; state and temporary
  files are mode `0600` under the process umask.
- State replacement uses a same-directory temporary file and atomic rename.
- GitHub publication is hard-coded to `gh pr review --comment`; Oracle output
  cannot choose approval or request-changes behavior.
- PR text and diffs are untrusted model input. The prompt limits the task to
  review output, and the executable does not interpret Oracle's Markdown as
  shell, configuration, or GitHub action instructions.
- Review size is checked before publication, and the PR's open/ready state and
  head SHA are re-read immediately before posting.

## Development

The test suite uses checked-in fixtures and command shims. It does not launch a
browser, authenticate to ChatGPT, or write to GitHub:

```console
make check
```

This runs ShellCheck, `shfmt -d`, and 30 Bats scenarios covering new and
unchanged PRs, head and CI changes, draft readiness, external activity, marker
filtering and recovery, canonical reordering, Oracle errors/timeouts/empty
output, stale heads, atomic-state failure, concurrency, malformed state,
discovery filters, and per-PR error isolation. CI requires no repository
secrets.

The GitHub Actions workflow has read-only repository contents permission.
