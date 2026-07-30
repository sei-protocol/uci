# xreview: agentic PR review

`xreview` is an on-demand, sandbox-backed code review. Comment `seidroid xreview` on a
pull request and the `sei-droid` agent runs inside a managed omnigent Kubernetes sandbox,
reads the PR through a real `git`/`gh` toolchain, and returns one structured verdict.

Unlike a diff-only reviewer, the agent drives a full session with a credentialed toolchain,
so it can run the tests, reproduce a claim, or grep the wider codebase before it decides.
That depth costs a live sandbox and a minute of wall-clock, so xreview is opt-in per PR —
triggered by the comment — rather than run on every push.

For how xreview sits alongside the other `seidroid` capabilities, see the
[seidroid index](../README.md).

## Layout

- `.github/workflows/seidroid-xreview.yml` — the **reusable workflow** this feature
  publishes. On a `seidroid xreview` comment it runs the trusted-commenter guard, fetches the
  driver at the caller's `uci-ref`, mints the omnigent bearer, drives the review, and posts
  the verdict as one sticky PR comment. Callers reach it with `uses:`.
- `driver/` — the session driver the reusable workflow runs. Creates exactly one managed
  `sei-droid` session, drives it through a review turn, auto-resolves the agent's permission
  prompts against a read-only policy, extracts the verdict, and tears the session down.
  Speaks the omnigent REST API directly over `httpx`. `driver/tests/selftest.py` covers the
  settle/nudge and verdict-parsing logic with a scripted fake client
  (`python .github/seidroid/xreview/driver/tests/selftest.py`).
- `tools/seidroid-xreview.yml` — the **caller template**. Copy it into the reviewed repo at
  `.github/workflows/seidroid-xreview.yml` (an `issue_comment` workflow only fires from the
  default branch, so the thin caller must live in each reviewed repo); it wires the trigger
  and `uses:` the reusable workflow at a pinned ref.

## How a run works

1. A trusted commenter writes `seidroid xreview` on a PR.
2. The trigger workflow's `guard` job (hosted runner, no secrets) checks the comment author
   is `OWNER`/`MEMBER`/`COLLABORATOR` and that the command line is exactly `seidroid xreview`
   as a whole line, so a comment that merely quotes or discusses it does not trigger.
3. The reusable workflow's `xreview` job runs on the `uci-default` org ARC scale set,
   in-cluster. It fetches the driver at `uci-ref`, mints an omnigent bearer with the
   client-credentials grant, and runs the driver.
4. The driver creates one managed `sei-droid` session, drives the review, and writes the
   verdict to a file only when a real verdict is produced.
5. In real-post mode the workflow upserts a single `<!-- seidroid-xreview -->` comment on the
   PR, and only when a real verdict was produced. Either way the
   session is deleted on exit, including on cancellation.

## Auth to omnigent

omnigent exposes an OAuth2 client-credentials grant at `POST /oauth/token`: a machine
`client_id`/`client_secret` pair, no user, exchanged for a short-lived Bearer token scoped
to `sessions`. The reusable workflow mints the bearer at the start of each run over HTTP Basic
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

**Prerequisite:** the reviewed repo must be able to run jobs on the `uci-default` ARC scale
set, which runs in-cluster and reaches omnigent over the ClusterIP Service. A repo or org
without that scale set cannot schedule the `xreview` job, and the run never starts.

1. Copy `tools/seidroid-xreview.yml` to the reviewed repo's
   `.github/workflows/seidroid-xreview.yml` on its default branch.
2. Pin both refs in it — the `uses: sei-protocol/uci/.github/workflows/seidroid-xreview.yml@...`
   line and the `uci-ref` input — to the same uci release tag or commit SHA (a fixed ref,
   never a moving tag). Bump both to adopt a new xreview release.
3. Set the `OMNIGENT_M2M_CLIENT_SECRET` repository (or organization) secret to the
   client-credentials secret; `secrets: inherit` in the caller passes it through. It is
   required for every run: the workflow always mints a bearer to
   whether the verdict is posted.
   Setting it to `false` enables posting — and enabling posts grants the sandbox agent a
   write-capable path to the PR. Read "Before enabling real posts" below and keep it unset
   until every item there holds.

## Security posture

