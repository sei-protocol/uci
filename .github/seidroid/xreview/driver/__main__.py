"""CLI entrypoint: ``python -m driver <repo> <pr>``."""

from __future__ import annotations

import argparse
import json
import signal
import sys

from .config import DriverConfig
from .driver import ReviewRequest, RunResult, SessionDriver, emit
from .errors import ConfigError, ExitCode


def main(argv: list[str] | None = None) -> int:
    args = _parse_args(argv)
    try:
        cfg = DriverConfig.from_env()
        cfg.require_auth()
    except ConfigError as exc:
        emit("config.error", error=str(exc))
        return int(ExitCode.CONFIG)

    _install_terminate_handlers()

    trigger_id = args.trigger_id or f"manual:{args.repo}#{args.pr}"
    req = ReviewRequest(repo=args.repo, pr=args.pr, trigger_id=trigger_id)
    try:
        result = SessionDriver(cfg).run(req)
    except KeyboardInterrupt:
        # A terminate signal unwound the run; the run's finally block runs
        # teardown (DELETE the session) on the way out. Best-effort, not
        # guaranteed: if the pre-SIGKILL grace period is shorter than
        # teardown's HTTP calls, or a second signal lands mid-DELETE, the
        # session can still leak. A server-side session TTL is the backstop.
        emit("run.cancelled")
        return int(ExitCode.CANCELLED)

    if result.verdict is not None:
        payload = {
            "session_id": result.session_id,
            "decision": (result.verdict.structured or {}).get("decision"),
            "structured": result.verdict.structured,
            "text": result.verdict.text,
        }
        print(json.dumps(payload, indent=2))
    if args.out:
        _write_verdict(args.out, result)
    return int(result.exit_code)


def _write_verdict(path: str, result: RunResult) -> None:
    """Write the verdict text for the caller to post — only on a real verdict.

    On a no-verdict outcome (NO_VERDICT / TIMEOUT / TURN_FAILED) the file is
    left absent, so the caller distinguishes "ready to post" from "nothing to
    post" by file existence and never upserts a placeholder over a prior good
    verdict. The exit code still carries the outcome for the caller to surface.
    """
    if result.verdict is None:
        return
    body = result.verdict.text
    if not body.endswith("\n"):
        body += "\n"
    with open(path, "w", encoding="utf-8") as handle:
        handle.write(body)


def _install_terminate_handlers() -> None:
    """Route SIGTERM/SIGINT into the normal unwind so teardown still runs.

    A bare SIGTERM kills the process without running the ``finally`` that
    deletes the omnigent session, leaking it. Converting the first signal
    into ``KeyboardInterrupt`` drives the same teardown path as a clean
    exit; further signals are ignored so teardown can finish.
    """

    def _on_terminate(_signum: int, _frame: object) -> None:
        signal.signal(signal.SIGTERM, signal.SIG_IGN)
        signal.signal(signal.SIGINT, signal.SIG_IGN)
        raise KeyboardInterrupt

    signal.signal(signal.SIGTERM, _on_terminate)
    signal.signal(signal.SIGINT, _on_terminate)


def _parse_args(argv: list[str] | None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(prog="seidroid-xreview")
    parser.add_argument("repo", help='"owner/name" of the repository')
    parser.add_argument("pr", type=int, help="pull request number")
    parser.add_argument(
        "--out",
        default=None,
        help="write the verdict text to this file for the caller to post",
    )
    parser.add_argument(
        "--trigger-id",
        default=None,
        help="idempotency key for this event (e.g. the triggering comment id)",
    )
    return parser.parse_args(argv)


if __name__ == "__main__":
    sys.exit(main())
