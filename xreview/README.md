# xreview: agentic PR review

`xreview` is an on-demand, sandbox-backed code review. Comment `seidroid xreview` on a
pull request and the `sei-droid` agent runs inside a managed omnigent Kubernetes sandbox,
reads the PR through a real `git`/`gh` toolchain, and returns one structured verdict.

It is a third `seidroid` capability alongside the two in `.github/seidroid/`, and it does
not replace them:

| Capability | Trigger | Engine | Best at |
|---|---|---|---|
| `ai-review` | every `pull_request` | Codex ∥ Cursor → Claude, in the Actions runner | fast, automatic, diff-scoped review on every push |
| `ai-assistant` | `@seidroid` mention | Claude in the Actions runner | conversational answers in a PR thread |
| **`xreview`** | `seidroid xreview` comment | the `sei-droid` agent in a managed omnigent sandbox | deep, on-demand review that can build, test, and inspect the tree, not just read the diff |

The difference that matters is the engine. `ai-review` and `ai-assistant` pass the diff to
a model from inside the GitHub Actions runner. `xreview` drives a full agent session in an
omnigent-managed sandbox with a credentialed toolchain, so the reviewer can run the tests,
reproduce a claim, or grep the wider codebase before it decides. That depth costs a live
sandbox and a minute of wall-clock, so it is opt-in per PR rather than automatic.

## Layout

- `driver/` — the session driver. Creates exactly one managed `sei-droid` session, drives
  it through a review turn, auto-resolves the agent's permission prompts against a
  read-only policy, extracts the verdict, and tears the session down. Speaks the omnigent
  REST API directly over `httpx`. `driver/tests/selftest.py` covers the settle/nudge and
  verdict-parsing logic with a scripted fake client (`python xreview/driver/tests/selftest.py`).
- `tools/action.yml` — the composite action this repo publishes. Mints the omnigent bearer,
  runs the driver, and (outside dry-run) upserts one sticky verdict comment.
- `tools/seidroid-xreview.yml` — the trigger workflow. It is a template: copy it into the
  **reviewed** repo at `.github/workflows/seidroid-xreview.yml`. An `issue_comment` workflow
  only fires from the repo's default branch, so the trigger has to live in each reviewed
  repo; this repo owns the reusable action and the driver.

## How a run works

1. A trusted commenter writes `seidroid xreview` on a PR.
2. The trigger workflow's `guard` job (hosted runner, no secrets) checks the comment author
   is `OWNER`/`MEMBER`/`COLLABORATOR` and that the command line is exactly `seidroid xreview`
   (optionally `--dry-run`), then resolves the dry-run flag.
3. The `xreview` job runs on the `uci-default` org ARC scale set, in-cluster. It mints an
   omnigent bearer with the client-credentials grant and hands it to the composite action.
4. The action creates one managed `sei-droid` session, drives the review, and writes the
   verdict to a file.
5. In real-post mode the action upserts a single `<!-- seidroid-xreview -->` comment on the
   PR; in dry-run it writes the verdict to the job summary and posts nothing. Either way the
   session is deleted on exit, including on cancellation.

## Auth to omnigent

omnigent exposes an OAuth2 client-credentials grant at `POST /oauth/token`: a machine
`client_id`/`client_secret` pair, no user, exchanged for a short-lived Bearer token scoped
to `sessions`. The action mints the bearer at the start of each run over HTTP Basic
(`client_id:client_secret`) with `grant_type=client_credentials`, masks it, and passes it to
the driver as `OMNIGENT_API_TOKEN`. A non-200 or a response without an `access_token` fails
the run loudly rather than falling through to an anonymous request.

The `uci-default` runner reaches omnigent over the ClusterIP Service
`omnigent.seigent.svc.cluster.local`, so no public ingress is involved. The `client_secret`
is the only omnigent credential GitHub holds; it carries no user identity and is passed as a
masked env var, never a workflow input.

Inside the sandbox, the agent's `git`/`gh` read the PR through a token vended to the runner
pod, separate from the workflow's `GITHUB_TOKEN`. The workflow's `GITHUB_TOKEN` is used only
to post the verdict comment.

## Wiring it into a reviewed repo

1. Copy `tools/seidroid-xreview.yml` to the reviewed repo's
   `.github/workflows/seidroid-xreview.yml` on its default branch.
2. Replace `PIN_ME_TO_A_SHA` in the `uses: sei-protocol/uci/xreview/tools@...` line with a
   full commit SHA of this repo. Pin to a SHA, never a moving tag.
3. Set the `OMNIGENT_M2M_CLIENT_SECRET` repository (or environment) secret to the
   client-credentials secret. It is required even for a dry run: the action always mints a
   bearer; dry-run controls only whether the verdict is posted.
4. Leave `vars.SEIDROID_XREVIEW_DRY_RUN` unset (or `true`) until you have watched a real run.
   Set it to `false` to enable posting. `OMNIGENT_M2M_CLIENT_ID` defaults to `sei-droid` and
   is not a secret; override it with an env var if needed.

## Security posture

- **Trusted commenters only.** The guard admits only `OWNER`/`MEMBER`/`COLLABORATOR`
  comment authors, so an untrusted PR author cannot trigger a run. The read-only policy
  accepts the agent's read/inspect tools (including `Bash`, the carrier for `git`/`gh`
  reads) by attested identity and declines every write, edit, or network-egress tool
  fail-closed, so the turn never hangs on a human and never blanket-approves a mutation.
  Accepting `Bash` by identity relies on the trusted-author gate; pointing this at
  untrusted or public PRs needs a server-side shell gate first.
- **Dry-run is the default.** With the repo variable unset the run posts nothing, which is
  the safe state for a new wiring.
- **One session per trigger, always torn down.** `concurrency` cancels a superseded run;
  the driver traps `SIGTERM`/`SIGINT` and deletes its session on the way out, so a cancelled
  run leaves nothing live. The verdict comment is a single sticky upsert, so re-runs edit
  one comment rather than stacking.
- **Untrusted PR content is data, not instructions.** The diff, file contents, and PR
  title/body are material to review, never commands to the reviewer.

## Status

The driver has been exercised end-to-end against live PRs: mint, session create, sandbox
launch, the agent reading the PR through the credential bridge, a structured verdict, and
teardown. The **trigger workflow and composite action have not yet run in GitHub Actions** —
the first `seidroid xreview` comment on a wired repo is their first real test. Keep
`SEIDROID_XREVIEW_DRY_RUN` unset for that first run and read the job summary before enabling
posts.

Known gaps for a follow-up: the verdict currently posts as `github-actions[bot]` rather than
`seidroid[bot]` (posting via the app token, as `ai-review` does, is a later change); and the
driver's Python dependency (`httpx`) is installed at run time rather than hash-pinned.
