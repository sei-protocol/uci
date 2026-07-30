"""Extract the review verdict from the final assistant message."""

from __future__ import annotations

import json
import re
from dataclasses import dataclass
from typing import Any

_FENCED_JSON = re.compile(r"```(?:json)?\s*(\{.*?\})\s*```", re.DOTALL)


@dataclass(frozen=True)
class Verdict:
    assistant_item_id: str | None
    text: str
    structured: dict[str, Any] | None


def new_assistant_message(
    items: list[dict[str, Any]], baseline_ids: set[str]
) -> dict[str, Any] | None:
    """Return the latest assistant message not present at turn start.

    Session ``status`` alone cannot mark the turn done: a fresh session
    is ``idle`` before the turn even begins, so keying off ``idle``
    races the start. Instead we treat the turn as producing output only
    once an assistant message appears that was not in the pre-turn
    baseline. Iterates newest-first so the returned message is the final
    one the agent emitted.
    """
    for item in reversed(items):
        if not _is_assistant_message(item):
            continue
        item_id = _item_id(item)
        if item_id is not None and item_id in baseline_ids:
            continue
        return item
    return None


def assistant_message_ids(items: list[dict[str, Any]]) -> set[str]:
    ids: set[str] = set()
    for item in items:
        if _is_assistant_message(item):
            item_id = _item_id(item)
            if item_id is not None:
                ids.add(item_id)
    return ids


def extract_verdict(item: dict[str, Any]) -> Verdict:
    text = _message_text(item)
    return Verdict(
        assistant_item_id=_item_id(item),
        text=text,
        structured=_parse_structured(text),
    )


def _is_assistant_message(item: dict[str, Any]) -> bool:
    if item.get("type") != "message":
        return False
    data = item.get("data")
    return isinstance(data, dict) and data.get("role") == "assistant"


def _item_id(item: dict[str, Any]) -> str | None:
    raw = item.get("id")
    return str(raw) if raw is not None else None


def _message_text(item: dict[str, Any]) -> str:
    data = item.get("data")
    if not isinstance(data, dict):
        return ""
    content = data.get("content")
    if isinstance(content, str):
        return content
    if not isinstance(content, list):
        return ""
    parts: list[str] = []
    for block in content:
        if isinstance(block, dict) and isinstance(block.get("text"), str):
            parts.append(block["text"])
    return "".join(parts)


def _parse_structured(text: str) -> dict[str, Any] | None:
    """Return the JSON verdict object from the message, or None.

    The verdict contract (see the driver's prompt and nudge) is a JSON
    object carrying a ``decision`` key alongside ``summary``/``findings``.
    Requiring ``decision`` is what separates the real verdict from a
    mid-reasoning message that merely quotes some other JSON — the latter
    must not be read as the verdict. Fenced blocks are scanned in order so
    the verdict is still found when the agent emits it after other JSON in
    one message. Absence of a structured verdict is not a failure:
    ``extract_verdict`` still returns the raw text as an unstructured one.
    """
    for match in _FENCED_JSON.finditer(text):
        verdict = _as_verdict_dict(match.group(1))
        if verdict is not None:
            return verdict
    start = text.find("{")
    end = text.rfind("}")
    if start != -1 and end > start:
        return _as_verdict_dict(text[start : end + 1])
    return None


def _as_verdict_dict(candidate: str) -> dict[str, Any] | None:
    try:
        parsed = json.loads(candidate)
    except (ValueError, TypeError):
        return None
    if isinstance(parsed, dict) and "decision" in parsed:
        return parsed
    return None
