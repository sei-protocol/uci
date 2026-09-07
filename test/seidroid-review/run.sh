#!/usr/bin/env bash
# Runs the shipped step script under bash with a gh stub on PATH.
#
# The step and the marker it writes are both read out of the workflow on every
# run, so a run tests what the file says now and cannot pass against a stale copy.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
REPOROOT="$(cd "$HERE/../.." && pwd)"
WORKFLOW="$REPOROOT/.github/workflows/seidroid-review.yml"
STEP="Place findings on the code"
SCRIPT="$HERE/place.sh"
MARKER="$(python3 "$HERE/extract.py" "$WORKFLOW" "$STEP" "$SCRIPT")" || {
  echo "could not read '$STEP' out of $WORKFLOW"; exit 1; }
pass=0 fail=0
rows=()

# A file list at the endpoint's cap, generated rather than committed. compare sends
# 300 files however large the diff is, so 300 is the length that tests the cap; the
# findings and the accepted line go with it so the case stays one thing to read.
GEN="$HERE/fx/gen"
rm -rf "$GEN"; mkdir -p "$GEN"
jq -nc '{files: [ range(300) | {filename: "pkg/gen\(.).go",
                                patch: "@@ -1,2 +1,3 @@\n one\n+two\n three"} ]}' \
  > "$GEN/files-at-cap.json"
jq -nc '[{file: "pkg/gen7.go", line: 2, side: "RIGHT", severity: "blocker",
          detail: "A finding in a diff as long as the endpoint will send."}]' \
  > "$GEN/findings-at-cap.json"
printf 'pkg/gen7.go\tRIGHT\t2\n' > "$GEN/line-ok-gen.tsv"

# Every shape of thread id one comment can name, generated because one of them is
# 201 characters and a fixture carrying it does not read. The step admits the shape
# GitHub mints and drops the rest, which is what keeps the record one id per line.
jq -nc --arg long "$(printf 'A%.0s' {1..201})" \
  '[{file: "pkg/a.go", line: 11, side: "RIGHT", severity: "blocker",
     detail: "Several shapes of id on one comment.",
     supersedes: ["PRRT_kwDOABCDEF4Ax1y2", "PRRT_has a space",
                  "carries\na line break", 42, $long,
                  "PRRT_kwDOABCDEF4Bz3w4"]}]' > "$GEN/findings-odd-ids.json"

run_case() {
  # $1 name, then KEY=VALUE overrides
  local name="$1"; shift
  CASE="$HERE/out/$name"
  rm -rf "$CASE"; mkdir -p "$CASE"
  export STUB_LOG="$CASE/calls.log"; : > "$STUB_LOG"
  export STUB_REQUEST="$CASE/request.json"; : > "$STUB_REQUEST"
  export STUB_BODIES="$CASE/bodies.txt"; : > "$STUB_BODIES"
  export STUB_FILES="$HERE/fx/files.json"
  export STUB_FILES_STALE="$HERE/fx/files-stale.json"
  # What the pull request says its diff holds. fx/files.json serves exactly this
  # many, so the step reads that list as whole; a case that serves a different
  # number sets this to match, or to the number that exposes the shortfall.
  export STUB_CHANGED_FILES=4
  export STUB_PR=7
  export STUB_BASE=0ba5e0ba5e0ba5e0ba5e0ba5e0ba5e0ba5e0ba5e0
  export STUB_STALE_SHA=facefeed1234facefeed1234facefeed1234face
  export STUB_REVIEW=ok
  export STUB_LINE_OK="$HERE/fx/line-ok.tsv"
  export STUB_FILE_OK="$HERE/fx/file-ok.txt"
  export FINDINGS="$HERE/fx/all-placeable.json"
  export REVIEWED_SHA=deadbeefcafedeadbeefcafedeadbeefcafedead
  for kv in "$@"; do export "${kv?}"; done

  export PATH="$HERE/bin:$PATH"
  export RUNNER_TEMP="$CASE/tmp"; mkdir -p "$RUNNER_TEMP"
  export GITHUB_OUTPUT="$CASE/output.txt"; : > "$GITHUB_OUTPUT"
  export NOTE="$CASE/note.md"
  export LINKAGE="$CASE/superseded-placed.txt"
  export REPO=owner/repo PR=7 GH_TOKEN=x
  export FINDING_MARKER="$MARKER"
  bash "$SCRIPT" > "$CASE/stdout.txt" 2> "$CASE/stderr.txt"
  echo "$?" > "$CASE/rc"
}

# Runs the step again over the case directory and the RUNNER_TEMP the last run
# left, which is what a second attempt of a job on a non-ephemeral self-hosted
# runner sees. Only the overrides given here change.
rerun_case() { # KEY=VALUE overrides
  for kv in "$@"; do export "${kv?}"; done
  : > "$STUB_LOG"; : > "$GITHUB_OUTPUT"; : > "$STUB_BODIES"
  bash "$SCRIPT" > "$CASE/stdout.txt" 2> "$CASE/stderr.txt"
  echo "$?" > "$CASE/rc"
}

out() { grep -E "^$1=" "$CASE/output.txt" | tail -1 | cut -d= -f2- ; }
calls() { grep -c "^CALL $1" "$CASE/calls.log" || true; }
# The thread ids the step recorded, sorted and space-joined, so a case names the set
# it expects on one line. Empty when no comment carrying a linkage posted.
linked() { sort -u "$CASE/superseded-placed.txt" 2>/dev/null | sed '/^$/d' | tr '\n' ' ' \
             | sed 's/ $//'; }

check() { # name expected actual
  if [ "$2" = "$3" ]; then pass=$((pass+1)); else fail=$((fail+1)); echo "  FAIL $1: want [$2] got [$3]"; fi
}

report() { # label
  rows+=("$(printf '%-34s rc=%s  pull=%s cmp=%s reviews=%s line=%s file=%s  on_line=%s on_file=%s unplaced=%s  note=%s' \
    "$1" "$(cat "$CASE/rc")" "$(calls pull)" "$(calls compare)" "$(calls reviews)" "$(calls line-comment)" "$(calls file-comment)" \
    "$(out on_line)" "$(out on_file)" "$(out unplaced)" "$(grep -c '^- `' "$CASE/note.md" 2>/dev/null; true)")")
}

