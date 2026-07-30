"""Selftest for the verdict-completion logic in ``_drive_turn`` + ``verdict``.

Run from the xreview/ root (or via this file directly; it puts xreview/ on
``sys.path``)::

    python xreview/driver/tests/selftest.py

Exercises the settle/nudge path with a scripted fake client and no real
sleeps, covering: a structured verdict on first settle (no nudge); a
non-structured latest message (one nudge, then the structured verdict is
accepted); nudge budget exhausted (graceful fallback); a settle with no
assistant message at all (nudge, then no_verdict); the re-nudge guard (a
stale unchanged state is nudged at most once even when budget remains); and
that distinct new messages each consume budget. Also unit-checks the
``decision``-key requirement that separates the real verdict from stray JSON.
"""

from __future__ import annotations

import sys
from pathlib import Path
from typing import Any

_REPO_ROOT = Path(__file__).resolve().parents[2]
if str(_REPO_ROOT) not in sys.path:
    sys.path.insert(0, str(_REPO_ROOT))

from driver.client import Deadline
from driver.config import DriverConfig
from driver.driver import SessionDriver
from driver.policy import best_effort_readonly_policy
from driver.verdict import extract_verdict

# ── Fixtures ─────────────────────────────────────────────────────────────

_STRUCTURED = (
    "```json\n"
    '{"decision": "request_changes", "summary": "overflow in the fuzzer",'
    ' "findings": [{"severity": "high", "note": "int cast wraps"}]}\n'
    "```"
)
# The exact shape that broke the live drive: the agent pausing mid-reasoning.
_MID_REASONING = (
    "I have enough to assess this thoroughly. Let me do a final consistency "
    "check across a couple more goldens and the fuzzing generator's overflow "
    "reasoning."
)
# Non-verdict JSON: fenced, parses to a dict, but carries no ``decision`` key.
# Must NOT be mistaken for the verdict.
_STRAY_JSON = (
    'Here is the golden fixture I checked:\n```json\n{"input": 5, "expected": 25}\n```'
)


def _assistant(item_id: str, text: str) -> dict[str, Any]:
    return {
        "type": "message",
        "id": item_id,
        "data": {"role": "assistant", "content": [{"type": "text", "text": text}]},
    }


def _user(item_id: str, text: str) -> dict[str, Any]:
    return {
        "type": "message",
        "id": item_id,
        "data": {"role": "user", "content": [{"type": "input_text", "text": text}]},
    }


def _tool_call(item_id: str) -> dict[str, Any]:
    return {"type": "function_call", "id": item_id, "data": {"name": "Bash"}}


def _idle(items: list[dict[str, Any]]) -> dict[str, Any]:
    return {"status": "idle", "items": items, "pending_elicitations": []}


class FakeClient:
    """Serves scripted snapshots; each posted event advances one phase.

    ``get_session`` returns the current phase's snapshot on every poll, so a
    repeated identical snapshot lets the settle counter accrue. Posting an
    event (the verdict nudge) advances to the next phase, clamped at the last
    — a single-phase script therefore models an agent that never produces a
    new message after being nudged.
    """

    def __init__(self, phases: list[dict[str, Any]]) -> None:
        self._phases = phases
        self._i = 0
        self.posted: list[str] = []

    def get_session(self, _session_id: str) -> dict[str, Any]:
        return self._phases[self._i]

    def post_event(self, _session_id: str, event: dict[str, Any]) -> dict[str, Any]:
        self.posted.append(event["data"]["content"][0]["text"])
        self._i = min(self._i + 1, len(self._phases) - 1)
        return {"item_id": f"evt-{len(self.posted)}"}

    def resolve_elicitation(self, *_a: Any, **_k: Any) -> dict[str, Any]:
        return {}


def _cfg(verdict_nudges: int) -> DriverConfig:
    return DriverConfig(
        base_url="http://x",
        origin="omnigent://internal",
        agent_id="sei-droid",
        token="t",
        run_deadline_s=5.0,
        connect_timeout_s=5.0,
        read_timeout_s=5.0,
        poll_min_interval_s=0.0,  # no real sleeps in the loop
        poll_max_interval_s=0.0,
        max_transient_retries=0,
        state_dir="/tmp",
        settle_confirmations=2,
        verdict_nudges=verdict_nudges,
    )


