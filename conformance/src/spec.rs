//! Flow specs: a TOML file describing a world (accounts, contracts, setup
//! calls) and flows (one transaction swept over a prepaid-gas grid), plus
//! the static gas and weight each created call was given, for the split
//! check. The format is documented in README.md.
use near_contract_sim::prelude::*;
use near_contract_sim::TxOutcome;
use serde::Deserialize;
use std::collections::BTreeMap;
use std::path::{Path, PathBuf};

#[derive(Deserialize, Debug, Clone)]
#[serde(deny_unknown_fields)]
pub struct Spec {
    #[serde(default)]
    pub world: World,
    #[serde(default, rename = "account")]
    pub accounts: Vec<Account>,
    #[serde(default, rename = "contract")]
    pub contracts: Vec<Contract>,
    #[serde(default, rename = "setup")]
    pub setup: Vec<Call>,
    #[serde(default, rename = "flow")]
    pub flows: Vec<Flow>,
    /// Static gas and weight of created calls, keyed `"<receiver>.<method>"`
    /// (a batch: methods joined by `+`), for every flow.
    #[serde(default, rename = "static")]
    pub statics: Vec<Static>,
    /// Where a key's burn size comes from (default: the flow's `size`).
    #[serde(default, rename = "size")]
    pub sizes: Vec<SizeSrc>,
    /// Burn paths read from each receipt's logs, for a call whose path a
    /// flow does not fix (a resolver refunds at some grid points only).
    #[serde(default, rename = "path_rule")]
    pub path_rules: Vec<PathRule>,
    /// Where a key's storage size comes from (`calibrate --stor`; default
    /// 0). Apart from `[[size]]`: burns grow per KB, bytes per byte.
    #[serde(default, rename = "stor_size")]
    pub stor_sizes: Vec<StorSizeSrc>,
}

/// `key` is `"<receiver>.<method>"`; `from` is `"arg_len:<f1>[+<f2>...]"`
/// (the summed byte lengths of those string arguments of the call),
/// `"predecessor_len"` (the length of its predecessor's account id) or
/// `"arg:<field>"` (a numeric argument); the size is that over `div`.
#[derive(Deserialize, Debug, Clone)]
#[serde(deny_unknown_fields)]
pub struct StorSizeSrc {
    pub key: String,
    pub from: String,
    #[serde(default = "one")]
    pub div: u64,
}

/// A receipt of `call` (`"<receiver>.<method>"`, one method) whose logs
/// contain `log` takes the path `path`, otherwise `else`; its burn key is
/// suffixed `/<path>`. A flow's own `path` for that call wins.
#[derive(Deserialize, Debug, Clone)]
#[serde(deny_unknown_fields)]
pub struct PathRule {
    pub call: String,
    pub log: String,
    pub path: String,
    #[serde(rename = "else")]
    pub otherwise: String,
}

impl PathRule {
    /// The path of a receipt with call key `ck` and these logs, if the rule
    /// applies to it.
    pub fn path_of<'a>(&self, ck: &str, logs: impl IntoIterator<Item = &'a str>) -> Option<&str> {
        if ck != self.call {
            return None;
        }
        Some(if logs.into_iter().any(|l| l.contains(&self.log)) { &self.path } else { &self.otherwise })
    }
}

/// `key` is `"<receiver>.<method>"`; `from` is `"arg:<field>"` (a numeric
/// JSON argument of the call), `"arg_count:<field>"` (the number of entries
/// of an array argument, e.g. a NEP-245 call's `token_ids`), `"result"`
/// (its numeric JSON result) or `"result_size"` (its result's length); the
/// size is that over `div`.
#[derive(Deserialize, Debug, Clone)]
#[serde(deny_unknown_fields)]
pub struct SizeSrc {
    pub key: String,
    pub from: String,
    #[serde(default = "one")]
    pub div: u64,
}

fn one() -> u64 {
    1
}