echo "== 1. several findings, all placeable =="
run_case all-placeable
report "1 all placeable"
check "one review call"      1 "$(calls reviews)"
check "no comment calls"     0 "$(( $(calls line-comment) + $(calls file-comment) ))"
check "on_line"              4 "$(out on_line)"
check "on_file"              0 "$(out on_file)"
check "unplaced"             0 "$(out unplaced)"
check "comments in request"  4 "$(jq '.comments | length' "$CASE/request.json")"
check "every body marked"    4 "$(jq --arg m "$FINDING_MARKER" '[.comments[] | select(.body | startswith($m + "\n"))] | length' "$CASE/request.json")"
check "event"                COMMENT "$(jq -r .event "$CASE/request.json")"
check "commit_id"            deadbeefcafedeadbeefcafedeadbeefcafedead "$(jq -r .commit_id "$CASE/request.json")"
check "body non-empty"       true "$(jq -r '(.body | length) > 0' "$CASE/request.json")"
check "paths/lines/sides"    'pkg/a.go:11:RIGHT pkg/a.go:12:RIGHT pkg/b.go:2:RIGHT pkg/a.go:11:LEFT' \
                             "$(jq -r '[.comments[] | "\(.path):\(.line):\(.side)"] | join(" ")' "$CASE/request.json")"
check "marker is first bytes"  4 "$(jq --arg m "$FINDING_MARKER" '[.comments[] | select((.body | .[0:($m|length)]) == $m)] | length' "$CASE/request.json")"
check "review body unmarked"   false "$(jq -r --arg v "<!-- seidroid-review -->" '.body | startswith($v)' "$CASE/request.json")"
check "review body has no marker" false "$(jq -r --arg m "$FINDING_MARKER" '.body | startswith($m)' "$CASE/request.json")"
check "multi-line detail intact" true \
  "$(jq -r '.comments[0].body | contains("A second paragraph with a\ttab.")' "$CASE/request.json")"
check "quoting intact"       true \
  "$(jq -r '.comments[1].body | contains("Backtick `code`, a \"quote\" and a $dollar.")' "$CASE/request.json")"

echo "== 2. mixed: off-hunk line, untouched file, no line at all =="
run_case mixed FINDINGS="$HERE/fx/mixed.json"
report "2 mixed"
check "one review call"      1 "$(calls reviews)"
check "no line-comment call" 0 "$(calls line-comment)"
check "three file attempts"  3 "$(calls file-comment)"
check "on_line"              4 "$(out on_line)"
check "on_file"              2 "$(out on_file)"
check "unplaced"             1 "$(out unplaced)"
check "note names the file"  1 "$(grep -c 'pkg/untouched.go:5' "$CASE/note.md")"
check "note header"          1 "$(grep -c 'Observations off the changed lines' "$CASE/note.md")"

echo "== 3. the batch is rejected with 422 =="
run_case batch-422 FINDINGS="$HERE/fx/mixed.json" STUB_REVIEW=422
report "3 batch 422"
check "one review call"      1 "$(calls reviews)"
check "four line retries"    4 "$(calls line-comment)"
check "on_line"              4 "$(out on_line)"
check "on_file"              2 "$(out on_file)"
check "unplaced"             1 "$(out unplaced)"
check "every fallback body marked" 7 "$(grep -cxF -- "$FINDING_MARKER" "$CASE/bodies.txt")"
check "warning emitted"      1 "$(grep -c '::warning::owner/repo#7 refused the review' "$CASE/stdout.txt")"

echo "== 4. batch 422, and one line the API also refuses on its own =="
run_case batch-422-partial FINDINGS="$HERE/fx/mixed.json" STUB_REVIEW=422 \
  STUB_LINE_OK="$HERE/fx/line-ok-minus-one.tsv"
report "4 batch 422 + one bad line"
check "on_line"              3 "$(out on_line)"
check "on_file"              3 "$(out on_file)"
check "unplaced"             1 "$(out unplaced)"

echo "== 5. the batch fails with something other than 422 =="
run_case batch-500 FINDINGS="$HERE/fx/mixed.json" STUB_REVIEW=500
report "5 batch 500"
check "one review call"      1 "$(calls reviews)"
check "no line retries"      0 "$(calls line-comment)"
check "on_line"              0 "$(out on_line)"
check "on_file"              2 "$(out on_file)"
check "unplaced"             5 "$(out unplaced)"
check "warning emitted"      1 "$(grep -c '::warning::the review carrying 4 comment(s) could not be posted' "$CASE/stdout.txt")"

echo "== 6. the batch fails and the error body has no readable code =="
run_case batch-noshape FINDINGS="$HERE/fx/mixed.json" STUB_REVIEW=noshape
report "6 batch, unreadable error"
check "no line retries"      0 "$(calls line-comment)"
check "on_line"              0 "$(out on_line)"
check "unplaced"             5 "$(out unplaced)"

echo "== 7. zero findings (empty file) =="
run_case zero FINDINGS="$HERE/fx/empty.json"
report "7 zero findings"
check "no calls at all"      0 "$(( $(calls reviews) + $(calls line-comment) + $(calls file-comment) + $(calls compare) + $(calls pull) ))"
check "on_line"              0 "$(out on_line)"
check "on_file"              0 "$(out on_file)"
check "unplaced"             0 "$(out unplaced)"

echo "== 8. an empty findings array =="
run_case emptyarray FINDINGS="$HERE/fx/emptyarray.json"
report "8 empty array"
check "no review call"       0 "$(calls reviews)"
check "on_line"              0 "$(out on_line)"
check "unplaced"             0 "$(out unplaced)"

