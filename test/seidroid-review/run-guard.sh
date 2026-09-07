#!/usr/bin/env bash
# Runs the guard's shipped step scripts under bash with a gh stub on PATH, and
# evaluates the shipped job conditions with gha.py.
#
# Every script and every condition is read out of the workflow on each run, so a
# run tests what the file says now and cannot pass against a stale copy.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
REPOROOT="$(cd "$HERE/../.." && pwd)"
WORKFLOW="$REPOROOT/.github/workflows/seidroid-review.yml"
ASSISTANT="$REPOROOT/.github/workflows/ai-assistant.yml"
REFUSE="$HERE/refuse.sh"
PARSE="$HERE/parse.sh"
ADMIT="$HERE/admit.sh"
# Named apart from the ack.sh and answer.sh reactions.sh writes. Both harnesses
# extract the same two steps, and a shared path lets one overwrite the other's
# extraction mid-run.
ACK="$HERE/guard-ack.sh"
ANSWER="$HERE/guard-answer.sh"
MARKER="$(python3 "$HERE/extract.py" "$WORKFLOW" "Refuse an event this workflow does not handle" "$REFUSE" VERDICT_MARKER)" || {
  echo "could not read the refusal step out of $WORKFLOW"; exit 1; }
python3 "$HERE/extract.py" "$WORKFLOW" parse "$PARSE" VERDICT_MARKER >/dev/null || {
  echo "could not read the parse step out of $WORKFLOW"; exit 1; }
python3 "$HERE/extract.py" "$WORKFLOW" "Admit the request" "$ADMIT" VERDICT_MARKER >/dev/null || {
  echo "could not read the admission step out of $WORKFLOW"; exit 1; }
python3 "$HERE/extract.py" "$WORKFLOW" "Acknowledge the trigger" "$ACK" VERDICT_MARKER >/dev/null || {
  echo "could not read the acknowledgement step out of $WORKFLOW"; exit 1; }
python3 "$HERE/extract.py" "$WORKFLOW" "Answer the request" "$ANSWER" VERDICT_MARKER >/dev/null || {
  echo "could not read the answering step out of $WORKFLOW"; exit 1; }

mkdir -p "$HERE/out"
CTX="$HERE/out/ctx.json"
PATH="$HERE/bin-guard:$PATH"
export PATH

pass=0 fail=0
check() { # label expected actual
  if [ "$2" = "$3" ]; then pass=$((pass + 1)); else
    fail=$((fail + 1)); echo "  FAIL $1: want [$2] got [$3]"; fi
}

# --- the job conditions -------------------------------------------------------
# One context per case, built here rather than committed: a condition reads six
# payload fields and a context file per case would be six lines of JSON each.
ctx_comment() { # event action login type association allowed-bots
  jq -nc --arg ev "$1" --arg action "$2" --arg login "$3" --arg type "$4" \
    --arg assoc "$5" --arg bots "$6" '
    {github: {event_name: $ev,
              event: {action: $action, pull_request: {number: 7}}},
     inputs: {mode: "review", "allowed-bots": $bots}}
    | .github.event |= (if $ev == "pull_request_review"
        then . + {review: {id: 99, user: {login: $login, type: $type},
                           author_association: $assoc, body: "@seidroid review"}}
        else . + {comment: {id: 42, user: {login: $login, type: $type},
                            author_association: $assoc, body: "@seidroid review"}}
        end)
    | if $ev == "issue_comment"
      then .github.event.issue = {number: 7, pull_request: {url: "https://api/pulls/7"}}
      else . end' > "$CTX"
}

ctx_issue_only() { # an issue_comment on an ISSUE, which carries no pull_request
  ctx_comment issue_comment created alice User MEMBER '[]'
  jq -c '.github.event.issue.pull_request = null' "$CTX" > "$CTX.tmp" && mv "$CTX.tmp" "$CTX"
}

ctx_plain() { # event mode [allowed-bots]
  jq -nc --arg ev "$1" --arg mode "$2" --arg bots "${3-[]}" '
    {github: {event_name: $ev, event: {action: "opened", pull_request: {number: 7}}},
     inputs: {mode: $mode, "allowed-bots": $bots}}' > "$CTX"
}

ctx_needs() { # event mode guard-result should_run
  # The guard's four request outputs, with distinct values, so an assertion on a
  # consumer names which output it read rather than only that it read something.
  jq -nc --arg ev "$1" --arg mode "$2" --arg result "$3" --arg run "$4" '
    {github: {event_name: $ev, event: {pull_request: {number: 7}}},
     inputs: {mode: $mode},
     needs: {guard: {result: $result,
                     outputs: {should_run: $run, pr_number: "7",
                               comment_id: "111", comment_api: "pulls/comments",
                               trigger_id: "222"}}}}' > "$CTX"
}

input_of_file() { # workflow input field
  python3 "$HERE/gha.py" --input "$1" "$2" "$3" 2>/dev/null || printf 'error'
}

input_of() { # input field
  input_of_file "$WORKFLOW" "$1" "$2"
}

env_of() { # step key -- against the context $CTX holds
  python3 "$HERE/gha.py" --env "$WORKFLOW" "$1" "$2" "$CTX" 2>/dev/null || printf 'error'
}