#[derive(Deserialize, Debug, Clone, Default)]
#[serde(deny_unknown_fields)]
pub struct World {
    /// Protocol version the sim runs; default: the pinned nearcore's.
    pub protocol_version: Option<u32>,
    /// Model account name for each sim account in emitted keys
    /// (`"wnear-probe.near" = "wnear_probe"`); default: the sim id.
    #[serde(default)]
    pub names: BTreeMap<String, String>,
    /// Model key for a method key (`"near_deposit+ft_transfer" =
    /// "batch/DT"`), applied before any `/shape` or `/path` suffix.
    #[serde(default)]
    pub keys: BTreeMap<String, String>,
}

#[derive(Deserialize, Debug, Clone)]
#[serde(deny_unknown_fields)]
pub struct Account {
    pub id: String,
    /// Balance in NEAR.
    #[serde(default = "default_near")]
    pub near: u64,
}

fn default_near() -> u64 {
    1000
}

#[derive(Deserialize, Debug, Clone)]
#[serde(deny_unknown_fields)]
pub struct Contract {
    pub id: String,
    /// Path relative to the spec file; `${WASM}` is `--wasm`'s value.
    pub wasm: String,
    #[serde(default = "default_near")]
    pub near: u64,
    pub init: Option<Init>,
    /// Source crate and version, for the provenance header.
    #[serde(default)]
    pub source: String,
}

#[derive(Deserialize, Debug, Clone)]
#[serde(deny_unknown_fields)]
pub struct Init {
    pub method: String,
    #[serde(default)]
    pub args: Args,
}

/// JSON arguments: a JSON text, or a TOML table converted to JSON.
#[derive(Deserialize, Debug, Clone, Default)]
#[serde(untagged)]
pub enum Args {
    #[default]
    None,
    Text(String),
    Table(toml::Table),
}

impl Args {
    pub fn json(&self) -> serde_json::Value {
        match self {
            Args::None => serde_json::json!({}),
            Args::Text(s) => serde_json::from_str(s).unwrap_or_else(|e| panic!("bad JSON args {s:?}: {e}")),
            Args::Table(t) => serde_json::to_value(t).unwrap(),
        }
    }
}

#[derive(Deserialize, Debug, Clone)]
#[serde(deny_unknown_fields)]
pub struct Call {
    pub signer: String,
    pub receiver: String,
    pub method: String,
    #[serde(default)]
    pub args: Args,
    /// yoctoNEAR, as a decimal string.
    #[serde(default)]
    pub deposit: String,
    /// Tgas; default 300.
    pub tgas: Option<f64>,
}

#[derive(Deserialize, Debug, Clone)]
#[serde(deny_unknown_fields)]
pub struct Flow {
    pub name: String,
    #[serde(default)]
    pub about: String,
    /// Setup calls of this flow, after the world's (at their own gas).
    #[serde(default)]
    pub setup: Vec<Call>,
    /// The transaction swept over the grid (its `tgas` is ignored).
    pub tx: Call,
    /// "standard" (0.5-130.0 by 0.1, 140-300 by 10), "smoke", or
    /// "lo:hi:step" in Tgas.
    #[serde(default = "default_grid")]
    pub grid: String,
    /// The size variable of this flow's burns (e.g. result bytes); fitted
    /// as burn = base + per * size across flows sharing a key.
    #[serde(default)]
    pub size: u64,
    /// Flow-specific statics (looked up before the spec's).
    #[serde(default, rename = "static")]
    pub statics: Vec<Static>,
    /// Burn keys of this flow are suffixed `/<path>` (for paths the
    /// child-shape doesn't tell apart).
    #[serde(default)]
    pub path: String,
    /// Keys (`"<receiver>.<method>"`) the `path` applies to; empty: all.
    #[serde(default)]
    pub path_for: Vec<String>,
    /// Method-list -> model key for this flow only (over `world.keys`),
    /// e.g. a one-call token batch `"ft_transfer" = "batch/T"`.
    #[serde(default)]
    pub keys: BTreeMap<String, String>,
    /// Model side only (scripts/mkconf.py): burn key -> the key to use
    /// instead, where the sim never completes the path the model takes.
    #[serde(default)]
    pub model_keys: BTreeMap<String, String>,
    /// Steps after the swept transaction, in order, each once the chain is
    /// idle: another transaction at its own gas, or the timeout of every
    /// parked yield (see `run_flow`).
    #[serde(default)]
    pub after: Vec<After>,
    /// Send the swept transaction as a meta transaction (NEP-366): its
    /// signer signs a delegate for the call, and this account relays it
    /// (`Tx::relay`). The swept gas is the delegated call's.
    pub relay: Option<String>,
}