echo "== 9. the findings file cannot be read =="
run_case broken FINDINGS="$HERE/fx/broken.json"
report "9 unreadable findings"
check "no posting calls"     0 "$(( $(calls reviews) + $(calls line-comment) + $(calls file-comment) ))"
check "on_line"              0 "$(out on_line)"
check "on_file"              0 "$(out on_file)"
check "unplaced"             0 "$(out unplaced)"
check "counts still written" 3 "$(grep -cE '^(on_line|on_file|unplaced)=' "$CASE/output.txt")"

echo "== 10. the changed-file list cannot be read =="
run_case nofiles FINDINGS="$HERE/fx/mixed.json" STUB_FILES=FAIL
report "10 file list fails"
check "no review call"       0 "$(calls reviews)"
check "seven line attempts"  7 "$(calls line-comment)"
check "on_line"              4 "$(out on_line)"
check "on_file"              2 "$(out on_file)"
check "unplaced"             1 "$(out unplaced)"

echo "== 11. the reviewed commit was never recorded =="
run_case nosha FINDINGS="$HERE/fx/mixed.json" REVIEWED_SHA=""
report "11 no reviewed commit"
check "no calls at all"      0 "$(( $(calls reviews) + $(calls line-comment) + $(calls file-comment) + $(calls compare) + $(calls pull) ))"
check "on_line"              0 "$(out on_line)"
check "on_file"              0 "$(out on_file)"
check "unplaced"             7 "$(out unplaced)"
check "note header"          1 "$(grep -c 'Every finding is here' "$CASE/note.md")"

echo "== 12. a string line, a junk line, a missing side, a missing file =="
run_case odd FINDINGS="$HERE/fx/odd.json"
report "12 odd field shapes"
check "one review call"      1 "$(calls reviews)"
check "two anchored"         2 "$(jq '.comments | length' "$CASE/request.json")"
check "string line coerced"  'pkg/a.go:12:RIGHT pkg/b.go:2:RIGHT' \
                             "$(jq -r '[.comments[] | "\(.path):\(.line):\(.side)"] | join(" ")' "$CASE/request.json")"
check "junk line to file"    1 "$(calls file-comment)"
check "on_line"              2 "$(out on_line)"
check "on_file"              1 "$(out on_file)"
check "unplaced"             0 "$(out unplaced)"
check "no file named is dropped" 0 "$(grep -c 'No file named' "$CASE/note.md")"

echo
echo "== 13. a finding with an empty severity =="
run_case shift FINDINGS="$HERE/fx/shift.json" STUB_REVIEW=ok
report "13 empty severity"
check "two file attempts"    2 "$(calls file-comment)"
check "on_file"              1 "$(out on_file)"
check "unplaced"             1 "$(out unplaced)"
# shellcheck disable=SC2016  # the backticks are the summary's markdown, not a substitution
check "no field shift"       1 "$(grep -c '^- `pkg/untouched.go:3` (note) — An unrated finding nowhere.$' "$CASE/note.md")"
check "both bodies marked"    2 "$(grep -cxF -- "$FINDING_MARKER" "$CASE/bodies.txt")"

echo
echo "== 14. the head moved during the review: the index reads the reviewed commit =="
run_case at-reviewed-commit
report "14 index at reviewed commit"
check "one pull read"        1 "$(calls pull)"
check "one compare"          1 "$(calls compare)"
check "compared at REVIEWED_SHA" "CALL compare 0ba5e0ba5e0ba5e0ba5e0ba5e0ba5e0ba5e0ba5e0...deadbeefcafedeadbeefcafedeadbeefcafedead" \
                             "$(grep '^CALL compare' "$CASE/calls.log")"
check "one review call"      1 "$(calls reviews)"
check "on_line"              4 "$(out on_line)"

echo "== 14b. the same run, had the index read the pushed head instead =="
run_case at-pushed-head REVIEWED_SHA=facefeed1234facefeed1234facefeed1234face STUB_CHANGED_FILES=2
report "14b index at pushed head"
check "compared at that sha" "CALL compare 0ba5e0ba5e0ba5e0ba5e0ba5e0ba5e0ba5e0ba5e0...facefeed1234facefeed1234facefeed1234face" \
                             "$(grep '^CALL compare' "$CASE/calls.log")"
check "no request was built"  ""  "$(cat "$CASE/request.json")"
check "no review call"       0 "$(calls reviews)"
check "all four to the file rung" 4 "$(calls file-comment)"

echo "== 14c. base.sha cannot be read =="
run_case nobase FINDINGS="$HERE/fx/mixed.json" STUB_BASE=FAIL
report "14c no base sha"
check "no compare"           0 "$(calls compare)"
check "no review call"       0 "$(calls reviews)"
check "ladder ran"           7 "$(calls line-comment)"
check "on_line"              4 "$(out on_line)"
check "on_file"              2 "$(out on_file)"
check "unplaced"             1 "$(out unplaced)"

echo "== 15. a non-422 failure heads its findings for what they are =="
run_case headings FINDINGS="$HERE/fx/mixed.json" STUB_REVIEW=500
report "15 headings on a 500"
check "on-diff heading"      1 "$(grep -c '^\*\*On the changed lines, and not posted\.\*\*' "$CASE/note.md")"
check "off-diff heading"     1 "$(grep -c '^\*\*Observations off the changed lines\.\*\*' "$CASE/note.md")"
check "on-diff group first"  true \
  "$([ "$(grep -n 'On the changed lines, and not posted' "$CASE/note.md" | cut -d: -f1)" -lt \
      "$(grep -n 'Observations off the changed lines' "$CASE/note.md" | cut -d: -f1)" ] && echo true || echo false)"
check "4 under on-diff"      4 "$(sed -n '/On the changed lines, and not posted/,/Observations off/p' "$CASE/note.md" | grep -c '^- `')"
check "1 under off-diff"     1 "$(sed -n '/Observations off/,$p' "$CASE/note.md" | grep -c '^- `')"
check "one rule, not two"    1 "$(grep -c '^---$' "$CASE/note.md")"
check "unplaced counts both" 5 "$(out unplaced)"
check "summary total"        5 "$(grep -c '^- `' "$CASE/note.md")"