cond() { # job-id
  local out
  if out="$(python3 "$HERE/gha.py" "$WORKFLOW" "$1" "$CTX" 2>/dev/null)"; then
    printf '%s' "$out"
  else
    printf 'error'
  fi
}

# --- the step scripts ---------------------------------------------------------
run_case() { # name script KEY=VALUE...
  local name="$1" script="$2"
  shift 2
  CASE="$HERE/out/$name"
  rm -rf "$CASE"
  mkdir -p "$CASE"
  export STUB_LOG="$CASE/calls.log"; : > "$STUB_LOG"
  export GITHUB_OUTPUT="$CASE/output.txt"; : > "$GITHUB_OUTPUT"
  export VERDICT_MARKER="$MARKER"
  # What `parse` reads.
  export EVENT_NAME=issue_comment
  export BODY='@seidroid review'
  export PR_NUMBER=7
  export COMMENT_ID=42
  export TRIGGER_PHRASE='@seidroid'
  # What `Admit the request` reads.
  export GH_TOKEN=app-token GATE_TOKEN=app-token
  export ALLOWED_TEAM=sei-protocol/sei-core
  export ALLOWED_BOTS='[]'
  export SKIP_LABEL='ai: skip-review'
  export ACTOR=alice ACTOR_TYPE=User
  export REPO=owner/repo PR=7 PARSED=true
  export IS_DRAFT=false ACTION=created RE_REVIEW_ON_PUSH=false MODE=review
  export HEAD_REPO_ID='' BASE_REPO_ID=''
  # What the two reacting steps read.
  export TRIGGER_REPO=owner/repo TRIGGER_ID=42 COMMENT_API=issues/comments
  export CHECK="$CASE/check.json" VERDICT_PRODUCED=true
  printf '%s\n' '{"conclusion":"success"}' > "$CASE/check.json"
  # What the gh stub answers.
  export STUB_TEAM=active STUB_ORIGIN=same STUB_LABELS='' STUB_REVIEWS=none STUB_COMMENTS=none
  export STUB_REACTIONS=none
  for kv in "$@"; do export "${kv?}"; done
  bash "$script" > "$CASE/stdout.txt" 2> "$CASE/stderr.txt"
  echo "$?" > "$CASE/rc"
}

rc() { cat "$CASE/rc"; }
out() { grep -E "^$1=" "$CASE/output.txt" | tail -1 | cut -d= -f2-; }
written() { grep -cE "^$1=" "$CASE/output.txt"; }
calls() { grep -c "^CALL $1" "$CASE/calls.log" || true; }
said() { grep -c -- "$1" "$CASE/stdout.txt" || true; }
cried() { grep -c -- "$1" "$CASE/stderr.txt" || true; }

echo "== 0. the expression model gha.py holds =="
python3 "$HERE/gha.py" --selftest
check "expression model clean" 0 "$?"

echo
echo "== 1. the guard's condition: which requests reach a runner =="
ctx_comment issue_comment created alice User MEMBER '[]'
check "issue_comment, member"                 true  "$(cond guard)"
ctx_comment pull_request_review_comment created alice User MEMBER '[]'
check "diff-thread comment, member"           true  "$(cond guard)"
ctx_comment pull_request_review submitted alice User MEMBER '[]'
check "review body, member"                   true  "$(cond guard)"
ctx_comment pull_request_review_comment edited alice User MEMBER '[]'
check "an edited diff-thread comment"         false "$(cond guard)"
ctx_comment pull_request_review dismissed alice User MEMBER '[]'
check "a dismissed review"                    false "$(cond guard)"
ctx_comment pull_request_review edited alice User MEMBER '[]'
check "an edited review"                      false "$(cond guard)"
ctx_comment pull_request_review submitted mallory User NONE '[]'
check "review body, outsider"                 false "$(cond guard)"
ctx_comment pull_request_review_comment created mallory User NONE '[]'
check "diff-thread comment, outsider"         false "$(cond guard)"
ctx_comment pull_request_review submitted alice User COLLABORATOR '[]'
check "review body, collaborator"             true  "$(cond guard)"
ctx_comment pull_request_review_comment created alice User OWNER '[]'
check "diff-thread comment, owner"            true  "$(cond guard)"
ctx_issue_only
check "a comment on an issue"                 false "$(cond guard)"

