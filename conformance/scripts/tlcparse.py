"""Parse the PrintT reports of a ProbeConf TLC run: <<"CONF", pp, {records}>>."""
import json
import re

REC = re.compile(r'\[([^\[\]]*)\]')
FLD = re.compile(r'(\w+) \|-> ("[^"]*"|-?\d+)')


def outcome(recs):
    """A report's records in a canonical form: every field of every record
    (receiver, method, transaction, id, status, gas), order-free."""
    return sorted(json.dumps(r, sort_keys=True) for r in recs)


def parse(text):
    """The reports in a TLC log's text, as ({pp: records}, {pp: number of
    distinct outcomes}) where the second holds the points reported with more
    than one distinct outcome (a nondeterministic model). Every field of a
    record counts, so two reports differing only in, say, the receiver are
    distinct; a point with distinct reports must fail the comparison, whatever
    report is kept for it."""
    txt = " ".join(text.split())
    out, seen = {}, {}
    for m in re.finditer(r'<<\s*"CONF", (\d+), \{(.*?)\}\s*>>', txt):
        pp, body = int(m.group(1)), m.group(2)
        recs = [{k: (v.strip('"') if v.startswith('"') else int(v)) for k, v in FLD.findall(r.group(1))}
                for r in REC.finditer(body)]
        seen.setdefault(pp, set()).add(tuple(outcome(recs)))
        out.setdefault(pp, recs)
    return out, {pp: len(s) for pp, s in seen.items() if len(s) > 1}


def reports(log):
    """`parse` of the log file `log`, read once."""
    with open(log) as f:
        return parse(f.read())