echo "== 15b. a 422 ladder puts what it believed on-diff in that group =="
run_case headings-422 FINDINGS="$HERE/fx/mixed.json" STUB_REVIEW=422 \
  STUB_LINE_OK="$HERE/fx/none.tsv" STUB_FILE_OK="$HERE/fx/none.txt"
report "15b headings on a 422"
check "on-diff heading"      1 "$(grep -c '^\*\*On the changed lines, and not posted\.\*\*' "$CASE/note.md")"
check "4 under on-diff"      4 "$(sed -n '/On the changed lines, and not posted/,/Observations off/p' "$CASE/note.md" | grep -c '^- `')"
check "3 under off-diff"     3 "$(sed -n '/Observations off/,$p' "$CASE/note.md" | grep -c '^- `')"
check "unplaced"             7 "$(out unplaced)"

echo "== 15c. no on-diff group means no on-diff heading =="
run_case headings-clean FINDINGS="$HERE/fx/mixed.json"
report "15c only off-diff"
check "no on-diff heading"   0 "$(grep -c 'On the changed lines, and not posted' "$CASE/note.md")"
check "off-diff heading"     1 "$(grep -c '^\*\*Observations off the changed lines\.\*\*' "$CASE/note.md")"
check "one rule"             1 "$(grep -c '^---$' "$CASE/note.md")"

echo
echo "== 16. a 422 whose body carries no status field =="
run_case no-status-field FINDINGS="$HERE/fx/mixed.json" STUB_REVIEW=422nostatus
report "16 422 with no status field"
check "one review call"      1 "$(calls reviews)"
check "ladder ran"           4 "$(calls line-comment)"
check "on_line"              4 "$(out on_line)"
check "on_file"              2 "$(out on_file)"
check "unplaced"             1 "$(out unplaced)"
check "refusal warning"      1 "$(grep -c 'refused the review carrying' "$CASE/stdout.txt")"

echo "== 17. a file the diff carries whose patch the API did not send =="
run_case no-patch FINDINGS="$HERE/fx/nopatch.json"
report "17 file with no patch"
check "one review call"      1 "$(calls reviews)"
check "only the known line batched" 1 "$(jq '.comments | length' "$CASE/request.json")"
check "batched the right one" 'pkg/a.go:11:RIGHT' \
                             "$(jq -r '[.comments[] | "\(.path):\(.line):\(.side)"] | join(" ")' "$CASE/request.json")"
check "the API was asked"    2 "$(calls line-comment)"
check "line accepted where the index could not see" 1 \
  "$(grep -c '^CALL line-comment pkg/huge.go RIGHT 120' "$CASE/calls.log")"
check "on_line"              2 "$(out on_line)"
check "on_file"              1 "$(out on_file)"
check "unplaced"             0 "$(out unplaced)"
check "no false 'outside this diff' on the accepted line" 0 \
  "$(grep -c '^CALL file-comment pkg/huge.go' "$CASE/calls.log")"

echo
echo "== 18. the diff came back short of the pull request's own file count =="
# pkg/b.go is in the pull request and missing from this list, which is what a
# truncated compare looks like. Read as the diff, it would put the finding on
# pkg/b.go under a body saying line 2 is outside a diff that adds line 2.
run_case short-list STUB_FILES="$HERE/fx/files-short.json" STUB_CHANGED_FILES=4
report "18 short file list"
check "no review call"       0 "$(calls reviews)"
check "the ladder ran"       4 "$(calls line-comment)"
check "on_line"              4 "$(out on_line)"
check "on_file"              0 "$(out on_file)"
check "unplaced"             0 "$(out unplaced)"
check "nothing sent to a file" 0 "$(calls file-comment)"
check "no false off-diff body" 0 "$(grep -c "outside this diff's changed lines" "$CASE/bodies.txt")"
check "warning names the shortfall" 1 \
  "$(grep -c 'came back with 3 of its 4 file(s)' "$CASE/stdout.txt")"

echo "== 19. a diff at the cap whose length the pull request confirms =="
run_case at-cap STUB_FILES="$GEN/files-at-cap.json" STUB_CHANGED_FILES=300 \
  FINDINGS="$GEN/findings-at-cap.json"
report "19 at the cap, count agrees"
check "one review call"      1 "$(calls reviews)"
check "one comment batched"  1 "$(jq '.comments | length' "$CASE/request.json")"
check "batched the right one" 'pkg/gen7.go:2:RIGHT' \
                             "$(jq -r '[.comments[] | "\(.path):\(.line):\(.side)"] | join(" ")' "$CASE/request.json")"
check "on_line"              1 "$(out on_line)"
check "unplaced"             0 "$(out unplaced)"
check "no shortfall warning" 0 "$(grep -c 'came back with' "$CASE/stdout.txt")"

echo "== 20. a diff at the cap whose true length could not be read =="
run_case at-cap-unknown STUB_FILES="$GEN/files-at-cap.json" STUB_CHANGED_FILES=NONE \
  FINDINGS="$GEN/findings-at-cap.json" STUB_LINE_OK="$GEN/line-ok-gen.tsv"
report "20 at the cap, count unknown"
check "no review call"       0 "$(calls reviews)"
check "the ladder ran"       1 "$(calls line-comment)"
check "on_line"              1 "$(out on_line)"
check "unplaced"             0 "$(out unplaced)"
check "warning names the cap" 1 \
  "$(grep -c 'which is all this endpoint sends' "$CASE/stdout.txt")"

echo "== 21. a diff under the cap whose true length could not be read =="
run_case under-cap-unknown STUB_CHANGED_FILES=NONE
report "21 under the cap, count unknown"
check "one review call"      1 "$(calls reviews)"
check "four comments batched" 4 "$(jq '.comments | length' "$CASE/request.json")"
check "on_line"              4 "$(out on_line)"
check "unplaced"             0 "$(out unplaced)"
check "no cap warning"       0 "$(grep -c 'all this endpoint sends' "$CASE/stdout.txt")"

