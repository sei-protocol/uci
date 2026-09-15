#!/usr/bin/env python3
"""Checks the review's two time limits against each other, and against a measurement.

A review has three clocks and only one of them is the driver's. The driver's own
budget bounds the review turn; the job cap bounds everything, including the work
that sits outside that budget. Set them wrong in either direction and the failure
is quiet:

  * a budget the reviews of the day are already reaching publishes NOTHING -- not
    a failing check, no findings, a pull request that reads as unreviewed rather
    than as broken;
  * a job cap at or under the budget lets the runner kill the job first, so the
    annotation says only that the job was cancelled and the driver's own report
    of WHY it timed out never gets written.

Neither shows up in a workflow that parses, so both are stated here.

    deadline.py <workflow>
"""
import sys

import yaml

# The longest review turn measured on sei-protocol/platform, in seconds: PR 1676,
# run 34556506000's predecessor, prompt sent 01:46:32 and reply 02:03:41. PR 1681
# ran 943s the same day. Both against the 1200s that was the driver's default, so
# the ceiling was being approached routinely rather than exceeded exceptionally --
# and two runs (PRs 1670 and 1671) did exceed it and published no verdict.
#
# A measurement, not a constant: re-measure it rather than trusting the number if
# the reviewer's reading habits change. What it is FOR is the multiplier below.
LONGEST_OBSERVED_TURN_S = 1029

# The budget must clear the longest observed turn by half again. A review that
# ranges wider than any yet seen is the normal case this has to survive; sizing to
# the observed maximum would put the next one over.
DEADLINE_HEADROOM = 1.5

# The job cap must clear the budget by 40%. A review costs more wall-clock than
# its own deadline: the scout pass, two sandbox launches, the driver install and
# the publish steps all sit outside it. Measured at ~90s of fixed overhead plus a
# scout turn, against a budget in the hundreds of seconds.
JOB_CAP_MARGIN = 1.4

DRIVE_STEP = "Drive session + collect verdict"
BUILD_STEP_ENV_KEY = "MIN_DRIVER_VERSION"

passed = failed = 0


def check(what, want, got):
    global passed, failed
    ok = want == got
    if ok:
        passed += 1
        print(f"  ok    {what}")
    else:
        failed += 1
        print(f"  FAIL  {what}: want {want!r}, got {got!r}")


def steps(wf):
    for job in wf.get("jobs", {}).values():
        for st in job.get("steps", []) or []:
            yield st


def step_named(wf, name):
    for st in steps(wf):
        if st.get("name") == name:
            return st
    return None


def main():
    if len(sys.argv) != 2:
        print(__doc__, file=sys.stderr)
        return 2
    wf = yaml.safe_load(open(sys.argv[1], encoding="utf-8"))
    # PyYAML reads the `on:` key as the boolean True.
    triggers = wf.get("on", wf.get(True))
    inputs = triggers["workflow_call"]["inputs"]

    print("the deadline input")
    spec = inputs.get("run-deadline-seconds", {})
    check("run-deadline-seconds is declared", True, bool(spec))
    check("run-deadline-seconds is a number", "number", spec.get("type"))
    deadline = spec.get("default")
    check(
        f"the deadline clears {DEADLINE_HEADROOM}x the longest observed turn "
        f"({LONGEST_OBSERVED_TURN_S}s)",
        True,
        isinstance(deadline, int) and deadline >= LONGEST_OBSERVED_TURN_S * DEADLINE_HEADROOM,
    )

    print("\nthe job cap")
    cap_minutes = inputs.get("timeout-minutes", {}).get("default")
    check("timeout-minutes has a numeric default", True, isinstance(cap_minutes, int))
    if isinstance(cap_minutes, int) and isinstance(deadline, int):
        check(
            f"the job cap ({cap_minutes}m) clears {JOB_CAP_MARGIN}x the deadline "
            f"({deadline}s), so a timeout is the driver's report and not the "
            f"runner's cancellation",
            True,
            cap_minutes * 60 > deadline * JOB_CAP_MARGIN,
        )

    print("\nthe wiring")
    drive = step_named(wf, DRIVE_STEP)
    check(f"{DRIVE_STEP!r} is in the workflow", True, drive is not None)
    if drive is not None:
        env = drive.get("env", {}) or {}
        # The driver reads the budget from its environment. Declaring the input and
        # never handing it over is the failure this catches: the workflow parses, the
        # caller can set the key, and the driver goes on using its own default.
        check(
            "the drive step passes SEIDROID_RUN_DEADLINE_S",
            "${{ inputs.run-deadline-seconds }}",
            env.get("SEIDROID_RUN_DEADLINE_S"),
        )

    print("\nthe driver floor")
    # Two places carry the driver version and the workflow's own comment says
    # nothing enforces it. Raising the floor alone fails every caller that omits the
    # input, loudly. Raising the default alone leaves a floor admitting a driver
    # this file no longer drives, quietly. This is the check that comment asks for.
    floor = None
    for st in steps(wf):
        env = st.get("env", {}) or {}
        if BUILD_STEP_ENV_KEY in env:
            floor = env[BUILD_STEP_ENV_KEY]
            break
    check(f"{BUILD_STEP_ENV_KEY} is set on a step", True, floor is not None)
    check(
        "the driver floor and the driver-version default name one version",
        inputs.get("driver-version", {}).get("default"),
        floor,
    )

    print(f"\nassertions: {passed} passed, {failed} failed")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
