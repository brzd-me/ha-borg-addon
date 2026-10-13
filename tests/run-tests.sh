#!/bin/sh
# Run the bats suite inside docker (Alpine/busybox, same userland as the add-on).
# Usage: tests/run-tests.sh [bats args...]   (default: all tests)
set -e
cd "$(dirname "$0")/.."
docker build -q -t ha-borg-tests tests >/dev/null
[ $# -eq 0 ] && set -- tests/
exec docker run --rm -v "$PWD:/code" -w /code ha-borg-tests "$@"