echo
echo "== 2. the guard's condition: allowed-bots =="
ctx_comment issue_comment created 'dependabot[bot]' Bot MEMBER '[]'
check "empty list denies a bot"               false "$(cond guard)"
ctx_comment issue_comment created 'dependabot[bot]' Bot NONE '["dependabot[bot]"]'
check "a listed bot"                          true  "$(cond guard)"
ctx_comment issue_comment created 'dependabot[bot]' Bot NONE '["renovate[bot]"]'
check "an unlisted bot"                       false "$(cond guard)"
ctx_comment issue_comment created 'DependaBot[BOT]' Bot NONE '["dependabot[bot]"]'
check "one login, either case"                true  "$(cond guard)"
# `bot` is a substring of every listed login here. A condition that tested the
# input as a STRING would admit it; membership of the parsed array does not.
ctx_comment issue_comment created 'bot' Bot NONE '["dependabot[bot]","renovate[bot]"]'
check "a login inside a listed one"           false "$(cond guard)"
ctx_comment pull_request_review submitted 'dependabot[bot]' Bot NONE '["dependabot[bot]"]'
check "a listed bot in a review body"         true  "$(cond guard)"
ctx_comment pull_request_review_comment created 'dependabot[bot]' Bot NONE '["dependabot[bot]"]'
check "a listed bot in a diff thread"         true  "$(cond guard)"
# A value fromJSON cannot read, on the two requesters that reach it differently.
# The runner short-circuits, so a person is admitted on association before the list
# is parsed at all; a bot is the requester whose admission depends on parsing it. A
# caller wiring error therefore fails the requests it governs and no others.
ctx_comment issue_comment created alice User MEMBER 'not json'
check "a person never reads the list"         true  "$(cond guard)"
ctx_comment issue_comment created 'dependabot[bot]' Bot NONE 'not json'
check "a bot reads it, and it fails loudly"   error "$(cond guard)"
ctx_plain pull_request review 'not json'
check "an automatic review never reads it"    true  "$(cond guard)"
# An UNSET input, which is the likelier accident: a workflow_call default applies
# only to an input the caller omits, so `allowed-bots: ${{ vars.UNSET }}` arrives as
# the empty string and fromJSON('') is not []. Empty has to read as the documented
# default -- deny every bot -- rather than take the run down.
ctx_comment issue_comment created 'dependabot[bot]' Bot NONE ''
check "an unset list denies every bot"        false "$(cond guard)"
ctx_comment issue_comment created 'dependabot[bot]' Bot MEMBER ''
check "and association is no way round it"    false "$(cond guard)"
ctx_comment issue_comment created alice User MEMBER ''
check "and a person is still admitted"        true  "$(cond guard)"
ctx_plain pull_request review ''
check "and an automatic review still runs"    true  "$(cond guard)"

echo
echo "== 3. the guard's condition: the events it does not handle =="
ctx_plain pull_request_target review
check "pull_request_target reaches the guard" true  "$(cond guard)"
ctx_plain push review
check "push reaches the guard"                true  "$(cond guard)"
ctx_plain workflow_dispatch review
check "workflow_dispatch reaches the guard"   true  "$(cond guard)"
ctx_plain pull_request review
check "an automatic review"                   true  "$(cond guard)"
# A pull_request close skips this guard, and the review job reads that skip as
# its own trigger. Admitting it here would break the only path that reclaims a
# sandbox.
ctx_plain pull_request close
check "a pull_request close skips the guard"  false "$(cond guard)"

echo
echo "== 4. the review job's condition =="
ctx_needs issue_comment review success true
check "issue_comment, admitted"               true  "$(cond review)"
ctx_needs pull_request_review_comment review success true
check "diff-thread comment, admitted"         true  "$(cond review)"
ctx_needs pull_request_review review success true
check "review body, admitted"                 true  "$(cond review)"
ctx_needs pull_request_review review success false
check "review body, refused"                  false "$(cond review)"
ctx_needs pull_request_review_comment review failure ''
check "diff-thread comment, guard failed"     false "$(cond review)"
ctx_needs pull_request_target review failure ''
check "pull_request_target never reviews"     false "$(cond review)"
ctx_needs pull_request review success true
check "an automatic review, admitted"         true  "$(cond review)"
ctx_needs pull_request close skipped ''
check "a pull_request close still runs"       true  "$(cond review)"

echo
echo "== 5. the refusal: an event this workflow does not handle =="
run_case refuse-target "$REFUSE" EVENT_NAME=pull_request_target
check "rc"                                    1 "$(rc)"
check "names the event"                       1 "$(cried pull_request_target)"
check "says why"                              1 "$(cried "base repository's secrets")"
check "names the four it handles"             1 "$(cried "pull_request, issue_comment, pull_request_review_comment or pull_request_review")"
run_case refuse-push "$REFUSE" EVENT_NAME=push
check "rc"                                    1 "$(rc)"
check "names the event"                       1 "$(cried "cannot be called from 'push'")"
check "names the four it handles"             1 "$(cried "pull_request, issue_comment, pull_request_review_comment and pull_request_review")"
run_case refuse-dispatch "$REFUSE" EVENT_NAME=workflow_dispatch
check "rc"                                    1 "$(rc)"
check "names the event"                       1 "$(cried workflow_dispatch)"
for ev in pull_request issue_comment pull_request_review_comment pull_request_review; do
  run_case "refuse-ok-$ev" "$REFUSE" "EVENT_NAME=$ev"
  check "$ev passes"                          0 "$(rc)"
  check "$ev says nothing"                    0 "$(cried '::')"
done

