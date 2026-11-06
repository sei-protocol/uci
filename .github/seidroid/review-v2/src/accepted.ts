const ACCEPTED_HEADING = "accepted";
const MIN_ACCEPTANCE_WORDS = 3;
const MAX_ACCEPTANCES = 100;
const NEGATION_REACH = 3;
const NEGATIONS = new Set(["no", "not", "never", "longer", "without", "stopped", "removed", "dropped", "neither", "nor"]);
const CONJUNCTIONS = [" and ", " but ", " also ", " as well as ", " plus ", "; "];

/**
 * parseAccepted returns the bullets under a guidelines heading whose first word is
 * "Accepted": the pre-existing conditions the base branch accepts. Bullets in fences,
 * and bullets naming fewer than three words, are skipped.
 */
export function parseAccepted(text: string): string[] {
  const out: string[] = [];
  let inSection = false;
  let inFence = false;
  for (const line of text.replace(/\r\n?/g, "\n").split("\n")) {
    const t = line.trim();
    if (t.startsWith("```") || t.startsWith("~~~")) {
      inFence = !inFence;
      continue;
    }
    if (inFence) continue;
    const title = headingTitle(t);
    if (title !== undefined) {
      const first = title.toLowerCase().split(/\s+/)[0] ?? "";
      inSection = first.replace(/[:.,]+$/, "") === ACCEPTED_HEADING;
      continue;
    }
    if (!inSection || !/^[-+*](\s|$)/.test(t)) continue;
    const entry = t.slice(1).trim();
    if (words(acceptancePhrase(entry)).length < MIN_ACCEPTANCE_WORDS) continue;
    out.push(entry);
    if (out.length >= MAX_ACCEPTANCES) break;
  }
  return out;
}

function headingTitle(line: string): string | undefined {
  const m = /^(#{1,6})(?:[ \t]|$)/.exec(line);
  if (!m || line[m[1]!.length] === "#") return undefined;
  return line.slice(m[1]!.length).trim();
}

const words = (s: string): string[] => s.split(/\s+/).filter((w) => w !== "");

/** acceptancePhrase is an entry without the rationale after its dash. */
function acceptancePhrase(entry: string): string {
  for (const sep of [" — ", " -- ", " – "]) {
    const at = entry.indexOf(sep);
    if (at >= 0) return entry.slice(0, at);
  }
  return entry;
}

/**
 * acceptanceFor returns the accepted entry a finding's body names, or "" when none does.
 * A phrase negated just before it, or joined to more after it, does not match.
 */
export function acceptanceFor(body: string, accepted: readonly string[]): string {
  const haystack = matchable(body);
  for (const entry of accepted) {
    const phrase = matchable(acceptancePhrase(entry));
    if (phrase === "") continue;
    const at = haystack.indexOf(phrase);
    if (at < 0) continue;
    const before = haystack.slice(0, at);
    const after = haystack.slice(at + phrase.length);
    if (!negated(before) && !CONJUNCTIONS.some((c) => (" " + after).includes(c))) return entry;
  }
  return "";
}

const negated = (before: string): boolean =>
  words(before)
    .slice(-NEGATION_REACH)
    .some((w) => NEGATIONS.has(w.replace(/^[.,;:()]+|[.,;:()]+$/g, "")));

const matchable = (s: string): string => words(s.toLowerCase().replace(/[`"'“”‘’]/g, "")).join(" ");
