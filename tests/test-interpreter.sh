#!/usr/bin/env bash
# No installed legacy interpreter is implied by the synthetic version-gate test.
# Shell snippets expand variables in the child interpreter, not the test driver.
# shellcheck disable=SC2016
set -euo pipefail
ROOT="$(cd "${BASH_SOURCE[0]%/*}/.." && pwd)"
LEGACY_BASH="${SWEEP_TEST_LEGACY_BASH:-}"
GH_CLI="${SWEEP_TEST_GH_CLI:-$(command -v gh)}"
MODERN_BASH="$BASH"
FIX="$(mktemp -d)"
trap 'rm -rf "$FIX"' EXIT
mkdir -p "$FIX/bin" "$FIX/home" "$FIX/data/gh/extensions/gh-sweep" "$FIX/legacy"
EXTENSION="$FIX/data/gh/extensions/gh-sweep/gh-sweep"
cp "$ROOT/gh-sweep" "$EXTENSION"
cp -R "$ROOT/lib" "${EXTENSION%/*}/lib"
ln -s "$MODERN_BASH" "$FIX/bin/bash"
ln -s "$(command -v dirname)" "$FIX/bin/dirname"
export HOME="$FIX/home" XDG_DATA_HOME="$FIX/data" GH_CONFIG_DIR="$FIX/home/gh"
unset GH_TOKEN GITHUB_TOKEN GH_HOST BASH_ENV ENV || true
OUT='' RC=0
check() {
  if ! "$@"; then printf 'FAIL: %s\n%s\n' "$*" "$OUT"; exit 1; fi
  printf 'PASS: %s\n' "$*"
}
eq() { [[ "$1" == "$2" ]]; }
contains() { [[ "$OUT" == *"$1"* ]]; }
absent() { [[ "$OUT" != *"$1"* ]]; }
run() { RC=0; OUT="$("$@" 2>&1)" || RC=$?; }

# Real gh dispatch, with private extension/config directories and no installation.
run env PATH="$FIX/bin" "$GH_CLI" sweep --version
check eq "$RC" 0
check contains 'gh-sweep v'
check test -f "${EXTENSION%/*}/lib/sweep.sh"
check test -f "${EXTENSION%/*}/lib/runs.jq"

# Force only the version predicate in a copy. With no utilities or libraries
# available, rejection must use builtins before even dirname can execute.
source_text="$(< "$ROOT/gh-sweep")"
gate='BASH_VERSINFO[0]'
[[ "$source_text" == *"$gate"* ]]
printf '%s\n' "${source_text/"$gate"/3}" > "$FIX/legacy/gh-sweep"
for mode in execute source; do
  if [[ "$mode" == execute ]]; then
    run env PATH="$FIX/legacy" "$MODERN_BASH" "$FIX/legacy/gh-sweep" branches --auto
  else
    run env PATH="$FIX/legacy" "$MODERN_BASH" -c 'source "$1"; exit "$?"' _ "$FIX/legacy/gh-sweep"
  fi
  check eq "$RC" 1
  check contains 'gh-sweep requires Bash 4+'
  check contains 'macOS /bin/bash is 3.2'
  check contains 'gh sweep branches --dry-run'
  check absent 'command not found'
  check absent 'bad substitution'
done

# QA can supply an already-installed Bash 3.2. Never download or install one.
if [[ -n "$LEGACY_BASH" ]]; then
  run "$LEGACY_BASH" -c 'printf "%s.%s" "${BASH_VERSINFO[0]}" "${BASH_VERSINFO[1]}"'
  check eq "$RC" 0
  check eq "$OUT" 3.2
  # Reproduce the unchanged library expression with only a fake origin read.
  run "$LEGACY_BASH" -c 'source "$1"; SELECTED_USER=""; git() { printf "%s\n" https://github.com/Example/Widgets.git; }; branch_plan example/widgets /unused' _ "$ROOT/lib/sweep.sh"
  check test "$RC" -ne 0
  check contains 'bad substitution'
  ln -s "$LEGACY_BASH" "$FIX/legacy/bash"
  run env PATH="$FIX/legacy" "$GH_CLI" sweep branches --auto
  check eq "$RC" 1
  check contains 'gh-sweep requires Bash 4+'
  check absent 'command not found'
  check absent 'bad substitution'
else
  printf 'SKIP: actual Bash 3.2 execution unavailable; set SWEEP_TEST_LEGACY_BASH to an installed interpreter\n'
fi