echo
echo "== 6. the parse: which body is a command, and what it resolves to =="
run_case parse-issue "$PARSE" EVENT_NAME=issue_comment
check "should_run"                            true              "$(out should_run)"
check "comment_id"                            42                "$(out comment_id)"
check "comment_api"                           issues/comments   "$(out comment_api)"
check "trigger_id"                            42                "$(out trigger_id)"
run_case parse-thread "$PARSE" EVENT_NAME=pull_request_review_comment
check "should_run"                            true              "$(out should_run)"
check "comment_id"                            42                "$(out comment_id)"
check "comment_api"                           pulls/comments    "$(out comment_api)"
check "trigger_id"                            42                "$(out trigger_id)"
run_case parse-review "$PARSE" EVENT_NAME=pull_request_review COMMENT_ID=99
check "should_run"                            true              "$(out should_run)"
check "comment_id held back"                  ''                "$(out comment_id)"
check "comment_id written once"               1                 "$(written comment_id)"
check "comment_api held back"                 ''                "$(out comment_api)"
# The log id is a different fact from the reactable id, and this is the event where
# they differ: nothing can react on a review, but the run still has a request to name.
check "trigger_id still carries the id"       99                "$(out trigger_id)"
check "says the request earns no reaction"    1                 "$(said 'carries no reactions endpoint')"
run_case parse-auto "$PARSE" EVENT_NAME=pull_request BODY=''
check "should_run"                            true              "$(out should_run)"
check "comment_id"                            ''                "$(out comment_id)"
check "comment_api written"                   1                 "$(written comment_api)"
check "trigger_id"                            ''                "$(out trigger_id)"
run_case parse-bare "$PARSE" BODY='seidroid review'
check "the bare phrase still asks"            true              "$(out should_run)"
run_case parse-prose "$PARSE" BODY='Do we need @seidroid review on this one?'
check "prose about the command"               false             "$(out should_run)"
run_case parse-close "$PARSE" BODY='@seidroid review close'
check "a close"                               true              "$(out should_run)"
run_case parse-multiline "$PARSE" BODY='Looks good otherwise.
@seidroid review
Thanks!'
check "a command on its own line"             true              "$(out should_run)"
run_case parse-target "$PARSE" BODY='@seidroid review owner/repo#5'
check "a named repository"                    false             "$(out should_run)"
check "and it says so"                        1                 "$(said 'takes no repository target')"
run_case parse-padded "$PARSE" BODY='   @seidroid   review   '
check "padding around the command"            true              "$(out should_run)"
run_case parse-suffix "$PARSE" BODY='@seidroidX review'
check "a longer login"                        false             "$(out should_run)"
run_case parse-target-own "$PARSE" TRIGGER_PHRASE='@mybot' BODY='@mybot review owner/repo#5'
check "a named repository, own phrase"        false             "$(out should_run)"
check "and it says so"                        1                 "$(said 'takes no repository target')"

echo
echo "== 7. the parse: a caller's own trigger phrase =="
run_case phrase-own "$PARSE" TRIGGER_PHRASE='@mybot' BODY='@mybot review'
check "the phrase the caller set"             true  "$(out should_run)"
check "no warning"                            0     "$(said '::warning')"
run_case phrase-not-default "$PARSE" TRIGGER_PHRASE='@mybot' BODY='@seidroid review'
check "and not the default"                   false "$(out should_run)"
run_case phrase-hyphen "$PARSE" TRIGGER_PHRASE='@sei-droid' BODY='@sei-droid review'
check "a hyphen is part of the phrase"        true  "$(out should_run)"
check "no warning"                            0     "$(said '::warning')"
run_case phrase-bare-ok "$PARSE" TRIGGER_PHRASE='mybot' BODY='mybot review'
check "a phrase written without the @"        true  "$(out should_run)"
run_case phrase-case "$PARSE" TRIGGER_PHRASE='@Seidroid' BODY='@Seidroid review'
check "the phrase is matched as written"      true  "$(out should_run)"
run_case phrase-case-other "$PARSE" TRIGGER_PHRASE='@Seidroid' BODY='@seidroid review'
check "and not in another case"               false "$(out should_run)"
# A `.` reaching the pattern unconstrained matches any character, so `@myXbot`
# would ask for a review under a phrase nobody configured.
run_case phrase-dot "$PARSE" TRIGGER_PHRASE='@my.bot' BODY='@myXbot review'
check "a dot cannot stand for a character"    false "$(out should_run)"
check "and the phrase is refused"             1     "$(said "trigger-phrase '@my.bot' is not")"
run_case phrase-dot-fallback "$PARSE" TRIGGER_PHRASE='@my.bot' BODY='@seidroid review'
check "the default takes over"                true  "$(out should_run)"
# A `|` reaching the pattern unconstrained splits it into two alternatives, and
# the first is `^[[:space:]]*@?a` -- which any line starting with `a` matches.
run_case phrase-pipe "$PARSE" TRIGGER_PHRASE='@a|b' BODY='a note about the diff'
check "a pipe cannot widen the match"         false "$(out should_run)"
check "and the phrase is refused"             1     "$(said "trigger-phrase '@a|b' is not")"
run_case phrase-pipe-fallback "$PARSE" TRIGGER_PHRASE='@a|b' BODY='@seidroid review'
check "the default takes over"                true  "$(out should_run)"
run_case phrase-empty "$PARSE" TRIGGER_PHRASE='' BODY='@seidroid review'
check "an empty phrase falls back"            true  "$(out should_run)"
check "and says so"                           1     "$(said "trigger-phrase '' is not")"
run_case phrase-space "$PARSE" TRIGGER_PHRASE='@my bot' BODY='@seidroid review'
check "a phrase with a space falls back"      true  "$(out should_run)"
run_case phrase-at-only "$PARSE" TRIGGER_PHRASE='@' BODY='@seidroid review'
check "a bare @ falls back"                   true  "$(out should_run)"

