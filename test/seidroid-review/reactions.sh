#!/usr/bin/env bash
# Runs the reaction steps of seidroid-review.yml under bash with a gh stub, and checks
# what each case leaves on the trigger comment.
#
# No case names the step it runs. `conditions.py --select` names it, from the job state
# and from whether `Post the verdict` landed its comment, so the shell layer and the
# condition layer cannot drift, and a case cannot stop exercising the step it claims to.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
REPOROOT="$(cd "$HERE/../.." && pwd)"
WORKFLOW="$REPOROOT/.github/workflows/seidroid-review.yml"
SELECT="python3 $HERE/conditions.py --select $WORKFLOW"

extract() { # step name, output file
  python3 "$HERE/extract.py" "$WORKFLOW" "$1" "$2" > /dev/null || {
    echo "could not read '$1' out of $WORKFLOW"; exit 1; }
}
extract "Acknowledge the trigger" "$HERE/ack.sh"
extract "Answer the request" "$HERE/answer.sh"
extract "Withdraw the reactions on a cancelled run" "$HERE/withdraw.sh"

# Step name -> the file it was extracted to.
script_for() {
  case "$1" in
    "Acknowledge the trigger") echo "$HERE/ack.sh" ;;
    "Answer the request") echo "$HERE/answer.sh" ;;
    "Withdraw the reactions on a cancelled run") echo "$HERE/withdraw.sh" ;;
    *) echo "" ;;
  esac
}

pass=0 fail=0
rows=()

BOT='github-actions[bot]'
NONE='[]'
HUMAN_ALL='[{"id":21,"content":"+1","user":{"login":"brandon"}},
            {"id":22,"content":"eyes","user":{"login":"brandon"}},
            {"id":23,"content":"-1","user":{"login":"brandon"}}]'
STALE_DOWN='[{"id":31,"content":"-1","user":{"login":"github-actions[bot]"}},
             {"id":21,"content":"+1","user":{"login":"brandon"}}]'
STALE_UP='[{"id":32,"content":"+1","user":{"login":"github-actions[bot]"}}]'
# An EARLIER run's thumb, on a comment a re-run replays. Its verdict is on the pull
# request, so it is not this run's to take.
EARLIER_THUMB='[{"id":51,"content":"+1","user":{"login":"github-actions[bot]"}}]'
# A reaction of this bot's that no step here ever chooses. Whatever put it there owns it.
FOREIGN='[{"id":41,"content":"rocket","user":{"login":"github-actions[bot]"}},
          {"id":21,"content":"+1","user":{"login":"brandon"}}]'

check() { # label expected actual
  if [ "$2" = "$3" ]; then pass=$((pass+1)); else fail=$((fail+1)); echo "  FAIL $1: want [$2] got [$3]"; fi
}

left() { jq -r '[.[] | "\(.user.login):\(.content)"] | sort | join(" ")' < "$STUB_STATE"; }
calls() { grep -c "^CALL $1" "$CASE/calls.log" || true; }
ran() { grep -c "^$1\$" "$CASE/ran.txt" || true; }

