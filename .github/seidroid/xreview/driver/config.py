"""Environment-driven configuration.

Every knob comes from the environment so the driver stays 12-factor and
carries no secrets in source. The API credential — the one input the
driver cannot decide on its own — is read here from an inline var or a
mounted file.
"""

from __future__ import annotations

import os
from dataclasses import dataclass

from .errors import ConfigError

# The server's first-party non-browser sentinel Origin. State-changing
# POSTs are gated by a trusted-origin CSRF check; this driver is not a
# browser and sends no Origin of its own, so it announces the sentinel
# to pass the guard (the value the python-client SDK also sends).
DEFAULT_ORIGIN = "omnigent://internal"

# In-cluster ClusterIP Service (plain HTTP, no ingress TLS); override to the
# ingress when off-cluster.
DEFAULT_BASE_URL = "http://omnigent.seigent.svc.cluster.local"

DEFAULT_AGENT_ID = "sei-droid"


@dataclass(frozen=True)
class DriverConfig:
    base_url: str
    origin: str
    agent_id: str
    token: str
    run_deadline_s: float
    connect_timeout_s: float
    read_timeout_s: float
    poll_min_interval_s: float
    poll_max_interval_s: float
    max_transient_retries: int
    state_dir: str
    settle_confirmations: int
    verdict_nudges: int

    @classmethod
    def from_env(cls) -> DriverConfig:
        return cls(
            base_url=os.environ.get("OMNIGENT_BASE_URL", DEFAULT_BASE_URL).rstrip("/"),
            origin=os.environ.get("OMNIGENT_ORIGIN", DEFAULT_ORIGIN),
            agent_id=os.environ.get("SEIDROID_AGENT_ID", DEFAULT_AGENT_ID),
            token=_resolve_token(),
            run_deadline_s=_float("XREVIEW_RUN_DEADLINE_S", 1200.0),
            connect_timeout_s=_float("XREVIEW_CONNECT_TIMEOUT_S", 30.0),
            read_timeout_s=_float("XREVIEW_READ_TIMEOUT_S", 30.0),
            poll_min_interval_s=_float("XREVIEW_POLL_MIN_S", 2.0),
            poll_max_interval_s=_float("XREVIEW_POLL_MAX_S", 10.0),
            max_transient_retries=int(_float("XREVIEW_MAX_RETRIES", 4.0)),
            state_dir=os.environ.get("XREVIEW_STATE_DIR", "/var/lib/seidroid-xreview"),
            settle_confirmations=int(_float("XREVIEW_SETTLE_CONFIRMATIONS", 2.0)),
            verdict_nudges=int(_float("XREVIEW_VERDICT_NUDGES", 2.0)),
        )

    def require_auth(self) -> None:
        if not self.token:
            raise ConfigError(
                "no API credential: set OMNIGENT_API_TOKEN or OMNIGENT_API_TOKEN_FILE"
            )


def _resolve_token() -> str:
    """Read the bearer token from a mounted file if given, else the env.

    The file path is preferred and re-read on each invocation so a
    rotated token is picked up without a code change. A missing or
    unreadable file yields an empty token, which ``require_auth`` then
    rejects loudly rather than silently sending an anonymous request.
    """
    path = os.environ.get("OMNIGENT_API_TOKEN_FILE")
    if path:
        try:
            with open(path, encoding="utf-8") as handle:
                return handle.read().strip()
        except OSError:
            return ""
    return os.environ.get("OMNIGENT_API_TOKEN", "").strip()


def _float(name: str, default: float) -> float:
    raw = os.environ.get(name)
    if raw is None or raw == "":
        return default
    try:
        return float(raw)
    except ValueError as exc:
        raise ConfigError(f"{name} must be a number, got {raw!r}") from exc
