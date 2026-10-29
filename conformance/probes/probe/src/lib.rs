//! The generic conformance probe. One contract, deployed on several
//! accounts, whose methods each exercise one receipt-level behavior the
//! TLA+ model encodes:
//!
//! - `chain`: creates function-call children with chosen static gas and
//!   weights, optionally joined, with an optional callback (the leftover
//!   gas split, W = 0 and the remainder rule);
//! - `burn`: burns a chosen amount of gas;
//! - `ret`: returns a chosen number of bytes; `on_read` reads every promise
//!   result in full, `on_count` only counts them (callback burn vs result
//!   size);
//! - `send`: a Transfer to any account, optionally with a callback
//!   (account-type dependent fees and implicit-account creation);
//! - `record`: logs the signer, its key and the predecessor (signer
//!   propagation);
//! - `mark`: appends a tag to an on-chain list (receipt order);
//! - `put` / `get` / `fail`: state writes and a panic (revert scope);
//! - `batch_self`: a contract-created `[DeleteKey, FunctionCall]` batch;
//! - `keys_self` / `spawn`: action-only children with AddKey, CreateAccount
//!   and DeleteAccount (the calibrator's action-only fee rules);
//! - `ft_on_transfer`: a NEP-141 receiver that keeps, returns, over-returns,
//!   burns or panics, chosen by `msg`.
//!
//! Gas amounts in arguments are in Ggas (1 Tgas = 1000 Ggas).
use near_sdk::json_types::U128;
use near_sdk::serde::{Deserialize, Serialize};
use near_sdk::{env, log, near, AccountId, Gas, GasWeight, NearToken, Promise, PublicKey};

#[near(contract_state)]
#[derive(Default)]
pub struct Probe {}

/// One function call a `chain` creates.
#[derive(Serialize, Deserialize, Clone)]
#[serde(crate = "near_sdk::serde")]
pub struct Call {
    pub receiver: Option<AccountId>,
    pub method: String,
    #[serde(default)]
    pub args: String,
    #[serde(default)]
    pub static_ggas: u64,
    #[serde(default)]
    pub weight: u64,
    #[serde(default)]
    pub deposit: U128,
}

fn burn_to(ggas: u64) {
    let target = ggas.saturating_mul(1_000_000_000);
    let mut x: u64 = 0;
    while env::used_gas().as_gas() < target {
        x = x.wrapping_add(1);
    }
    let _ = x;
}

fn mk(c: &Call) -> Promise {
    let to = c.receiver.clone().unwrap_or_else(env::current_account_id);
    Promise::new(to).function_call_weight(
        c.method.clone(),
        c.args.clone().into_bytes(),
        NearToken::from_yoctonear(c.deposit.0),
        Gas::from_ggas(c.static_ggas),
        GasWeight(c.weight),
    )
}

#[near]
impl Probe {
    /// Burns until this call has used `ggas` Ggas (no-op if already past).
    pub fn burn(&self, ggas: u64) {
        burn_to(ggas);
    }

    /// Returns `bytes` bytes of `x` (not JSON).
    pub fn ret(&self, bytes: u32) {
        env::value_return(&vec![b'x'; bytes as usize]);
    }

    /// Burns `burn` Ggas, then creates `kids` (joined with `and` when
    /// several; with `detach`, all but the last stand alone), then `cb` on
    /// the joined (or last) result.
    pub fn chain(&self, kids: Vec<Call>, cb: Option<Call>, burn: Option<u64>, detach: Option<bool>) {
        burn_to(burn.unwrap_or(0));
        let mut ps: Vec<Promise> = kids.iter().map(mk).collect();
        let joined = if detach.unwrap_or(false) {
            let last = ps.pop();
            for p in ps {
                drop(p);
            }
            last
        } else {
            let mut it = ps.into_iter();
            it.next().map(|first| it.fold(first, |acc, q| acc.and(q)))
        };
        match (joined, cb) {
            (Some(p), Some(c)) => {
                let _ = p.then(mk(&c));
            }
            (Some(p), None) => drop(p),
            (None, Some(c)) => drop(mk(&c)),
            (None, None) => {}
        }
    }

    /// Burns `burn` Ggas, then creates ONE receipt to `receiver` holding
    /// every call of `calls` as its own function-call action (their
    /// `receiver` fields are ignored), then `cb` on its result.
    pub fn batch(&self, receiver: AccountId, calls: Vec<Call>, cb: Option<Call>, burn: Option<u64>) {
        burn_to(burn.unwrap_or(0));
        let mut p = Promise::new(receiver);
        for c in &calls {
            p = p.function_call_weight(
                c.method.clone(),
                c.args.clone().into_bytes(),
                NearToken::from_yoctonear(c.deposit.0),
                Gas::from_ggas(c.static_ggas),
                GasWeight(c.weight),
            );
        }
        match cb {
            Some(c) => {
                let _ = p.then(mk(&c));
            }
            None => {
                let _ = p;
            }
        }
    }

    /// A callback that reads every promise result in full. Returns the
    /// total size read (failed results count 0) as a JSON number.
    pub fn on_read(&self) -> u64 {
        let n = env::promise_results_count();
        let mut total = 0u64;
        for i in 0..n {
            #[allow(deprecated)]
            let r = env::promise_result(i);
            if let near_sdk::PromiseResult::Successful(v) = r {
                total += v.len() as u64;
            }
        }
        total
    }

    /// A callback that only counts its results.
    pub fn on_count(&self) -> u64 {
        env::promise_results_count()
    }

