#!/usr/bin/env bash
# Where the verdict goes, per what the placement step carried.
#
# One verdict, in one place. The review that holds the inline comments carries it
# when that review landed; a comment of its own carries it when no review did.
# Both at once is the duplication PLT-1268 asked us to remove, and neither at all
# is a review nobody can read -- so every case here asserts the pair, not one of
# them.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKFLOW="${1:-$HERE/../../.github/workflows/seidroid-review.yml}"
STEP="Post the verdict"
SCRIPT="$(mktemp)"

# The marker the step opens the body with, read out of the workflow rather than
# restated here.
MARKER="$(python3 "$HERE/extract.py" "$WORKFLOW" "$STEP" "$SCRIPT" VERDICT_MARKER)" || {
  echo "could not extract '$STEP'"; exit 1; }

# The step's own literal env, read from the same file. Restating these here would
# let the harness and the step drift apart on a bound the step is written around.
step_env() {
  python3 - "$WORKFLOW" "$STEP" "$1" <<'PY'
import sys, yaml
d = yaml.safe_load(open(sys.argv[1], encoding="utf-8"))
for job in d["jobs"].values():
    for s in job.get("steps", []):
        if s.get("name") == sys.argv[2] or s.get("id") == sys.argv[2]:
            v = (s.get("env") or {}).get(sys.argv[3])
            if v is None:
                sys.exit("no such step env: " + sys.argv[3])
            print(v)
            sys.exit(0)
sys.exit("step not found")
PY
}
# Workflow-level, beside the other two markers, and read the same way. Two steps
# write this one -- the notice, and the verdict step that withdraws a stale one --
# so reading it from the step would let the harness pass while those two drift.
NO_VERDICT_MARKER="$(python3 "$HERE/extract.py" "$WORKFLOW" "$STEP" "$SCRIPT" NO_VERDICT_MARKER)" || {
  echo "could not read NO_VERDICT_MARKER out of $WORKFLOW"; exit 1; }
MAX_BODY_BYTES="$(step_env MAX_BODY_BYTES)" || exit 1
NOTICE_BYTES="$(step_env NOTICE_BYTES)" || exit 1

passed=0; failed=0
check() { # name expected actual
  if [ "$2" = "$3" ]; then passed=$((passed+1)); else
    failed=$((failed+1)); echo "  FAIL $1: want [$2] got [$3]"
  fi
}

# run_case <name> [KEY=VALUE ...]
run_case() {
  local name="$1"; shift
  # Named after the case, so a body kept from a failure says which run wrote it.
  CASE="$(mktemp -d)/$name"; mkdir -p "$CASE"
  export STUB_LOG="$CASE/log"; : > "$STUB_LOG"
  export STUB_PUT_BODY="$CASE/put-body.txt"; : > "$STUB_PUT_BODY"
  export STUB_POST_BODY="$CASE/post-body.txt"; : > "$STUB_POST_BODY"
  export STUB_PUT=ok STUB_POST=ok
  # The stale no-verdict notices this pull request carries. Cleared per case, so one
  # case's leftovers are not the next case's pull request.
  export STUB_NOTICES=

  printf '%s\n' "the verdict the driver rendered" > "$CASE/verdict.md"
  printf '{"conclusion":"failure","counts":{"blocking":2,"non_blocking":1,"pre_existing":0}}\n' \
    > "$CASE/check.json"
  : > "$CASE/note.md"

  export VERDICT="$CASE/verdict.md" CHECK="$CASE/check.json" NOTE="$CASE/note.md"
  export ON_LINE=3 ON_FILE=1 UNPLACED=0
  export SUMMARY_POSTED=true REVIEW_ID=9001
  export REPO=o/r PR=7 GH_TOKEN=stub REVIEWED_SHA=deadbeef AI_REVIEW_COPY=false
  export VERDICT_MARKER="$MARKER" NO_VERDICT_MARKER MAX_BODY_BYTES NOTICE_BYTES
  export GITHUB_SERVER_URL=https://github.com GITHUB_REPOSITORY=o/r GITHUB_RUN_ID=1
  export RUNNER_TEMP="$CASE/tmp"; mkdir -p "$RUNNER_TEMP"
  export GITHUB_OUTPUT="$CASE/output.txt"; : > "$GITHUB_OUTPUT"
  # Cleared before the overrides, so an observation one case names does not
  # follow the next one into its own body.
  export NOTE_TEXT=""
  for kv in "$@"; do export "${kv?}"; done
  # What placement could not put on a line, in the shape it writes it.
  if [ -n "$NOTE_TEXT" ]; then printf '%s\n' "$NOTE_TEXT" > "$NOTE"; fi

  PATH="$HERE/bin-verdict:$PATH" bash "$SCRIPT" > "$CASE/out" 2>&1
  echo "$?" > "$CASE/rc"
}

