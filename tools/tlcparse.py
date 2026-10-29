"""Parse the text output of a TLC run (tla2tools v1.7.4, TLC 2.19) into a verdict.

`parse(text, exit_code)` returns a `Result` with:

- `verdict`: one of
    "pass"        exit code 0 and a line starting "Model checking completed. No error
                  has been found"
    "violation"   "Invariant X is violated", "Action property X is violated",
                  "The invariant of X is equal to FALSE" (an invariant that reads
                  no variable, checked before the search), or "Temporal
                  properties were violated" (TLC does not name the property;
                  `name` is then "<temporal>")
    "assert"      "The first argument of Assert evaluated to FALSE"
    "assumption"  "Assumption line ... is false"
    "deadlock"    "Deadlock reached" (only when TLC runs without -deadlock)
    "error"       parse/semantic errors, evaluation errors, unknown config names,
                  or a nonzero exit code with no recognized verdict
    "unfinished"  none of the above (e.g. the run was killed)
- `name`: the violated invariant/property, or None;
- `message`: a one-line detail (the Assert message, the error text, ...);
- `generated`, `distinct`: state counts from the last progress/final line;
- `depth`: the search depth, if printed;
- `tlc_seconds`: TLC's own "Finished in" time, if printed.

All patterns are anchored at the start of a line. TLC prints these messages at
column 0, while PrintT output of a string starts with a quote, so a spec that prints
one of these sentences cannot fake a verdict.

Precedence: a log can contain several "Error:" lines, so parse/semantic errors are
checked first, then Assert, then violations, then assumptions, deadlock and pass.
"""

from __future__ import annotations

import re
from dataclasses import dataclass

PARSE_ERROR_PATTERNS = (
    r"^Error: Parsing or semantic analysis failed",
    r"^\*\*\*\s*Parse Error\s*\*\*\*",
    r"^\*\*\* Errors: \d+",
    r"^Semantic errors:",
    r"^Fatal errors while parsing",
    r"^Could not parse module",
)

_STATES = re.compile(
    r"^(?:Progress\(\d+\) at [^:]*:\d\d:\d\d: )?([\d,]+) states generated(?: \([^)]*\))?, "
    r"([\d,]+) distinct states found", re.M)
_DEPTH = re.compile(r"^The depth of the complete state graph search is (\d+)", re.M)
_FINISHED = re.compile(r"^Finished in (?:(\d+)h )?(?:(\d+)min )?(\d+)s", re.M)
_PASS = re.compile(r"^Model checking completed\. No error has been found", re.M)


@dataclass
class Result:
    verdict: str = "unfinished"
    name: str | None = None
    message: str = ""
    generated: int | None = None
    distinct: int | None = None
    depth: int | None = None
    tlc_seconds: int | None = None
    exit_code: int | None = None

    def label(self) -> str:
        """Short human-readable verdict, e.g. 'violation Books'."""
        if self.verdict == "violation" and self.name:
            return f"violation {self.name}"
        return self.verdict


def _int(s: str) -> int:
    return int(s.replace(",", ""))


# SANY's specific complaints. The log's last line, "Error: Parsing or semantic analysis
# failed.", says nothing more, so these come before it.
SANY_MESSAGES = (
    r"^(Multiply-defined symbol .*)$",
    r"^(Cannot find source file for module .*)$",
)
# the first complaint SANY locates ("line 3, col 1 to ... of module M", a blank line, the text)
SANY_LOCATED = r"^line \d+, col \d+ to line \d+, col \d+ of module \w+\s*\n\s*\n(.+)$"


def _error_message(text: str, sany: bool = False) -> str:
    """The most informative error line, for reports. `sany`: a parse or semantic failure,
    whose specific message comes before the closing "Error: ... failed." line."""
    for pat in (SANY_MESSAGES if sany else ()) + (
        r"^(Unknown operator: .*)$",
        r"^(Was expecting .*)$",
        r"^(Encountered .*)$",
        r"^Error: (The (?:invariant|property|constant|operator) .*)$",
        r"^(Attempted .*)$",
        r"^(TLC threw .*)$",
        r"^(Error: Evaluating .*)$",
    ) + ((SANY_LOCATED,) if sany else ()) + (
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


def parse(text: str, exit_code: int | None) -> Result:
    r = Result(exit_code=exit_code)

    states = _STATES.findall(text)
    if states:
        r.generated, r.distinct = _int(states[-1][0]), _int(states[-1][1])
    m = _DEPTH.search(text)
    if m:
        r.depth = int(m.group(1))
    m = _FINISHED.search(text)
    if m:
        h, mi, s = (int(x) if x else 0 for x in m.groups())
        r.tlc_seconds = h * 3600 + mi * 60 + s

    def found(pat):
        return re.search(pat, text, re.M)

    if any(found(p) for p in PARSE_ERROR_PATTERNS):
        r.verdict, r.message = "error", "parse/semantic: " + _error_message(text, sany=True)
        return r
    m = found(r"^Error: The first argument of Assert evaluated to FALSE; the second argument was:[ \t]*\n?"
              r"((?:(?!Error:).+\n?)*)")
    if m:
        # TLC prints a tuple one element per line; join it into one line.
        r.verdict, r.message = "assert", " ".join(m.group(1).split())[:300]
        return r
    if found(r"^Error: The first argument of Assert evaluated to FALSE"):
        r.verdict = "assert"
        return r
    m = (found(r"^Error: Invariant (\S+) is violated") or found(r"^Error: Action property (\S+) is violated")
         # an invariant that reads no variable is evaluated once, before the search
         or found(r"^Error: The invariant of (\S+) is equal to FALSE\s*$"))
    if m:
        r.verdict, r.name = "violation", m.group(1).rstrip(".")
        return r
    if found(r"^Error: Temporal properties were violated"):
        r.verdict, r.name = "violation", "<temporal>"
        return r
    m = found(r"^Error: Assumption (.*) is false\.")
    if m:
        r.verdict, r.message = "assumption", m.group(1).strip()
        return r
    if found(r"^Error: Deadlock reached"):
        r.verdict = "deadlock"
        return r
    if found(r"^Error: "):
        r.verdict, r.message = "error", _error_message(text)
        return r
    if _PASS.search(text):
        if exit_code == 0:
            r.verdict = "pass"
        else:
            r.verdict, r.message = "error", f"TLC reported no error but exited with code {exit_code}"
        return r
    if exit_code not in (None, 0):
        r.verdict = "error"
        r.message = _error_message(text) or f"TLC exited with code {exit_code}"
    return r
