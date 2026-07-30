"""Typed errors and process exit codes.

Distinct exit codes let the calling job (a CI step or a controller)
tell a clean review from a timeout, a turn failure, or a leaked runner
without scraping logs — each failure mode gets its own code.
"""

from __future__ import annotations

from enum import IntEnum
from typing import Any


class ExitCode(IntEnum):
    """Process exit codes, surfaced to the invoking job."""

    OK = 0
    TURN_FAILED = 1
    NO_VERDICT = 2
    TEARDOWN_LEAK = 3
    TRANSIENT_EXHAUSTED = 75  # EX_TEMPFAIL
    CONFIG = 78  # EX_CONFIG
    TIMEOUT = 124  # coreutils `timeout` convention
    CANCELLED = 130  # terminated by SIGINT/SIGTERM after teardown


class DriverError(Exception):
    """Base class for driver failures."""


class ConfigError(DriverError):
    """Missing or invalid configuration (e.g. no API credential)."""


class TransientExhausted(DriverError):
    """A request kept failing transiently until the retry budget ran out."""


class RunTimeout(DriverError):
    """The overall per-run deadline elapsed before the turn settled."""


class TurnFailed(DriverError):
    """The agent turn reached a failed terminal state."""

    def __init__(self, message: str, detail: Any = None) -> None:
        super().__init__(message)
        self.detail = detail


class ApiError(DriverError):
    """A non-retryable, unexpected HTTP status from the API."""

    def __init__(self, method: str, path: str, status: int, body: str) -> None:
        super().__init__(f"{method} {path} -> {status}: {body[:512]}")
        self.method = method
        self.path = path
        self.status = status
        self.body = body
