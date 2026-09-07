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
  export REPO=owner/repo PR=7 GH_TOKEN=x
  export FINDING_MARKER="$MARKER"
  bash "$SCRIPT" > "$CASE/stdout.txt" 2> "$CASE/stderr.txt"
  echo "$?" > "$CASE/rc"
}

out() { grep -E "^$1=" "$CASE/output.txt" | tail -1 | cut -d= -f2- ; }
calls() { grep -c "^CALL $1" "$CASE/calls.log" || true; }

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
printf '%s\n' "${rows[@]}"
echo
echo "assertions: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