echo
echo "== 22. the batch is refused with 413, which an unbounded detail invites =="
run_case batch-413 FINDINGS="$HERE/fx/mixed.json" STUB_REVIEW=413
report "22 batch 413"
check "one review call"      1 "$(calls reviews)"
check "four line retries"    4 "$(calls line-comment)"
check "on_line"              4 "$(out on_line)"
check "on_file"              2 "$(out on_file)"
check "unplaced"             1 "$(out unplaced)"
check "warning names the code" 1 \
  "$(grep -c 'refused the review carrying 4 comment(s) with 413' "$CASE/stdout.txt")"

echo "== 23. the batch is refused with 403 =="
run_case batch-403 FINDINGS="$HERE/fx/mixed.json" STUB_REVIEW=403
report "23 batch 403"
check "four line retries"    4 "$(calls line-comment)"
check "on_line"              4 "$(out on_line)"
check "unplaced"             1 "$(out unplaced)"

echo "== 24. the batch is refused with 400 =="
run_case batch-400 FINDINGS="$HERE/fx/mixed.json" STUB_REVIEW=400
report "24 batch 400"
check "four line retries"    4 "$(calls line-comment)"
check "on_line"              4 "$(out on_line)"
check "unplaced"             1 "$(out unplaced)"

echo "== 25. a 502 keeps its findings off the retry: the write may have landed =="
run_case batch-502 FINDINGS="$HERE/fx/mixed.json" STUB_REVIEW=502
report "25 batch 502"
check "one review call"      1 "$(calls reviews)"
check "no line retries"      0 "$(calls line-comment)"
check "on_line"              0 "$(out on_line)"
check "on_file"              2 "$(out on_file)"
check "unplaced"             5 "$(out unplaced)"
check "on-diff heading"      1 \
  "$(grep -c '^\*\*On the changed lines, and not posted\.\*\*' "$CASE/note.md")"

echo
echo "== 26. three threads superseded, and only the first replacement places =="
# The ticket's own case. The batch carries A's replacement; B's and C's name files
# this diff does not touch, so both reach the summary. The record has to name A and
# nothing else -- a record naming all three closes two threads with their
# replacements sitting in the summary instead of on the diff.
run_case superseded FINDINGS="$HERE/fx/superseded.json"
report "26 A places, B and C do not"
check "one review call"      1 "$(calls reviews)"
check "two file attempts"    2 "$(calls file-comment)"
check "on_line"              1 "$(out on_line)"
check "on_file"              0 "$(out on_file)"
check "unplaced"             2 "$(out unplaced)"
check "the linkage is published" true "$(out superseded_linked)"
check "only A's thread recorded" PRRT_kwDOABCDEF4Ax1y2 "$(linked)"

echo "== 27. a replacement that degrades to a file comment still replaces =="
# The recorded decision. A file comment is on the diff, in the file the reader is
# in, and its body carries the cited line, so it closes the thread it replaces. The
# sibling that reached neither a line nor a file closes nothing.
run_case superseded-file FINDINGS="$HERE/fx/superseded-file.json"
report "27 file comment replaces"
check "no review call"       0 "$(calls reviews)"
check "two file attempts"    2 "$(calls file-comment)"
check "on_line"              0 "$(out on_line)"
check "on_file"              1 "$(out on_file)"
check "unplaced"             1 "$(out unplaced)"
check "the file comment recorded its thread" PRRT_kwDOABCDEF4Ax1y2 "$(linked)"

echo "== 27b. a replacement on a file whose patch the API did not send =="
# The third bucket. A file with no patch has unknown lines rather than no lines, so
# its findings leave the batch and go to the API one at a time -- and the record has
# to follow them there, because that rung is the only thing that can still say
# whether the line exists.
run_case superseded-unknown FINDINGS="$HERE/fx/superseded-unknown.json"
report "27b unknown-lines bucket"
check "no review call"       0 "$(calls reviews)"
check "one line attempt"     1 "$(calls line-comment)"
check "on_line"              1 "$(out on_line)"
check "unplaced"             0 "$(out unplaced)"
check "its thread recorded"  PRRT_kwDOABCDEF4Ax1y2 "$(linked)"

echo "== 28. the batch is refused and the ladder splits the two threads =="
# One review carried both replacements and the API refused it, so each is posted on
# its own. A's lands on its line; B's is refused there and refused on its file. The
# gate is per thread, so the refusal costs B's thread and not A's.
run_case superseded-batch FINDINGS="$HERE/fx/superseded-batch.json" STUB_REVIEW=422 \
  STUB_LINE_OK="$HERE/fx/line-ok-minus-one.tsv" STUB_FILE_OK="$HERE/fx/none.txt"
report "28 batch refused, ladder run"
check "one review call"      1 "$(calls reviews)"
check "two line retries"     2 "$(calls line-comment)"
check "one file attempt"     1 "$(calls file-comment)"
check "on_line"              1 "$(out on_line)"
check "unplaced"             1 "$(out unplaced)"
check "only A's thread recorded" PRRT_kwDOABCDEF4Ax1y2 "$(linked)"

echo "== 29. the compare list is short, so the ladder runs and the record holds =="
run_case superseded-short FINDINGS="$HERE/fx/superseded-short.json" \
  STUB_FILES="$HERE/fx/files-short.json" STUB_CHANGED_FILES=4
report "29 short list, linkage kept"
check "no review call"       0 "$(calls reviews)"
check "two line attempts"    2 "$(calls line-comment)"
check "on_line"              1 "$(out on_line)"
check "unplaced"             1 "$(out unplaced)"
check "the linkage is published" true "$(out superseded_linked)"
check "only A's thread recorded" PRRT_kwDOABCDEF4Ax1y2 "$(linked)"
check "warning names the shortfall" 1 \
  "$(grep -c 'came back with 3 of its 4 file(s)' "$CASE/stdout.txt")"

echo "== 30. a driver that publishes no linkage =="
# fx/all-placeable.json carries the key on no finding, which is every driver before
# this change. The step has to say so, because that answer is what sends the resolve
# step to its per-review gate rather than to an empty record.
run_case superseded-older
report "30 older driver, no linkage"
check "one review call"      1 "$(calls reviews)"
check "on_line"              4 "$(out on_line)"
check "unplaced"             0 "$(out unplaced)"
check "no linkage published" false "$(out superseded_linked)"
check "nothing recorded"     "" "$(linked)"

