#!/usr/bin/env bash
# Tests for gh-sweep repo discovery and worktree handling.
# Builds throwaway git fixtures under mktemp and sources gh-sweep for its
# functions (the script skips main() when sourced). No network, no gh calls.
set -euo pipefail

SCRIPT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/gh-sweep"

set --
# shellcheck source=../gh-sweep
source "$SCRIPT"

# hermetic git: no reliance on the host's identity or global config
export GIT_AUTHOR_NAME="gh-sweep-test" GIT_AUTHOR_EMAIL="test@localhost"
export GIT_COMMITTER_NAME="gh-sweep-test" GIT_COMMITTER_EMAIL="test@localhost"
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1

FIX="$(cd "$(mktemp -d)" && pwd -P)"
TREE="$FIX/tree"
trap 'rm -rf "$FIX"' EXIT
mkdir -p "$TREE"

fail=0

check_discover() {
  local desc="$1" depth="$2" dir="$3" expected="$4"
  local got
  got="$(cd "$dir" && DEPTH="$depth" discover_repos 2>/dev/null | sort)" || got="(error exit)"
  if [[ "$got" == "$expected" ]]; then
    echo "PASS: $desc"
  else
    echo "FAIL: $desc"
    echo "  expected: $(echo "$expected" | tr '\n' '|')"
    echo "  got:      $(echo "$got" | tr '\n' '|')"
    fail=1
  fi
}

# --- fixtures -----------------------------------------------------------
# regular1/                regular repo, with a submodule at regular1/sub
# container/{.bare,main,feature-x}     bare layout, protected worktree
# container2/{.bare,feature-y}         bare layout, no protected worktree
# container3/{.bare,main,trunk}        dir names disagree with branches:
#                                      main/ has feature-z, trunk/ has main
# nested/regular2/         regular repo one level deeper
# plainfolder/             nothing

git init -q -b main "$TREE/regular1"
git -C "$TREE/regular1" commit -q --allow-empty -m init

git init -q -b main "$FIX/subsrc"
git -C "$FIX/subsrc" commit -q --allow-empty -m init
git -C "$TREE/regular1" -c protocol.file.allow=always submodule add -q "$FIX/subsrc" sub

mkdir -p "$TREE/container" "$TREE/container2" "$TREE/container3" "$TREE/nested" "$TREE/plainfolder"

git clone -q --bare "$TREE/regular1" "$TREE/container/.bare"
git -C "$TREE/container/.bare" worktree add -q "$TREE/container/main" main
git -C "$TREE/container/.bare" worktree add -q "$TREE/container/feature-x" -b feature-x

git clone -q --bare "$TREE/regular1" "$TREE/container2/.bare"
git -C "$TREE/container2/.bare" worktree add -q "$TREE/container2/feature-y" -b feature-y

git clone -q --bare "$TREE/regular1" "$TREE/container3/.bare"
git -C "$TREE/container3/.bare" worktree add -q "$TREE/container3/main" -b feature-z
git -C "$TREE/container3/.bare" worktree add -q "$TREE/container3/trunk" main

git init -q -b main "$TREE/nested/regular2"
git -C "$TREE/nested/regular2" commit -q --allow-empty -m init

# --- discovery ----------------------------------------------------------

check_discover "depth 1 finds regular and bare-layout repos, excludes submodule and deeper repos" 1 "$TREE" \
"$TREE/container/main
$TREE/container2/feature-y
$TREE/container3/trunk
$TREE/regular1"

check_discover "depth 2 adds nested repo, worktrees still deduped" 2 "$TREE" \
"$TREE/container/main
$TREE/container2/feature-y
$TREE/container3/trunk
$TREE/nested/regular2
$TREE/regular1"

check_discover "dedupe prefers checked-out protected branch over directory name" 1 "$TREE" \
"$TREE/container/main
$TREE/container2/feature-y
$TREE/container3/trunk
$TREE/regular1"

check_discover "no repos in walk range errors" 1 "$TREE/plainfolder" "(error exit)"

check_discover "depth 0 inside a repo returns that repo" 0 "$TREE/regular1" "$TREE/regular1"

# --- sweep-root preservation --------------------------------------------
# The worktree a sweep operates from must never be removed, even when its
# branch is in the merged set.

out="$(
  cd "$TREE/container2/feature-y" || exit 1
  # shellcheck disable=SC2034  # read by the sourced sweep_local
  DRY_RUN=true
  sweep_local "$TREE/container2/feature-y" feature-y 2>&1
)" || out="(sweep_local failed: $out)"
if [[ "$out" == *"sweep root"* && "$out" != *"Would remove worktree: $TREE/container2/feature-y"* ]]; then
  echo "PASS: sweep root worktree is never removed"
else
  echo "FAIL: sweep root worktree is never removed"
  echo "  output: $out"
  fail=1
fi

exit "$fail"
