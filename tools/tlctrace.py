#!/usr/bin/env python3
"""Summarize the counterexample in a TLC log.

TLC prints a violating behavior as numbered states:

    State 1: <Initial predicate>
    /\\ x = 0
    /\\ y = {}

    State 2: <Next line 7, col 9 to line 7, col 27 of module M>
    ...

`states(text)` returns [(number, action, {var: value})]; values are TLC's text with
whitespace collapsed. `raw_summary(text)` prints the initial state, then for each step
the action name and only the variables that changed.

`summary(text)` does the same for any spec, and for a near-tla model (one with the
platform variables rq and post) tells each step as a story instead:

    State 4: RunReceipt (Tally:82)
        ran #2 work c->d: out of gas
            (tx 1, gas 5000, result to #3)
        data -> #3: Failed

It names the receipt each step ran and how it ended (committed, failed, out of gas,
forced fault), the receipts and data it created, and the other variables that changed,
field by field. Promise-result sentinels are decoded (v = -4 is NOPR). Platform
variables that never change are left out, and the model's own variables are listed
together at the last state, where the invariant failed.

CLI: tlctrace.py [--width N] [--raw] <log>
"""

from __future__ import annotations

import argparse
import re
import sys

_STATE = re.compile(r"^State (\d+): (.*)$")
_VAR = re.compile(r"^(?:/\\ )?([A-Za-z_][A-Za-z0-9_]*) = (.*)$")
_LOC = re.compile(r"^(\S+) line (\d+), col \d+ to line \d+, col \d+ of module (\S+)$")

# NearAsync's platform variables (platformVars) and NearKeys' keyVars. Everything else
# in a trace is the model's own state (token modules' tk and mtk included).
PLATFORM = {"rq", "post", "data", "near", "locked", "proposal", "epoch", "nid", "fails", "paid",
            "minted", "oog", "rlog", "txsig", "created", "burnt", "blk", "stor", "deleted", "code",
            "gcode", "guse", "gnonce", "ofail", "keys", "sigpaid"}
# Told by the story rather than listed as changes.
STORY_VARS = {"rq", "post", "data", "nid", "oog", "fails"}
# Promise-result sentinels (NearAsync: EMPTY, MAL, NONEMPTY, NOPR, JOINTRES).
SENTINELS = {-1: "EMPTY", -2: "MAL", -3: "NONEMPTY", -4: "NOPR", -5: "JOINTRES"}


def _action(header: str) -> str:
    h = header.strip()
    if h.startswith("<") and h.endswith(">"):
        h = h[1:-1]
    return h.split(" line ")[0].strip() or h


def _action_at(header: str) -> str:
    """The action name with its module and line: "Next (Tally:83)"."""
    h = header.strip()
    if h.startswith("<") and h.endswith(">"):
        h = h[1:-1]
    m = _LOC.match(h)
    return f"{m.group(1)} ({m.group(3)}:{m.group(2)})" if m else _action(header)


def _blocks(text: str) -> list[tuple[int, str, dict[str, str]]]:
    out: list[tuple[int, str, dict[str, str]]] = []
    cur: dict[str, str] | None = None  # variables of the state block being read
    var = None
    for line in text.splitlines():
        m = _STATE.match(line)
        if m:
            cur, var = {}, None
            out.append((int(m.group(1)), m.group(2), cur))
            continue
        if cur is None:
            continue
        if not line.strip():  # a blank line ends the state block
            cur = None
            continue
        mv = _VAR.match(line)
        # A new variable starts with "/\ " (several variables) or is the block's first line.
        if mv and (line.startswith("/\\ ") or var is None):
            var = mv.group(1)
            cur[var] = mv.group(2).strip()
        elif var is not None:
            cur[var] += " " + line.strip()
    for _, _, vs in out:
        for k in vs:
            vs[k] = " ".join(vs[k].split())
    return out


def states(text: str) -> list[tuple[int, str, dict[str, str]]]:
    return [(n, _action(h), vs) for n, h, vs in _blocks(text)]


def _cut(s: str, width: int) -> str:
    return s if width <= 0 or len(s) <= width else s[: width - 3] + "..."