echo "== 30b. an older driver whose batch is refused, so the ladder runs =="
# The per-finding rungs are handed a dot where the file names no thread, and a dot
# is not an id and does not reach the record. A record that is non-empty when
# nothing was replaced says something untrue about what this review did.
run_case superseded-older-ladder FINDINGS="$HERE/fx/mixed.json" STUB_REVIEW=422
report "30b older driver, ladder"
check "four line retries"    4 "$(calls line-comment)"
check "no linkage published" false "$(out superseded_linked)"
check "nothing recorded"     "" "$(linked)"
check "the record is empty"  0 "$(wc -c < "$CASE/superseded-placed.txt" | tr -d ' ')"

echo "== 31. a 502 records nothing: the write may have landed =="
# The one place the record must under-report. A 502 may be a write that landed and
# lost its connection, so those findings are not retried -- and a thread closed on a
# comment this run cannot confirm is the defect the record exists to remove.
run_case superseded-502 FINDINGS="$HERE/fx/superseded.json" STUB_REVIEW=502
report "31 502 records nothing"
check "one review call"      1 "$(calls reviews)"
check "no line retries"      0 "$(calls line-comment)"
check "on_line"              0 "$(out on_line)"
check "unplaced"             3 "$(out unplaced)"
check "the linkage is published" true "$(out superseded_linked)"
check "nothing recorded"     "" "$(linked)"

echo "== 32. one comment, six ids, and only two of them are ids =="
# The record is read line by line and each id is matched whole, so an id carrying a
# space or a line break would split into something the resolve step cannot find. The
# two well-formed ids land on their own lines; the rest are dropped, which leaves
# their threads open.
run_case superseded-odd-ids FINDINGS="$GEN/findings-odd-ids.json"
report "32 odd ids dropped"
check "one review call"      1 "$(calls reviews)"
check "on_line"              1 "$(out on_line)"
check "the linkage is published" true "$(out superseded_linked)"
check "both ids recorded"    "PRRT_kwDOABCDEF4Ax1y2 PRRT_kwDOABCDEF4Bz3w4" "$(linked)"
check "two lines, not six"   2 "$(wc -l < "$CASE/superseded-placed.txt" | tr -d ' ')"

echo "== 32c. one comment naming two threads, posted on its own =="
# The batch writes the record straight out of the placement file, one id per line.
# This is the other writer: the per-finding rung is handed the ids as one string and
# has to split them, because the record is read line by line and matched whole.
run_case superseded-two-ids FINDINGS="$GEN/findings-odd-ids.json" STUB_REVIEW=422
report "32c two ids, one comment"
check "one review call"       1 "$(calls reviews)"
check "one line retry"        1 "$(calls line-comment)"
check "on_line"               1 "$(out on_line)"
check "both ids recorded"     "PRRT_kwDOABCDEF4Ax1y2 PRRT_kwDOABCDEF4Bz3w4" "$(linked)"
check "on their own lines"    2 "$(wc -l < "$CASE/superseded-placed.txt" | tr -d ' ')"

echo "== 32b. a second attempt does not inherit the first one's record =="
# RUNNER_TEMP survives a re-run of a job on a non-ephemeral self-hosted runner,
# which is the steady state here. Attempt 1 replaces thread A; attempt 2 replaces
# thread B and nothing else, so A must not still be in the record to close.
run_case superseded-rerun FINDINGS="$HERE/fx/superseded.json"
check "attempt 1 recorded A"  PRRT_kwDOABCDEF4Ax1y2 "$(linked)"
rerun_case FINDINGS="$HERE/fx/superseded-b.json"
report "32b a second attempt"
check "one review call"       1 "$(calls reviews)"
check "on_line"               1 "$(out on_line)"
check "attempt 2 records its own alone" PRRT_kwDOABCDEF4Bz3w4 "$(linked)"

# ============================================================================
# Resolve the threads this review closed
# ============================================================================
# Extracted from the same workflow, so the two halves are one file's behaviour:
# placement writes the record and this reads it. extract.py prints the marker
# again, and the two have to be one value -- placement stamps a comment with it
# and this recognises a thread by it, so a drift between them closes nothing and
# says nothing.
RESOLVE_STEP="Resolve the threads this review closed"
RESOLVE="$HERE/resolve.sh"
RESOLVE_MARKER="$(python3 "$HERE/extract.py" "$WORKFLOW" "$RESOLVE_STEP" "$RESOLVE")" || {
  echo "could not read '$RESOLVE_STEP' out of $WORKFLOW"; exit 1; }

echo
echo "== the two steps read one marker =="
check "one FINDING_MARKER" "$MARKER" "$RESOLVE_MARKER"

# The identities this run posts as. REVIEWER is the one it holds now and the only
# one allowed to have written a thread it closes; WORKFLOW_ID is what a run without
# app credentials falls back to, which the history read admits and this does not.
REVIEWER='seidroid[bot]'
WORKFLOW_ID='github-actions[bot]'

# The pull request's review threads, in two pages, because both readers page. Eight
# threads over the four ways one can fail this step's tests: the wrong identity, no
# marker, a marker quoted mid-body, and already resolved.
jq -nc --arg m "$MARKER" --arg rev "$REVIEWER" --arg wf "$WORKFLOW_ID" '
  def t($id; $resolved; $login; $body):
    {id: $id, isResolved: $resolved,
     comments: {nodes: [{body: $body, author: {login: $login}}]}};
  def page($nodes; $more):
    {data: {repository: {pullRequest: {reviewThreads:
      {nodes: $nodes, pageInfo: {hasNextPage: $more, endCursor: "c1"}}}}}};
  page([ t("PRRT_kwDOABCDEF4Ax1y2"; false; $rev; $m + "\n**blocker** — A still holds"),
         t("PRRT_kwDOABCDEF4Bz3w4"; false; $rev; $m + "\n**blocker** — B still holds") ];
       true),
  page([ t("PRRT_kwDOABCDEF4Cq9r8"; false; $rev; $m + "\n**suggestion** — C still holds"),
         t("PRRT_kwDOABCDEF4Dm5n6"; false; $wf;  $m + "\n**blocker** — under the other identity"),
         t("PRRT_kwDOABCDEF4Es7t8"; false; "someone-else"; $m + "\n**blocker** — not ours"),
         t("PRRT_kwDOABCDEF4Fu1v2"; true;  $rev; $m + "\n**blocker** — ours, already resolved"),
         t("PRRT_kwDOABCDEF4Gw3x4"; false; $rev; "A comment of ours carrying no marker."),
         t("PRRT_kwDOABCDEF4Hy5z6"; false; $rev; "Quoting " + $m + " in prose, not opening with it.") ];
       false)' > "$GEN/threads.json"

