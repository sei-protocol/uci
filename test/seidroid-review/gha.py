"""Evaluates a job's `if:` expression out of a workflow file.

The subset covered is the one seidroid-review.yml's own conditions use: the
operators `!`, `==`, `!=`, `<`, `<=`, `>`, `>=`, `&&` and `||`; the functions
`contains`, `fromJSON`, `startsWith`, `endsWith`, `format`, `join`, `toJSON`,
`always`, `cancelled`, `success` and `failure`; and dotted lookups into the
`github`, `inputs`, `needs`, `steps`, `env` and `secrets` contexts.

Four GitHub semantics carry the conditions under test, so they are modelled
exactly and `--selftest` checks each one:

  * `==` on two strings ignores case, and on mixed types casts both to number,
    where null and the empty string are 0 and any other non-numeric string is
    NaN. NaN equals nothing.
  * `a || b` yields `a` when `a` is truthy and `b` otherwise. False, 0, the
    empty string and null are the falsy values. `a && b` yields `a` when `a` is
    falsy and `b` otherwise.
  * BOTH SHORT-CIRCUIT. The runner's Or and And nodes return on the first
    truthy or falsy operand and never evaluate the rest, so an error in an
    operand nothing reaches never surfaces. A model that evaluated eagerly would
    report a failure the runner does not have -- and would make an assertion here
    state the opposite of what a real event does.
  * `contains(array, item)` tests membership under that same loose equality,
    so a listed login matches whatever case it is written in. `contains` over a
    STRING tests substring instead, which is the reading this file's conditions
    must not have.

The fidelity of that model rests on GitHub's published expression semantics,
read rather than measured: nothing here calls a runner.

Usage:
  gha.py <workflow.yml> <job-id> <context.json>   -> prints true or false
  gha.py --expr '<expression>' <context.json>     -> prints true or false
  gha.py --env <workflow.yml> <step> <key> <context.json>  -> prints the value
  gha.py --input <workflow.yml> <input> <field>   -> prints a declared field
  gha.py --selftest                               -> checks the model above
"""

import json
import math
import re
import sys

import yaml

NAN = float("nan")

TOKEN = re.compile(
    r"""\s+
      |(?P<str>'(?:[^']|'')*')
      |(?P<num>\d+(?:\.\d+)?(?:[eE][-+]?\d+)?)
      |(?P<op>==|!=|>=|<=|&&|\|\||[!<>(),.\[\]])
      |(?P<name>[A-Za-z_][A-Za-z0-9_-]*)""",
    re.X,
)


class Bad(Exception):
    """An expression GitHub would refuse, such as fromJSON over a non-JSON input."""


def lex(text):
    tokens, i = [], 0
    while i < len(text):
        m = TOKEN.match(text, i)
        if not m:
            raise Bad("cannot read expression at: " + text[i:i + 20])
        i = m.end()
        for kind in ("str", "num", "op", "name"):
            if m.group(kind) is not None:
                tokens.append((kind, m.group(kind)))
                break
    tokens.append(("end", ""))
    return tokens


