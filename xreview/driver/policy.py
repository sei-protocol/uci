"""Elicitation decision policy.

When sei-droid needs permission to run a tool, the server parks the turn
on an *elicitation*. Unattended, the driver must decide accept/decline
for each one. The policy keys on the *attested tool identity* the server
stamps on the elicitation (``params.tool_name``) — never the free-text
message or preview the model can influence.

Read/inspect tools are accepted by identity. ``Bash`` — the carrier for
``git``/``gh`` reads — is also accepted by identity: read-vs-write is not
decidable from the model-chosen, server-truncated command preview, so the
driver does not parse it (parsing that preview would be both fragile and a
model-controlled decision surface). Every other tool (Write, Edit,
MultiEdit, NotebookEdit, WebFetch, WebSearch, AskUserQuestion, any MCP or
unrecognized tool) declines, fail-closed — so the turn never hangs on a
human and never blanket-approves a Write/Edit or an unconstrained MCP/web
egress.

What this policy does and does not guarantee: it keeps the *driver* from
relaying a post, and it declines the write/egress *tools* named above. It
does NOT make the agent read-only — ``Bash`` is permitted and the agent
holds ``gh``/``git``/``curl`` in its sandbox. So the read-only guarantee for
untrusted content does not rest on this policy; it rests on three controls
outside it: the trusted-author trigger gate, the untrusted-content
instruction in the review prompt, and a server-side shell gate enforced
against the full command arguments.

Trust scope: accepting ``Bash`` by identity relies on the reviewed PRs
coming from trusted authors AND on that server-side shell gate actually
being enforced for this agent. Pointing this at untrusted/public PRs — or
enabling real posting — is unsafe until the server-side gate (or a
structured read-only tool set) is in place and verified. See the README
security posture.
"""

from __future__ import annotations

from collections.abc import Callable
from dataclasses import dataclass
from typing import Any, Literal

Action = Literal["accept", "decline"]
DecisionFn = Callable[["Elicitation"], Action]


@dataclass(frozen=True)
class Elicitation:
    """A permission prompt parked on the turn, parsed from the raw dict."""

    elicitation_id: str
    message: str
    phase: str
    policy_name: str
    content_preview: str
    mode: str
    tool_name: str
    target_session_id: str | None

    @classmethod
    def from_raw(cls, raw: dict[str, Any]) -> Elicitation:
        # The wire event nests everything under ``params`` (the MCP
        # elicitation shape); older snapshots flatten it. Read params
        # first, fall back to the top level, so either serialization
        # yields the same Elicitation.
        params = raw.get("params") if isinstance(raw.get("params"), dict) else {}
        return cls(
            elicitation_id=str(
                raw.get("elicitation_id")
                or raw.get("id")
                or params.get("elicitation_id")
                or ""
            ),
            message=str(raw.get("message") or params.get("message") or ""),
            phase=str(raw.get("phase") or params.get("phase") or ""),
            policy_name=str(raw.get("policy_name") or params.get("policy_name") or ""),
            content_preview=str(
                raw.get("content_preview") or params.get("content_preview") or ""
            ),
            mode=str(raw.get("mode") or params.get("mode") or ""),
            # The gated tool's registered name, stamped by the harness
            # (not the model). This is the reliable classification key.
            tool_name=str(raw.get("tool_name") or params.get("tool_name") or ""),
            target_session_id=raw.get("target_session_id")
            or params.get("target_session_id"),
        )

    @property
    def resolve_session_id(self) -> str | None:
        """Session whose resolve endpoint owns this elicitation, if mirrored."""
        return self.target_session_id


# Tools accepted on attested identity alone. Read/inspect the workspace,
# plus Bash (the carrier for git/gh reads — see the module docstring for
# why it is not command-parsed here). Everything not listed falls through
# to the fail-closed decline.
_PERMITTED_TOOLS = frozenset(
    {
        "Read",
        "Glob",
        "Grep",
        "LS",
        "NotebookRead",
        "TodoWrite",
        "ExitPlanMode",
        "Bash",
    }
)


def best_effort_readonly_policy(elicitation: Elicitation) -> Action:
    """Accept the permitted tools by attested identity; decline everything else.

    Classification is on the attested ``tool_name`` — an unrecognized tool,
    or any elicitation carrying no tool identity, declines.
    """
    return "accept" if elicitation.tool_name in _PERMITTED_TOOLS else "decline"


def fail_closed_policy(_elicitation: Elicitation) -> Action:
    """Decline everything. The safest possible default."""
    return "decline"


def dry_run_guard(inner: DecisionFn) -> DecisionFn:
    """Wrap a policy so it can only accept a permitted-by-identity tool.

    The agent is read-only in both modes (the driver posts the verdict, the
    agent does not), so the same identity set applies; this wrapper keeps a
    dry run from accepting anything ``inner`` might, regardless of ``inner``.
    """

    def decide(elicitation: Elicitation) -> Action:
        if elicitation.tool_name not in _PERMITTED_TOOLS:
            return "decline"
        return inner(elicitation)

    return decide