out()   { grep -E "^$1=" "$CASE/output.txt" | tail -1 | cut -d= -f2- ; }
calls() { grep -c "^$1" "$STUB_LOG" || true; }
said()  { grep -c "$1" "$CASE/out" || true; }

echo "the verdict rides in the review that carried the findings"
run_case carried
check "one append"                1 "$(calls 'PUT 9001')"
check "and no comment"            0 "$(calls 'POST comment')"
check "posted"                    true "$(out posted)"
check "the append opens with the marker" 1 "$(grep -c "^$MARKER" "$STUB_PUT_BODY")"
check "and carries the verdict"   1 "$(grep -c 'the verdict the driver rendered' "$STUB_PUT_BODY")"
check "and the findings line"     1 "$(grep -c '\*\*Findings:\*\* 2 blocking' "$STUB_PUT_BODY")"
check "and withdraws a stale notice" 1 "$(calls 'LIST comments')"

echo
echo "the observations that reached no line ride with it"
run_case carried-note \
  NOTE_TEXT='- `pkg/a.go:1` (note) — an observation off the changed lines'
check "one append"                  1 "$(calls 'PUT 9001')"
check "the note reached the review" 1 "$(grep -c 'an observation off the changed lines' "$STUB_PUT_BODY")"
check "and no comment carried it"   0 "$(calls 'POST comment')"

echo
echo "a review that could not be named"
run_case carried-unnamed REVIEW_ID=
check "no append"                 0 "$(calls 'PUT')"
check "and still no comment"      0 "$(calls 'POST comment')"
check "posted"                    true "$(out posted)"
check "and says what did not reach it" 1 "$(said 'could not be named')"

echo
echo "an append the API refused"
run_case carried-refused STUB_PUT=fail
check "one attempt"               1 "$(calls 'PUT 9001')"
check "and no comment"            0 "$(calls 'POST comment')"
check "posted"                    true "$(out posted)"
check "and says so"               1 "$(said 'could not append the findings line')"

echo
echo "no review carried it, so a comment does"
run_case fallback SUMMARY_POSTED=false REVIEW_ID=
check "no append"                 0 "$(calls 'PUT')"
check "one comment"               1 "$(calls 'POST comment')"
check "posted"                    true "$(out posted)"
check "it opens with the marker"  1 "$(grep -c "^$MARKER" "$STUB_POST_BODY")"
check "and carries the verdict"   1 "$(grep -c 'the verdict the driver rendered' "$STUB_POST_BODY")"

echo
echo "and when that comment is refused too"
run_case fallback-refused SUMMARY_POSTED=false REVIEW_ID= STUB_POST=fail
check "posted"                    false "$(out posted)"
check "the check run fails"       1 "$(calls 'CHECK review')"
check "and the verdict is in the log" 1 "$(said 'verdict, unposted')"

echo
echo
echo "every stale no-verdict notice is withdrawn, not the newest"
# The "exactly one notice" invariant holds only while no deletion has ever failed,
# and that path is tolerated -- so duplicates accumulate, and taking the newest per
# run leaves the older ones standing on a pull request whose review did complete.
run_case carried-notices STUB_NOTICES="101 102 103"
check "one read"                    1 "$(calls 'LIST comments')"
check "all three withdrawn"         3 "$(calls 'DELETE')"
check "the oldest among them"       1 "$(grep -c '^DELETE 101$' "$STUB_LOG")"
check "and the newest"              1 "$(grep -c '^DELETE 103$' "$STUB_LOG")"
run_case carried-no-notices
check "none to withdraw"            0 "$(calls 'DELETE')"

echo "assertions: $passed passed, $failed failed"
[ "$failed" -eq 0 ]
