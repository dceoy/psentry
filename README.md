# oracle-pr-sentry

`oracle-pr-sentry` is a small Linux service that polls GitHub for pull requests
and asks [Oracle](https://github.com/steipete/oracle) to review meaningful
updates through a signed-in ChatGPT Web browser session. It posts only
comment-only GitHub reviews. Trusted, authenticated review markers are the
authoritative per-PR event history.

The native Linux implementation deliberately stays close to shell glue:

- one Bash entrypoint;
- `gh` for every GitHub read and write;
- `jq` and SHA-256 for normalized snapshots and fingerprints;
- one atomic local JSON file containing only the candidate-rotation cursor;
- `flock` for process-wide exclusion;
- a `systemd --user` oneshot service and timer;
- journald for operational logs.

There is no webhook server, database, queue, repository clone, or custom
GitHub client. The optional Apple Container environment described below
packages the same one-pass executable without changing that runtime model.

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

## Apple Container on macOS

An optional Apple Container environment provides Linux, Chromium, XFCE, and
noVNC on an Apple silicon Mac. Its lifecycle follows the small wrapper pattern
used by [dceoy/acld](https://github.com/dceoy/acld).

Requirements:

- Apple silicon Mac
- macOS 26 or later
- Apple `container` CLI
- `make` from the macOS command line developer tools

Build and start the desktop:

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
sign-in there. The image seeds
`~/.config/oracle-pr-sentry/env` from `config/env.example`; edit it from
`make shell` before the first sentry pass when different GitHub filters or
Oracle settings are needed.

Validate discovery, then run one pass:

```console
make dry-run
make run
```

The container stays up to preserve its graphical browser session, but the
sentry still runs exactly one pass per `make run`; it does not add a daemon
loop or emulate the systemd timer. Schedule the host-side command separately
if unattended repetition is needed.

Useful targets:

| Target              | Purpose                                                 |
| ------------------- | ------------------------------------------------------- |
| `make status`       | Show the container state and noVNC URL                  |
| `make shell`        | Open a shell as the unprivileged `agent` user           |
| `make down`         | Stop the container while preserving its home volume     |
| `make build`        | Rebuild the local `linux/arm64` image                   |
| `make pull IMAGE=…` | Pull an explicitly selected `linux/arm64` image         |
| `make clean`        | Remove the container, image, and persistent home volume |

The defaults can be overridden with Make variables such as `PORT`, `CPUS`,
`MEMORY`, `VNC_GEOMETRY`, `VNC_PASSWORD`, `HOME_VOLUME`, and `WORKSPACE_DIR`.
The host-side noVNC publication binds to `127.0.0.1` by default. Websockify
still listens on the container network, where peer Apple containers can reach
it by container IP, so run the desktop only alongside trusted containers. A
non-loopback host publication requires an explicit `VNC_PASSWORD`; do not
expose the unencrypted noVNC connection on an untrusted network.

The named home volume contains the `gh` credential, ChatGPT browser session,
Oracle data, sentry configuration, and sentry state. Treat it as sensitive.
`make clean` permanently deletes that volume. The workspace bind mount is
read-write; set `WORKSPACE_DIR` only to a directory the container may modify.

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
install -d -m 700 ~/.local/share/oracle-pr-sentry/oracle-home
env -u ORACLE_BROWSER_PROFILE_DIR \
  ORACLE_HOME_DIR=~/.local/share/oracle-pr-sentry/oracle-home \
  oracle --engine browser \
  --browser-manual-login \
  --browser-manual-login-profile-dir \
    ~/.local/share/oracle-pr-sentry/oracle-home/browser-profile \
  --browser-keep-browser \
  --browser-input-timeout 120000 \
  --prompt "Initialize the oracle-pr-sentry browser profile"
```

Complete the ChatGPT sign-in in the opened window. This pins the dedicated
automation profile under
`~/.local/share/oracle-pr-sentry/oracle-home/browser-profile`. The timer must
run as this same Linux user. If `XDG_DATA_HOME` is set, use
`$XDG_DATA_HOME/oracle-pr-sentry/oracle-home` instead, or set
`ORACLE_PR_SENTRY_ORACLE_HOME_DIR` to a custom location before the first run.

Browser automation depends on the ChatGPT Web UI and login state. UI changes,
anti-bot challenges, subscription/model availability, and session expiry can
interrupt it even when the sentry itself is healthy.

## Native Linux install

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
- `~/.local/share/oracle-pr-sentry/decision-reducer.jq`
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

| Variable                                 | Default                                       | Purpose                                                                                  |
| ---------------------------------------- | --------------------------------------------- | ---------------------------------------------------------------------------------------- |
| `ORACLE_PR_SENTRY_GITHUB_OWNER`          | authenticated `gh` login                      | Repository owner or organization filter                                                  |
| `ORACLE_PR_SENTRY_GITHUB_AUTHOR`         | authenticated `gh` login                      | Pull request author filter                                                               |
| `ORACLE_PR_SENTRY_PR_SEARCH_LIMIT`       | `50`                                          | Maximum most-recently-updated ready and draft observations per search                    |
| `ORACLE_PR_SENTRY_ORACLE_BIN`            | `oracle`                                      | Oracle executable name or absolute path                                                  |
| `ORACLE_PR_SENTRY_ORACLE_MODEL`          | `gpt-5.5-pro`                                 | ChatGPT model requested from Oracle                                                      |
| `ORACLE_PR_SENTRY_ORACLE_THINKING_TIME`  | `extended`                                    | Oracle browser thinking level                                                            |
| `ORACLE_PR_SENTRY_ORACLE_MANUAL_LOGIN`   | `1`                                           | Reuse Oracle's persistent manual-login profile                                           |
| `ORACLE_PR_SENTRY_ORACLE_HOME_DIR`       | `$XDG_DATA_HOME/oracle-pr-sentry/oracle-home` | Private `ORACLE_HOME_DIR` isolating Oracle's config and browser profile from `~/.oracle` |
| `ORACLE_PR_SENTRY_REATTACH_DELAY`        | unset                                         | Optional Oracle browser auto-reattach delay                                              |
| `ORACLE_PR_SENTRY_REATTACH_INTERVAL`     | unset                                         | Optional Oracle browser auto-reattach polling interval                                   |
| `ORACLE_PR_SENTRY_REATTACH_TIMEOUT`      | unset                                         | Optional Oracle browser auto-reattach timeout                                            |
| `ORACLE_PR_SENTRY_PROMPT_PATH`           | installed prompt                              | Independently editable review instructions                                               |
| `ORACLE_PR_SENTRY_MAX_REVIEW_RUNTIME`    | `1800`                                        | Oracle timeout in whole seconds                                                          |
| `ORACLE_PR_SENTRY_MAX_REVIEW_BODY_BYTES` | `60000`                                       | Maximum generated review plus marker                                                     |
| `ORACLE_PR_SENTRY_STATE_FILE`            | `$XDG_STATE_HOME/oracle-pr-sentry/state.json` | Persistent candidate-rotation cursor only                                                |
| `ORACLE_PR_SENTRY_CACHE_DIR`             | `$XDG_CACHE_HOME/oracle-pr-sentry`            | Private cache directory                                                                  |
| `ORACLE_PR_SENTRY_RUNTIME_DIR`           | `$XDG_RUNTIME_DIR/oracle-pr-sentry-$UID`      | Lock and secure temporary workspace                                                      |
| `ORACLE_PR_SENTRY_LOCK_FILE`             | runtime directory `sentry.lock`               | Global non-blocking lock                                                                 |
| `ORACLE_PR_SENTRY_IDENTITY`              | `oracle-pr-sentry`                            | Identity encoded in hidden review markers                                                |
| `ORACLE_PR_SENTRY_DRY_RUN`               | `0`                                           | Environment equivalent of `--dry-run`                                                    |

The optional reattach settings accept only positive integer durations with an
`ms`, `s`, `m`, or `h` suffix:

```bash
ORACLE_PR_SENTRY_REATTACH_DELAY=30s
ORACLE_PR_SENTRY_REATTACH_INTERVAL=2m
ORACLE_PR_SENTRY_REATTACH_TIMEOUT=2m
```

No generic Oracle argument passthrough is supported. The browser engine,
configured model, prompt, attachments, output path, fresh local tab,
single-tab concurrency, attached bounded foreground execution, route, and
timeout policy remain fixed by the executable.

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

`uninstall` removes only the five installed project files listed above. It
preserves configuration, state, cache, Oracle sessions, and browser profiles.

The executable uses a non-blocking global `flock`. If a timer activation
overlaps an existing pass, the new process logs that another invocation holds
the lock and exits successfully without opening another browser session.
Before each candidate attempt, the sentry checkpoints the only local persistent
value: a rotation cursor. If a slow Oracle run consumes the remaining service
budget, the next activation starts after that candidate, while completed
passes naturally return to most-recently-updated order.

### Upgrading from v5 markers

Version 6 deliberately has no v5 marker or local per-PR state compatibility
parser. Stop the timer and remove the old state file (or replace it with
`{"version":1}`) before the first v6 pass. Each open PR then receives a
one-time review or baseline event that establishes the v6 marker history.
After that rebaseline, deleting the local state file does not lose per-PR
transition history.

### Unattended user services

To let the user's systemd manager continue after logout:

```console
loginctl enable-linger "$USER"
```

This may require administrator policy. Lingering keeps the user manager alive;
it does not create a graphical display or refresh an expired ChatGPT login.
Headful Chrome needs a reachable graphical session. Set `DISPLAY` and, where
needed, `XAUTHORITY` in the environment file using absolute values from that
session. The user service keeps its private temporary directory while binding
the host's `/tmp/.X11-unix` socket directory read-only for X11 and Xwayland.
Wayland environments may require their corresponding runtime variables.

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
  for diagnosis, then replace it with `{"version":1}` or remove it to start
  with an empty rotation cursor. Existing v6 GitHub markers preserve per-PR
  transition history.
- **Head changed during review:** the generated result is discarded without
  posting. The new head is reviewed on the next pass.
- **Review posted but the process exits:** GitHub acceptance is the commit
  point. The exact hidden marker prevents another Oracle invocation or
  duplicate publication on the next pass.

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
.agents/skills/local-qa/scripts/qa.sh
```

This formats Markdown and shell scripts, runs ShellCheck, and runs Bats
scenarios covering the table-driven decision matrix, readiness, external
activity, marker filtering and recovery, canonical reordering, Oracle
errors/timeouts/empty output, stale inputs, cursor persistence, concurrency,
malformed state, discovery filters, and per-PR error isolation. It also lints
and fixes the GitHub Actions workflows with zizmor, actionlint, yamllint, and
checkov. CI requires no repository secrets.

The GitHub Actions workflow has read-only repository contents permission.