    /// Sends `yocto` to `to`; with `cb`, then `on_read` on its result
    /// (static `cb_ggas`, weight 1).
    pub fn send(&self, to: AccountId, yocto: U128, cb: Option<bool>, cb_ggas: Option<u64>) {
        let p = Promise::new(to).transfer(NearToken::from_yoctonear(yocto.0));
        if cb.unwrap_or(false) {
            let c = Call {
                receiver: None,
                method: "on_read".into(),
                args: String::new(),
                static_ggas: cb_ggas.unwrap_or(0),
                weight: 1,
                deposit: U128(0),
            };
            let _ = p.then(mk(&c));
        }
    }

    /// Logs and returns who called: signer, signer key, predecessor.
    pub fn record(&self, tag: String) -> String {
        let pk: PublicKey = env::signer_account_pk();
        let pk_s: String = (&pk).into();
        let s = format!(
            "{{\"tag\":\"{}\",\"signer\":\"{}\",\"signer_pk\":\"{}\",\"predecessor\":\"{}\",\"current\":\"{}\"}}",
            tag,
            env::signer_account_id(),
            pk_s,
            env::predecessor_account_id(),
            env::current_account_id()
        );
        log!("record {}", s);
        s
    }

    /// Appends `tag` to the list under key `m`; returns its position.
    pub fn mark(&mut self, tag: String) -> u64 {
        let mut v = env::storage_read(b"m").unwrap_or_default();
        let pos = v.iter().filter(|b| **b == b',').count() as u64;
        v.extend_from_slice(tag.as_bytes());
        v.push(b',');
        env::storage_write(b"m", &v);
        log!("mark {} at {} in block {}", tag, pos, env::block_height());
        pos
    }

    /// The marks so far, comma-separated.
    pub fn marks(&self) -> String {
        String::from_utf8(env::storage_read(b"m").unwrap_or_default()).unwrap_or_default()
    }

    pub fn put(&mut self, key: String, value: String) {
        env::storage_write(key.as_bytes(), value.as_bytes());
    }

    pub fn get(&self, key: String) -> Option<String> {
        env::storage_read(key.as_bytes()).map(|v| String::from_utf8(v).unwrap_or_default())
    }

    /// Writes `key`, then panics: the write must not survive.
    pub fn fail(&mut self, key: String) {
        env::storage_write(key.as_bytes(), b"written-before-panic");
        env::panic_str("probe fail");
    }

    /// A contract-created batch to this account: `[DeleteKey(pk),
    /// FunctionCall(put(key, "1"))]`, or `fail(key)` as the call with
    /// `fail`.
    pub fn batch_self(&self, pk: PublicKey, key: String, fail: Option<bool>) {
        let args = format!("{{\"key\":\"{}\",\"value\":\"1\"}}", key).into_bytes();
        let m = if fail.unwrap_or(false) { "fail" } else { "put" };
        let _ = Promise::new(env::current_account_id()).delete_key(pk).function_call_weight(
            m.to_string(),
            args,
            NearToken::from_yoctonear(0),
            Gas::from_tgas(5),
            GasWeight(1),
        );
    }

    /// An action-only child to this account: `[AddKey(pk), DeleteKey(pk)]`,
    /// the key full-access, or with `fc` a function-call key for `mark`.
    pub fn keys_self(&self, pk: PublicKey, fc: Option<bool>) {
        let me = env::current_account_id();
        let p = if fc.unwrap_or(false) {
            Promise::new(me.clone()).add_access_key_allowance_with_nonce(pk.clone(), near_sdk::Allowance::Unlimited, me, "mark".to_string(), 0)
        } else {
            Promise::new(me).add_full_access_key(pk.clone())
        };
        let _ = p.delete_key(pk);
    }

    /// An action-only child creating `<name>.<this account>`:
    /// `[CreateAccount, Transfer(yocto), AddKey(pk)]`, and with `delete`
    /// a final `DeleteAccount` (beneficiary: this account).
    pub fn spawn(&self, name: String, pk: PublicKey, yocto: U128, delete: Option<bool>) {
        let me = env::current_account_id();
        let sub: AccountId = format!("{name}.{me}").parse().unwrap();
        let mut p = Promise::new(sub).create_account().transfer(NearToken::from_yoctonear(yocto.0)).add_full_access_key(pk);
        if delete.unwrap_or(false) {
            p = p.delete_account(me);
        }
        let _ = p;
    }

    /// NEP-141 receiver. `msg`: "keep" (or ""), "return" (all unused),
    /// "over" (amount + 1 unused), "panic", "burn:<ggas>" (burn, then keep),
    /// "big:<bytes>" (a non-numeric result of that size).
    pub fn ft_on_transfer(&mut self, sender_id: AccountId, amount: U128, msg: String) {
        let _ = sender_id;
        let unused: u128 = match msg.as_str() {
            "" | "keep" => 0,
            "return" => amount.0,
            "over" => amount.0 + 1,
            "panic" => env::panic_str("receiver panicked"),
            m if m.starts_with("burn:") => {
                burn_to(m[5..].parse().unwrap_or(0));
                0
            }
            m if m.starts_with("big:") => {
                let n: usize = m[4..].parse().unwrap_or(0);
                env::value_return(&vec![b'x'; n]);
                return;
            }
            _ => env::panic_str("unknown msg"),
        };
        env::value_return(format!("\"{}\"", unused).as_bytes());
    }
}