# run_case <name> <seed> <answer state> <final state> <posted> \
#          <conclusion|-> <produced> <check?> [K=V...]
#
# Two states, because a cancellation has a moment. `answer state` is the job state when
# the runner reached `Answer the request`; `final state` is the state when it reached the
# withdrawal step at the end. A cancellation arriving after the verdict landed gives
# success then cancelled, so the answer step posts its thumb and the fixture does not
# have to place one.
#
# `posted` is `Post the verdict`'s own output: true when its comment landed, false when
# the POST was refused, `-` when that step never reported. Not its outcome, which reads
# success even on a refused POST.
run_case() {
  local name="$1" seed="$2" answer_state="$3" state="$4" posted="$5"
  local conclusion="$6" produced="$7" have_check="$8"
  shift 8
  CASE="$HERE/out-reactions/$name"
  rm -rf "$CASE"; mkdir -p "$CASE"
  # Every per-case knob is cleared here, not at the end of the case that set it. An
  # export leaks to every later case otherwise, and a case that stops exercising what
  # it claims fails nothing.
  unset ANSWERED_AS ACK_POST SKIP_ACK
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
  : > "$CASE/ran.txt"

  # The acknowledgement runs before any cancellation could land, so it is selected in
  # the state the job starts in, not in the state it ends in.
  local ack_step
  ack_step="$($SELECT success review 7 - | grep '^Acknowledge the trigger$' || true)"
  if [ -n "$ack_step" ] && [ "${SKIP_ACK:-no}" = no ]; then
    STUB_LOG="$CASE/ack-calls.log"; export STUB_LOG; : > "$STUB_LOG"
    # ACK_POST refuses the acknowledgement alone, so a case can start from a comment
    # that never got the eyes without also refusing the answer.
    STUB_POST="${ACK_POST:-${STUB_POST:-ok}}" bash "$HERE/ack.sh" > "$CASE/ack.out" 2>&1
    echo "$ack_step" >> "$CASE/ran.txt"
  fi

  STUB_LOG="$CASE/calls.log"; export STUB_LOG; : > "$STUB_LOG"
  : > "$CASE/step.out"
  local rc=0 step script
  run_selected() { # state, verdict outcome, step to keep
    while IFS= read -r step; do
      [ "$step" = "$3" ] || continue
      script="$(script_for "$step")"
      if [ -z "$script" ]; then echo "no script for step '$step'"; exit 1; fi
      bash "$script" >> "$CASE/step.out" 2>&1 || rc=$?
      echo "$step" >> "$CASE/ran.txt"
    done < <($SELECT "$1" review 7 "$2")
  }
  run_selected "$answer_state" "$posted" "Answer the request"
  # The withdrawal reads the answer step's outcome to decide what it may take. Derived
  # from whether the harness just ran that step, not passed in, so a case cannot claim
  # an outcome the timeline it declared would not produce. ANSWERED_AS overrides it, for
  # the arms a two-state timeline cannot reach.
  if [ "$(ran 'Answer the request')" = 1 ]; then
    ANSWERED="${ANSWERED_AS-success}"
  else
    ANSWERED="${ANSWERED_AS-skipped}"
  fi
  export ANSWERED
  run_selected "$state" "$posted" "Withdraw the reactions on a cancelled run"
  echo "$rc" > "$CASE/rc"

  rows+=("$(printf '%-29s %-19s posted=%-10s ran=%-9s list=%s del=%s post=%s  left=%s' \
    "$name" "$answer_state>$state" "${posted/-/unreported}" \
    "$(sed -n 's/^Answer the request$/answer/p;s/^Withdraw.*/withdraw/p' \
        "$CASE/ran.txt" | paste -sd+ - || true)" \
    "$(calls list)" "$(calls delete)" "$(calls post)" "$(left)")")
}

echo "== a green review thumbs the request up =="
run_case success "$NONE" success success true success true yes
check "answer ran"  1 "$(ran 'Answer the request')"
check "left"        "$BOT:+1" "$(left)"

echo "== a blocking review thumbs it down =="
run_case failure "$NONE" success success true failure true yes
check "left"        "$BOT:-1" "$(left)"

echo "== a run that reached no verdict clears and says nothing =="
run_case no-verdict "$NONE" success success - failure false yes
check "left"        "" "$(left)"
check "no post"     0 "$(calls post)"

echo "== neutral earns no reaction =="
run_case neutral "$NONE" success success - neutral true yes
check "left"        "" "$(left)"

echo "== a cancelled run with the verdict outputs POPULATED still posts nothing."
echo "   A cancellation after the driver finishes leaves a real conclusion on disk. =="
run_case cancelled-after-drive "$NONE" cancelled cancelled - success true yes
check "withdraw ran" 1 "$(ran 'Withdraw the reactions on a cancelled run')"
check "answer skipped" 0 "$(ran 'Answer the request')"
check "left"         "" "$(left)"
check "no post"      0 "$(calls post)"

echo "== a cancelled run before the driver finishes =="
run_case cancelled-early "$NONE" cancelled cancelled - - '' no
check "left"        "" "$(left)"
check "no post"     0 "$(calls post)"