echo
echo "== 8. the admission: who may ask, on every comment path =="
run_case admit-member "$ADMIT" EVENT_NAME=issue_comment
check "admit"                                 true  "$(out admit)"
check "the team was read"                     1     "$(calls membership)"
run_case admit-thread "$ADMIT" EVENT_NAME=pull_request_review_comment
check "admit"                                 true  "$(out admit)"
check "the team was read"                     1     "$(calls membership)"
check "the origin was read"                   1     "$(calls origin)"
check "the labels were read"                  1     "$(calls labels)"
run_case admit-reviewbody "$ADMIT" EVENT_NAME=pull_request_review
check "admit"                                 true  "$(out admit)"
check "the team was read"                     1     "$(calls membership)"
check "the origin was read"                   1     "$(calls origin)"
check "the labels were read"                  1     "$(calls labels)"
run_case admit-pending "$ADMIT" EVENT_NAME=issue_comment STUB_TEAM=pending
check "admit"                                 false "$(out admit)"
check "and names the team"                    1     "$(said 'not an active member of sei-protocol/sei-core')"
run_case admit-thread-pending "$ADMIT" EVENT_NAME=pull_request_review_comment STUB_TEAM=pending
check "a diff thread is no way round it"      false "$(out admit)"
run_case admit-review-pending "$ADMIT" EVENT_NAME=pull_request_review STUB_TEAM=pending
check "a review body is no way round it"      false "$(out admit)"
run_case admit-team-fail "$ADMIT" EVENT_NAME=pull_request_review STUB_TEAM=FAIL
check "a membership read that fails"          false "$(out admit)"
run_case admit-no-team "$ADMIT" EVENT_NAME=pull_request_review ALLOWED_TEAM=''
check "an empty team denies"                  false "$(out admit)"
check "and reads nothing"                     0     "$(calls membership)"
run_case admit-no-app "$ADMIT" EVENT_NAME=pull_request_review_comment GH_TOKEN=''
check "no App identity denies"                false "$(out admit)"
check "and names the two secrets"             1     "$(said 'SEIDROID_APP_ID and SEIDROID_APP_PRIVATE_KEY')"
check "and reads nothing"                     0     "$(calls membership)"

echo
echo "== 9. the admission: a bot is held to allowed-bots =="
run_case bot-listed "$ADMIT" ACTOR='dependabot[bot]' ACTOR_TYPE=Bot ALLOWED_BOTS='["dependabot[bot]"]'
check "admit"                                 true  "$(out admit)"
check "the team is not read for a bot"        0     "$(calls membership)"
run_case bot-case "$ADMIT" ACTOR='DependaBot[BOT]' ACTOR_TYPE=Bot ALLOWED_BOTS='["dependabot[bot]"]'
check "one login, either case"                true  "$(out admit)"
run_case bot-type-case "$ADMIT" ACTOR='dependabot[bot]' ACTOR_TYPE=bot ALLOWED_BOTS='["dependabot[bot]"]'
check "the type is read either case"          true  "$(out admit)"
check "the team is not read"                  0     "$(calls membership)"
run_case bot-unlisted "$ADMIT" ACTOR='renovate[bot]' ACTOR_TYPE=Bot ALLOWED_BOTS='["dependabot[bot]"]'
check "an unlisted bot"                       false "$(out admit)"
check "and names the input"                   1     "$(said 'is not in allowed-bots')"
check "and reads no team"                     0     "$(calls membership)"
run_case bot-empty-list "$ADMIT" ACTOR='dependabot[bot]' ACTOR_TYPE=Bot ALLOWED_BOTS='[]'
check "the default list denies"               false "$(out admit)"
run_case bot-substring "$ADMIT" ACTOR='bot' ACTOR_TYPE=Bot ALLOWED_BOTS='["dependabot[bot]"]'
check "a login inside a listed one"           false "$(out admit)"
run_case bot-prefix "$ADMIT" ACTOR='dependabot[bot]x' ACTOR_TYPE=Bot ALLOWED_BOTS='["dependabot[bot]"]'
check "a login that extends a listed one"     false "$(out admit)"
run_case bot-not-json "$ADMIT" ACTOR='dependabot[bot]' ACTOR_TYPE=Bot ALLOWED_BOTS='not json'
check "a list that is not JSON"               false "$(out admit)"
run_case bot-not-array "$ADMIT" ACTOR='dependabot[bot]' ACTOR_TYPE=Bot ALLOWED_BOTS='"dependabot[bot]"'
check "a string where an array belongs"       false "$(out admit)"
run_case bot-numbers "$ADMIT" ACTOR='123' ACTOR_TYPE=Bot ALLOWED_BOTS='[123]'
check "a list of numbers matches nothing"     false "$(out admit)"
run_case bot-no-actor "$ADMIT" ACTOR='' ACTOR_TYPE=Bot ALLOWED_BOTS='["dependabot[bot]"]'
check "an empty login matches nothing"        false "$(out admit)"
run_case bot-null-list "$ADMIT" ACTOR='dependabot[bot]' ACTOR_TYPE=Bot ALLOWED_BOTS='[null]'
check "a list of nulls matches nothing"       false "$(out admit)"
run_case bot-review "$ADMIT" EVENT_NAME=pull_request_review ACTOR='dependabot[bot]' ACTOR_TYPE=Bot \
  ALLOWED_BOTS='["dependabot[bot]"]'
