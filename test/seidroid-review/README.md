# Workflow tests

Five harnesses over `.github/workflows/seidroid-review.yml`. All five read the
steps out of the YAML on every run, so none can pass against a stale copy.

```sh
test/seidroid-review/run.sh        # placement and thread resolution
test/seidroid-review/reactions.sh  # the three reaction steps
test/seidroid-review/run-guard.sh  # the guard, and the reaction collection
test/seidroid-review/decision.sh   # which review event the position step records
python3 test/seidroid-review/conditions.py .github/workflows/seidroid-review.yml
python3 test/seidroid-review/deadline.py   .github/workflows/seidroid-review.yml
```

Each needs `bash`, `jq`, and `python3` with PyYAML, and exits non-zero on the
first failed assertion count.

`extract.py` is shared. It reads a step's `run:` block and a workflow-level env
key out of the YAML, by step name or step id.

`reactions.sh` and `run-guard.sh` both extract `Acknowledge the trigger` and
`Answer the request`, and they ask different things of them: `reactions.sh` asks
which step runs in which job state and what it leaves on the comment,
`run-guard.sh` asks which REST collection the URL reaches. Each writes its own
extraction — `ack.sh` and `answer.sh` against `guard-ack.sh` and
`guard-answer.sh` — so running both cannot have one overwrite the other.

## `Place findings on the code` and `Resolve the threads this review closed`

Runs both steps under `bash`, against a `gh` stub, and checks what they posted,
counted and closed. It prints a table of one row per case.

Both steps are in one harness because they are one behaviour. Placement records
which thread each posted comment replaced; the resolve step closes a thread on
finding its id in that record. A harness that ran only one of them could not
tell whether the record it wrote is the record the other reads.

The extractor runs twice, once per step, and the two `FINDING_MARKER` readings
are asserted equal: placement stamps a comment with it and the resolve step
recognises a thread by it.

`bin/gh` goes on `PATH` ahead of the real `gh`. It logs every call, serves
fixture JSON through the step's own `jq`, keeps the request body the step sent,
and decides per case whether a call succeeds. `STUB_*` variables in `run_case`
and `run_resolve` select the fixtures and the answers.

### The fixtures

`fx/files*.json` are `GET /compare` responses. One JSON object each: compare
paginates its commits, and a second page carries no `files` key, so the step
reads one page.

- `files.json` — four files, two with a patch, two without
- `files-short.json` — the same diff with `pkg/b.go` missing, which is what a
  truncated response looks like
- `files-stale.json` — a different commit's diff, for the pushed-head case

`fx/line-ok.tsv` and `fx/file-ok.txt` list the `path`/`side`/`line` and the
paths the stub accepts. A finding outside them is refused, which is how the
per-finding ladder is exercised.

`fx/superseded*.json` are findings files carrying the driver's `supersedes`
linkage. `fx/all-placeable.json` carries it on no finding, which is what a
driver older than the linkage writes.

`fx/check-*.json` are the driver's `check.json`, one per thread plan the resolve
step has to act on. The review threads themselves are generated in `run.sh`,
because every body has to open with the marker the workflow defines now: two
pages, and four threads that fail this step's own tests — the other identity, a
foreign account, no marker, and a marker quoted mid-body.

## The reaction steps

`reactions.sh` runs `Acknowledge the trigger`, `Answer the request` and
`Withdraw the reactions on a cancelled run` against `bin-reactions/gh`, which keeps
the reaction list a comment carries and serves it through the step's own `jq`. Each
case reports the exact set left on the trigger comment.

No case names the step it runs. `conditions.py --select` names it, from the job state
and from `Post the verdict`'s outcome, so the two harnesses cannot drift and a case
cannot quietly stop exercising the step it claims to.

Each case declares **two** job states, because a cancellation has a moment: the state
the runner reached `Answer the request` in, and the state it reached the withdrawal step
in. `success>cancelled` is a cancellation that arrived after the answer. The answer step
then posts its own thumb, so a late-cancellation case proves the outcome through the
steps rather than placing a reaction by hand.

A case's `posted` column is `Post the verdict`'s own output: `true` when its comment
landed, `false` when the POST was refused, unreported when that step never ran. Not its
outcome. That step tolerates a refused POST and exits 0 either way, so its outcome reads
`success` on a verdict that never landed, and a thumb kept on that reading would stand
for a review nobody can see.

