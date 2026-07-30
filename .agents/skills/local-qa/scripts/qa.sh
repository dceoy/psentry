#!/usr/bin/env bash

set -euxo pipefail
cd "$(git rev-parse --show-toplevel)"

# The project targets Linux and uses GNU coreutils semantics. Homebrew installs
# those utilities outside the default PATH on macOS.
if [[ "$(uname -s)" == 'Darwin' ]] && command -v brew > /dev/null 2>&1; then
  coreutils_gnubin="$(brew --prefix coreutils 2> /dev/null)/libexec/gnubin"
  if [[ -d "${coreutils_gnubin}" ]]; then
    export PATH="${coreutils_gnubin}:${PATH}"
  fi
fi

COOLDOWN_DAYS=7
export UV_EXCLUDE_NEWER="${COOLDOWN_DAYS} days"
export NPM_CONFIG_MIN_RELEASE_AGE="${COOLDOWN_DAYS}"
export PNPM_CONFIG_MINIMUM_RELEASE_AGE=$((COOLDOWN_DAYS * 24 * 60))

# Markdown
npx -y prettier --write './**/*.md'

# Shell scripts
git ls-files -z -- '*.sh' '*.bash' '*.bats' \
  | xargs -0 -t shfmt --write --indent=2 --binary-next-line --case-indent --space-redirects
git ls-files -z -- '*.sh' '*.bash' '*.bats' \
  | xargs -0 -t shellcheck
bats tests/sentry.bats

# GitHub Actions
zizmor --fix=safe .github/workflows
git ls-files -z -- '.github/workflows/*.yml' '.github/workflows/*.yaml' \
  | xargs -0 -t actionlint
git ls-files -z -- '.github/workflows/*.yml' '.github/workflows/*.yaml' \
  | xargs -0 -t yamllint -d '{"extends": "relaxed", "rules": {"line-length": "disable"}}'
checkov --framework=all --output=github_failed_only --directory=.

# CI-only: locally this would fail on the developer's own unstaged edits.
if [ "${CI:-}" = "true" ] && ! git diff --exit-code; then
  echo 'error: formatting/auto-fix left tracked files modified; commit the changes shown above' >&2
  exit 1
fi
