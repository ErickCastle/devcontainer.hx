#!/bin/sh
# End-to-end tests against a real container runtime.
#
# Unlike tests/run.sh these need `devcontainer`, `docker` and network access to
# pull an image. Containers created here are removed afterwards.
set -e

cd "$(dirname "$0")/.."

for tool in steel devcontainer docker; do
	command -v "$tool" >/dev/null 2>&1 || {
		echo "e2e: '$tool' not found on PATH; skipping"
		exit 0
	}
done

docker info >/dev/null 2>&1 || {
	echo "e2e: no reachable container runtime; skipping"
	exit 0
}

cleanup() {
	echo
	echo "== cleaning up =="
	for fixture in e2e-dir e2e-file invalid; do
		path="$PWD/tests/fixtures/$fixture"
		ids=$(docker ps --all --quiet --filter "label=devcontainer.local_folder=$path" 2>/dev/null || true)
		[ -n "$ids" ] && docker rm --force $ids >/dev/null 2>&1 || true
	done
}
trap cleanup EXIT

echo "== end to end =="
steel tests/e2e-test.scm
