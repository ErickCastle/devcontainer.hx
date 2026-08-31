#!/bin/sh
# Runs the plugin's test suite. Requires `steel` on PATH; does not require Docker
# or the real Dev Container CLI.
set -e

cd "$(dirname "$0")/.."
ROOT="$PWD"
FAILED=0

run() {
	echo
	echo "== $1 =="
	shift
	if ! "$@"; then FAILED=1; fi
}

# An empty PATH guarantees the dev container CLI cannot be found. `steel` is
# invoked by absolute path so it still runs.
STEEL="$(command -v steel)"
EMPTY_DIR="$ROOT/tests/tmp/empty-path"
mkdir -p "$EMPTY_DIR"

run "config discovery" steel tests/config-test.scm
run "process layer" steel tests/proc-test.scm
run "session state" steel tests/state-test.scm
run "lsp configuration" steel tests/lsp-test.scm
run "cli adapter (fake CLI on PATH)" env PATH="$ROOT/tests/fake-bin:$PATH" steel tests/cli-test.scm
run "cli adapter (CLI absent)" env PATH="$EMPTY_DIR" "$STEEL" tests/cli-missing-test.scm

echo
if [ "$FAILED" -eq 0 ]; then
	echo "all suites completed"
else
	echo "some suites reported failures"
	exit 1
fi
