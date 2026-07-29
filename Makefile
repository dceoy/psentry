.PHONY: check format shellcheck test

check: shellcheck format test

shellcheck:
	shellcheck -x bin/oracle-pr-sentry tests/shims/gh tests/shims/oracle tests/shims/flock tests/shims/mv

format:
	shfmt -d -i 2 -ci bin/oracle-pr-sentry tests/test_helper.bash tests/shims/gh tests/shims/oracle tests/shims/flock tests/shims/mv
	shfmt -d -ln bats -i 2 -ci tests/sentry.bats

test:
	bats tests/sentry.bats
