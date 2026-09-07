#!/usr/bin/env bash
# Runs the three reaction steps of seidroid-review.yml under bash with a gh stub,
# and checks what each leaves on the trigger comment.
#
# The steps are read out of the workflow on every run, so a run tests what the file
# says now. `conditions.py` covers the part a shell harness cannot see: which step
# runs in which job state.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
REPOROOT="$(cd "$HERE/../.." && pwd)"
WORKFLOW="$REPOROOT/.github/workflows/seidroid-review.yml"

python3 "$HERE/extract.py" "$WORKFLOW" "Acknowledge the trigger" "$HERE/ack.sh" > /dev/null || {
  echo "could not read 'Acknowledge the trigger' out of $WORKFLOW"; exit 1; }
python3 "$HERE/extract.py" "$WORKFLOW" "Answer the request" "$HERE/answer.sh" > /dev/null || {
  echo "could not read 'Answer the request' out of $WORKFLOW"; exit 1; }
python3 "$HERE/extract.py" "$WORKFLOW" "Withdraw the reactions on a cancelled run" \
  "$HERE/withdraw.sh" > /dev/null || {
  echo "could not read the withdrawal step out of $WORKFLOW"; exit 1; }

pass=0 fail=0
rows=()

BOT='github-actions[bot]'
HUMAN_ALL='[{"id":21,"content":"+1","user":{"login":"brandon"}},
            {"id":22,"content":"eyes","user":{"login":"brandon"}},
            {"id":23,"content":"-1","user":{"login":"brandon"}}]'
STALE_DOWN='[{"id":31,"content":"-1","user":{"login":"github-actions[bot]"}},
             {"id":21,"content":"+1","user":{"login":"brandon"}}]'
STALE_UP='[{"id":32,"content":"+1","user":{"login":"github-actions[bot]"}}]'
# A reaction of this bot's that no step here ever chooses. Whatever put it there owns it.
FOREIGN='[{"id":41,"content":"rocket","user":{"login":"github-actions[bot]"}},
          {"id":21,"content":"+1","user":{"login":"brandon"}}]'

check() { # label expected actual
  if [ "$2" = "$3" ]; then pass=$((pass+1)); else fail=$((fail+1)); echo "  FAIL $1: want [$2] got [$3]"; fi
}

left() { jq -r '[.[] | "\(.user.login):\(.content)"] | sort | join(" ")' < "$STUB_STATE"; }
calls() { grep -c "^CALL $1" "$STUB_LOG" || true; }

# run_case <name> <seed json> <which step> <conclusion|-> <verdict_produced> <check?> [K=V...]
#
# "which step" is answer or withdraw: a job state decides which of them GitHub runs,
# and conditions.py checks that mapping. This runs the one that state selects.
run_case() {
  local name="$1" seed="$2" which="$3" conclusion="$4" produced="$5" have_check="$6"
  shift 6
  CASE="$HERE/out-reactions/$name"
  rm -rf "$CASE"; mkdir -p "$CASE"
  export STUB_STATE="$CASE/reactions.json"; printf '%s\n' "$seed" > "$STUB_STATE"
  export STUB_LIST=ok STUB_DELETE=ok STUB_POST=ok STUB_ACTOR="$BOT"
  export PATH="$HERE/bin-reactions:$PATH"
  export GH_TOKEN=x REPO=owner/repo TRIGGER_REPO=owner/repo TRIGGER_ID=7
  local check_path=""
  if [ "$have_check" = yes ]; then
    printf '{"conclusion":"%s","title":"t"}\n' "$conclusion" > "$CASE/check.json"
    check_path="$CASE/check.json"
  fi
  export CHECK="$check_path" VERDICT_PRODUCED="$produced"
  for kv in "$@"; do export "${kv?}"; done

  # The acknowledgement first, as the job runs it, unless a case suppresses it. Its
  # calls go to a log of their own: every count below is the step under test, not the
  # POST that put the eyes there.
  if [ "${SKIP_ACK:-no}" = no ]; then
    STUB_LOG="$CASE/ack-calls.log" ; export STUB_LOG; : > "$STUB_LOG"
    # ACK_POST refuses the acknowledgement alone, so a case can start from a comment
    # that never got the eyes without also refusing the answer.
    STUB_POST="${ACK_POST:-${STUB_POST:-ok}}" bash "$HERE/ack.sh" > "$CASE/ack.out" 2>&1
  fi
  STUB_LOG="$CASE/calls.log" ; export STUB_LOG; : > "$STUB_LOG"
  bash "$HERE/$which.sh" > "$CASE/step.out" 2>&1
  echo "$?" > "$CASE/rc"
  rows+=("$(printf '%-28s %-8s rc=%s  list=%s del=%s post=%s  left=%s' \
    "$name" "$which" "$(cat "$CASE/rc")" "$(calls list)" "$(calls delete)" \
    "$(calls post)" "$(left)")")
}

echo "== a green review thumbs the request up =="
run_case success '[]' answer success true yes
check "left"        "$BOT:+1" "$(left)"
check "one post"    1 "$(calls post)"

