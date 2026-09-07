# `Place findings on the code` and `Resolve the threads this review closed`

Runs both steps of `.github/workflows/seidroid-review.yml` under `bash`, against
a `gh` stub, and checks what they posted, counted and closed.

```sh
test/seidroid-review/run.sh
```

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
