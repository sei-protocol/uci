# seidroid AI workflows

Reusable workflows that run the `seidroid[bot]` AI helpers, plus the base prompts they
use. Two workflows live in `.github/workflows/`:

| Workflow | Trigger (in the caller) | What it does |
|----------|-------------------------|--------------|
| `ai-review.yml` | `pull_request` | Three-pass review (OpenAI Codex ∥ Cursor → Claude synthesizes), posting **one** PR review + an `AI Review` check run. |
| `ai-assistant.yml` | `issue_comment`, `pull_request_review_comment`, `pull_request_review` | Conversational responder: mention `@seidroid` on a PR and the bot answers in-thread. |

## Base prompts (edit these)

The prompts are plain Markdown so they are easy to read and change:

- `scout.md` — shared prompt for the Codex and Cursor "scout" passes.
- `review.md` — prompt for the Claude synthesis/review pass.
- `assistant.md` — system prompt (persona) for the `@seidroid` responder. **Keep it free
  of double-quote characters** — it is injected into a CLI argument.

Each workflow fetches these files from `sei-protocol/uci` at the ref given by the
`uci-ref` input, so **set `uci-ref` to the same ref you pin `uses:` to**.

### Adding guidance without editing the prompts

Two layers, both append to the base prompt:

1. **`extra-instructions` input** — set per-caller in your wrapper workflow.
2. **`REVIEW.md` on your repo's base branch** (review workflow only) — committed,
   version-controlled review standards. It is read from the PR's **base** branch, so a PR
   cannot weaken its own review by editing it. Configurable via `guidelines-file`.

## Using the review workflow

```yaml
name: AI Review
on:
  pull_request:
    types: [opened, ready_for_review, synchronize, reopened]
jobs:
  ai-review:
    uses: sei-protocol/uci/.github/workflows/ai-review.yml@v1
    permissions:
      contents: read
      pull-requests: write
      checks: write
      id-token: write          # Anthropic workload identity federation
    secrets: inherit
    with:
      uci-ref: v1
      # extra-instructions: "Flag added allocations in the hot path."
      # prebuild-script: "go mod download"   # warm Codex's offline sandbox
```

| Input | Default | Notes |
|-------|---------|-------|
| `uci-ref` | `main` | Ref to fetch the prompt files from; pin to your `uses:` ref. |
| `enable-codex` | `true` | Toggle the Codex scout. |
| `enable-cursor` | `true` | Toggle the Cursor scout. |
| `extra-instructions` | `''` | Appended to the scout + review prompts. |
| `prebuild-script` | `''` | Shell run in scout jobs before the tool (e.g. warm offline deps). |
| `guidelines-file` | `REVIEW.md` | Base-branch guidelines file to load. |
| `runs-on` | `ubuntu-latest` | Runner label. |
| `claude-model` | `''` | Optional Claude model override. |
| `approve-on-success` | `true` | If true, APPROVE on a clean verdict; else COMMENT. |
| `timeout-minutes` | `15` | Per-job timeout. |

## Using the assistant workflow

```yaml
name: Seidroid Assistant
on:
  issue_comment:
    types: [created]
  pull_request_review_comment:
    types: [created]
  pull_request_review:
    types: [submitted]
jobs:
  assistant:
    uses: sei-protocol/uci/.github/workflows/ai-assistant.yml@v1
    permissions:
      contents: read           # use `write` only with allow-write: true
      pull-requests: write
      issues: write
      id-token: write
    secrets: inherit
    with:
      uci-ref: v1
      # allowed-team: my-org/my-team   # default: sei-protocol/sei-core
      # allow-write: true              # also set contents: write above
```

| Input | Default | Notes |
|-------|---------|-------|
| `uci-ref` | `main` | Ref to fetch `assistant.md` from; pin to your `uses:` ref. |
| `extra-instructions` | `''` | Appended to the persona. **No double-quote characters.** |
| `trigger-phrase` | `@seidroid` | Mention that invokes the bot. |
| `allowed-team` | `sei-protocol/sei-core` | `org/team-slug` allowed to invoke. **Empty ⇒ deny all.** |
| `allow-write` | `false` | Grant Claude edit/commit tools. Requires `contents: write` from the caller. |
| `runs-on` | `ubuntu-latest` | Runner label. |
| `claude-model` | `''` | Optional Claude model override. |
| `timeout-minutes` | `10` | Job timeout. |

## Requirements

- **Secrets** (via `secrets: inherit`): `PLATFORM_CODE_AGENT_APP_ID`,
  `PLATFORM_CODE_AGENT_APP_PK`, `PLATFORM_CODE_AGENT_OPENAI_API_KEY` (Codex),
  `PLATFORM_CODE_AGENT_CURSOR_API_KEY` (Cursor). Missing review API keys make that scout
  no-op gracefully; the review still posts.
- **Org variables**: `PLATFORM_CODE_AGENT_ANTHROPIC_FDRL_ID`, `SEI_LABS_ANTHROPIC_ORG_ID`,
  `PLATFORM_CODE_AGENT_ANTHROPIC_SVAC_ID`, `PLATFORM_CODE_AGENT_USER_ID`.
- **GitHub App**: the seidroid app must be installed with read access to `sei-protocol/uci`
  (to fetch the prompts). For the assistant, it also needs organization **Members: Read**
  on the org owning `allowed-team` — without it the team lookup fails and **everyone is
  denied** (fail-closed).

## Security notes

- The review workflow must be called from **`pull_request`** (it refuses
  `pull_request_target`). On `pull_request`, fork PRs receive no secrets and a read-only
  token, so the workflow degrades gracefully for forks; do not switch to
  `pull_request_target` to "fix" forks.
- The assistant is gated to active members of `allowed-team` (checked before any model
  runs) and ignores bot-authored comments. It is read-only unless `allow-write` is set.
- Untrusted PR/comment content is passed to the models as **data**, never interpolated
  into shell or prompt strings, and every prompt instructs the model to treat it as such.
- The Cursor scout installs the CLI via `curl https://cursor.com/install | bash` (an
  external installer). It runs only in a least-privilege scout job that never sees the app
  token; pin/disable it if your threat model requires.
- Actions are currently referenced by version tag (matching this repo's convention).
  Pinning third-party actions to full commit SHAs is recommended; dependabot keeps the
  `github-actions` ecosystem updated.
