"""The flow sets: a flows file and what the model side needs for it.

mkconf.py, tlc.sh and conform.py take `--set NAME` (default `probes`, so a
command line without it is what it always was). A set's flows file is
swept on its own (`calibrate --flows <flows>`, its sweeps in `data/<flows
stem>`), its calibration table is generated from those sweeps alone, and
its TLC runs go to its own build directory, so two sets never read each
other's data, and a flow name may recur across sets.

  flows    the flows file
  data     its sweeps (calibrate's default for that flows file)
  build    mkconf's MC_<flow> files and tlc.sh's logs
  calib    the generated table module (`calibrate --tla tla/<calib>.tla
           --prefix <prefix>`): <prefix>GasCall, <prefix>GasBurn
  conf     the driver module the MC files extend
  staking  StakingAcct (one account per run, NearAsync's ExecStake)
  over     cfg replacements of the driver's definitions (TLC's `<-`)
  refunds  conform.py also compares deposit refund receipts (by receiver)
"""
import os

HERE = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

SETS = {
    "probes": dict(flows="flows/probes.toml", data="data/probes", build="tla/build", calib="CalibProbes",
                   prefix="Probe", conf="ProbeConf", staking="p", over={}, refunds=False),
    # probe2's rule parts (Probe2Conf.tla): the world adds z (probe2) and bob.
    "probes2": dict(flows="flows/probes2.toml", data="data/probes2", build="tla/build/probes2", calib="CalibProbes2",
                    prefix="Probe2", conf="Probe2Conf", staking="z",
                    over={"Accts": "Accts2", "ConfContracts": "ConfContracts2", "Run": "Run2"}, refunds=True),
}
DEFAULT = "probes"


class FlowSet:
    def __init__(self, name):
        if name not in SETS:
            raise SystemExit(f"no flow set {name!r} (sets: {', '.join(SETS)})")
        s = SETS[name]
        self.name = name
        self.rel_flows = s["flows"]
        self.rel_data = s["data"]
        self.rel_build = s["build"]
        self.flows = os.path.join(HERE, s["flows"])
        self.data = os.path.join(HERE, s["data"])
        self.build = os.path.join(HERE, s["build"])
        self.calib_module = s["calib"]
        self.calib = os.path.join(HERE, "tla", s["calib"] + ".tla")
        self.prefix = s["prefix"]
        self.conf = s["conf"]
        self.staking = s["staking"]
        self.over = s["over"]
        self.refunds = s["refunds"]


def take(args):
    """The flow set `--set NAME` names (default: probes), and the other
    arguments."""
    args = list(args)
    name = DEFAULT
    if "--set" in args:
        i = args.index("--set")
        if i + 1 >= len(args):
            raise SystemExit("--set needs a set name")
        name = args[i + 1]
        del args[i:i + 2]
    return FlowSet(name), args


if __name__ == "__main__":
    # flowsets.py <set> <field>: one field of a set, for tlc.sh
    import sys
    fs = FlowSet(sys.argv[1])
    print(getattr(fs, sys.argv[2]))
