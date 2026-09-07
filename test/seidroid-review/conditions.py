#!/usr/bin/env python3
"""Checks which reaction step runs in which job state.

A shell harness cannot see a step condition, and the reaction steps put their
whole cancellation behaviour there: `Answer the request` reads a conclusion and
may post a thumb, so it must not run on a cancelled run, and the withdrawal step
must.

This models the GitHub expression engine over the subset the three conditions
use: &&, ||, !, parentheses, == and !=, single-quoted strings, the status
functions, and dotted context reads. It applies the runner's own wrapping rule --
actions/runner, PipelineTemplateConverter.ConvertToIfCondition:

    return hasStatusFunction ? condition : $"{Success}() && ({condition})";

so a condition that names none of always/cancelled/failure/success skips a
cancelled run without saying so.

    conditions.py <workflow>
"""
import re
import sys

import yaml

# step -> job state -> does it run? mode is 'review' with a comment id unless said.
#
# The cancelled column is the invariant. `Answer the request` reads check_path and
# verdict_produced, and a cancellation arriving after the driver finishes leaves both
# populated -- so a run of it on a cancelled job posts a thumb for a verdict that no
# step published.
EXPECTED = {
    "Acknowledge the trigger": {
        ("success", "review", "7"): True,
        ("failure", "review", "7"): False,
        ("cancelled", "review", "7"): False,
        ("success", "review", ""): False,
        ("success", "close", "7"): False,
    },
    "Answer the request": {
        ("success", "review", "7"): True,
        ("failure", "review", "7"): True,
        ("cancelled", "review", "7"): False,
        ("success", "review", ""): False,
        ("success", "close", "7"): False,
        ("cancelled", "close", "7"): False,
    },
    "Withdraw the reactions on a cancelled run": {
        ("success", "review", "7"): False,
        ("failure", "review", "7"): False,
        ("cancelled", "review", "7"): True,
        ("cancelled", "review", ""): False,
        ("cancelled", "close", "7"): False,
    },
}

# What a step is allowed to read. A step that runs on a cancelled job must not be
# able to reach a conclusion, or a cancelled run can state an outcome.
CONCLUSION_INPUTS = ("check_path", "verdict_produced")

STATUS_FUNCS = ("always", "cancelled", "failure", "success")

TOKEN = re.compile(
    r"\s*(?:(?P<str>'(?:[^']|'')*')"
    r"|(?P<op>&&|\|\||==|!=|!|\(|\))"
    r"|(?P<word>[A-Za-z_][A-Za-z0-9_.\-]*))"
)


def lex(text):
    pos, out = 0, []
    while pos < len(text):
        if text[pos].isspace():
            pos += 1
            continue
        m = TOKEN.match(text, pos)
        if not m:
            raise SyntaxError(f"cannot lex at {text[pos:pos + 20]!r}")
        pos = m.end()
        if m.group("str") is not None:
            out.append(("str", m.group("str")[1:-1].replace("''", "'")))
        elif m.group("op") is not None:
            out.append(("op", m.group("op")))
        else:
            out.append(("word", m.group("word")))
    return out


class Unknown:
    """A term this model does not decide."""

    def __repr__(self):
        return "UNKNOWN"


UNKNOWN = Unknown()


class Ctx:
    def __init__(self, state, mode, comment_id, lenient=False):
        self.state = state
        self.lenient = lenient
        self.values = {
            "inputs.mode": mode,
            "needs.guard.outputs.comment_id": comment_id,
        }

    def func(self, name):
        if name == "always":
            return True
        if name in ("cancelled", "success", "failure"):
            return self.state == ("cancelled" if name == "cancelled" else name)
        raise KeyError(f"unmodelled function {name}()")

    def read(self, path):
        if path not in self.values:
            # The sweep at the end asks only whether a step can run on a cancelled
            # job. Every other term is UNKNOWN, and the three-valued operators keep
            # the answer sound without modelling contexts this file does not decide.
            if self.lenient:
                return UNKNOWN
            raise KeyError(f"unmodelled context read {path}")
        return self.values[path]


def truthy(value):
    if value is UNKNOWN:
        return UNKNOWN
    if isinstance(value, bool):
        return value
    if isinstance(value, str):
        return value != ""
    return bool(value)


def and3(left, right):
    if left is False or right is False:
        return False
    if left is UNKNOWN or right is UNKNOWN:
        return UNKNOWN
    return True


