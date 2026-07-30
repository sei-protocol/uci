# seidroid

`seidroid[bot]` is Sei's AI reviewer and assistant for GitHub. Each subfolder here is a
**seidroid feature** — its base prompts, its driver, and/or the reusable workflow it
publishes. The reusable *workflows* that run these features live in `.github/workflows/`
(`ai-review.yml`, `ai-assistant.yml`); a caller repo wires them with `uses:` and pins
`uci-ref` to the same ref. See each feature's own README for how to enable it.

| Feature | What it is | Trigger |
|---|---|---|
| [`auto-review/`](auto-review/) | The workflow-driven seidroid[bot] helpers and their base prompts: an automatic three-pass PR review (OpenAI Codex ∥ Cursor → Claude synthesis, posting one PR review + an `AI Review` check) and the conversational `@seidroid` assistant. Prompts: `scout.md`, `review.md`, `assistant.md`. | `pull_request` (review); `@seidroid` mention (assistant) |
| [`xreview/`](xreview/) | On-demand, sandbox-backed deep review. Drives the `sei-droid` agent inside a managed omnigent Kubernetes sandbox with a real `git`/`gh` toolchain, so it can build, test, and inspect the tree before returning one structured verdict. A reusable workflow (`.github/workflows/seidroid-xreview.yml`) plus a Python session driver. | `seidroid xreview` PR comment |

The difference between the two review paths is the engine: `auto-review` passes the diff to
models from inside the Actions runner and runs on every push; `xreview` drives a full agent
session in a credentialed sandbox and is opt-in per PR, for when a review needs to actually
run the code.
