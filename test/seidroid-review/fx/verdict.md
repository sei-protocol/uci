The change moves the retry budget onto the caller, which is where the deadline
already lives. Two of the three call sites pass a context that cannot carry it.

### Blocking

- `internal/retry`: the budget is read once at construction, so a caller that
  lowers it per-request is ignored.

_2 finding(s) on the changed lines, as inline comments._

### Non-blocking

_1 finding(s) on the changed lines, as inline comments._

<details><summary>3 nits, not posted on the code</summary>

- `internal/retry/backoff.go`: the receiver name changes mid-file.
- `internal/retry/doc.go`: the package sentence repeats the package name.
- `internal/retry/budget.go`: an unused named return.

</details>
