#!/usr/bin/env bash
# Which review event the position step records, per decision the driver wrote.
#
# This is the harness for the defect that produced it. The step used to re-derive
# an event from `conclusion`, so a run whose driver recorded `approve` beside a
# neutral check posted a comment ending "Approving" and NO REVIEW AT ALL -- on
# three pull requests, with nothing on any of them saying why. Two computations of
# one question disagree eventually; the driver now records the position and this
# step submits it.
#
# So every case here asserts the event posted, not the conclusion. A case that
# checked the conclusion would pass against the code that had the bug.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKFLOW="${1:-$HERE/../../.github/workflows/seidroid-review.yml}"
STEP="State the review's position on the pull request"
SCRIPT="$(mktemp)"

# extract.py prints a workflow-level env key and writes the step's run block. The
# marker is what the step stamps on the review body, and the withdrawal recognises
# its own earlier reviews by it, so the harness reads it from the file rather than
# restating it.
MARKER="$(python3 "$HERE/extract.py" "$WORKFLOW" "$STEP" "$SCRIPT" VERDICT_MARKER)" || {
  echo "could not extract '$STEP'"; exit 1; }

passed=0; failed=0

# run_case <name> <decision> <conclusion> <approve-on-success> <event> <withdrawal: yes|no>
#
# The withdrawal column is not decoration. It is the only thing in this job that
# clears a merge gate, and splitting the decision from the conclusion gave it two new
# ways to fire when it must not.
run_case() {
  local name="$1" decision="$2" conclusion="$3" approve="$4" want="$5" want_wd="${6:-no}"
  local dir; dir="$(mktemp -d)"
  local check="$dir/check.json" log="$dir/log"
  : > "$log"

  # A decision of the empty string writes no field at all, which is what a
  # no-verdict run and a pre-v0.20.0 driver both leave behind.
  if [ -n "$decision" ]; then
    printf '{"decision":"%s","conclusion":"%s","counts":{"blocking":0,"non_blocking":1,"pre_existing":0}}\n' \
      "$decision" "$conclusion" > "$check"
  else
    printf '{"conclusion":"%s","counts":{"blocking":0,"non_blocking":1,"pre_existing":0}}\n' \
      "$conclusion" > "$check"
  fi

  # A block this tool left earlier, standing on the pull request. Every case runs
  # against one, so "did not withdraw" is a decision the step made rather than a list
  # that happened to be empty.
  STUB_LOG="$log" STUB_STANDING=11 PATH="$HERE/bin-decision:$PATH" \
  GH_TOKEN=stub REPO=o/r PR=7 REVIEWED_SHA=deadbeef \
  CHECK="$check" APPROVE_ON_SUCCESS="$approve" VERDICT_MARKER="$MARKER" \
    bash "$SCRIPT" > "$dir/out" 2>&1

  local got wd
  got="$(grep '^POST ' "$log" | head -1 | cut -d' ' -f2 || true)"
  if grep -q '^dismissed' "$log"; then wd=yes; else wd=no; fi

  if [ "$got" = "$want" ] && [ "$wd" = "$want_wd" ]; then
    passed=$((passed+1))
    printf '  ok    %-35s event %-16s withdrew %s\n' "$name" "${got:-<none>}" "$wd"
  else
    failed=$((failed+1))
    printf '  FAIL  %-35s event %s (want %s), withdrew %s (want %s)\n' \
      "$name" "${got:-<none>}" "${want:-<none>}" "$wd" "$want_wd"
    sed 's/^/          /' "$dir/out"
  fi
  rm -rf "$dir"
}

echo "the recorded decision is the event"
run_case "approve, approval on"         approve         success true  APPROVE         yes
run_case "request_changes"              request_changes failure true  REQUEST_CHANGES no
run_case "withheld, unaccepted blocker" comment         neutral true  COMMENT         yes

echo
echo "what the step still decides, and what it no longer does"
# approve-on-success is the one call left to the caller. Everything else is the
# driver's, including the refusal to act on a decision this step cannot read.
run_case "approve, approval off"        approve         success false ""              yes
# `comment` beside `success` is the agent's own word with nothing withholding. The
# driver publishes no notice there, so a COMMENT review would name a finding that
# does not exist -- beside a thumbs-up the reaction step leaves off the same success.
run_case "comment beside success"       comment         success true  ""              yes

echo
echo "a block this run must not clear"
# Its own, seconds old. Deriving the event from the conclusion made "posted
# REQUEST_CHANGES" and "concluded failure" one fact; reading the decision from the
# driver split them, and nothing replaced the invariant until it was named.
run_case "request_changes, odd success" request_changes success true  REQUEST_CHANGES no
# An unreadable conclusion is not a clean review. Falling through the withdrawal on
# one dismisses a standing block on the strength of a file this step could not read.
run_case "no conclusion field"          approve         ""      true  APPROVE         no

echo
echo "half a check file costs half the step, not all of it"
# A missing decision costs the POSITION. Taking the withdrawal with it would strand a
# block on a finding this run did not reproduce, which only a human can then clear.
run_case "no decision field"            ""              success true  ""              yes
run_case "unrecognised decision"        banana          success true  ""              yes

echo "assertions: $passed passed, $failed failed"
rm -f "$SCRIPT"
[ "$failed" -eq 0 ]
