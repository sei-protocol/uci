# Workflow tests

Two harnesses over `.github/workflows/seidroid-review.yml`. Both read the steps out
of the YAML on every run, so neither can pass against a stale copy.

```sh
test/seidroid-review/run.sh        # placement and thread resolution
test/seidroid-review/reactions.sh  # the three reaction steps
python3 test/seidroid-review/conditions.py .github/workflows/seidroid-review.yml
```

# `Place findings on the code` and `Resolve the threads this review closed`

Runs both steps under `bash`, against a `gh` stub, and checks what they posted,
counted and closed.

The run needs `bash`, `jq`, and `python3` with PyYAML. It exits non-zero on the
first failed assertion count and prints a table of one row per case.

Both steps are in one harness because they are one behaviour. Placement records
which thread each posted comment replaced; the resolve step closes a thread on
finding its id in that record. A harness that ran only one of them could not
tell whether the record it wrote is the record the other reads.

## How it works

`extract.py` reads a step's `run:` block and the workflow's `FINDING_MARKER` out
of the YAML on every run, so the harness tests the file as it stands. It runs
twice, once per step, and the two markers are asserted equal: placement stamps a
comment with it and the resolve step recognises a thread by it.

`bin/gh` goes on `PATH` ahead of the real `gh`. It logs every call, serves
fixture JSON through the step's own `jq`, keeps the request body the step sent,
and decides per case whether a call succeeds. `STUB_*` variables in `run_case`
and `run_resolve` select the fixtures and the answers.

## The fixtures

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

# The reaction steps

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

Four properties every case holds to. A human's reaction is never withdrawn. Neither is
a reaction of this bot's that no step here chooses, so a `rocket` some other workflow
left survives. A thumb that answers a verdict already on the pull request survives a
later cancellation. And a run cancelled before it reached `Answer the request` takes
only the eyes: a thumb on the comment then belongs to an EARLIER run, whose verdict may
still stand.

# The step conditions

`conditions.py` covers what a shell harness cannot see. A step condition decides which
reaction step runs in which job state, and that is where the cancellation behaviour
lives. `Answer the request` reads a conclusion and may thumb the request, so it must
skip a cancelled run. The withdrawal step must take a cancelled run, unless
`Post the verdict` already completed.

It models the runner's own rule that a condition naming none of
`always`/`cancelled`/`failure`/`success` is stored as `success() && (...)`, and treats
any term it does not decide as unknown rather than as false.

Two checks are stated over the file rather than over a table, so they cover a step
added later. Both walk **every job's raw steps list**, so an unnamed step is not
invisible to them, and both search the **whole step** rather than one key:

- No step that can run on a cancelled job may reach `check_path` or
  `verdict_produced`. An inline `${{ steps.drive.outputs.check_path }}` in `run:`,
  `with:` or `if:` reaches the same value an `env:` key would.
- Every `steps.<id>` a step reads must be a real id on an earlier step. Delete the id,
  or move the reader in front of it, and the read is empty forever with no error
  anywhere — and a harness that takes the value as an argument cannot notice.

Neither check needs telling where to look. A check that has to be pointed at a step is
not stated over the file.