def _drive(phases: list[dict[str, Any]], verdict_nudges: int = 1):
    """Run ``_drive_turn`` against a scripted fake; return (verdict, client)."""
    cfg = _cfg(verdict_nudges)
    driver = SessionDriver(cfg)
    client = FakeClient(phases)
    # 5s deadline is a hang-guard only; the correct paths settle in a handful
    # of zero-interval iterations well under it.
    verdict = driver._drive_turn(
        client, "sess-1", Deadline(5.0), best_effort_readonly_policy, set()
    )
    return verdict, client


# ── Harness ──────────────────────────────────────────────────────────────

_failures: list[str] = []


def check(name: str, cond: bool, detail: str = "") -> None:
    status = "PASS" if cond else "FAIL"
    print(f"[{status}] {name}" + (f" — {detail}" if detail and not cond else ""))
    if not cond:
        _failures.append(name)


# ── Tests: the drive loop ────────────────────────────────────────────────


def test_structured_first_settle_no_nudge() -> None:
    verdict, client = _drive([_idle([_assistant("a1", _STRUCTURED)])])
    check("structured-first: no nudge sent", client.posted == [], repr(client.posted))
    check(
        "structured-first: structured verdict returned",
        verdict is not None and verdict.structured is not None,
    )
    check(
        "structured-first: decision parsed",
        verdict is not None
        and verdict.structured is not None
        and verdict.structured.get("decision") == "request_changes",
    )


def test_nonstructured_then_nudge_then_structured() -> None:
    phases = [
        _idle([_assistant("a1", _MID_REASONING)]),
        _idle(
            [
                _assistant("a1", _MID_REASONING),
                _user("u1", "nudge"),
                _assistant("b1", _STRUCTURED),
            ]
        ),
    ]
    verdict, client = _drive(phases, verdict_nudges=1)
    check(
        "nonstructured→nudge: exactly one nudge sent",
        len(client.posted) == 1,
        f"posted={len(client.posted)}",
    )
    check(
        "nonstructured→nudge: nudge asked for the fenced json verdict",
        bool(client.posted)
        and "```json" in client.posted[0]
        and "decision" in client.posted[0],
    )
    check(
        "nonstructured→nudge: structured verdict accepted after nudge",
        verdict is not None
        and verdict.structured is not None
        and verdict.structured.get("decision") == "request_changes",
    )


def test_nudge_exhausted_falls_back_to_unstructured() -> None:
    phases = [
        _idle([_assistant("a1", _MID_REASONING)]),
        _idle([_assistant("a2", _MID_REASONING + " still thinking")]),
    ]
    verdict, client = _drive(phases, verdict_nudges=1)
    check(
        "exhausted: exactly one nudge sent",
        len(client.posted) == 1,
        f"posted={len(client.posted)}",
    )
    check(
        "exhausted: falls back to unstructured verdict (no hang, not None)",
        verdict is not None and verdict.structured is None,
    )
    check(
        "exhausted: fallback carries the latest assistant text",
        verdict is not None and "still thinking" in verdict.text,
    )


def test_no_message_settle_then_no_verdict() -> None:
    # Engaged via a tool call, but no assistant message ever appears.
    phases = [_idle([_tool_call("f1")]), _idle([_tool_call("f1")])]
    verdict, client = _drive(phases, verdict_nudges=1)
    check(
        "no-message: one nudge sent on absent verdict",
        len(client.posted) == 1,
        f"posted={len(client.posted)}",
    )
    check("no-message: no_verdict (None) when agent never speaks", verdict is None)


def test_stale_state_not_renudged_when_budget_remains() -> None:
    # Budget of 2, but the agent never produces a new message: a single phase
    # means every poll (and every post) returns the same unchanged snapshot.
    phases = [_idle([_assistant("a1", _MID_REASONING)])]
    verdict, client = _drive(phases, verdict_nudges=2)
    check(
        "re-nudge guard: stale unchanged state nudged at most once (budget=2)",
        len(client.posted) == 1,
        f"posted={len(client.posted)}",
    )
    check(
        "re-nudge guard: falls back to unstructured after the single nudge",
        verdict is not None and verdict.structured is None,
    )