- **Trusted commenters gate the trigger.** The guard admits only
  `OWNER`/`MEMBER`/`COLLABORATOR` comment authors, so an untrusted actor cannot start a run.
  Note this authenticates the **commenter**, not the PR author or the code under review: a
  trusted member can run the bot over a fork PR's untrusted code, so the reviewed content is
  untrusted regardless of who triggered it.
- **What the driver policy does and does not enforce.** The policy accepts the agent's
  read/inspect tools by attested identity and declines Write/Edit/WebFetch/WebSearch (and any
  MCP or unknown tool) fail-closed, so the turn never hangs on a human and never
  blanket-approves a Write/Edit or an MCP/web egress. It does **not** make the agent
  read-only: `Bash` is permitted (it is the carrier for `git`/`gh` reads), so `gh`,
  `git push`, and `curl` remain reachable inside the sandbox. The read-only guarantee for
  untrusted content therefore depends on three controls outside this policy, not on the tool
  policy blocking egress: the trusted-commenter gate, the untrusted-content instruction in the
  review prompt, and a server-side shell gate against the full command. The first two are in
  place; the shell gate is a precondition to confirm before running over untrusted content or
  enabling real posts (see "Before enabling real posts"), so treat the read-only guarantee as
  not yet fully established until it holds.
- **Untrusted PR content is data, not instructions.** The review prompt instructs the agent
  to treat the diff, file contents, commit messages, and title/body as untrusted material to
  review, never as directives, and to report an embedded directive as a possible
  prompt-injection finding.
- **A run with no verdict posts nothing.** The post step keys on a real verdict having been
  produced rather than on the exit code, so a failed or timed-out review leaves no comment and
  a teardown-only failure still posts the verdict it did produce.
- **One session per trigger, torn down best-effort.** `concurrency` cancels a superseded
  run; the driver traps `SIGTERM`/`SIGINT` and deletes its session on the way out. Under a
  hard kill (a grace period shorter than teardown, a signal mid-DELETE) a session can still
  leak, so a server-side session TTL is the backstop. The verdict comment is a single sticky
  upsert, so re-runs edit one comment rather than stacking.
- **Credential scope.** The `client_secret` is the only omnigent credential GitHub holds; it
  is passed as a masked env var (never an input), carries no user identity, and mints a
  short-lived bearer scoped to `sessions`. The workflow `GITHUB_TOKEN` is `pull-requests:
  write` / `contents: read`. The sandbox `gh`/`git` token is vended to the runner pod by a
  rotator, separate from the workflow token, and is currently scoped to a single repo with
  `contents: read`, `pull_requests: write`, `metadata: read`. `pull_requests: write` means a
  successfully-injected agent could post or approve — which is exactly why the
  untrusted-content instruction and the server-side shell gate are load-bearing before real
  posting is enabled.

### Before pointing this at untrusted content

The agent holds a vended `pull_requests: write` token and an auto-accepted `Bash` tool, so on
untrusted content (e.g. a fork PR) with no server-side shell gate a prompt injection can drive
a real `gh`/`git` write. That risk belongs to running the agent at all, not to whether the
driver posts its verdict, so there is no review mode that mitigates it. Confirm before pointing
this at content you do not control:

1. **A server-side shell gate is enforced** for the `sei-droid` managed agent (or the agent is
   restricted to a structured read-only tool set), so a prompt-injection string cannot drive
   `gh` / `git push` / `curl`.
2. **The vended runner token is confirmed minimally scoped** for what review needs, given that
   an injection would run under it.
3. **Reviewed content is first-party / trusted, OR item 1 is in place** — the trigger
   authenticates the commenter, not the code.

Running over first-party / trusted content is safe today. Keep the bot off untrusted content
until the items above hold.

## Status

The driver has been exercised end-to-end against live PRs: mint, session create, sandbox
launch, the agent reading the PR through the credential bridge, a structured verdict, and
teardown. The **reusable workflow and its thin caller** are being wired into their first repo
now; the first `seidroid xreview` comment there is the comment-trigger path's first real test.

Known gaps for a follow-up: the verdict currently posts as `github-actions[bot]` rather than
`seidroid[bot]` (posting via the seidroid app token is a later change); and the
driver's Python dependency (`httpx`) is installed at run time rather than hash-pinned.
