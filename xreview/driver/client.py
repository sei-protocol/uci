"""Thin, bounded REST client for the omnigent sessions API.

Every request carries an explicit timeout; transient failures (network
errors and 429/502/503/504) retry with exponential backoff and full
jitter, capped by both an attempt budget and the overall run deadline
so retries never outlive the run. 4xx (other than 429) never retries.
"""

from __future__ import annotations

import random
import time
from typing import Any, Self

import httpx

from .config import DriverConfig
from .errors import ApiError, TransientExhausted

_RETRYABLE_STATUS = frozenset({429, 502, 503, 504})
_BACKOFF_BASE_S = 0.5
_BACKOFF_CAP_S = 8.0


class Deadline:
    """A monotonic deadline shared across the run and its retries."""

    def __init__(self, budget_s: float) -> None:
        self._end = time.monotonic() + budget_s

    def remaining(self) -> float:
        return self._end - time.monotonic()

    def expired(self) -> bool:
        return self.remaining() <= 0.0


class RestClient:
    def __init__(self, cfg: DriverConfig, deadline: Deadline | None = None) -> None:
        self._cfg = cfg
        self._deadline = deadline
        headers = {
            "Origin": cfg.origin,
            "Accept": "application/json",
            "User-Agent": "seidroid-xreview-driver/0",
        }
        if cfg.token:
            headers["Authorization"] = f"Bearer {cfg.token}"
        self._http = httpx.Client(
            base_url=cfg.base_url,
            headers=headers,
            timeout=httpx.Timeout(
                connect=cfg.connect_timeout_s,
                read=cfg.read_timeout_s,
                write=cfg.connect_timeout_s,
                pool=cfg.connect_timeout_s,
            ),
        )

    # ── Session lifecycle ────────────────────────────────────────────

    def resolve_agent_id(self, name_or_id: str) -> str:
        """Resolve an agent name (or id) to its server-side id.

        A managed built-in's id is a derived value, not its name, so a
        session create keyed on the bare name 404s. Match on id first (an
        already-resolved id passes through), then on name.
        """
        resp = self._request("GET", "/v1/agents")
        body = resp.json()
        data = body.get("data", []) if isinstance(body, dict) else []
        for agent in data:
            if isinstance(agent, dict) and name_or_id in (agent.get("id"), agent.get("name")):
                return str(agent["id"])
        raise ApiError("GET", "/v1/agents", resp.status_code, f"no agent matching {name_or_id!r}")

    def create_managed_session(
        self, *, agent_id: str, title: str, labels: dict[str, str] | None = None
    ) -> dict[str, Any]:
        """Create a managed session bound to the given agent id.

        Posts the managed JSON body and then fetches the full snapshot,
        mirroring the SDK's create-then-get so the caller always sees a
        complete session dict (the create response may return only an
        id).
        """
        body: dict[str, Any] = {
            "agent_id": agent_id,
            "host_type": "managed",
            "title": title,
        }
        if labels:
            body["labels"] = labels
        resp = self._request("POST", "/v1/sessions", json=body)
        created = resp.json()
        session_id = created.get("session_id") or created.get("id")
        if not session_id:
            raise ApiError("POST", "/v1/sessions", resp.status_code, resp.text)
        return self.get_session(str(session_id))

    def get_session(self, session_id: str) -> dict[str, Any]:
        resp = self._request("GET", f"/v1/sessions/{session_id}")
        return resp.json()

    def list_sessions_by_agent(
        self, agent_id: str, *, limit: int = 20
    ) -> list[dict[str, Any]]:
        resp = self._request(
            "GET", "/v1/sessions", params={"agent_id": agent_id, "limit": limit}
        )
        body = resp.json()
        data = body.get("data", []) if isinstance(body, dict) else []
        return [item for item in data if isinstance(item, dict)]

    def post_event(self, session_id: str, event: dict[str, Any]) -> dict[str, Any]:
        resp = self._request(
            "POST", f"/v1/sessions/{session_id}/events", json=event
        )
        return resp.json()

    def resolve_elicitation(
        self, session_id: str, elicitation_id: str, action: str
    ) -> dict[str, Any]:
        resp = self._request(
            "POST",
            f"/v1/sessions/{session_id}/elicitations/{elicitation_id}/resolve",
            json={"action": action},
        )
        return resp.json()

    def interrupt(self, session_id: str) -> None:
        self._request(
            "POST",
            f"/v1/sessions/{session_id}/events",
            json={"type": "interrupt", "data": {}},
        )

    def delete_session(self, session_id: str) -> None:
        """Tear the session down. A 404 means it is already gone (ok)."""
        self._request(
            "DELETE",
            f"/v1/sessions/{session_id}",
            expect=(200, 202, 204, 404),
        )

    def close(self) -> None:
        self._http.close()

    def __enter__(self) -> Self:
        return self

    def __exit__(self, *exc: object) -> None:
        self.close()

    # ── Transport ────────────────────────────────────────────────────

    def _request(
        self,
        method: str,
        path: str,
        *,
        json: dict[str, Any] | None = None,
        params: dict[str, Any] | None = None,
        expect: tuple[int, ...] = (200, 201, 202, 204),
    ) -> httpx.Response:
        attempt = 0
        while True:
            try:
                resp = self._http.request(method, path, json=json, params=params)
            except httpx.TransportError as exc:
                if not self._retry_ok(attempt):
                    raise TransientExhausted(f"{method} {path}: {exc}") from exc
                self._sleep(attempt)
                attempt += 1
                continue
            if resp.status_code in _RETRYABLE_STATUS and self._retry_ok(attempt):
                self._sleep(attempt, resp)
                attempt += 1
                continue
            if resp.status_code not in expect:
                raise ApiError(method, path, resp.status_code, resp.text)
            return resp

    def _retry_ok(self, attempt: int) -> bool:
        budget_left = (
            self._deadline is None
            or self._deadline.remaining() > _BACKOFF_BASE_S
        )
        return attempt < self._cfg.max_transient_retries and budget_left

    def _sleep(self, attempt: int, resp: httpx.Response | None = None) -> None:
        delay = min(_BACKOFF_CAP_S, _BACKOFF_BASE_S * (2**attempt))
        delay = random.uniform(0.0, delay)  # full jitter
        retry_after = _retry_after_seconds(resp)
        if retry_after is not None:
            delay = max(delay, retry_after)
        if self._deadline is not None:
            delay = min(delay, max(0.0, self._deadline.remaining()))
        if delay > 0:
            time.sleep(delay)


def _retry_after_seconds(resp: httpx.Response | None) -> float | None:
    if resp is None:
        return None
    value = resp.headers.get("retry-after")
    if not value:
        return None
    try:
        return float(value)
    except ValueError:
        return None