check "a listed bot in a review body"         true  "$(out admit)"
run_case bot-thread "$ADMIT" EVENT_NAME=pull_request_review_comment ACTOR='dependabot[bot]' ACTOR_TYPE=Bot \
  ALLOWED_BOTS='["dependabot[bot]"]'
check "a listed bot in a diff thread"         true  "$(out admit)"
run_case bot-fork "$ADMIT" ACTOR='dependabot[bot]' ACTOR_TYPE=Bot ALLOWED_BOTS='["dependabot[bot]"]' \
  STUB_ORIGIN=fork
check "a listed bot still meets the fork check" false "$(out admit)"
run_case bot-label "$ADMIT" ACTOR='dependabot[bot]' ACTOR_TYPE=Bot ALLOWED_BOTS='["dependabot[bot]"]' \
  STUB_LABELS='ai: skip-review'
check "a listed bot still meets the label"    false "$(out admit)"

echo
echo "== 10. the admission: the rules that were already there, on the new paths =="
run_case fork-thread "$ADMIT" EVENT_NAME=pull_request_review_comment STUB_ORIGIN=fork
check "a fork in a diff thread"               false "$(out admit)"
check "and names the refusal"                 1     "$(said 'explicit re-reviews are disabled for fork-originated')"
run_case fork-review "$ADMIT" EVENT_NAME=pull_request_review STUB_ORIGIN=fork
check "a fork in a review body"               false "$(out admit)"
run_case fork-unreadable "$ADMIT" EVENT_NAME=pull_request_review STUB_ORIGIN=FAIL
check "an origin nobody could read"           false "$(out admit)"
check "and says a fork is not ruled out"      1     "$(said 'could not read where owner/repo#7 comes from')"
run_case fork-null-head "$ADMIT" EVENT_NAME=pull_request_review_comment STUB_ORIGIN=null
check "a null head repository reads as a fork" false "$(out admit)"
run_case label-thread "$ADMIT" EVENT_NAME=pull_request_review_comment STUB_LABELS='ai: skip-review'
check "the skip label in a diff thread"       false "$(out admit)"
check "and names the label"                   1     "$(said 'carries ai: skip-review')"
run_case label-review "$ADMIT" EVENT_NAME=pull_request_review STUB_LABELS='ai: skip-review'
check "the skip label in a review body"       false "$(out admit)"
run_case label-other "$ADMIT" EVENT_NAME=pull_request_review STUB_LABELS='needs-rebase,ai: nitpick'
check "another label admits"                  true  "$(out admit)"
run_case label-fail "$ADMIT" EVENT_NAME=pull_request_review STUB_LABELS=FAIL
check "a label read that fails"               false "$(out admit)"
check "and names both fixes"                  1     "$(said 'Grant pull-requests: read on the calling job')"
run_case gate-review "$ADMIT" EVENT_NAME=pull_request_review STUB_COMMENTS=verdict
check "a review already ran, asked by name"   true  "$(out admit)"
check "and the gate reads nothing"            0     "$(calls comments)"
run_case gate-thread "$ADMIT" EVENT_NAME=pull_request_review_comment STUB_COMMENTS=verdict
check "the same from a diff thread"           true  "$(out admit)"
run_case not-parsed "$ADMIT" EVENT_NAME=pull_request_review PARSED=false
check "a body that is no command"             false "$(out admit)"
check "and reads nothing at all"              0     "$(( $(calls membership) + $(calls origin) + $(calls labels) ))"

echo
echo "== 11. the admission: the paths that were already there =="
run_case close-bot "$ADMIT" MODE=close ACTOR='renovate[bot]' ACTOR_TYPE=Bot ALLOWED_BOTS='[]'
check "a teardown is not refused"             true  "$(out admit)"
check "and checks nothing"                    0     "$(( $(calls membership) + $(calls origin) + $(calls labels) ))"
run_case close-outsider "$ADMIT" MODE=close STUB_TEAM=pending STUB_ORIGIN=fork STUB_LABELS='ai: skip-review'
check "a teardown from outside the team"      true  "$(out admit)"
run_case auto-draft "$ADMIT" EVENT_NAME=pull_request IS_DRAFT=true ACTION=opened BASE_REPO_ID=1 HEAD_REPO_ID=1
check "a draft"                               false "$(out admit)"
check "and names it"                          1     "$(said 'is a draft; not reviewing')"
run_case auto-first "$ADMIT" EVENT_NAME=pull_request ACTION=opened BASE_REPO_ID=1 HEAD_REPO_ID=1
check "a first automatic review"              true  "$(out admit)"
check "and reads no team"                     0     "$(calls membership)"
run_case auto-again "$ADMIT" EVENT_NAME=pull_request ACTION=synchronize BASE_REPO_ID=1 HEAD_REPO_ID=1 \
  STUB_COMMENTS=verdict
