# `Place findings on the code`

Runs the placement step of `.github/workflows/seidroid-review.yml` under `bash`,
against a `gh` stub, and checks what it posted and what it counted.

```sh
test/seidroid-review/run.sh
```

The run needs `bash`, `jq`, and `python3` with PyYAML. It exits non-zero on the
first failed assertion count and prints a table of one row per case.

## How it works

`extract.py` reads the step's `run:` block and the workflow's `FINDING_MARKER`
out of the YAML on every run, so the harness tests the file as it stands.

`bin/gh` goes on `PATH` ahead of the real `gh`. It logs every call, serves
fixture JSON through the step's own `jq`, keeps the request body the step sent,
and decides per case whether a call succeeds. `STUB_*` variables in `run_case`
select the fixtures and the answers.

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
