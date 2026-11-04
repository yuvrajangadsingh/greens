#!/bin/bash
# Test the shared Perl supervisor with real pipelines and descendant processes.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
source "$ROOT/lib/common.sh"
fail() { echo "FAIL: $*" >&2; exit 1; }
output_file="$(mktemp)"
trap 'rm -f "$output_file"' EXIT
TIMEOUT_CMD=(greens_perl_timeout 120)
start="$(date +%s)"
# Plain statements keep errexit enabled, unlike a surrounding if/|| check.
output="$(greens_run bash -c 'printf success')"
[[ "$output" == success ]] || fail "successful command substitution"
greens_run bash -c 'printf pipeline' | cat > "$output_file"
[[ "$(cat "$output_file")" == pipeline ]] || fail "successful pipeline"
[[ "$(( $(date +%s) - start ))" -lt 10 ]] || fail "supervisor retained stdout after success"
rc=0
greens_run bash -c 'exit 7' || rc=$?
[[ "$rc" == 7 ]] || fail "child exit code changed to $rc"
# Both the parent and its child ignore TERM: the grace-period KILL must reach
# the entire process group. A unique argv makes surviving descendants visible.
marker="greens-perl-timeout-$RANDOM-$$"
start="$(date +%s)"
rc=0
greens_perl_timeout 1 bash -c 'trap "" TERM; bash -c '\''trap "" TERM; exec -a "$1" sleep 600'\'' bash "$1" & wait' bash "$marker" || rc=$?
[[ "$rc" == 124 ]] || fail "timeout exit code $rc"
[[ "$(( $(date +%s) - start ))" -lt 20 ]] || fail "deadline exceeded"
if pgrep -f "$marker" >/dev/null 2>&1; then
  pkill -9 -f "$marker" 2>/dev/null || true
  fail "descendant survived timeout"
fi
echo "PASS: Perl timeout success under errexit, pipe closure, exit codes and process-group termination"
