#!/usr/bin/env bash

set -euxo pipefail
cd "$(git rev-parse --show-toplevel)"

# Markdown
npx -y prettier --write './**/*.md'

# Shell scripts
shell_files=(
  bin/oracle-pr-sentry
  tests/shims/flock
  tests/shims/gh
  tests/shims/mv
  tests/shims/oracle
)
mapfile -d '' -t glob_shell_files < <(git ls-files -z -- '*.sh' '*.bash' '*.bats')
shell_files+=("${glob_shell_files[@]}")
shfmt --write --indent=2 --binary-next-line --case-indent --space-redirects "${shell_files[@]}"
shellcheck "${shell_files[@]}"
bats tests/sentry.bats

# GitHub Actions
zizmor --fix=safe .github/workflows
git ls-files -z -- '.github/workflows/*.yml' '.github/workflows/*.yaml' \
  | xargs -0 -t actionlint
git ls-files -z -- '.github/workflows/*.yml' '.github/workflows/*.yaml' \
  | xargs -0 -t yamllint -d '{"extends": "relaxed", "rules": {"line-length": "disable"}}'
checkov --framework=all --output=github_failed_only --directory=.
