import { test } from "node:test";
import assert from "node:assert/strict";
import { parseAccepted } from "../src/accepted.ts";
import {
  buildThreadPlan,
  ownThreadIds,
  parseSubmission,
  placeableFindings,
  postablePath,
  preExisting,
  reportedBySeverity,
  standing,
  verdictOf,
  type Verdict,
} from "../src/verdict.ts";

function verdict(raw: object, accepted: string[] = []): Verdict {
  const parsed = parseSubmission(raw);
  assert.ok(parsed.ok, parsed.ok ? "" : parsed.reason);
  return verdictOf(parsed.submission, accepted);
}

const finding = (over: object = {}) => ({ path: "a.go", line: 2, severity: "suggestion", body: "x", ...over });

test("parseSubmission refuses what the contract does not describe", async (t) => {
  const cases: [string, unknown][] = [
    ["not an object", "approve"],
    ["no decision", { read: 1, summary: "s" }],
    ["an unrecognised decision", { read: 1, decision: "LGTM ship it", summary: "s" }],
    ["a near-miss decision", { read: 1, decision: "changes_requested", summary: "s" }],
    ["no summary", { read: 1, decision: "approve" }],
    ["a blank summary", { read: 1, decision: "approve", summary: "  " }],
    ["no line count", { decision: "approve", summary: "s" }],
    ["a severity outside the set", { read: 1, decision: "comment", summary: "s", inline_comments: [finding({ severity: "critical" })] }],
    ["a line of 0", { read: 1, decision: "comment", summary: "s", inline_comments: [finding({ line: 0 })] }],
  ];
  for (const [name, raw] of cases) {
    await t.test(name, () => {
      const parsed = parseSubmission(raw);
      assert.equal(parsed.ok, false);
      assert.notEqual(parsed.ok ? "" : parsed.reason, "");
    });
  }
});

test("standing derives the decision with the conclusion", async (t) => {
  const cases: [string, object, string, string, string][] = [
    ["clean approve", { read: 40, decision: "approve", summary: "s" }, "approve", "success", "as-said"],
    ["approve over suggestions", { read: 40, decision: "approve", summary: "s", non_blockers: ["consider a table"] }, "approve", "success", "as-said"],
    ["request_changes with a blocker", { read: 40, decision: "request_changes", summary: "s", blockers: ["nil deref"] }, "request_changes", "failure", "as-said"],
    ["request_changes with nothing written", { read: 40, decision: "request_changes", summary: "s" }, "request_changes", "failure", "as-said"],
    ["approve beside a blocker", { read: 40, decision: "approve", summary: "s", blockers: ["nil deref"] }, "request_changes", "failure", "blocker"],
    ["approve beside a line-tied blocker", { read: 40, decision: "approve", summary: "s", inline_comments: [finding({ severity: "blocker" })] }, "request_changes", "failure", "blocker"],
    ["an unplaceable blocker still blocks", { read: 40, decision: "approve", summary: "s", inline_comments: [finding({ path: "../x", severity: "blocker" })] }, "request_changes", "failure", "blocker"],
    ["approve beside an unaccepted pre-existing blocker", { read: 40, decision: "approve", summary: "s", pre_existing_issues: [{ severity: "blocker", body: "b.go:4 leaks a handle" }] }, "comment", "neutral", "pre-existing"],
    ["a pre-existing suggestion does not withhold", { read: 40, decision: "approve", summary: "s", pre_existing_issues: [{ severity: "suggestion", body: "README drifts" }] }, "approve", "success", "as-said"],
    ["approve that did not read the diff", { read: 0, decision: "approve", summary: "s" }, "comment", "neutral", "unread-diff"],
    ["comment and nothing else", { read: 40, decision: "comment", summary: "s" }, "comment", "neutral", "empty-comment"],
    ["comment with notes", { read: 40, decision: "comment", summary: "s", non_blockers: ["a note"] }, "comment", "success", "as-said"],
  ];
  for (const [name, raw, decision, conclusion, why] of cases) {
    await t.test(name, () => assert.deepEqual(standing(verdict(raw)), { decision, conclusion, why }));
  }
});