tA=PRRT_kwDOABCDEF4Ax1y2
tB=PRRT_kwDOABCDEF4Bz3w4
tC=PRRT_kwDOABCDEF4Cq9r8
tD=PRRT_kwDOABCDEF4Dm5n6
tE=PRRT_kwDOABCDEF4Es7t8
tF=PRRT_kwDOABCDEF4Fu1v2
tG=PRRT_kwDOABCDEF4Gw3x4
tH=PRRT_kwDOABCDEF4Hy5z6

run_resolve() {
  # $1 name, then KEY=VALUE overrides. RECORD is the record placement left, as a
  # space-separated list of ids. KEY=UNSET removes the variable, which is how the
  # case for an output placement never wrote is set up.
  local name="$1"; shift
  CASE="$HERE/out/$name"
  rm -rf "$CASE"; mkdir -p "$CASE"
  export STUB_LOG="$CASE/calls.log"; : > "$STUB_LOG"
  export STUB_THREADS="$GEN/threads.json"
  export STUB_RESOLVE=ok
  export CHECK="$HERE/fx/check-abc.json"
  export PLACED_LINKED=true
  export PLACED_ON_LINE=1 PLACED_ON_FILE=0 PLACED_UNPLACED=0
  export REVIEWER_LOGIN="$REVIEWER" WORKFLOW_LOGIN="$WORKFLOW_ID"
  RECORD=""
  for kv in "$@"; do
    case "$kv" in
      *=UNSET) unset "${kv%%=*}" ;;
      *)       export "${kv?}" ;;
    esac
  done

  export PATH="$HERE/bin:$PATH"
  export RUNNER_TEMP="$CASE/tmp"; mkdir -p "$RUNNER_TEMP"
  export GITHUB_OUTPUT="$CASE/output.txt"; : > "$GITHUB_OUTPUT"
  export REPO=owner/repo PR=7 GH_TOKEN=x
  export FINDING_MARKER="$MARKER"
  # What placement would have left behind, one id per line.
  export LINKAGE="$CASE/superseded-placed.txt"
  printf '%s' "$RECORD" | tr ' ' '\n' | sed '/^$/d' > "$LINKAGE"
  bash "$RESOLVE" > "$CASE/stdout.txt" 2> "$CASE/stderr.txt"
  echo "$?" > "$CASE/rc"
}

# The threads the step actually closed, sorted and space-joined.
closed() { grep '^CALL resolve ' "$CASE/calls.log" 2>/dev/null | awk '{print $3}' \
             | sort -u | tr '\n' ' ' | sed 's/ $//'; }

report_resolve() { # label
  rows+=("$(printf '%-34s rc=%s  threads=%s resolve=%s  closed=[%s]' \
    "$1" "$(cat "$CASE/rc")" "$(calls threads)" "$(calls resolve)" "$(closed)")")
}

echo
echo "== 33. A's replacement placed and B's and C's did not =="
# The ticket's invariant, on the closing side. A closes because the comment that
# replaced it is on the code. B and C stay open because theirs are in the summary,
# and the per-review gate closed all three on A's placing.
run_resolve per-thread-a RECORD="$tA"
report_resolve "33 A closes, B and C hold"
check "one resolve call"     1 "$(calls resolve)"
check "closed"               "$tA" "$(closed)"
check "two held open"        2 "$(grep -c 'stays open: nothing replacing it reached the code' "$CASE/stdout.txt")"
check "the tally"            1 "$(grep -c 'superseded: 1 of 3 thread(s) had their own replacement reach the code' "$CASE/stdout.txt")"
check "no refusal warning"   0 "$(grep -c '::warning::' "$CASE/stdout.txt")"

echo "== 34. two replacements placed, and one of them is on page two =="
run_resolve per-thread-ac RECORD="$tA $tC"
report_resolve "34 A and C close"
check "two resolve calls"    2 "$(calls resolve)"
check "closed"               "$tA $tC" "$(closed)"
check "one held open"        1 "$(grep -c 'stays open: nothing' "$CASE/stdout.txt")"

echo "== 35. no replacement placed, so no superseded thread closes =="
run_resolve per-thread-none RECORD=""
report_resolve "35 nothing closes"
check "no thread read"       0 "$(calls threads)"
check "no resolve call"      0 "$(calls resolve)"
check "says so"              1 "$(grep -c 'this review closes no thread' "$CASE/stdout.txt")"

echo "== 36. an addressed thread needs no record =="
# addressed is a finding the diff no longer shows. Nothing replaces it, so nothing
# can be recorded for it, and it closes on the review publishing.
run_resolve addressed CHECK="$HERE/fx/check-addressed.json" RECORD=""
report_resolve "36 addressed closes"
check "one resolve call"     1 "$(calls resolve)"
check "closed"               "$tA" "$(closed)"
check "the refused id is echoed" 1 \
  "$(grep -c "::warning::the review named review thread 'PRRT_neverOurs'" "$CASE/stdout.txt")"

echo "== 37. an older driver publishes no linkage, so the per-review gate runs =="
# The same empty record as case 35 and the same plan. What changes is one bit, and
# a driver that cannot say which comment replaced which thread closes all three on
# placement having dropped nothing.
run_resolve older-clean PLACED_LINKED=false PLACED_ON_LINE=3 PLACED_UNPLACED=0 RECORD=""
report_resolve "37 older driver, clean"
check "three resolve calls"  3 "$(calls resolve)"
check "closed"               "$tA $tB $tC" "$(closed)"

