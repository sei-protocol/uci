"""Run-once idempotency via an atomic on-disk lease.

A single (repo, PR, trigger) event must drive exactly one session and
must not re-run if the same event fires again (a retried webhook, a
re-delivered comment). The mechanism is an ``O_EXCL`` lease file keyed
by a hash of the event: the first invocation to create it owns the run;
any later invocation for the same key finds the file and stands down.

Scope: this guards a single-writer deployment. Two concurrent replicas
on separate filesystems would each acquire their own lease and could
both create a session — see the module note on a shared lease store for
the multi-replica case.
"""

from __future__ import annotations

import hashlib
import json
import os
import time
from dataclasses import dataclass
from typing import Any


@dataclass
class Lease:
    path: str
    run_key: str
    owned: bool
    prior: dict[str, Any] | None


def compute_run_key(repo: str, pr: int, trigger_id: str) -> str:
    digest = hashlib.sha256(f"{repo}\x00{pr}\x00{trigger_id}".encode()).hexdigest()
    return digest[:24]


def acquire_lease(state_dir: str, run_key: str, meta: dict[str, Any]) -> Lease:
    """Atomically claim the run key, or report that it is already claimed.

    Returns ``owned=True`` with a fresh lease when this invocation won
    the claim, or ``owned=False`` with the prior lease contents (which
    include any recorded ``session_id`` / verdict) when the key was
    already taken.
    """
    os.makedirs(state_dir, exist_ok=True)
    path = os.path.join(state_dir, f"{run_key}.json")
    payload = {
        "run_key": run_key,
        "state": "acquired",
        "pid": os.getpid(),
        "acquired_at": int(time.time()),
        **meta,
    }
    try:
        fd = os.open(path, os.O_CREAT | os.O_EXCL | os.O_WRONLY, 0o600)
    except FileExistsError:
        return Lease(path=path, run_key=run_key, owned=False, prior=_read(path))
    with os.fdopen(fd, "w", encoding="utf-8") as handle:
        json.dump(payload, handle)
    return Lease(path=path, run_key=run_key, owned=True, prior=None)


def record_session(lease: Lease, session_id: str) -> None:
    """Persist the session id so a crash-restart tears down, not re-creates."""
    _update(lease, {"session_id": session_id, "state": "running"})


def finalize_lease(lease: Lease, state: str, summary: dict[str, Any] | None) -> None:
    """Mark the run terminal. The file is kept so re-fires stay suppressed."""
    patch: dict[str, Any] = {"state": state, "finalized_at": int(time.time())}
    if summary is not None:
        patch["verdict_summary"] = summary
    _update(lease, patch)


def _update(lease: Lease, patch: dict[str, Any]) -> None:
    if not lease.owned:
        return
    current = _read(lease.path) or {}
    current.update(patch)
    tmp = f"{lease.path}.tmp"
    with open(tmp, "w", encoding="utf-8") as handle:
        json.dump(current, handle)
    os.replace(tmp, lease.path)


def _read(path: str) -> dict[str, Any] | None:
    try:
        with open(path, encoding="utf-8") as handle:
            data = json.load(handle)
    except (OSError, ValueError):
        return None
    return data if isinstance(data, dict) else None