check "a push after a verdict"                false "$(out admit)"
check "and points at the comment"             1     "$(said 'comment @seidroid review to ask for one')"
run_case auto-fork "$ADMIT" EVENT_NAME=pull_request ACTION=opened BASE_REPO_ID=1 HEAD_REPO_ID=2
check "a fork pull request"                   false "$(out admit)"
check "and spends no API call"                0     "$(calls origin)"

echo
echo "== 12. the payload field each step reads, per event =="
ctx_comment issue_comment created alice User MEMBER '[]'
check "parse reads the comment body"          '@seidroid review' "$(env_of parse BODY)"
check "parse reads the comment id"            42    "$(env_of parse COMMENT_ID)"
check "parse reads the pull request number"   7     "$(env_of parse PR_NUMBER)"
check "admit reads the commenter"             alice "$(env_of "Admit the request" ACTOR)"
check "admit reads the commenter's type"      User  "$(env_of "Admit the request" ACTOR_TYPE)"
ctx_comment pull_request_review_comment created alice User MEMBER '[]'
check "parse reads the thread comment body"   '@seidroid review' "$(env_of parse BODY)"
check "parse reads the thread comment id"     42    "$(env_of parse COMMENT_ID)"
check "parse reads the pull request number"   7     "$(env_of parse PR_NUMBER)"
check "admit reads the commenter"             alice "$(env_of "Admit the request" ACTOR)"
ctx_comment pull_request_review submitted alice User MEMBER '[]'
# The review event names none of these under `comment`, so a step reading that
# key alone would see an empty body, parse no command, and refuse in silence.
check "parse reads the review body"           '@seidroid review' "$(env_of parse BODY)"
check "parse reads the review id"             99    "$(env_of parse COMMENT_ID)"
check "parse reads the pull request number"   7     "$(env_of parse PR_NUMBER)"
check "admit reads the reviewer"              alice "$(env_of "Admit the request" ACTOR)"
check "admit reads the reviewer's type"       User  "$(env_of "Admit the request" ACTOR_TYPE)"
ctx_comment pull_request_review submitted 'dependabot[bot]' Bot NONE '["dependabot[bot]"]'
check "admit reads a review bot's login"      'dependabot[bot]' "$(env_of "Admit the request" ACTOR)"
check "admit reads a review bot's type"       Bot   "$(env_of "Admit the request" ACTOR_TYPE)"

echo
echo "== 12b. each consumer reads the output meant for it =="
ctx_needs issue_comment review success true
check "the driver labels with trigger_id"     222 \
  "$(env_of "Drive session + collect verdict" TRIGGER_ID)"
check "the acknowledgement reacts on comment_id" 111 \
  "$(env_of "Acknowledge the trigger" TRIGGER_ID)"
check "and on the collection beside it"       pulls/comments \
  "$(env_of "Acknowledge the trigger" COMMENT_API)"
check "the answer reads the same two"         "111 pulls/comments" \
  "$(env_of "Answer the request" TRIGGER_ID) $(env_of "Answer the request" COMMENT_API)"
check "so does the withdrawal"                "111 pulls/comments" \
  "$(env_of "Withdraw the reactions on a cancelled run" TRIGGER_ID) $(env_of "Withdraw the reactions on a cancelled run" COMMENT_API)"

echo
echo "== 13. the defaults a caller inherits =="
check "trigger-phrase default"  '@seidroid' "$(input_of trigger-phrase default)"
check "trigger-phrase optional" false       "$(input_of trigger-phrase required)"
check "allowed-bots default"    '[]'        "$(input_of allowed-bots default)"
check "allowed-bots optional"   false       "$(input_of allowed-bots required)"
check "allowed-team default"    'sei-protocol/sei-core' "$(input_of allowed-team default)"

echo
echo "== 14. the acknowledgement lands on the object that asked =="
run_case ack-issue "$ACK" COMMENT_API=issues/comments TRIGGER_ID=42
check "the issue comments collection" \
  "CALL reaction POST repos/owner/repo/issues/comments/42/reactions" "$(cat "$CASE/calls.log")"
check "and reports it"                        1 "$(said 'acknowledged comment 42')"
run_case ack-thread "$ACK" COMMENT_API=pulls/comments TRIGGER_ID=77
check "the pull comments collection" \
  "CALL reaction POST repos/owner/repo/pulls/comments/77/reactions" "$(cat "$CASE/calls.log")"
run_case ack-fails "$ACK" COMMENT_API=pulls/comments STUB_REACTIONS=FAIL
check "a reaction that does not post warns"   1 "$(said '::warning::could not react to comment 42')"
check "and the review goes on"                0 "$(rc)"