Four properties every case holds to. A human's reaction is never withdrawn. Neither is
a reaction of this bot's that no step here chooses, so a `rocket` some other workflow
left survives. A thumb that answers a verdict already on the pull request survives a
later cancellation. And a run cancelled before it reached `Answer the request` takes
only the eyes: a thumb on the comment then belongs to an EARLIER run, whose verdict may
still stand.

## The step conditions

`conditions.py` covers what a shell harness cannot see. A step condition decides which
reaction step runs in which job state, and that is where the cancellation behaviour
lives. `Answer the request` reads a conclusion and may thumb the request, so it must
skip a cancelled run. The withdrawal step must take a cancelled run, unless
`Post the verdict` landed its comment.

It models the runner's own rule that a condition naming none of
`always`/`cancelled`/`failure`/`success` is stored as `success() && (...)`, and treats
any term it does not decide as unknown rather than as false.

Three checks are stated over the file rather than over a table, so they cover a step
added later. The two that walk steps walk **every job's raw steps list**, so an unnamed
step is not invisible to them, and both search the **whole step** rather than one key:

- No step that can run on a cancelled job may reach `check_path` or
  `verdict_produced`. An inline `${{ steps.drive.outputs.check_path }}` in `run:`,
  `with:` or `if:` reaches the same value an `env:` key would.
- Every `steps.<id>` a step reads must be a real id on an earlier step. Delete the id,
  or move the reader in front of it, and the read is empty forever with no error
  anywhere — and a harness that takes the value as an argument cannot notice.
- The withdrawal is the **last** step of the review job. The runner evaluates a
  condition when it reaches the step, so any step after the withdrawal is a step during
  which a cancellation leaves the eyes standing. Checking the position covers a step
  appended later; mutating one ordering would not.

No check needs telling where to look. A check that has to be pointed at a step is not
stated over the file.

## The guard, and the two steps that react

Runs the request-admission path under `bash` against a `gh` stub of its own, and
evaluates the shipped job conditions against synthetic event payloads. Five
steps are read: `Refuse an event this workflow does not handle`, `parse`, `Admit
the request`, `Acknowledge the trigger` and `Answer the request`.

`gha.py` covers what a script harness cannot see. A job condition and a step's
`env:` mapping are GitHub expressions, and both decide which payload field a
request is read from, so both are evaluated here rather than restated. It models
four GitHub semantics the conditions rest on — case-insensitive string
comparison, `||` and `&&` yielding one operand each, **both short-circuiting**,
and `contains` over an array testing membership — and `--selftest` checks each
one. That model is read from GitHub's published expression semantics: nothing in
this directory calls a runner.

Short-circuiting is the one to be careful with. The runner's Or and And nodes
return on the first truthy or falsy operand and never evaluate the rest, so a
`fromJSON` an operand nothing reaches would refuse never runs. A model that
evaluated eagerly reports a failure the runner does not have, and one assertion
here stated the opposite of what a real event does before this was modelled.

Four modes:

```sh
gha.py <workflow> <job> <context.json>          # the job's if:, as true or false
gha.py --env <workflow> <step> <key> <ctx.json> # what a step's env key resolves to
gha.py --input <workflow> <input> <field>       # a declared workflow_call input field
gha.py --selftest                               # the expression model itself
```

One group reaches outside this file. `ai-assistant.yml` answers the same comments
and reserves the exact `@seidroid review` body for the reviewer, so the last group
evaluates that workflow's own reply condition beside the parse and records which
tool answers each body. Every body is checked on all three comment events, because
the assistant has a branch each and this workflow now answers all three: a helper
naming one event would measure the division on the path that already had it and
infer the two this workflow adds. Two bodies both tools answer; the group says
which and why.

`ai-assistant.yml` is in `workflow-test-self.yml`'s `paths:` filter for that
reason. Without it an edit there breaks an invariant stated here, and the break
lands on the next unrelated pull request that touches `seidroid-review.yml`.

`bin-guard/gh` logs every call, serves the answer the case chose through the
step's own `--jq` filter, and tells the fork check from the label check by the
filter each sends. A failed read prints nothing and exits non-zero, which is the
shape `Admit the request` is written against: it captures stdout, so an empty
capture is what tells the fork check and the once-per-PR gate that nobody
answered. `bin/gh` beside it files an error body instead, because the placement
step reads one.