echo "== a blocking review thumbs it down =="
run_case failure '[]' answer failure true yes
check "left"        "$BOT:-1" "$(left)"

echo "== a run that reached no verdict clears and says nothing =="
run_case no-verdict '[]' answer failure false yes
check "left"        "" "$(left)"
check "no post"     0 "$(calls post)"

echo "== neutral earns no reaction =="
run_case neutral '[]' answer neutral true yes
check "left"        "" "$(left)"

echo "== A CANCELLED RUN, VERDICT OUTPUTS POPULATED. The case that matters: a"
echo "   cancellation after the driver finishes leaves a real conclusion on disk, and"
echo "   the withdrawal step must still post nothing. =="
run_case cancelled-after-drive '[]' withdraw success true yes
check "left"        "" "$(left)"
check "no post"     0 "$(calls post)"
check "eyes gone"   0 "$(grep -c 'eyes' <<< "$(left)")"

echo "== a cancelled run before the driver finishes =="
run_case cancelled-early '[]' withdraw - '' no
check "left"        "" "$(left)"
check "no post"     0 "$(calls post)"

echo "== a cancelled run withdraws a thumb the answer step had already posted =="
run_case cancelled-heals "[{\"id\":51,\"content\":\"+1\",\"user\":{\"login\":\"$BOT\"}}]" \
  withdraw success true yes
check "left"        "" "$(left)"
check "no post"     0 "$(calls post)"

echo "== a human's reaction survives every path =="
run_case success-human "$HUMAN_ALL" answer success true yes
check "left"  "brandon:+1 brandon:-1 brandon:eyes $BOT:+1" "$(left)"
run_case failure-human "$HUMAN_ALL" answer failure true yes
check "left"  "brandon:+1 brandon:-1 brandon:eyes $BOT:-1" "$(left)"
run_case noverdict-human "$HUMAN_ALL" answer failure false yes
check "left"  "brandon:+1 brandon:-1 brandon:eyes" "$(left)"
run_case cancelled-human "$HUMAN_ALL" withdraw success true yes
check "left"  "brandon:+1 brandon:-1 brandon:eyes" "$(left)"

echo "== a stale thumb from an earlier attempt goes, a human's stays =="
run_case stale-thumb "$STALE_DOWN" answer success true yes
check "left"  "brandon:+1 $BOT:+1" "$(left)"
run_case stale-thumb-cancelled "$STALE_DOWN" withdraw success true yes
check "left"  "brandon:+1" "$(left)"
run_case stale-up-noverdict "$STALE_UP" answer failure false yes
check "left"  "" "$(left)"

echo "== a reaction no step here chooses is not this job's to withdraw =="
run_case foreign "$FOREIGN" answer success true yes
check "left"  "brandon:+1 $BOT:+1 $BOT:rocket" "$(left)"
run_case foreign-cancelled "$FOREIGN" withdraw success true yes
check "left"  "brandon:+1 $BOT:rocket" "$(left)"

echo "== a refused call warns and never fails the step =="
run_case list-refused '[{"id":21,"content":"+1","user":{"login":"brandon"}}]' \
  answer success true yes STUB_LIST=FAIL
check "rc"          0 "$(cat "$CASE/rc")"
check "warned"      1 "$(grep -c '::warning::could not read the reactions' "$CASE/step.out")"
check "thumb still" 1 "$(calls post)"
run_case delete-refused '[]' answer success true yes STUB_DELETE=FAIL
check "rc"          0 "$(cat "$CASE/rc")"
check "eyes stay"   "$BOT:+1 $BOT:eyes" "$(left)"
run_case post-refused '[]' answer success true yes STUB_POST=FAIL
check "rc"          0 "$(cat "$CASE/rc")"
check "left"        "" "$(left)"
run_case list-refused-cancelled '[]' withdraw - '' no STUB_LIST=FAIL
check "rc"          0 "$(cat "$CASE/rc")"
check "warned"      1 "$(grep -c '::warning::could not read the reactions' "$CASE/step.out")"
run_case delete-refused-cancelled '[]' withdraw - '' no STUB_DELETE=FAIL
check "rc"          0 "$(cat "$CASE/rc")"
check "eyes stay"   "$BOT:eyes" "$(left)"

echo "== the acknowledgement itself refused: no eyes to clear, the answer still lands =="
run_case ack-refused '[]' answer success true yes ACK_POST=FAIL
check "rc"           0 "$(cat "$CASE/rc")"
check "ack warned"   1 "$(grep -c '::warning::could not react to comment' "$CASE/ack.out")"
check "nothing to clear" 0 "$(calls delete)"
check "left"         "$BOT:+1" "$(left)"
unset ACK_POST

echo "== no step made a call the stub does not serve =="
check "unstubbed calls" 0 "$(grep -rc 'CALL UNSTUBBED' "$HERE/out-reactions" 2>/dev/null | awk -F: '{s+=$2} END {print s+0}')"

echo
printf '%s\n' "${rows[@]}"
echo
echo "assertions: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