test("an accepted pre-existing blocker does not withhold approval", () => {
  const raw = {
    read: 40,
    decision: "approve",
    summary: "s",
    pre_existing_issues: [
      { severity: "blocker", body: "go.mod pins uci to the feature branch, not a tag" },
      { severity: "suggestion", body: "go.mod pins uci to the feature branch" },
    ],
  };
  const accepted = parseAccepted("## Accepted pre-existing conditions\n\n- pins `uci` to the feature branch — until PLT-1300\n");
  assert.equal(standing(verdict(raw)).decision, "comment");
  const v = verdict(raw, accepted);
  assert.deepEqual(standing(v), { decision: "approve", conclusion: "success", why: "as-said" });
  assert.deepEqual(
    preExisting(v).map((i) => i.accepted),
    [accepted[0], ""],
  );
});

test("an acceptance lifts only the blocker it names", () => {
  const v = verdict(
    {
      read: 40,
      decision: "approve",
      summary: "s",
      pre_existing_issues: [
        { severity: "blocker", body: "go.mod pins uci to the feature branch" },
        { severity: "blocker", body: "c.go:9 writes the token to the log" },
      ],
    },
    ["pins uci to the feature branch"],
  );
  assert.equal(standing(v).why, "pre-existing");
});

test("placeableFindings drops, dedupes and gates nits", () => {
  const v = verdict({
    read: 40,
    decision: "comment",
    summary: "s",
    inline_comments: [
      finding(),
      finding(),
      finding({ side: "LEFT" }),
      finding({ severity: "nit", body: "nit" }),
      finding({ path: "/etc/passwd" }),
      finding({ body: "  " }),
      finding({ body: "y", supersedes_thread_ids: ["PRRT_own", "PRRT_other"] }),
    ],
  });
  const own = ownThreadIds(["PRRT_own"]);
  const keys = (nits: boolean) => placeableFindings(v, nits, own).map((f) => `${f.side}:${f.detail}`);
  assert.deepEqual(keys(false), ["RIGHT:x", "LEFT:x", "RIGHT:y"]);
  assert.deepEqual(keys(true), ["RIGHT:x", "LEFT:x", "RIGHT:nit", "RIGHT:y"]);
  assert.deepEqual(placeableFindings(v, false, own).at(-1)?.supersedes, ["PRRT_own"]);
  assert.deepEqual(reportedBySeverity(v, false), { blocking: 0, other: 5 });
});

test("postablePath", () => {
  for (const p of ["a.go", "x/y/z.go", "dir.with.dots/f"]) assert.ok(postablePath(p), p);
  for (const p of ["", "/abs", "~/x", "-flag", "a//b", "a/./b", "../x", "a/..", "a\nb", "a\x7fb", `${"x".repeat(256)}/f`]) {
    assert.ok(!postablePath(p), JSON.stringify(p));
  }
});

test("buildThreadPlan admits only this review's own threads", () => {
  const v = verdict({
    read: 40,
    decision: "comment",
    summary: "s",
    inline_comments: [
      finding({ supersedes_thread_ids: ["PRRT_a", "PRRT_forged"] }),
      finding({ path: "../x", supersedes_thread_ids: ["PRRT_unplaced"] }),
    ],
    resolved_thread_ids: ["PRRT_b", "PRRT_a", "bad id<>", " "],
  });
  const plan = buildThreadPlan(v, false, ownThreadIds(["PRRT_a", "PRRT_b", "PRRT_unplaced", "bad id<>"]));
  assert.deepEqual(plan, {
    addressed: ["PRRT_b"],
    superseded: ["PRRT_a"],
    refused: ["PRRT_forged", "bad?id??"],
    refusedTotal: 2,
  });
});
