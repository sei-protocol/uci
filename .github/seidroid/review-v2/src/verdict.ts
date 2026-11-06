import { Type, type Static } from "typebox";
import { Value } from "typebox/value";
import { acceptanceFor } from "./accepted.ts";

const oneOf = <const T extends readonly string[]>(values: T, description?: string) =>
  Type.Unsafe<T[number]>({ type: "string", enum: [...values], description });

const Ids = (description: string) => Type.Optional(Type.Array(Type.String(), { description }));

export const InlineComment = Type.Object({
  path: Type.String({ description: "File path relative to the repository root." }),
  line: Type.Integer({ minimum: 1, description: "Line in the diff the comment anchors to." }),
  side: Type.Optional(oneOf(["RIGHT", "LEFT"] as const, "RIGHT for the new file, LEFT for the old.")),
  severity: oneOf(["blocker", "suggestion", "nit"] as const),
  body: Type.String({ minLength: 1, description: "What is wrong and why it matters." }),
  supersedes_thread_ids: Ids("Ids of your earlier threads this comment restates."),
});

export const PreExistingIssue = Type.Object({
  severity: oneOf(["blocker", "suggestion"] as const),
  body: Type.String({ minLength: 1, description: "Where it is and what it costs." }),
});

export const ReviewSubmission = Type.Object({
  read: Type.Integer({ minimum: 0, description: "Line count of the diff you read; 0 if you never got it." }),
  decision: oneOf(["approve", "comment", "request_changes"] as const),
  summary: Type.String({
    minLength: 1,
    description: "What the change does, then what decides the verdict; two sentences at most.",
  }),
  inline_comments: Type.Optional(Type.Array(InlineComment)),
  blockers: Type.Optional(Type.Array(Type.String(), { description: "Must fix, tied to no single line." })),
  non_blockers: Type.Optional(Type.Array(Type.String(), { description: "Worth noting, tied to no single line." })),
  pre_existing_issues: Type.Optional(Type.Array(PreExistingIssue)),
  resolved_thread_ids: Ids("Ids of your open threads whose finding this diff now addresses."),
});

export type ReviewSubmission = Static<typeof ReviewSubmission>;
export type Decision = ReviewSubmission["decision"];
export type Conclusion = "success" | "neutral" | "failure";

/** Why a recorded position departs from the decision the review wrote. */
export type Withheld = "as-said" | "blocker" | "empty-comment" | "unread-diff" | "pre-existing";

export interface Verdict {
  submission: ReviewSubmission;
  /** Accepted pre-existing conditions from the base branch's guidelines. */
  accepted: string[];
  /** The ref accepted was read from; empty when unreported. */
  acceptedFrom: string;
  /** Scouts whose readings decided this verdict in place of a review; empty otherwise. */
  settledBy: string;
}

export interface Finding {
  file: string;
  line: number;
  side: "RIGHT" | "LEFT";
  severity: "blocker" | "suggestion" | "nit";
  detail: string;
  supersedes: string[];
}

export interface PreExisting {
  severity: "blocker" | "suggestion";
  body: string;
  /** The acceptance this blocker matched; empty when none. */
  accepted: string;
}

export type Parsed = { ok: true; submission: ReviewSubmission } | { ok: false; reason: string };

/** parseSubmission validates a submission from outside the process, such as an artifact. */
export function parseSubmission(raw: unknown): Parsed {
  if (!Value.Check(ReviewSubmission, raw)) {
    const first = Value.Errors(ReviewSubmission, raw)[0];
    return { ok: false, reason: `the submission does not match the schema: ${first?.instancePath || "/"} ${first?.message ?? ""}`.trim() };
  }
  if (raw.summary.trim() === "") {
    return { ok: false, reason: "the submission decides without a summary" };
  }
  return { ok: true, submission: raw };
}

export function verdictOf(submission: ReviewSubmission, accepted: string[] = [], acceptedFrom = ""): Verdict {
  return { submission, accepted, acceptedFrom, settledBy: "" };
}

const MAX_PLACEABLE_FINDINGS = 50;
const MAX_THREAD_IDS = 100;
const MAX_THREAD_ID = 200;
const MAX_REFUSED_THREAD_IDS = 20;
const MAX_COMMENT_PATH = 4096;
const MAX_COMMENT_PATH_SEGMENT = 255;

const trimmed = (items: readonly string[] | undefined): string[] =>
  (items ?? []).map((s) => s.trim()).filter((s) => s !== "");

export const blockers = (v: Verdict): string[] => trimmed(v.submission.blockers);
export const nonBlockers = (v: Verdict): string[] => trimmed(v.submission.non_blockers);

const threadIds = (ids: readonly string[] | undefined): string[] => trimmed(ids).slice(0, MAX_THREAD_IDS);

/** reportedFindings returns every inline comment, placeable or not. */
export function reportedFindings(v: Verdict): Finding[] {
  return (v.submission.inline_comments ?? []).map((c) => ({
    file: c.path.trim(),
    line: c.line,
    side: c.side === "LEFT" ? "LEFT" : "RIGHT",
    severity: c.severity,
    detail: c.body.trim(),
    supersedes: threadIds(c.supersedes_thread_ids),
  }));
}

/**
 * placeableFindings returns the findings that can be posted on a line, deduplicated and
 * capped, with nits only when included and supersedes narrowed to this review's own threads.
 */
export function placeableFindings(v: Verdict, includeNits: boolean, own: ReadonlySet<string>): Finding[] {
  return placeable(v, includeNits).map((f) => ({ ...f, supersedes: f.supersedes.filter((id) => own.has(id)) }));
}