def or3(left, right):
    if left is True or right is True:
        return True
    if left is UNKNOWN or right is UNKNOWN:
        return UNKNOWN
    return True if (left or right) else False


def not3(value):
    return UNKNOWN if value is UNKNOWN else (not value)


class Parser:
    def __init__(self, tokens, ctx):
        self.t, self.i, self.ctx = tokens, 0, ctx

    def peek(self):
        return self.t[self.i] if self.i < len(self.t) else (None, None)

    def take(self, kind=None, value=None):
        k, v = self.peek()
        if kind and (k != kind or (value is not None and v != value)):
            raise SyntaxError(f"expected {value or kind}, found {v!r}")
        self.i += 1
        return v

    def parse(self):
        value = self.or_()
        if self.i != len(self.t):
            raise SyntaxError(f"trailing tokens at {self.t[self.i:]}")
        return value

    def or_(self):
        left = self.and_()
        while self.peek() == ("op", "||"):
            self.take()
            right = self.and_()          # parsed first: Python's or short-circuits
            left = or3(truthy(left), truthy(right))
        return left

    def and_(self):
        left = self.cmp_()
        while self.peek() == ("op", "&&"):
            self.take()
            right = self.cmp_()
            left = and3(truthy(left), truthy(right))
        return left

    def cmp_(self):
        left = self.unary()
        k, v = self.peek()
        if k == "op" and v in ("==", "!="):
            self.take()
            right = self.unary()
            if left is UNKNOWN or right is UNKNOWN:
                return UNKNOWN
            return (left == right) if v == "==" else (left != right)
        return left

    def unary(self):
        if self.peek() == ("op", "!"):
            self.take()
            return not3(truthy(self.unary()))
        return self.primary()

    def primary(self):
        k, v = self.peek()
        if k == "op" and v == "(":
            self.take()
            inner = self.or_()
            self.take("op", ")")
            return inner
        if k == "str":
            return self.take()
        if k == "word":
            name = self.take()
            if self.peek() == ("op", "("):
                self.take()
                self.take("op", ")")
                return self.ctx.func(name)
            if name in ("true", "false"):
                return name == "true"
            return self.ctx.read(name)
        raise SyntaxError(f"unexpected {v!r}")


def stored_condition(raw):
    """What the runner keeps as the step condition."""
    expr = " ".join(str(raw).split())
    if expr.startswith("${{") and expr.endswith("}}"):
        expr = expr[3:-2].strip()
    if {v for k, v in lex(expr) if k == "word"} & set(STATUS_FUNCS):
        return expr
    return f"success() && ({expr})"


def main():
    with open(sys.argv[1], encoding="utf-8") as handle:
        doc = yaml.safe_load(handle)
    steps = {s["name"]: s for s in doc["jobs"]["review"]["steps"] if "name" in s}

    passed = failed = 0

    def check(label, want, got):
        nonlocal passed, failed
        if want == got:
            passed += 1
        else:
            failed += 1
            print(f"  FAIL {label}: want [{want}] got [{got}]")

    for name, cases in EXPECTED.items():
        if name not in steps:
            print(f"  FAIL no step named {name!r} in the review job")
            failed += 1
            continue
        expr = stored_condition(steps[name].get("if", "success()"))
        print(f"== {name}\n   {expr}")
        for (state, mode, cid), want in cases.items():
            got = truthy(Parser(lex(expr), Ctx(state, mode, cid)).parse())
            check(f"{name} / {state} / {mode} / id={cid or 'empty'}", want, got)

    # Whatever the table above says, no step that can reach a conclusion may run on a
    # cancelled job. This is the invariant, stated over the file rather than over the
    # table, so a step added later is covered too.
    print("== nothing that reads a conclusion runs on a cancelled run")
    for name, step in steps.items():
        expr = stored_condition(step.get("if", "success()"))
        verdict = truthy(
            Parser(lex(expr), Ctx("cancelled", "review", "7", lenient=True)).parse()
        )
        # UNKNOWN counts as "can run": the check must not pass because a term went
        # unmodelled.
        runs = verdict is not False
        env = " ".join(str(v) for v in (step.get("env") or {}).values())
        reads = [k for k in CONCLUSION_INPUTS if k in env]
        if runs and reads:
            print(f"  FAIL {name} runs on a cancelled run and reads {', '.join(reads)}")
            failed += 1
        else:
            passed += 1

    print(f"\nassertions: {passed} passed, {failed} failed")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