def raw_summary(text: str, width: int = 160) -> str:
    st = states(text)
    if not st:
        return "(no counterexample in log)"
    lines = []
    prev: dict[str, str] = {}
    for n, act, vs in st:
        lines.append(f"State {n}: {act}")
        changed = vs if not prev else {k: v for k, v in vs.items() if prev.get(k) != v}
        for k, v in changed.items():
            lines.append(f"    {k} = {_cut(v, width)}")
        if prev and not changed:
            lines.append("    (no change)")
        prev = vs
    return "\n".join(lines)


# ---------------------------------------------------------------- TLC values


class Atom(str):
    """A TLC model value or identifier, printed without quotes."""


class Rec(dict):
    """A record, or a function TLC printed as one."""


class Set(list):
    pass


class Seq(list):
    pass


class Fn(list):
    """A function printed as (k :> v @@ ...): a list of (k, v)."""


class _Parser:
    _TOKEN = re.compile(r'\s*(<<|>>|\|->|:>|@@|"(?:[^"\\]|\\.)*"|-?\d+|[A-Za-z_][A-Za-z0-9_]*|[\[\]{}(),])')

    def __init__(self, text: str):
        self.toks = []
        pos = 0
        text = text.strip()
        while pos < len(text):
            m = self._TOKEN.match(text, pos)
            if not m:
                raise ValueError(f"cannot parse TLC value at {text[pos:pos + 20]!r}")
            self.toks.append(m.group(1))
            pos = m.end()
        self.i = 0

    def peek(self):
        return self.toks[self.i] if self.i < len(self.toks) else None

    def take(self, want=None):
        t = self.peek()
        if t is None or (want is not None and t != want):
            raise ValueError(f"expected {want!r}, got {t!r}")
        self.i += 1
        return t

    def items(self, close: str) -> list:
        out = []
        while self.peek() != close:
            out.append(self.value())
            if self.peek() == ",":
                self.take(",")
        self.take(close)
        return out

    def value(self):
        t = self.take()
        if t == "<<":
            return Seq(self.items(">>"))
        if t == "{":
            return Set(self.items("}"))
        if t == "[":
            rec = Rec()
            while self.peek() != "]":
                k = self.take()
                self.take("|->")
                rec[k] = self.value()
                if self.peek() == ",":
                    self.take(",")
            self.take("]")
            return rec
        if t == "(":
            pairs = Fn()
            while True:
                k = self.value()
                self.take(":>")
                pairs.append((k, self.value()))
                if self.peek() == "@@":
                    self.take("@@")
                    continue
                self.take(")")
                return pairs
        if t.startswith('"'):
            return t[1:-1].replace('\\"', '"').replace("\\\\", "\\")
        if t in ("TRUE", "FALSE"):
            return t == "TRUE"
        if re.fullmatch(r"-?\d+", t):
            return int(t)
        return Atom(t)


def parse_value(text: str):
    p = _Parser(text)
    v = p.value()
    if p.peek() is not None:
        raise ValueError(f"trailing text after value: {p.peek()!r}")
    return v


def fmt(v) -> str:
    """TLC-like text for a parsed value, with promise-result sentinels decoded."""
    if isinstance(v, bool):
        return "TRUE" if v else "FALSE"
    if isinstance(v, Atom):
        return str(v)
    if isinstance(v, str):
        return '"' + v.replace("\\", "\\\\").replace('"', '\\"') + '"'
    if isinstance(v, int):
        return str(v)
    if isinstance(v, Rec):
        res_like = "ok" in v and "v" in v
        parts = []
        for k, x in v.items():
            if res_like and k == "v" and isinstance(x, int) and x in SENTINELS:
                parts.append(f"{k} |-> {SENTINELS[x]}")
            else:
                parts.append(f"{k} |-> {fmt(x)}")
        return "[" + ", ".join(parts) + "]"
    if isinstance(v, Set):
        return "{" + ", ".join(fmt(x) for x in v) + "}"
    if isinstance(v, Seq):
        return "<<" + ", ".join(fmt(x) for x in v) + ">>"
    if isinstance(v, Fn):
        return "(" + " @@ ".join(f"{fmt(k)} :> {fmt(x)}" for k, x in v) + ")"
    return str(v)


# ---------------------------------------------------------------- the story


def result_text(res) -> str:
    """A promise result [ok, v, sz, len] in words."""
    if not isinstance(res, Rec) or "ok" not in res:
        return fmt(res)
    if res.get("v") == -5:
        return "joint callback (not a result)"
    if not res["ok"]:
        return "Failed"
    v = res.get("v")
    s = SENTINELS.get(v, fmt(v)) if isinstance(v, int) else fmt(v)
    if v == -4:
        s = "NOPR (no promise result)"
    size = [f"{res[k]} {u}" for k, u in (("len", "B"), ("sz", "KB")) if res.get(k)]
    return s + (f" ({', '.join(size)})" if size else "")