function placeable(v: Verdict, includeNits: boolean): Finding[] {
  const seen = new Set<string>();
  const out: Finding[] = [];
  for (const f of reportedFindings(v)) {
    if (f.severity === "nit" && !includeNits) continue;
    const key = dedupeKey(f);
    if (!postablePath(f.file) || f.line <= 0 || f.detail === "" || seen.has(key)) continue;
    seen.add(key);
    out.push(f);
    if (out.length >= MAX_PLACEABLE_FINDINGS) break;
  }
  return out;
}

const dedupeKey = (f: Finding): string => [f.file, f.side, f.line, f.detail].join("\0");

/** reportedBySeverity counts distinct reported findings that block and that do not. */
export function reportedBySeverity(v: Verdict, includeNits: boolean): { blocking: number; other: number } {
  const blocks = new Map<string, boolean>();
  for (const f of reportedFindings(v)) {
    if (f.severity === "nit" && !includeNits) continue;
    const key = dedupeKey(f);
    blocks.set(key, (blocks.get(key) ?? false) || f.severity === "blocker");
  }
  const blocking = [...blocks.values()].filter(Boolean).length;
  return { blocking, other: blocks.size - blocking };
}

/** postablePath reports whether a path is a plain relative path GitHub can anchor a comment to. */
export function postablePath(p: string): boolean {
  if (p === "" || Buffer.byteLength(p) > MAX_COMMENT_PATH || !p.isWellFormed()) return false;
  if (/^[/~-]/.test(p) || /[\x00-\x1f\x7f]/.test(p)) return false;
  return p
    .split("/")
    .every((seg) => seg !== "" && seg !== "." && seg !== ".." && Buffer.byteLength(seg) <= MAX_COMMENT_PATH_SEGMENT);
}

export function preExisting(v: Verdict): PreExisting[] {
  return (v.submission.pre_existing_issues ?? [])
    .map((issue) => ({ severity: issue.severity, body: issue.body.trim() }))
    .filter((issue) => issue.body !== "")
    .map((issue) => ({
      ...issue,
      accepted: issue.severity === "blocker" ? acceptanceFor(issue.body, v.accepted) : "",
    }));
}

export interface Standing {
  decision: Decision;
  conclusion: Conclusion;
  why: Withheld;
}

/**
 * standing derives the decision and the check conclusion together from the findings. The
 * decision the review wrote can escalate but never clear: approve is recorded only where
 * nothing withholds it.
 */
export function standing(v: Verdict): Standing {
  const said = v.submission.decision;
  if (blockers(v).length > 0 || reportedFindings(v).some((f) => f.severity === "blocker")) {
    return { decision: "request_changes", conclusion: "failure", why: said === "request_changes" ? "as-said" : "blocker" };
  }
  if (said === "request_changes") return { decision: said, conclusion: "failure", why: "as-said" };
  // A comment with nothing written down is the prompt's read-failure signal.
  if (said === "comment" && !wroteAnythingDown(v)) {
    return { decision: "comment", conclusion: "neutral", why: "empty-comment" };
  }
  // Without a line count a clean review cannot be told from a review of nothing.
  if (v.submission.read <= 0) return { decision: "comment", conclusion: "neutral", why: "unread-diff" };
  // A pre-existing blocker is not the author's to fix, so it never fails the check, but
  // no approval is recorded while one stands unaccepted.
  if (preExisting(v).some((i) => i.severity === "blocker" && i.accepted === "")) {
    return { decision: "comment", conclusion: "neutral", why: "pre-existing" };
  }
  return { decision: said, conclusion: "success", why: "as-said" };
}

const wroteAnythingDown = (v: Verdict): boolean =>
  reportedFindings(v).length > 0 || nonBlockers(v).length > 0 || preExisting(v).length > 0;

export interface ThreadPlan {
  addressed: string[];
  superseded: string[];
  refused: string[];
  refusedTotal: number;
}

/** ownThreadIds is the set of well-formed ids of the threads this review left before. */
export function ownThreadIds(ids: readonly string[]): Set<string> {
  return new Set(ids.filter(wellFormedThreadId));
}

/**
 * buildThreadPlan splits the thread ids a review named into those it addressed, those its
 * placed findings supersede, and those refused because they are not this review's own.
 */
export function buildThreadPlan(v: Verdict, includeNits: boolean, own: ReadonlySet<string>): ThreadPlan {
  const plan: ThreadPlan = { addressed: [], superseded: [], refused: [], refusedTotal: 0 };
  const seen = new Set<string>();
  const admit = (ids: string[], into?: string[]) => {
    for (const id of ids) {
      if (seen.has(id) || seen.size >= MAX_THREAD_IDS * MAX_PLACEABLE_FINDINGS) continue;
      seen.add(id);
      if (own.has(id)) {
        into?.push(id);
        continue;
      }
      plan.refusedTotal++;
      if (plan.refused.length < MAX_REFUSED_THREAD_IDS) plan.refused.push(safeThreadId(id));
    }
  };
  admit(placeable(v, includeNits).flatMap((f) => f.supersedes), plan.superseded);
  admit(reportedFindings(v).flatMap((f) => f.supersedes));
  admit(threadIds(v.submission.resolved_thread_ids), plan.addressed);
  return plan;
}

const THREAD_ID_RUNE = /^[A-Za-z0-9_\-=+/]$/;

export const wellFormedThreadId = (s: string): boolean =>
  s !== "" && s.length <= MAX_THREAD_ID && [...s].every((r) => THREAD_ID_RUNE.test(r));

const safeThreadId = (s: string): string =>
  [...s]
    .map((r) => (THREAD_ID_RUNE.test(r) ? r : "?"))
    .join("")
    .slice(0, MAX_THREAD_ID);
