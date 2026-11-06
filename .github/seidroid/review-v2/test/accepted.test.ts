import { test } from "node:test";
import assert from "node:assert/strict";
import { acceptanceFor, parseAccepted } from "../src/accepted.ts";

test("parseAccepted", async (t) => {
  const cases: [string, string, string[]][] = [
    ["no section", "# Review\n\n- pins uci to the feature branch\n", []],
    [
      "the section, then another heading ends it",
      "## Accepted pre-existing conditions\n- pins uci to the feature branch\n## Style\n- prefer short names here\n",
      ["pins uci to the feature branch"],
    ],
    [
      "star bullets and a rationale",
      "### Accepted\n* pins uci to the feature branch -- until PLT-1300\n",
      ["pins uci to the feature branch -- until PLT-1300"],
    ],
    ["too short to name one condition", "## Accepted\n- pin\n- the pin\n- blocker — anything\n", []],
    ["a heading that merely contains the word", "## Not accepted\n- pins uci to the feature branch\n", []],
    ["crlf", "## Accepted\r\n- pins uci to the feature branch\r\n", ["pins uci to the feature branch"]],
    ["a heading that only begins with the word", "## Acceptedness of pins\n- pins uci to the feature branch\n", []],
    ["a heading with the word later", "## Conditions accepted on main\n- pins uci to the feature branch\n", []],
    ["seven hashes is no heading", "####### Accepted\n- pins uci to the feature branch\n", []],
    [
      "an example in a fence is not an entry",
      "## Accepted\n```markdown\n- pins uci to the feature branch\n```\n- reads the token from the env\n",
      ["reads the token from the env"],
    ],
  ];
  for (const [name, text, want] of cases) {
    await t.test(name, () => assert.deepEqual(parseAccepted(text), want));
  }
});

test("acceptanceFor folds form and stays narrow", () => {
  const accepted = ["pins `uci` to the feature branch — deliberate"];
  const cases: [string, boolean][] = [
    ["go.mod PINS uci   to the feature branch instead of a tag", true],
    ["pins 'uci' to the feature branch", true],
    ["pins uci to a tag", false],
    ["", false],
    ["go.mod no longer pins uci to the feature branch", false],
    ["the module is untagged, so go.mod pins uci to the feature branch", true],
    ["pins uci to the feature branch and leaks the token", false],
    ["pins uci to the feature branch; the token is logged", false],
    ["pins uci to the feature branch, which has no tag", true],
  ];
  for (const [body, want] of cases) {
    assert.equal(acceptanceFor(body, accepted) !== "", want, body);
  }
});