echo
echo "== 15. the answer withdraws from the same collection =="
run_case answer-issue "$ANSWER" COMMENT_API=issues/comments STUB_REACTIONS=eyes
check "read from the issue collection"        1 \
  "$(grep -c '^CALL reaction GET repos/owner/repo/issues/comments/42/reactions' "$CASE/calls.log")"
check "withdrew the eyes there"               1 \
  "$(grep -c '^CALL reaction DELETE repos/owner/repo/issues/comments/42/reactions/1' "$CASE/calls.log")"
check "and thumbed up there"                  1 \
  "$(grep -c '^CALL reaction POST repos/owner/repo/issues/comments/42/reactions' "$CASE/calls.log")"
run_case answer-thread "$ANSWER" COMMENT_API=pulls/comments STUB_REACTIONS=eyes
check "read from the pull collection"         1 \
  "$(grep -c '^CALL reaction GET repos/owner/repo/pulls/comments/42/reactions' "$CASE/calls.log")"
check "withdrew the eyes there"               1 \
  "$(grep -c '^CALL reaction DELETE repos/owner/repo/pulls/comments/42/reactions/1' "$CASE/calls.log")"
check "and thumbed up there"                  1 \
  "$(grep -c '^CALL reaction POST repos/owner/repo/pulls/comments/42/reactions' "$CASE/calls.log")"
check "nothing reached the other collection"  0 "$(grep -c 'issues/comments' "$CASE/calls.log")"

echo
echo "== 16. what ai-assistant.yml claims of the same body, on every event =="
# The two tools read one comment, on the same three events. This group evaluates the
# assistant's own reply condition beside the parse above, so which of them answers a
# given body is measured rather than reasoned about. Both conditions read one phrase,
# and the reasoning holds only while the two defaults agree.
check "the assistant takes the same phrase" '@seidroid' "$(input_of_file "$ASSISTANT" trigger-phrase default)"
claims() { # event body -- true when the assistant's reply job would run
  # Per event, because the assistant has a branch each and this branch keys on the
  # payload key the event populates. A helper that named one event would measure the
  # overlap on the path that already had it, and infer the two this workflow adds.
  jq -nc --arg ev "$1" --arg b "$2" '
    {github: {event_name: $ev, event: {}},
     inputs: {"trigger-phrase": "@seidroid"}}
    | .github.event |= (if $ev == "pull_request_review"
        then {review: {body: $b, user: {type: "User"}}}
        else {comment: {body: $b, user: {type: "User"}}} end)
    | if $ev == "issue_comment"
      then .github.event.issue = {number: 7, pull_request: {url: "u"}}
      else . end' > "$CTX"
  python3 "$HERE/gha.py" "$ASSISTANT" reply "$CTX" 2>/dev/null || printf 'error'
}
# Every body is checked on all three events, because this workflow now answers all
# three and the division of labour has to hold on each.
for ev in issue_comment pull_request_review_comment pull_request_review; do
  # The bare form is the widening this workflow keeps. The assistant needs the @ to
  # claim a body at all, so nothing else answers it, on any event.
  run_case "claim-bare-$ev" "$PARSE" "EVENT_NAME=$ev" BODY='seidroid review'
  check "$ev bare: this workflow"             true  "$(out should_run)"
  check "$ev bare: the assistant"             false "$(claims "$ev" 'seidroid review')"
  run_case "claim-exact-$ev" "$PARSE" "EVENT_NAME=$ev" BODY='@seidroid review'
  check "$ev exact: this workflow"            true  "$(out should_run)"
  check "$ev exact: the assistant"            false "$(claims "$ev" '@seidroid review')"
  run_case "claim-prose-$ev" "$PARSE" "EVENT_NAME=$ev" BODY='Do we need @seidroid review here?'
  check "$ev prose: this workflow"            false "$(out should_run)"
  check "$ev prose: the assistant"            true  "$(claims "$ev" 'Do we need @seidroid review here?')"
  # Two bodies both tools answer. Whole-line anchoring is what admits the second, and
  # it is also what keeps the prose above from starting a review, so the overlap is
  # the price of that. The assistant reserves the exact body, and neither of these is
  # it. This branch widens both onto the two events it adds, which is why each is
  # asserted per event rather than once.
  run_case "claim-close-$ev" "$PARSE" "EVENT_NAME=$ev" BODY='@seidroid review close'
  check "$ev close: this workflow"            true  "$(out should_run)"
  check "$ev close: the assistant too"        true  "$(claims "$ev" '@seidroid review close')"
  run_case "claim-multiline-$ev" "$PARSE" "EVENT_NAME=$ev" BODY='Looks good.
@seidroid review
Thanks!'
  check "$ev amid prose: this workflow"       true  "$(out should_run)"
  check "$ev amid prose: the assistant too"   true  "$(claims "$ev" 'Looks good.
@seidroid review
Thanks!')"
done
# A review with no body at all. The assistant names that case; this workflow reads an
# empty body as no command.
run_case claim-empty-review "$PARSE" EVENT_NAME=pull_request_review BODY=''
check "an empty review body: this workflow"   false "$(out should_run)"
check "an empty review body: the assistant"   false "$(claims pull_request_review '')"

echo
echo "assertions: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