def test_distinct_new_messages_each_consume_budget() -> None:
    phases = [
        _idle([_assistant("a1", _MID_REASONING)]),
        _idle(
            [
                _assistant("a1", _MID_REASONING),
                _user("u1", "n"),
                _assistant("b1", "still not the verdict"),
            ]
        ),
        _idle(
            [
                _assistant("a1", _MID_REASONING),
                _user("u1", "n"),
                _assistant("b1", "still not the verdict"),
                _user("u2", "n"),
                _assistant("c1", _STRUCTURED),
            ]
        ),
    ]
    verdict, client = _drive(phases, verdict_nudges=2)
    check(
        "distinct-messages: two nudges consumed across two new messages",
        len(client.posted) == 2,
        f"posted={len(client.posted)}",
    )
    check(
        "distinct-messages: structured verdict accepted on the third settle",
        verdict is not None
        and verdict.structured is not None
        and verdict.structured.get("decision") == "request_changes",
    )


# ── Tests: verdict.py decision-key requirement ───────────────────────────


def test_verdict_parsing_requires_decision_key() -> None:
    v_struct = extract_verdict(_assistant("a1", _STRUCTURED))
    check("parse: real verdict is structured", v_struct.structured is not None)

    v_stray = extract_verdict(_assistant("a1", _STRAY_JSON))
    check(
        "parse: stray json without a decision key is NOT structured",
        v_stray.structured is None,
        repr(v_stray.structured),
    )
    check("parse: stray-json text is preserved", "golden fixture" in v_stray.text)

    v_prose = extract_verdict(_assistant("a1", _MID_REASONING))
    check("parse: plain prose is not structured", v_prose.structured is None)

    # Reasoning + a stray block THEN the real verdict, all in one message:
    # the scan must skip the stray block and find the verdict.
    mixed = f"{_STRAY_JSON}\n\nFinal verdict:\n{_STRUCTURED}"
    v_mixed = extract_verdict(_assistant("a1", mixed))
    check(
        "parse: verdict found after a stray json block in one message",
        v_mixed.structured is not None
        and v_mixed.structured.get("decision") == "request_changes",
    )


# ── Tests: _write_verdict file existence == verdict produced ──────────────


def test_write_verdict_only_on_real_verdict() -> None:
    """A no-verdict run leaves the out-file absent, so the action never upserts
    a placeholder over a prior good verdict; a real verdict writes the text."""
    import os
    import tempfile

    from driver.__main__ import _write_verdict
    from driver.driver import RunResult
    from driver.errors import ExitCode
    from driver.verdict import Verdict

    d = tempfile.mkdtemp()

    real = os.path.join(d, "verdict-real.md")
    verdict = Verdict(
        assistant_item_id="a1",
        text="Reviewed the change; approve.",
        structured={"decision": "approve"},
    )
    _write_verdict(real, RunResult(exit_code=ExitCode.OK, verdict=verdict))
    check(
        "write-verdict: a real verdict writes the file with its text",
        os.path.exists(real)
        and "approve" in open(real, encoding="utf-8").read(),
    )

    absent = os.path.join(d, "verdict-none.md")
    _write_verdict(absent, RunResult(exit_code=ExitCode.NO_VERDICT, verdict=None))
    check(
        "write-verdict: a no-verdict run leaves the file absent (no placeholder)",
        not os.path.exists(absent),
    )


def main() -> int:
    for test in (
        test_structured_first_settle_no_nudge,
        test_nonstructured_then_nudge_then_structured,
        test_nudge_exhausted_falls_back_to_unstructured,
        test_no_message_settle_then_no_verdict,
        test_stale_state_not_renudged_when_budget_remains,
        test_distinct_new_messages_each_consume_budget,
        test_verdict_parsing_requires_decision_key,
        test_write_verdict_only_on_real_verdict,
    ):
        test()
    print()
    if _failures:
        print(f"FAILED {len(_failures)}: {', '.join(_failures)}")
        return 1
    print("ALL PASS")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