class Parser:
    def __init__(self, tokens, ctx):
        self.t, self.i, self.ctx = tokens, 0, ctx
        # False while walking an operand the runner would not reach. The tokens still
        # have to be consumed -- this evaluates as it parses -- so the walk continues
        # and only the function calls are held back, which is where an error lives.
        self.live = True

    def skip(self, parse):
        was, self.live = self.live, False
        try:
            parse()
        finally:
            self.live = was

    def peek(self):
        return self.t[self.i]

    def take(self, value=None):
        kind, text = self.t[self.i]
        if value is not None and text != value:
            raise Bad("expected %r, found %r" % (value, text))
        self.i += 1
        return text

    def parse(self):
        value = self.or_()
        if self.peek()[0] != "end":
            raise Bad("trailing input at %r" % (self.peek()[1],))
        return value

    def or_(self):
        left = self.and_()
        while self.peek()[1] == "||":
            self.take()
            if truthy(left):
                self.skip(self.and_)
            else:
                left = self.and_()
        return left

    def and_(self):
        left = self.compare()
        while self.peek()[1] == "&&":
            self.take()
            if truthy(left):
                left = self.compare()
            else:
                self.skip(self.compare)
        return left

    def compare(self):
        left = self.unary()
        while self.peek()[1] in ("==", "!=", "<", "<=", ">", ">="):
            op = self.take()
            right = self.unary()
            if op == "==":
                left = loose_eq(left, right)
            elif op == "!=":
                left = not loose_eq(left, right)
            else:
                a, b = to_number(left), to_number(right)
                if math.isnan(a) or math.isnan(b):
                    left = False
                else:
                    left = {"<": a < b, "<=": a <= b, ">": a > b, ">=": a >= b}[op]
        return left

    def unary(self):
        if self.peek()[1] == "!":
            self.take()
            return not truthy(self.unary())
        return self.primary()

    def primary(self):
        kind, text = self.peek()
        if text == "(":
            self.take()
            value = self.or_()
            self.take(")")
            return value
        if kind == "str":
            self.take()
            return text[1:-1].replace("''", "'")
        if kind == "num":
            self.take()
            return float(text)
        if kind != "name":
            raise Bad("unexpected %r" % (text,))
        self.take()
        if text == "true":
            return True
        if text == "false":
            return False
        if text == "null":
            return None
        if self.peek()[1] == "(":
            return self.call(text)
        return self.path(self.ctx.get(text, {}))

    def path(self, value):
        while self.peek()[1] == ".":
            self.take()
            key = self.take()
            value = value.get(key) if isinstance(value, dict) else None
        return value

    def call(self, name):
        self.take("(")
        args = []
        if self.peek()[1] != ")":
            args.append(self.or_())
            while self.peek()[1] == ",":
                self.take()
                args.append(self.or_())
        self.take(")")
        # An unreached call is not made, which is the whole of short-circuiting: this
        # is where fromJSON would refuse a value the runner never looks at.
        if not self.live:
            return None
        return apply_function(name, args)


def apply_function(name, args):
    if name == "always":
        return True
    if name == "success":
        return True
    if name in ("cancelled", "failure"):
        return False
    if name == "contains":
        return gha_contains(args[0], args[1])
    if name == "startsWith":
        return as_string(args[0]).lower().startswith(as_string(args[1]).lower())
    if name == "endsWith":
        return as_string(args[0]).lower().endswith(as_string(args[1]).lower())
    if name == "fromJSON":
        try:
            return json.loads(as_string(args[0]))
        except ValueError as err:
            raise Bad("fromJSON: %s" % (err,))
    if name == "toJSON":
        return json.dumps(args[0])
    if name == "format":
        out = as_string(args[0])
        for index, value in enumerate(args[1:]):
            out = out.replace("{%d}" % index, as_string(value))
        return out
    if name == "join":
        sep = as_string(args[1]) if len(args) > 1 else ","
        items = args[0] if isinstance(args[0], list) else [args[0]]
        return sep.join(as_string(item) for item in items)
    raise Bad("unsupported function: " + name)


def truthy(value):
    if value is None or value is False:
        return False
    if value is True:
        return True
    if isinstance(value, (int, float)):
        return not (value == 0 or math.isnan(value))
    if isinstance(value, str):
        return value != ""
    return True


def to_number(value):
    if value is None:
        return 0.0
    if isinstance(value, bool):
        return 1.0 if value else 0.0
    if isinstance(value, (int, float)):
        return float(value)
    if isinstance(value, str):
        text = value.strip()
        if text == "":
            return 0.0
        try:
            return float(int(text, 16)) if text[:2].lower() == "0x" else float(text)
        except ValueError:
            return NAN
    return NAN


def as_string(value):
    if value is None:
        return ""
    if value is True:
        return "true"
    if value is False:
        return "false"
    if isinstance(value, float) and value.is_integer():
        return str(int(value))
    if isinstance(value, (list, dict)):
        return json.dumps(value)
    return str(value)


def loose_eq(a, b):
    if isinstance(a, str) and isinstance(b, str):
        return a.lower() == b.lower()
    if isinstance(a, bool) and isinstance(b, bool):
        return a is b
    if a is None and b is None:
        return True
    if isinstance(a, (list, dict)) or isinstance(b, (list, dict)):
        return a is b
    x, y = to_number(a), to_number(b)
    if math.isnan(x) or math.isnan(y):
        return False
    return x == y


