"""Parse the text output of a TLC run (tla2tools v1.7.4, TLC 2.19) into a verdict.

`parse(text, exit_code=None)` returns a `Result` with:

- `verdict`: one of
    "pass"        "Model checking completed. No error has been found."
    "violation"   "Invariant X is violated", "Action property X is violated",
                  or "Temporal properties were violated" (name "<temporal>")
    "assert"      "The first argument of Assert evaluated to FALSE"
    "assumption"  "Assumption line ... is false"
    "deadlock"    "Deadlock reached" (only when TLC runs without -deadlock)
    "error"       parse/semantic errors, evaluation errors, unknown config names,
                  or a nonzero exit code with no recognised verdict
    "unfinished"  none of the above (e.g. the run was killed)
- `name`: the violated invariant/property, or None;
- `message`: a one-line detail (the Assert message, the error text, ...);
- `generated`, `distinct`, `left`: state counts from the last progress/final line;
- `depth`: the search depth, if printed;
- `tlc_seconds`: TLC's own "Finished in" time, if printed.

Precedence: a log can contain several "Error:" lines, so parse/semantic errors are
checked first, then Assert, then violations, then assumptions, deadlock and pass.
"""

from __future__ import annotations

import re
from dataclasses import dataclass, field

PARSE_ERROR_PATTERNS = (
    r"Parsing or semantic analysis failed",
    r"\*\*\*\s*Parse Error\s*\*\*\*",
    r"\*\*\* Errors: \d+",
    r"^Semantic errors:",
    r"Fatal errors while parsing",
    r"Could not parse module",
)

_STATES = re.compile(
    r"([\d,]+) states generated(?: \([^)]*\))?, ([\d,]+) distinct states found"
    r"(?: \([^)]*\))?, ([\d,]+) states left on queue"
)
_DEPTH = re.compile(r"The depth of the complete state graph search is (\d+)")
_FINISHED = re.compile(r"Finished in (?:(\d+)h )?(?:(\d+)min )?(\d+)s")


@dataclass
class Result:
    verdict: str = "unfinished"
    name: str | None = None
    message: str = ""
    generated: int | None = None
    distinct: int | None = None
    left: int | None = None
    depth: int | None = None
    tlc_seconds: int | None = None
    exit_code: int | None = None
    extra: dict = field(default_factory=dict)

    def label(self) -> str:
        """Short human-readable verdict, e.g. 'violation Books'."""
        if self.verdict in ("violation", "assert") and self.name:
            return f"{self.verdict} {self.name}"
        return self.verdict


def _int(s: str) -> int:
    return int(s.replace(",", ""))


def _error_message(text: str) -> str:
    """The most informative error line, for reports."""
    for pat in (
        r"^(Unknown operator: .*)$",
        r"^(Was expecting .*)$",
        r"^(Encountered .*)$",
        r"Error: (The (?:invariant|property|constant|operator) .*)$",
        r"^(Attempted .*)$",
        r"^(TLC threw .*)$",
        r"^(Error: Evaluating .*)$",
        r"^Error: (.*)$",
        r"^(Exception in thread .*)$",
    ):
        m = re.search(pat, text, re.M)
        if m:
            # TLC wraps some messages over a few lines; join them up to a blank line.
            parts = [m.group(1).strip()]
            for line in text[m.end():].splitlines()[1:4]:
                if not line.strip() or line.startswith(("Error:", "Finished", "Starting")):
                    break
                parts.append(line.strip())
            return " ".join(parts)[:300]
    return ""


def parse(text: str, exit_code: int | None = None) -> Result:
    r = Result(exit_code=exit_code)

    states = _STATES.findall(text)
    if states:
        g, d, q = states[-1]
        r.generated, r.distinct, r.left = _int(g), _int(d), _int(q)
    m = _DEPTH.search(text)
    if m:
        r.depth = int(m.group(1))
    m = _FINISHED.search(text)
    if m:
        h, mi, s = (int(x) if x else 0 for x in m.groups())
        r.tlc_seconds = h * 3600 + mi * 60 + s

    if any(re.search(p, text, re.M) for p in PARSE_ERROR_PATTERNS):
        r.verdict, r.message = "error", "parse/semantic: " + _error_message(text)
        return r

    m = re.search(r"The first argument of Assert evaluated to FALSE; the second argument was:\s*\n?(.*)", text)
    if m:
        r.verdict, r.message = "assert", m.group(1).strip()[:300]
        r.name = None
        return r
    if "The first argument of Assert evaluated to FALSE" in text:
        r.verdict = "assert"
        return r

    m = re.search(r"Error: Invariant (\S+) is violated", text)
    if m:
        r.verdict, r.name = "violation", m.group(1).rstrip(".")
        return r
    m = re.search(r"Error: Action property (\S+) is violated", text)
    if m:
        r.verdict, r.name = "violation", m.group(1).rstrip(".")
        return r
    if re.search(r"Error: Temporal properties were violated", text):
        r.verdict, r.name = "violation", "<temporal>"
        return r

    m = re.search(r"Error: Assumption (.*) is false\.", text)
    if m:
        r.verdict, r.message = "assumption", m.group(1).strip()
        return r
    if re.search(r"Error: Deadlock reached", text):
        r.verdict = "deadlock"
        return r
    if re.search(r"^Error: ", text, re.M):
        r.verdict, r.message = "error", _error_message(text)
        return r
    if "Model checking completed. No error has been found." in text:
        r.verdict = "pass"
        return r
    if exit_code not in (None, 0):
        r.verdict = "error"
        r.message = _error_message(text) or f"TLC exited with code {exit_code}"
    return r
