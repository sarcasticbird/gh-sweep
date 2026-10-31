#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "${BASH_SOURCE[0]%/*}/.." && pwd)"
cd "$ROOT"
bash -n gh-sweep lib/sweep.sh tests/check.sh tests/test-gh-sweep.sh tests/test-safety.sh tests/test-branches.sh tests/mock-bin/gh tests/mock-bin/git
shellcheck -x gh-sweep lib/sweep.sh tests/check.sh tests/test-gh-sweep.sh tests/test-safety.sh tests/test-branches.sh tests/mock-bin/gh tests/mock-bin/git
bash tests/test-gh-sweep.sh
bash tests/test-safety.sh
bash tests/test-branches.sh