def _plain(v) -> str:
    return v if isinstance(v, str) and not isinstance(v, Atom) else fmt(v)


def _args(a) -> str:
    """A receipt's args, leaving out fields that hold an empty value ("", <<>>, {}):
    the token modules share one wide argument record, and most of it is unused."""
    if isinstance(a, Rec):
        kept = Rec((k, v) for k, v in a.items() if fmt(v) not in ('""', "<<>>", "{}"))
        return fmt(kept) if kept else ""
    return fmt(a)


def rcpt_head(r) -> str:
    """A receipt's id, method, predecessor and receiver: "#2 work c->d"."""
    if not isinstance(r, Rec) or "id" not in r:
        return fmt(r)
    return f"#{r['id']} {_plain(r.get('m'))} {_plain(r.get('fr'))}->{_plain(r.get('to'))}"


def rcpt_text(r) -> str:
    """One receipt: "#2 work c->d (tx 1, deposit 1, gas 5100, result to #3, args [x |-> 0])"."""
    head = rcpt_head(r)
    return head + (f" ({rcpt_details(r)})" if isinstance(r, Rec) and rcpt_details(r) else "")


def rcpt_details(r) -> str:
    bits = [f"tx {r['tx']}"] if "tx" in r else []
    if r.get("dep"):
        bits.append(f"deposit {fmt(r['dep'])}")
    g = r.get("g")
    if isinstance(g, Seq) and any(x != 0 for x in g):
        bits.append("gas " + ", ".join(fmt(x) for x in g))
    ac = r.get("ac")
    if isinstance(ac, Rec):
        acts = (["CreateAccount"] if ac.get("mk") is True else []) + \
               ([f"DeleteAccount, beneficiary {_plain(ac['bnf'])}"] if ac.get("bnf") not in (None, "") else [])
        if acts:
            bits.append(" + ".join(acts))
    res = r.get("res")
    if isinstance(res, Rec) and res.get("v") != -4:
        bits.append(f"sees {result_text(res)}")
    if r.get("cb"):
        bits.append(f"result to #{r['cb']}")
    for k in ("owed", "dtch"):
        if r.get(k) is True:
            bits.append("owed" if k == "owed" else "detached")
    a = _args(r.get("a")) if "a" in r else ""
    if a:
        bits.append(f"args {a}")
    return ", ".join(bits)


def _inputs(r) -> list:
    """The data ids receipt r waits on: its `ins` for a joint callback, else its own id."""
    ins = r.get("ins") if isinstance(r, Rec) else None
    return list(ins) if isinstance(ins, Seq) else [r.get("id")] if isinstance(r, Rec) else []


def _seeing(r, P: dict, S: dict) -> str:
    """The promise results receipt r consumed when it ran, in input order."""
    gone = [d for d in _new(S.get("data"), P.get("data")) if isinstance(d, Rec)]
    seen = []
    for i in _inputs(r):
        hit = [d for d in gone if d.get("to") == i]
        if hit:
            seen.append(result_text(hit[0]))
    if seen:
        return f", seeing {', '.join(seen)}"
    if "ydl" in r:
        return ", seeing Failed (timed out)"
    return ""


def _waits(r) -> str:
    """For a postponed receipt: what it waits on."""
    if "ydl" in r:
        return f" (postponed: a yield, until resumed or block {r['ydl']})"
    ins = r.get("ins")
    if isinstance(ins, Seq):
        return f" (postponed: a joint callback, waits for the results sent to {', '.join(f'#{x}' for x in ins)})"
    return " (postponed)"


def _by_id(*sets) -> dict:
    out = {}
    for s in sets:
        for r in s if isinstance(s, list) else []:
            if isinstance(r, Rec) and "id" in r:
                out[r["id"]] = r
    return out


def _dup_ids(*sets) -> list:
    ids = [r["id"] for s in sets if isinstance(s, list) for r in s if isinstance(r, Rec) and "id" in r]
    return sorted({i for i in ids if ids.count(i) > 1})


def _new(prev, cur) -> list:
    """Elements of set `cur` not in set `prev`, by their text."""
    seen = {fmt(x) for x in prev} if isinstance(prev, list) else set()
    return [x for x in cur if fmt(x) not in seen] if isinstance(cur, list) else []