/// One step after a flow's transaction: exactly one of `call` (a
/// transaction, at its `tgas`, default 300) and `expire = true` (every
/// yield still parked times out: the sim advances to its `expires_at` and
/// settles, so its callback runs with `PromiseResult::Failed`).
#[derive(Deserialize, Debug, Clone)]
#[serde(deny_unknown_fields)]
pub struct After {
    #[serde(default)]
    pub expire: bool,
    pub call: Option<Call>,
}

fn default_grid() -> String {
    "standard".into()
}

/// Static gas and weight per function-call action of a created receipt.
#[derive(Deserialize, Debug, Clone)]
#[serde(deny_unknown_fields)]
pub struct Static {
    /// `"<receiver>.<method>"`; a batch `"<receiver>.<m1>+<m2>"`.
    pub child: String,
    /// Only for children of this `"<receiver>.<method>"` (optional).
    pub parent: Option<String>,
    /// One `[static_ggas, weight]` per function-call action.
    #[serde(default)]
    pub actions: Vec<[u64; 2]>,
    /// Instead: one action with static = the creating action's own gas
    /// minus this (Ggas), and `weight`.
    pub prepaid_minus_ggas: Option<u64>,
    #[serde(default)]
    pub weight: u64,
}

pub fn load(path: &Path) -> Spec {
    let text = std::fs::read_to_string(path).unwrap_or_else(|e| panic!("{}: {e}", path.display()));
    toml::from_str(&text).unwrap_or_else(|e| panic!("{}: {e}", path.display()))
}

pub fn parse_grid(g: &str) -> Vec<u64> {
    match g {
        "standard" => crate::grid::standard(),
        "smoke" => crate::grid::smoke(),
        _ => {
            let p: Vec<f64> = g.split(':').map(|x| x.parse().expect("grid lo:hi:step in Tgas")).collect();
            assert_eq!(p.len(), 3, "grid lo:hi:step in Tgas");
            let (lo, hi, st) = ((p[0] * 10.0).round() as u64, (p[1] * 10.0).round() as u64, (p[2] * 10.0).round() as u64);
            crate::grid::range(lo, hi, st.max(1))
        }
    }
}

/// Resolves wasm paths of a spec at `spec_path`.
pub struct Resolved {
    pub spec: Spec,
    pub dir: PathBuf,
    pub wasm_var: Option<PathBuf>,
}

impl Resolved {
    pub fn new(spec_path: &Path, wasm_var: Option<PathBuf>) -> Self {
        let spec = load(spec_path);
        let dir = spec_path.parent().unwrap().to_path_buf();
        Resolved { spec, dir, wasm_var }
    }

    pub fn wasm_path(&self, c: &Contract) -> PathBuf {
        if c.wasm.contains("${WASM}") {
            self.wasm_var.clone().unwrap_or_else(|| panic!("contract {} needs --wasm", c.id))
        } else {
            self.dir.join(&c.wasm)
        }
    }

    /// Every contract's wasm sha256, and its source.
    pub fn wasms(&self) -> Vec<(String, String, String, String)> {
        self.spec
            .contracts
            .iter()
            .map(|c| {
                let p = self.wasm_path(c);
                let b = std::fs::read(&p).unwrap_or_else(|e| panic!("{}: {e}", p.display()));
                let name = p.file_name().unwrap().to_string_lossy().into_owned();
                (c.id.clone(), name, crate::sha256_hex(&b), c.source.clone())
            })
            .collect()
    }

