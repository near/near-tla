"""Parse the PrintT reports of a ProbeConf TLC run: <<"CONF", pp, {records}>>."""
import re

REC = re.compile(r'\[([^\[\]]*)\]')
FLD = re.compile(r'(\w+) \|-> ("[^"]*"|-?\d+)')


def reports(log):
    txt = " ".join(open(log).read().split())
    out = {}
    for m in re.finditer(r'<<\s*"CONF", (\d+), \{(.*?)\}\s*>>', txt):
        pp, body = int(m.group(1)), m.group(2)
        recs = [{k: (v.strip('"') if v.startswith('"') else int(v)) for k, v in FLD.findall(r.group(1))}
                for r in REC.finditer(body)]
        key = sorted((r["id"], r["st"], r["g"]) for r in recs)
        if pp in out:
            assert sorted((r["id"], r["st"], r["g"]) for r in out[pp]) == key, ("nondeterministic outcome", log, pp)
        out[pp] = recs
    return out