def _grew(P: dict, S: dict, k: str) -> list:
    return _new(P.get(k), S.get(k))


def _outcome(r, P: dict, S: dict, added: dict, new_data: list) -> str:
    """How receipt r, gone between states P and S, ended. Read from the platform
    variables: NearAsync's commit and failure paths differ in what they leave behind.
    The rules, in order:
      out of gas        oog gained an element
      forced fault      fails grew
      burnt             a refund ran and burnt grew (its receiver is gone)
      account action    deleted or created gained an account: the action committed
      failed            a Failed data receipt went to r's callback, or nothing but a fresh
                        id changed, or a system refund with the next id appeared while no
                        balance moved (a failure leaves `near` unchanged)
      committed         anything else
    """
    if _grew(P, S, "oog"):
        return "out of gas"
    if isinstance(S.get("fails"), int) and S["fails"] > P.get("fails", 0):
        return "failed (forced fault)"
    if r.get("m") == "REFUND" and isinstance(S.get("burnt"), int) and S["burnt"] > P.get("burnt", 0):
        return f"burnt ({_plain(r.get('to'))} does not exist; {S['burnt'] - P.get('burnt', 0)} burnt)"
    gone, made = _grew(P, S, "deleted"), _grew(P, S, "created")
    if gone or made:
        what = [f"deleted {', '.join(_plain(x) for x in gone)}"] if gone else []
        what += [f"created {', '.join(_plain(x) for x in made)}"] if made else []
        return f"committed ({'; '.join(what)})"
    # oog is a set of <<tx, method>>: a second out-of-gas of the same method in the same
    # transaction does not grow it, so that failure reads as a plain one.
    again = " (or out of gas again: oog already holds this tx and method)" \
        if any(fmt(x) == fmt(Seq([r.get("tx"), r.get("m")])) for x in P.get("oog", [])) else ""
    if r.get("cb") and any(isinstance(d, Rec) and d.get("to") == r["cb"] and d.get("ok") is False
                           for d in new_data):
        return "failed" + again
    still = fmt(P.get("near")) == fmt(S.get("near"))
    nid0 = P.get("nid")
    refund = added.get(nid0)
    if still and refund is not None and refund.get("m") == "REFUND" and refund.get("fr") == "system":
        return "failed (deposit refunded)" + again
    if still and isinstance(nid0, int) and S.get("nid") == nid0 + 1 and nid0 not in added and not new_data:
        return "failed" + again
    return "committed"


def _diff(path: str, old, new, out: list, depth: int = 0) -> None:
    if fmt(old) == fmt(new):
        return
    if depth < 3 and isinstance(old, Rec) and isinstance(new, Rec) and old.keys() == new.keys():
        for k in new:
            _diff(f"{path}.{k}" if re.fullmatch(r"[A-Za-z_]\w*", k) else f'{path}["{k}"]',
                  old[k], new[k], out, depth + 1)
        return
    if depth < 3 and isinstance(old, Seq) and isinstance(new, Seq) and len(old) == len(new):
        for i, (a, b) in enumerate(zip(old, new), 1):
            _diff(f"{path}[{i}]", a, b, out, depth + 1)
        return
    if isinstance(old, Set) and isinstance(new, Set):
        for x in _new(old, new):
            out.append(f"{path} + {fmt(x)}")
        for x in _new(new, old):
            out.append(f"{path} - {fmt(x)}")
        return
    out.append(f"{path}: {fmt(old)} -> {fmt(new)}")


def _parsed(vs: dict[str, str]) -> dict:
    out = {}
    for k, v in vs.items():
        try:
            out[k] = parse_value(v)
        except ValueError:
            out[k] = Atom(v)
    return out