def gha_contains(search, item):
    if isinstance(search, list):
        return any(loose_eq(element, item) for element in search)
    if isinstance(search, dict):
        return False
    return as_string(item).lower() in as_string(search).lower()


def evaluate(text, ctx):
    text = text.strip()
    if text.startswith("${{") and text.endswith("}}"):
        text = text[3:-2]
    return Parser(lex(text), ctx).parse()


def job_condition(workflow, job_id):
    doc = yaml.safe_load(open(workflow, encoding="utf-8"))
    job = doc["jobs"][job_id]
    if "if" not in job:
        sys.exit("job has no if: " + job_id)
    return job["if"]


def input_field(workflow, name, field):
    """One field of one workflow_call input, so a declared default is testable."""
    doc = yaml.safe_load(open(workflow, encoding="utf-8"))
    # PyYAML reads the `on:` key as the boolean True.
    triggers = doc.get("on", doc.get(True))
    spec = triggers["workflow_call"]["inputs"]
    if name not in spec:
        sys.exit("no such input: " + name)
    return spec[name].get(field)


def step_env(workflow, step, key):
    """The expression a step's env key holds, found by step name or step id.

    The step scripts read these as shell variables, so a script harness cannot
    see them. They are where a per-event payload field is chosen.
    """
    doc = yaml.safe_load(open(workflow, encoding="utf-8"))
    for job in doc["jobs"].values():
        for candidate in job.get("steps", []):
            if candidate.get("name") == step or candidate.get("id") == step:
                env = candidate.get("env") or {}
                if key not in env:
                    sys.exit("step %s has no env %s" % (step, key))
                return env[key]
    sys.exit("step not found: " + step)


SELFTEST = [
    ("'Bot' == 'bot'", True),
    ("'MEMBER' != 'member'", False),
    ("null == ''", True),
    ("null == 'Bot'", False),
    ("'' != 'Bot'", True),
    ("true == 1", True),
    ("'' || 'second'", "second"),
    ("'first' || 'second'", "first"),
    ("null || ''", ""),
    ("contains(fromJSON('[\"dependabot[bot]\"]'), 'DependaBot[BOT]')", True),
    ("contains(fromJSON('[\"dependabot[bot]\"]'), 'bot')", False),
    ("contains('[\"dependabot[bot]\"]', 'bot')", True),
    ("contains(fromJSON('[]'), 'anyone')", False),
    ("!contains(fromJSON('[\"a\",\"b\"]'), 'c')", True),
    # Short-circuiting, stated as the three shapes the conditions rely on.
    ("true || fromJSON('not json')", True),
    ("false && fromJSON('not json')", False),
    ("'' || '[]'", "[]"),
    ("'[\"x\"]' || '[]'", '["x"]'),
]


def selftest():
    failed = 0
    for expression, want in SELFTEST:
        got = evaluate(expression, {})
        if got != want:
            failed += 1
            print("  FAIL %s: want %r got %r" % (expression, want, got))
    print("gha.py selftest: %d of %d checks passed" % (len(SELFTEST) - failed, len(SELFTEST)))
    return 1 if failed else 0


def main(argv):
    if argv[1:2] == ["--selftest"]:
        return selftest()
    raw = False
    if argv[1:2] == ["--expr"]:
        text, ctx_path = argv[2], argv[3]
    elif argv[1:2] == ["--input"]:
        print(as_string(input_field(argv[2], argv[3], argv[4])))
        return 0
    elif argv[1:2] == ["--env"]:
        # The value a step's env key resolves to, printed as the shell would see
        # it rather than as a truth value.
        text, ctx_path, raw = step_env(argv[2], argv[3], argv[4]), argv[5], True
    else:
        text, ctx_path = job_condition(argv[1], argv[2]), argv[3]
    ctx = json.load(open(ctx_path, encoding="utf-8"))
    try:
        value = evaluate(text, ctx)
    except Bad as err:
        print("error: %s" % (err,), file=sys.stderr)
        return 2
    print(as_string(value) if raw else ("true" if truthy(value) else "false"))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
