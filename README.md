# psentry

`psentry` is a small Linux command that searches GitHub pull requests and asks
[Oracle](https://github.com/steipete/oracle) to review meaningful updates
through a signed-in ChatGPT Web browser session. It posts only comment-only
GitHub reviews. Trusted, authenticated review markers are the authoritative
per-PR event history.

The native Linux implementation deliberately stays close to shell glue:

- one Bash entrypoint;
- `gh` for every GitHub read and write;
- `jq` and SHA-256 for normalized snapshots and fingerprints;
- `flock` for process-wide exclusion;
- deterministic, stateless candidate ordering.

There is no webhook server, database, queue, repository clone, or custom
GitHub client. The Apple Container environment described below adds the only
repository-managed polling loop while keeping `bin/psentry` one-pass.

## Requirements

- Linux with Bash, util-linux, and GNU coreutils
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

## Apple Container on macOS

The supported unattended environment uses Apple Container to provide Linux,
Chromium, XFCE, and noVNC on an Apple silicon Mac. Its lifecycle follows the
small wrapper pattern used by [dceoy/acld](https://github.com/dceoy/acld).

Requirements:

- Apple silicon Mac
- macOS 26 or later
- Apple `container` CLI
- `make` from the macOS command line developer tools

Build and start the desktop and polling workload:

```console
make up
```

Open the printed noVNC URL, normally
`http://127.0.0.1:6080/vnc.html`, and enter the printed VNC password. Then
persist GitHub and ChatGPT authentication in the container home volume:

```console
make gh-login
make oracle-login
```

`make oracle-login` opens Chromium on the noVNC desktop. Complete the ChatGPT
sign-in there. The image seeds `~/.config/psentry/env` from
`config/env.example` only the first time `HOME_VOLUME` is created; startup
preserves an existing file on every later rebuild (`cp -an`), so changing
`config/env.example` and rebuilding has no effect once the volume exists.
Edit the live configuration directly in the persistent volume instead:

```console
container exec --interactive --tty psentry \
  /usr/local/bin/psentry-entrypoint bash -c 'vim "$HOME/.config/psentry/env"'
```

Each pass re-reads this file, so the change applies on the next scheduled
pass (or immediately with `make run`).

The container starts one pass immediately, waits 15 minutes after it completes,
and repeats. A failed pass is logged and does not stop polling. Change the
fixed delay by recreating the container:

```console
make down
make up POLL_INTERVAL=1h
```

`POLL_INTERVAL` is passed directly to GNU `sleep`; values must be longer than
100ms. `15m` is the default and `1h` is the primary lower-frequency
alternative. Invalid values make the container fail during startup. Manual
checks remain available and keep the same global overlap protection as the
polling process:

```console
make dry-run
make run
```

Useful targets:

| Target              | Purpose                                                 |
| ------------------- | ------------------------------------------------------- |
| `make up`           | Build when needed and start polling                     |
| `make down`         | Stop the container while preserving its home volume     |
| `make status`       | Show the container state and noVNC URL                  |
| `make gh-login`     | Authenticate GitHub CLI                                 |
| `make oracle-login` | Authenticate ChatGPT Web through noVNC                  |
| `make run`          | Run one manual pass                                     |
| `make dry-run`      | Run one discovery-only pass                             |
| `make build`        | Rebuild the local `linux/arm64` image                   |
| `make clean`        | Remove the container, image, and persistent home volume |

The defaults can be overridden with Make variables such as `PORT`, `CPUS`,
`MEMORY`, `POLL_INTERVAL`, `VNC_GEOMETRY`, `VNC_PASSWORD`, and `HOME_VOLUME`.
The host-side noVNC publication binds to `127.0.0.1` by default. Websockify
still listens on the container network, where peer Apple containers can reach
it by container IP, so run the desktop only alongside trusted containers. A
non-loopback host publication requires an explicit `VNC_PASSWORD`; do not
expose the unencrypted noVNC connection on an untrusted network.

The named home volume contains the `gh` credential, ChatGPT browser session,
Oracle data, and sentry configuration. Treat it as sensitive. `make clean`
permanently deletes that volume. No host workspace is mounted into the
container, and automation runs as the unprivileged `agent` user.

## Initial browser login on native Linux

The sentry never runs Oracle against the user's default `~/.oracle`
configuration. It always points `ORACLE_HOME_DIR` at a dedicated, private
directory it owns, so an ambient `~/.oracle/config.json` cannot inject a
`promptSuffix`, `browser.remoteHost`, or other setting into a sentry run.
`ORACLE_HOME_DIR` does not, by itself, relocate Oracle's manual-login browser
profile: Oracle resolves that from `--browser-manual-login-profile-dir`, then
an inherited `ORACLE_BROWSER_PROFILE_DIR`, and otherwise falls back to
`~/.oracle/browser-profile`. Pin the profile directory explicitly with
`--browser-manual-login-profile-dir` (and clear any ambient
`ORACLE_BROWSER_PROFILE_DIR`) so login state cannot mix with the user's
ordinary Oracle/ChatGPT profile. Create the directory and log in through it
from the user's graphical session:

```console
install -d -m 700 ~/.local/share/psentry/oracle-home
env -u ORACLE_BROWSER_PROFILE_DIR \
  ORACLE_HOME_DIR=~/.local/share/psentry/oracle-home \
  oracle --engine browser \
  --browser-manual-login \
  --browser-manual-login-profile-dir \
    ~/.local/share/psentry/oracle-home/browser-profile \
  --browser-keep-browser \
  --browser-input-timeout 120000 \
  --prompt "Initialize the psentry browser profile"
```

Complete the ChatGPT sign-in in the opened window. This pins the dedicated
automation profile under
`~/.local/share/psentry/oracle-home/browser-profile`. The command must run as
this same Linux user. If `XDG_DATA_HOME` is set, use
`$XDG_DATA_HOME/psentry/oracle-home` instead, or set
`PSENTRY_ORACLE_HOME_DIR` to a custom location before the first run.

Browser automation depends on the ChatGPT Web UI and login state. UI changes,
anti-bot challenges, subscription/model availability, and session expiry can
interrupt it even when the sentry itself is healthy.

## Native Linux one-pass execution

Native Linux is supported as a manual or externally orchestrated one-pass
command. From a checkout:

```console
install -d -m 700 ~/.config/psentry
install -m 600 config/env.example ~/.config/psentry/env
${EDITOR:-vi} ~/.config/psentry/env
bin/psentry --dry-run
bin/psentry
```

Dry-run mode performs live GitHub discovery and fingerprint decisions. It still
validates all required commands, but it does not invoke Oracle, post to GitHub,
or alter configured cache, runtime, or lock storage. Temporary discovery
files use an isolated workspace that is removed when the pass exits.

The executable has no install, enable, disable, or uninstall lifecycle
commands. Use an external orchestrator if native repetition is required.

## Configuration

The default configuration file is
`~/.config/psentry/env`. The executable validates its owner and mode
before sourcing it as trusted Bash. Keep it owned by the user and non-writable by group or
other users:

```console
chmod 600 ~/.config/psentry/env
```

The sourced file takes precedence over exported environment values; the
`--dry-run` command-line option takes precedence over both.

| Variable                        | Default                              | Purpose                                                                                  |
| ------------------------------- | ------------------------------------ | ---------------------------------------------------------------------------------------- |
| `PSENTRY_GITHUB_OWNER`          | authenticated `gh` login             | Repository owner or organization filter                                                  |
| `PSENTRY_GITHUB_AUTHOR`         | authenticated `gh` login             | Pull request author filter                                                               |
| `PSENTRY_PR_SEARCH_LIMIT`       | `1000`                               | Maximum ready and draft observations per search (GitHub's own search API ceiling)         |
| `PSENTRY_ORACLE_BIN`            | `oracle`                             | Oracle executable name or absolute path                                                  |
| `PSENTRY_ORACLE_MODEL`          | `gpt-5.5-pro`                        | ChatGPT model requested from Oracle                                                      |
| `PSENTRY_ORACLE_THINKING_TIME`  | `extended`                           | Oracle browser thinking level                                                            |
| `PSENTRY_ORACLE_MANUAL_LOGIN`   | `1`                                  | Reuse Oracle's persistent manual-login profile                                           |
| `PSENTRY_ORACLE_HOME_DIR`       | `$XDG_DATA_HOME/psentry/oracle-home` | Private `ORACLE_HOME_DIR` isolating Oracle's config and browser profile from `~/.oracle` |
| `PSENTRY_REATTACH_DELAY`        | unset                                | Optional Oracle browser auto-reattach delay                                              |
| `PSENTRY_REATTACH_INTERVAL`     | unset                                | Optional Oracle browser auto-reattach polling interval                                   |
| `PSENTRY_REATTACH_TIMEOUT`      | unset                                | Optional Oracle browser auto-reattach timeout                                            |
| `PSENTRY_PROMPT_PATH`           | installed prompt                     | Independently editable review instructions                                               |
| `PSENTRY_MAX_REVIEW_RUNTIME`    | `1800`                               | Oracle timeout in whole seconds                                                          |
| `PSENTRY_MAX_REVIEW_BODY_BYTES` | `60000`                              | Maximum generated review plus marker                                                     |
| `PSENTRY_CACHE_DIR`             | `$XDG_CACHE_HOME/psentry`            | Private cache directory                                                                  |
| `PSENTRY_RUNTIME_DIR`           | `$XDG_RUNTIME_DIR/psentry-$UID`      | Lock and secure temporary workspace                                                      |
| `PSENTRY_LOCK_FILE`             | runtime directory `sentry.lock`      | Global non-blocking lock                                                                 |
| `PSENTRY_IDENTITY`              | `psentry`                            | Identity encoded in hidden review markers                                                |
| `PSENTRY_DRY_RUN`               | `0`                                  | Environment equivalent of `--dry-run`                                                    |

The optional reattach settings accept only positive integer durations with an
`ms`, `s`, `m`, or `h` suffix:

```bash
PSENTRY_REATTACH_DELAY=30s
PSENTRY_REATTACH_INTERVAL=2m
PSENTRY_REATTACH_TIMEOUT=2m
```

No generic Oracle argument passthrough is supported. The browser engine,
configured model, prompt, attachments, output path, fresh local tab,
single-tab concurrency, attached bounded foreground execution, route, and
timeout policy remain fixed by the executable.

## What causes a review

Ready, open pull requests in non-archived repositories are reviewed when:

- they are first observed;
- they transition from draft to ready;
- their head SHA changes;
- their title or body changes;
- their base ref or effective unified diff changes;
- a check for the current head reaches a relevant failure conclusion;
- an external review, issue comment, or inline review comment changes.

Pending and successful checks do not trigger by themselves. Label, assignee,
milestone, and generic `updatedAt` changes are not part of the fingerprint.
Activities containing a valid sentry marker are ignored only when the
authenticated sentry account authored them, so another participant cannot
spoof a marker to suppress a review.

Oracle receives only the normalized pull request metadata, unified diff, and
the local review prompt. Prior trusted sentry publications are excluded from
that metadata. The MVP does not clone or inspect the full repository. See
[docs/architecture.md](docs/architecture.md) for the snapshot schema,
fingerprint, race handling, and stateless scheduling model.

## Polling, ordering, and concurrency

The Apple Container entrypoint runs fixed-delay polling as its foreground
workload under `tini`. `SIGINT` and `SIGTERM` are forwarded to the active
`psentry` or `sleep` child so `make down` stops promptly. TigerVNC and noVNC
remain available in the background for login and recovery.

The executable uses a non-blocking global `flock`. If a manual pass
overlaps an existing pass, the new process logs that another invocation holds
the lock and exits successfully without opening another browser session.

Every pass processes the normalized candidate list in deterministic
most-recently-updated order. There is no local cursor. GitHub markers skip
unchanged PRs quickly, each Oracle review has a bounded runtime, and failures
continue to the remaining candidates, so an early failing or slow candidate
cannot indefinitely starve later candidates during an allowed-to-complete
pass. Container restarts recompute the same order from current GitHub data;
concurrent manual runs exit through `flock`; and long-running passes simply
delay the next fixed-delay interval without overlap.

### Upgrading from v5 markers

Version 6 deliberately has no v5 marker or local per-PR state compatibility
parser. Each open PR receives a one-time review or baseline event that
establishes v6 marker history. Legacy local state files are no longer read and
may be removed; malformed legacy files do not affect startup.

Do not expose a Chrome DevTools endpoint on a public interface. If attaching to
an already-running browser, bind remote debugging to loopback and protect the
local user session.

## Failure and recovery

The one-pass command exits non-zero when discovery, Oracle, or publication
fails. Container polling logs the failure, waits for the configured interval,
and retries because no successful GitHub marker was published.

Common cases:

- **Missing command:** install the named dependency and rerun `--dry-run`.
- **GitHub authentication/permission error:** run `gh auth status`, refresh the
  credential, and verify repository access.
- **Oracle login or browser error:** rerun `make oracle-login`, confirm a small
  Oracle prompt succeeds, and allow the next pass to retry.
- **Oracle timeout:** inspect container logs and the Oracle session; increase
  `PSENTRY_MAX_REVIEW_RUNTIME` only when longer runs are expected.
- **Head changed during review:** the generated result is discarded without
  posting. The new head is reviewed on the next pass.
- **Review posted but the process exits:** GitHub acceptance is the commit
  point. The exact hidden marker prevents another Oracle invocation or
  duplicate publication on the next pass.

## Security model

- The command and container automation run only as an unprivileged user.
- GitHub and ChatGPT credentials remain in `gh` and the local browser profile;
  they are never copied into project files.
- Configuration is executable because it is sourced. The sentry rejects
  symlinks, unexpected owners, and group/world-writable trusted files or their
  immediate parent directories.
- Runtime, cache, and Oracle directories are user-owned mode `0700`; temporary
  files are mode `0600` under the process umask.
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
.agents/skills/local-qa/scripts/qa.sh
```

This formats Markdown and shell scripts, runs ShellCheck, and runs Bats
scenarios covering the table-driven decision matrix, readiness, external
activity, marker filtering and recovery, canonical reordering, Oracle
errors/timeouts/empty output, stale inputs, stateless ordering, concurrency,
legacy-state tolerance, discovery filters, and per-PR error isolation. It also lints
and fixes the GitHub Actions workflows with zizmor, actionlint, yamllint, and
checkov. CI requires no repository secrets.

The GitHub Actions workflow has read-only repository contents permission.