def story(text: str, width: int = 160) -> str:
    blocks = _blocks(text)
    if not blocks:
        return "(no counterexample in log)"
    st = [(n, _action_at(h), _parsed(vs)) for n, h, vs in blocks]
    names = list(st[0][2])
    changes = {k for _, _, vs in st[1:] for k in vs if fmt(vs[k]) != fmt(st[0][2].get(k))}
    lines = []
    prev: dict = {}
    for n, act, S in st:
        lines.append(f"State {n}: {act}")
        if not prev:
            shown = [k for k in names if k not in PLATFORM or k in changes]
            for k in shown:
                if k in STORY_VARS and (k == "nid" or fmt(S[k]) in ("{}", "0")):
                    continue
                lines.append(f"    {k} = {_cut(fmt(S[k]), width)}")
            hidden = [k for k in names if k in PLATFORM and k not in changes]
            if hidden:
                lines.append(f"    ({len(hidden)} platform variables never change here; "
                             "to see them, rerun with --keep, then tools/tlctrace.py --raw <log>)")
            prev = S
            continue
        if not S:  # "Stuttering", or a state TLC printed without variables
            continue
        P = prev
        before = _by_id(P.get("rq"), P.get("post"))
        after = _by_id(S.get("rq"), S.get("post"))
        dup = _dup_ids(S.get("rq"), S.get("post"))
        added = {i: r for i, r in after.items() if i not in before}
        new_data = _new(P.get("data"), S.get("data"))
        said = []
        for i, r in before.items():
            if i not in after:
                sees = _seeing(r, P, S)
                said.append(f"ran {rcpt_head(r)}{sees}: {_outcome(r, P, S, added, new_data)}")
                if rcpt_details(r):
                    said.append(f"    ({rcpt_details(r)})")
        old_tx = {r.get("tx") for r in before.values()} | set(range(1, 1 + _txs(P)))
        for i, r in sorted(added.items()):
            where = _waits(r) if any(x is r for x in S.get("post", [])) else ""
            verb = "submitted" if not said and r.get("tx") not in old_tx else "created"
            said.append(f"{verb} {rcpt_text(r)}{where}")
        for i, r in after.items():
            if i in before and fmt(before[i]) != fmt(r):
                said.append(f"updated {rcpt_text(r)}")
        for d in new_data:
            if isinstance(d, Rec) and "to" in d:
                said.append(f"data -> #{d['to']}: {result_text(d)}")
        for k in S:
            if k in STORY_VARS:
                continue
            _diff(k, P.get(k), S[k], said)
        if dup:
            said.append(f"warning: receipts share an id ({', '.join(f'#{i}' for i in dup)}): check the ids "
                        "the model gave them")
        if not said:
            said.append("(no change)")
        lines += [f"    {_cut(s, width)}" for s in said]
        prev = S
    mine = [k for k in names if k not in PLATFORM]
    last = next((vs for _, _, vs in reversed(st) if vs), {})
    if len(st) > 1 and mine:
        lines.append("The model's variables at the last state:")
        lines += [f"    {k} = {_cut(fmt(last[k]), width)}" for k in mine]
    if "fails" in last and "oog" in last:
        lines.append(f"Label: {_label(last)}")
    return "\n".join(lines)


LABELS = {
    "forced": "the forced-fault switch fired; ask whether the network can cause that failure",
    "caller-gas": "a receipt ran out of gas at a prepaid amount the caller chose",
    "no-fault": "no forced fault and no out-of-gas; any failure follows from the code and the accounts",
}


def _label(S: dict) -> str:
    """The library's Label of a counterexample, from its last state (NearAsync's Label)."""
    fails = str(S.get("fails", "0"))
    k = ("forced" if fails.isdigit() and int(fails) > 0
         else "caller-gas" if fmt(S.get("oog")) != "{}" else "no-fault")
    return f"{k} ({LABELS[k]})"


def _txs(S: dict) -> int:
    """Transactions already signed in state S (txsig's length), when TrackSigner is on."""
    t = S.get("txsig")
    return len(t) if isinstance(t, (Seq, Fn)) else 0


def summary(text: str, width: int = 160) -> str:
    """The story for a near-tla trace, else the raw summary."""
    blocks = _blocks(text)
    if blocks and {"rq", "post"} <= set(blocks[0][2]):
        try:
            return story(text, width)
        except (ValueError, KeyError, TypeError):
            pass
    return raw_summary(text, width)


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--width", type=int, default=None,
                    help="truncate values to N chars (0 = no limit; default 160, and no limit with --raw)")
    ap.add_argument("--raw", action="store_true", help="every variable as TLC printed it, changes only")
    ap.add_argument("log")
    a = ap.parse_args(argv)
    with open(a.log, encoding="utf-8", errors="replace") as f:
        text = f.read()
    width = a.width if a.width is not None else (0 if a.raw else 160)
    print(raw_summary(text, width) if a.raw else summary(text, width))
    return 0


if __name__ == "__main__":
    sys.exit(main())