echo "== cancelled while the verdict was posting: the thumb goes, it may not have landed =="
run_case cancelled-mid-publish "$NONE" success cancelled - success true yes
check "withdraw ran" 1 "$(ran 'Withdraw the reactions on a cancelled run')"
check "left"        "" "$(left)"

echo "== THE VERDICT COMMENT WAS REFUSED. `Post the verdict` tolerates that and exits 0,"
echo "   so its OUTCOME reads success while nothing landed. The thumb has to go: reading"
echo "   the outcome here would leave it standing for a review nobody can see. =="
run_case cancelled-publish-failed "$NONE" success cancelled false success true yes
check "answer posted a thumb" 1 "$(calls post)"
check "withdraw ran"          1 "$(ran 'Withdraw the reactions on a cancelled run')"
check "THUMB GOES"            "" "$(left)"

echo "== an outcome this step cannot read clears rather than leaving a thumb =="
run_case cancelled-unreported "$NONE" success cancelled - success true yes
check "withdraw ran" 1 "$(ran 'Withdraw the reactions on a cancelled run')"
check "left"        "" "$(left)"

echo "== CANCELLED AFTER THE VERDICT PUBLISHED. The thumb answers a review that is on"
echo "   the pull request, so it survives: withdrawing it would read as never answered. =="
run_case cancelled-after-publish "$NONE" success cancelled true success true yes
check "answer ran"       1 "$(ran 'Answer the request')"
check "withdraw skipped" 0 "$(ran 'Withdraw the reactions on a cancelled run')"
check "one post, no later delete" "1 1" "$(calls post) $(calls delete)"
check "THUMB SURVIVES"   "$BOT:+1" "$(left)"

echo "== A RE-RUN REPLAYS THE TRIGGER COMMENT ID, so an earlier run's thumb can already"
echo "   be on it. A run cancelled before it answers has posted only the eyes, and that"
echo "   thumb answers a verdict still on the pull request. =="
run_case rerun-cancelled-before-answer "$EARLIER_THUMB" cancelled cancelled - - '' no
check "answer never ran"   0 "$(ran 'Answer the request')"
check "withdraw ran"       1 "$(ran 'Withdraw the reactions on a cancelled run')"
check "took the eyes only" 1 "$(calls delete)"
check "EARLIER THUMB SURVIVES" "$BOT:+1" "$(left)"

echo "== the same, beside a human's =="
run_case rerun-cancelled-human \
  '[{"id":51,"content":"+1","user":{"login":"github-actions[bot]"}},
    {"id":23,"content":"-1","user":{"login":"brandon"}}]' \
  cancelled cancelled - - '' no
check "left"  "brandon:-1 $BOT:+1" "$(left)"

echo "== but once this run has answered, every reaction on the comment is its own =="
run_case rerun-answered-then-cancelled "$EARLIER_THUMB" success cancelled - success true yes
check "answer ran"     1 "$(ran 'Answer the request')"
check "withdraw ran"   1 "$(ran 'Withdraw the reactions on a cancelled run')"
check "left"           "" "$(left)"

echo "== a partial answer clears: it most likely took the earlier thumb already =="
run_case rerun-answer-failed "$EARLIER_THUMB" cancelled cancelled - - '' no ANSWERED_AS=failure
check "left"  "" "$(left)"
run_case rerun-answer-cancelled "$EARLIER_THUMB" cancelled cancelled - - '' no ANSWERED_AS=cancelled
check "left"  "" "$(left)"

echo "== an outcome the step cannot read clears: a thumb standing for nothing is worse =="
run_case rerun-answer-unreported "$EARLIER_THUMB" cancelled cancelled - - '' no ANSWERED_AS=
check "left"  "" "$(left)"

echo "== and it survives beside a human's reactions =="
run_case cancelled-after-publish-human \
  '[{"id":21,"content":"-1","user":{"login":"brandon"}}]' \
  success cancelled true success true yes
check "left"        "brandon:-1 $BOT:+1" "$(left)"