### The fixtures

There are none. A guard case turns on six payload fields and five API answers,
so each is built in the run from `STUB_*` and context arguments, where the case
that chose it can be read beside the assertion it drives.

`STUB_TEAM`, `STUB_ORIGIN`, `STUB_LABELS`, `STUB_REVIEWS`, `STUB_COMMENTS` and
`STUB_REACTIONS` choose what the stub answers; `FAIL` on any of them is a read
that nobody answered.
## The review's time limits

`deadline.py` states the relationship between the driver's own budget
(`run-deadline-seconds`, handed over as `SEIDROID_RUN_DEADLINE_S`) and the job cap
(`timeout-minutes`). Both are numbers in a file that parses either way, and getting
either wrong publishes nothing a reader can act on.

A budget the reviews of the day are already reaching produces no verdict at all --
not a failing check: no findings, and a pull request that reads as unreviewed rather
than as broken. Two runs on `sei-protocol/platform` did exactly that against the
driver's old 1200s default, while ordinary reviews landed at 943s and 1029s. The
budget is therefore held to 1.5x the longest turn measured there, and that
measurement is named in the file rather than folded into the threshold.

A job cap at or under the budget is the same failure from the other side. A review
costs more wall-clock than its own deadline: the scout pass, two sandbox launches, the
driver install and the publish steps all sit outside it. The runner then kills the job
before the driver can report why it timed out, and the annotation says only that the
job was cancelled. The cap is held to 1.4x the budget.

The last check is the one `seidroid-review.yml`'s own comment asks for and nothing
enforced: `MIN_DRIVER_VERSION` and the `driver-version` default are one version in two
places. Raising the floor alone fails every caller that omits the input, at once and in
the open. Raising the default alone leaves a floor admitting a driver this file no
longer drives, and says nothing while it happens.

## The review's position

`decision.sh` runs `State the review's position on the pull request` against a `gh`
stub of its own and asserts the review event it posted, one case per decision the
driver can record.

It exists because of what the step used to do. The event was derived here from
`conclusion`, while the driver recorded its own `decision` from the findings — two
computations of one question, and they disagreed. A run whose driver recorded
`approve` beside a `neutral` check posted a comment ending "Approving", a footer
reading decision `approve`, and **no review at all**. That shipped on three pull
requests, and nothing on any of them said why.

Since v0.20.0 the driver records the position and this step submits it. Every case
here therefore asserts the EVENT, never the conclusion: a case written against the
conclusion would pass against the code that had the bug. Run the harness against a copy of the
workflow carrying the old derivation and four of the eight cases fail, including the
two that were live — a withheld decision posting nothing, and a `success` conclusion
manufacturing an APPROVE the driver did not record.

`approve-on-success` is the one thing the step still decides, and it has its own
case. Everything else comes from the driver, including the refusal to act on a
decision the step does not recognise.

### The withdrawal column

Every case also asserts whether the step withdrew a standing block, and that half
matters more than the event. The withdrawal is the only thing in this job that clears
a merge gate, and deriving the event from the conclusion used to make
"posted REQUEST_CHANGES" and "concluded failure" one fact — so the failure test
covered both. Reading the decision from the driver split them, and three cases here
exist because of what that split opened:

- **`request_changes, odd success`** — the step must not record a block and dismiss
  its own, seconds old, on a conclusion that disagrees with the position it just took.
- **`no conclusion field`** — an unreadable conclusion is not a clean review. Falling
  through the withdrawal on one clears a block on the strength of a file this step
  could not read.
- **`no decision field`** — the opposite direction, and the one that is easy to get
  backwards. A missing decision costs the POSITION only. Taking the withdrawal with it
  strands a block on a finding this run did not reproduce, which only a human clears.

Every case runs against a standing block, so "did not withdraw" is a decision the step
made rather than a list that happened to be empty.

`bin-decision/gh` records the event posted, serves that standing block to the
withdrawal's list, and accepts the dismissal. The list and the dismissal are stubbed
so the step reaches its end under `set -e`: a step that died on an unstubbed call
would pass a harness asserting what it never posted.