    /// The world, with the spec's setup calls run.
    pub fn world(&self) -> Sim {
        let mut f = Fixture::new();
        if let Some(v) = self.spec.world.protocol_version {
            f = f.config(move |c| c.protocol_version = v);
        }
        for a in &self.spec.accounts {
            f = f.account(a.id.as_str(), Balance::from_near(a.near as u128));
        }
        for c in &self.spec.contracts {
            let p = self.wasm_path(c);
            let wasm = std::fs::read(&p).unwrap_or_else(|e| panic!("{}: {e}", p.display()));
            f = f.account(c.id.as_str(), Balance::from_near(c.near as u128)).contract(c.id.as_str(), wasm);
            if let Some(i) = &c.init {
                f = f.init(&i.method, i.args.json());
            }
        }
        let mut sim = f.build();
        for c in &self.spec.setup {
            run(&mut sim, c, None).assert_success();
        }
        sim
    }

    /// The world plus a flow's own setup.
    pub fn flow_world(&self, base: &Sim, flow: &Flow) -> Sim {
        let mut sim = base.clone();
        for c in &flow.setup {
            let o = run(&mut sim, c, None);
            assert!(o.receipts.iter().all(|r| r.failure().is_none()), "flow {} setup {}.{} failed:\n{o}", flow.name, c.receiver, c.method);
        }
        sim
    }

    /// Statics for a child `key` created by `parent`: flow's, then spec's.
    pub fn static_of<'a>(&'a self, flow: &'a Flow, parent: &str, key: &str) -> Option<&'a Static> {
        flow.statics
            .iter()
            .chain(&self.spec.statics)
            .find(|s| s.child == key && s.parent.as_deref().is_none_or(|p| p == parent))
    }

    /// The model name of a sim account.
    pub fn name<'a>(&'a self, id: &'a str) -> &'a str {
        self.spec.world.names.get(id).map(|s| s.as_str()).unwrap_or(id)
    }
}

/// Runs a flow at prepaid `gas`: its transaction, then its `after` steps,
/// each once the chain is idle (`transact` returns with a yield still
/// parked). Returns the outcome of every transaction, the flow's first,
/// each read again at the end: a yield callback belongs to the transaction
/// that yielded, whichever one resumed it.
pub fn run_flow(sim: &mut Sim, flow: &Flow, gas: Gas) -> Vec<TxOutcome> {
    let mut hashes = vec![run_as(sim, &flow.tx, Some(gas), flow.relay.as_deref()).hash];
    for (i, a) in flow.after.iter().enumerate() {
        match (a.expire, &a.call) {
            (true, None) => {
                for y in sim.yields() {
                    // expiring one fires every yield due before it
                    if sim.yields().contains(&y) {
                        sim.expire(&y);
                    }
                }
            }
            (false, Some(c)) => hashes.push(run(sim, c, None).hash),
            _ => panic!("flow {} after[{i}]: set exactly one of call and expire = true", flow.name),
        }
    }
    hashes.into_iter().map(|h| sim.outcome(h)).collect()
}

/// Runs one call to completion, at `gas` (default: its `tgas`, else 300).
pub fn run(sim: &mut Sim, c: &Call, gas: Option<Gas>) -> TxOutcome {
    run_as(sim, c, gas, None)
}

/// `run`, or with `relay` the same call as a delegate that account relays.
pub fn run_as(sim: &mut Sim, c: &Call, gas: Option<Gas>, relay: Option<&str>) -> TxOutcome {
    let dep: u128 = if c.deposit.is_empty() { 0 } else { c.deposit.parse().expect("deposit: yocto decimal") };
    let g = gas.unwrap_or_else(|| Gas::from_gas((c.tgas.unwrap_or(300.0) * 1e12).round() as u64));
    let args = c.args.json();
    let mut tx = sim.call(c.signer.as_str(), c.receiver.as_str(), &c.method);
    tx = match &c.args {
        Args::None => tx,
        _ => tx.args_json(args),
    };
    let tx = tx.deposit(Balance::from_yoctonear(dep)).gas(g);
    match relay {
        Some(r) => tx.relay(r),
        None => tx.transact(),
    }
}