echo "== a human's reaction survives every path =="
run_case success-human "$HUMAN_ALL" success success true success true yes
check "left"  "brandon:+1 brandon:-1 brandon:eyes $BOT:+1" "$(left)"
run_case failure-human "$HUMAN_ALL" success success true failure true yes
check "left"  "brandon:+1 brandon:-1 brandon:eyes $BOT:-1" "$(left)"
run_case noverdict-human "$HUMAN_ALL" success success - failure false yes
check "left"  "brandon:+1 brandon:-1 brandon:eyes" "$(left)"
run_case cancelled-human "$HUMAN_ALL" cancelled cancelled - success true yes
check "left"  "brandon:+1 brandon:-1 brandon:eyes" "$(left)"

echo "== a run that answers replaces the stale thumb; a human's stays =="
run_case stale-thumb "$STALE_DOWN" success success true success true yes
check "left"  "brandon:+1 $BOT:+1" "$(left)"

echo "== a cancelled run that never answered leaves it: the earlier verdict may stand =="
run_case stale-thumb-cancelled "$STALE_DOWN" cancelled cancelled - success true yes
check "left"  "brandon:+1 $BOT:-1" "$(left)"
run_case stale-up-noverdict "$STALE_UP" success success - failure false yes
check "left"  "" "$(left)"

echo "== a reaction no step here chooses is not this job's to withdraw =="
run_case foreign "$FOREIGN" success success true success true yes
check "left"  "brandon:+1 $BOT:+1 $BOT:rocket" "$(left)"
run_case foreign-cancelled "$FOREIGN" cancelled cancelled - success true yes
check "left"  "brandon:+1 $BOT:rocket" "$(left)"

echo "== a refused call warns and never fails the step =="
run_case list-refused '[{"id":21,"content":"+1","user":{"login":"brandon"}}]' \
  success success true success true yes STUB_LIST=FAIL
check "rc"          0 "$(cat "$CASE/rc")"
check "warned"      1 "$(grep -c '::warning::could not read the reactions' "$CASE/step.out")"
check "thumb still" 1 "$(calls post)"
run_case delete-refused "$NONE" success success true success true yes STUB_DELETE=FAIL
check "rc"          0 "$(cat "$CASE/rc")"
check "eyes stay"   "$BOT:+1 $BOT:eyes" "$(left)"
run_case post-refused "$NONE" success success true success true yes STUB_POST=FAIL
check "rc"          0 "$(cat "$CASE/rc")"
check "left"        "" "$(left)"
run_case list-refused-cancelled "$NONE" cancelled cancelled - - '' no STUB_LIST=FAIL
check "rc"          0 "$(cat "$CASE/rc")"
check "warned"      1 "$(grep -c '::warning::could not read the reactions' "$CASE/step.out")"
run_case delete-refused-cancelled "$NONE" cancelled cancelled - - '' no STUB_DELETE=FAIL
check "rc"          0 "$(cat "$CASE/rc")"
check "eyes stay"   "$BOT:eyes" "$(left)"

echo "== the acknowledgement itself refused: no eyes to clear, the answer still lands =="
run_case ack-refused "$NONE" success success true success true yes ACK_POST=FAIL
check "rc"           0 "$(cat "$CASE/rc")"
check "ack warned"   1 "$(grep -c '::warning::could not react to comment' "$CASE/ack.out")"
check "nothing to clear" 0 "$(calls delete)"
check "left"         "$BOT:+1" "$(left)"

echo "== a close reacts nowhere, so nothing is left to clear =="
CASE="$HERE/out-reactions/close-mode"; rm -rf "$CASE"; mkdir -p "$CASE"
check "close selects no step" "" "$($SELECT success close 7 - | paste -sd, -)"
check "cancelled close selects no step" "" "$($SELECT cancelled close 7 false | paste -sd, -)"

echo "== no step made a call the stub does not serve =="
check "unstubbed calls" 0 \
  "$(grep -rh 'CALL UNSTUBBED' "$HERE/out-reactions" 2>/dev/null | wc -l | tr -d ' ')"

echo
printf '%s\n' "${rows[@]}"
echo
echo "assertions: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