echo "== 38. an older driver with one finding unplaced closes none of them =="
run_resolve older-unplaced PLACED_LINKED=false PLACED_ON_LINE=3 PLACED_UNPLACED=1 RECORD=""
report_resolve "38 older driver, one unplaced"
check "no resolve call"      0 "$(calls resolve)"
check "says why"             1 \
  "$(grep -c '3 superseded thread(s) stay open: 3 comment(s) reached the code and 1 could not be placed' "$CASE/stdout.txt")"

echo "== 39. an older driver that reported its placings and not its unplaced count =="
# An absent output is not a zero. Placement reported three comments on the code and
# said nothing about what it dropped, so something may be unplaced -- and this gate
# decides whether a live finding comes off a pull request, so the unknown falls on
# the side that leaves the thread open.
run_resolve older-half PLACED_LINKED=false PLACED_ON_LINE=3 PLACED_ON_FILE=0 \
  PLACED_UNPLACED=UNSET RECORD=""
report_resolve "39 older driver, half-reported"
check "no resolve call"      0 "$(calls resolve)"
check "names the unknown"    1 "$(grep -c 'an unreported number could not be placed' "$CASE/stdout.txt")"

echo "== 39b. an older driver whose placement reported nothing at all =="
run_resolve older-silent PLACED_LINKED=false PLACED_ON_LINE=UNSET PLACED_ON_FILE=UNSET \
  PLACED_UNPLACED=UNSET RECORD=""
report_resolve "39b older driver, silent"
check "no resolve call"      0 "$(calls resolve)"
check "names the unknown"    1 "$(grep -c 'an unreported number could not be placed' "$CASE/stdout.txt")"

echo "== 40. the strict single-login test, and the marker test with it =="
# Four threads the record names and this step closes none of. One this tool wrote
# under its other identity, one another account wrote, one of ours carrying no
# marker, and one quoting the marker mid-body. Only the first is not a warning.
run_resolve identity CHECK="$HERE/fx/check-identity.json" \
  RECORD="$tD $tE $tG $tH"
report_resolve "40 identity and marker"
check "no resolve call"      0 "$(calls resolve)"
check "the other identity is named" 1 \
  "$(grep -c "review thread $tD on owner/repo#7 was left under this tool's other identity" "$CASE/stdout.txt")"
check "three refusals"       3 \
  "$(grep -c "::warning::review thread '.*' is not an unresolved thread this tool left" "$CASE/stdout.txt")"
check "a foreign thread is refused" 1 "$(grep -c "review thread '$tE'" "$CASE/stdout.txt")"
check "an unmarked thread is refused" 1 "$(grep -c "review thread '$tG'" "$CASE/stdout.txt")"
check "a quoted marker does not open a body" 1 "$(grep -c "review thread '$tH'" "$CASE/stdout.txt")"
check "the tally"            1 \
  "$(grep -c 'threads: 0 closed, 3 refused, 1 left under another identity, 0 could not be resolved' "$CASE/stdout.txt")"

echo "== 41. a thread of ours that is already resolved =="
run_resolve already CHECK="$HERE/fx/check-resolved.json" RECORD="$tF"
report_resolve "41 already resolved"
check "no resolve call"      0 "$(calls resolve)"
check "says so"              1 "$(grep -c "review thread $tF is already resolved" "$CASE/stdout.txt")"
check "no warning"           0 "$(grep -c '::warning::' "$CASE/stdout.txt")"

echo "== 42. the thread read fails, so nothing is closed =="
run_resolve unreadable STUB_THREADS=FAIL RECORD="$tA"
report_resolve "42 thread read fails"
check "one thread read"      1 "$(calls threads)"
check "no resolve call"      0 "$(calls resolve)"
# -F, because the identity carries a [bot] suffix a regex reads as a character class.
check "warning names the identity" 1 \
  "$(grep -cF "::warning::the review threads on owner/repo#7 could not be read as $REVIEWER" "$CASE/stdout.txt")"

echo "== 43. the mutation is refused, and the warning names the identity =="
run_resolve refused CHECK="$HERE/fx/check-one.json" RECORD="$tA" STUB_RESOLVE=403
report_resolve "43 mutation refused"
check "one resolve call"     1 "$(calls resolve)"
check "the thread warning"   1 "$(grep -c "review thread $tA on owner/repo#7 was not resolved" "$CASE/stdout.txt")"
check "the identity warning" 1 "$(grep -c 'that refusal names the identity, not the thread' "$CASE/stdout.txt")"
check "the tally"            1 "$(grep -c 'threads: 0 closed, 0 refused, 0 left under another identity, 1 could not be resolved' "$CASE/stdout.txt")"

echo "== 44. the record cannot close a thread the plan does not name =="
# The plan is the warrant. It is what the driver admitted against the history it
# was handed, and a record naming more than it closes a thread the driver refused.
run_resolve record-wider CHECK="$HERE/fx/check-one.json" RECORD="$tA $tB $tC"
report_resolve "44 record cannot widen"
check "one resolve call"     1 "$(calls resolve)"
check "closed"               "$tA" "$(closed)"

echo "== 45. no check file, so nothing names a thread =="
run_resolve nocheck CHECK="$CASE/never-written.json" RECORD="$tA"
report_resolve "45 no check file"
check "no calls at all"      0 "$(( $(calls threads) + $(calls resolve) ))"
check "says so"              1 "$(grep -c 'no check file, so nothing names a thread to close' "$CASE/stdout.txt")"

echo "== 46. a driver that writes no threads key at all =="
run_resolve noplan CHECK="$HERE/fx/check-noplan.json" RECORD="$tA"
report_resolve "46 no thread plan"
check "no calls at all"      0 "$(( $(calls threads) + $(calls resolve) ))"
check "says so"              1 "$(grep -c 'this review closes no thread' "$CASE/stdout.txt")"

echo
printf '%s\n' "${rows[@]}"
echo
echo "assertions: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
