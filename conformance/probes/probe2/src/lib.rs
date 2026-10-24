//! The second generic conformance probe: host calls the other probes do not
//! make, each in the order its arguments give. It is a separate contract so
//! that the other probes' code, and so every burn calibrated on them, stays
//! as it is. Promises are built with the raw host functions, so a promise
//! index can be joined, returned, appended to or given a `refund_to` at
//! will.
//!
//! - `refund_call`: one function call (its deposit from this account), its
//!   `refund_to` set when given (`promise_set_refund_to`);
//! - `paid`: payable; logs its deposit, `refund_to_account_id` and the
//!   predecessor, then panics with `fail`;
//! - `join`: function calls joined with `promise_and`, flat or nested, then
//!   a callback; or, with `misuse`, the joint promise returned, given an
//!   action, or given a `refund_to`;
//! - `on_at`: a callback that reads result `i` only, and returns its size
//!   (-1 for `Failed`); `on_expect` panics unless result `i` has the given
//!   size or exact bytes, so its status shows what it read;
//! - `clock`: logs the block height and timestamp; with `kid`, calls itself
//!   once more;
//! - `interleave`: two promises created A then B, and one weighted call
//!   appended to each in a chosen order;
//! - `stake_then`: a Stake of this account, then `on_at(0)` or `on_expect`
//!   on its result;
//! - `yield_id`: a yield, by `promise_yield_create_with_id` (a custom id, a
//!   deposit, optionally a second create with the same id) or by
//!   `promise_yield_create`; optionally returned;
//! - `resume`: resumes by custom id, or the stored data id;
//! - `on_yield`: the yield callback; logs its signer, predecessor, deposit
//!   and what it read, returns the payload, and optionally re-creates its
//!   own custom id.
//!
//! Gas amounts in arguments are in Ggas (1 Tgas = 1000 Ggas).
use near_sdk::json_types::U128;
use near_sdk::serde::{Deserialize, Serialize};
use near_sdk::{env, log, near, AccountId, PublicKey};

#[near(contract_state)]
#[derive(Default)]
pub struct Probe2 {}

// The raw host functions this probe calls (near-sdk exposes them only
// behind its `unstable` and `deterministic-account-ids` features, which
// would also change the other probes' build: one workspace).
mod sys {
    #[cfg_attr(target_arch = "wasm32", link(wasm_import_module = "env"))]
    extern "C" {
        pub fn promise_batch_create(account_id_len: u64, account_id_ptr: u64) -> u64;
        pub fn promise_batch_then(promise_index: u64, account_id_len: u64, account_id_ptr: u64) -> u64;
        pub fn promise_and(promise_idx_ptr: u64, promise_idx_count: u64) -> u64;
        pub fn promise_batch_action_function_call_weight(
            promise_index: u64,
            function_name_len: u64,
            function_name_ptr: u64,
            arguments_len: u64,
            arguments_ptr: u64,
            amount_ptr: u64,
            gas: u64,
            weight: u64,
        );
        pub fn promise_batch_action_stake(promise_index: u64, amount_ptr: u64, public_key_len: u64, public_key_ptr: u64);
        pub fn promise_set_refund_to(promise_index: u64, account_id_len: u64, account_id_ptr: u64);
        pub fn promise_return(promise_id: u64);
        pub fn promise_result(result_idx: u64, register_id: u64) -> u64;
        pub fn refund_to_account_id(register_id: u64);
        pub fn promise_yield_create(
            function_name_len: u64,
            function_name_ptr: u64,
            arguments_len: u64,
            arguments_ptr: u64,
            gas: u64,
            gas_weight: u64,
            register_id: u64,
        ) -> u64;
        pub fn promise_yield_create_with_id(
            function_name_len: u64,
            function_name_ptr: u64,
            arguments_len: u64,
            arguments_ptr: u64,
            amount_ptr: u64,
            gas: u64,
            gas_weight: u64,
            yield_id_len: u64,
            yield_id_ptr: u64,
        ) -> u64;
    }
}

const REG: u64 = 0;
/// Storage key of the last plain yield's data id.
const LAST: &[u8] = b"y";

/// One function call.
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

fn to(c: &Call) -> String {
    c.receiver.clone().unwrap_or_else(env::current_account_id).to_string()
}

fn create(to: &str) -> u64 {
    unsafe { sys::promise_batch_create(to.len() as _, to.as_ptr() as _) }
}

fn then(p: u64, to: &str) -> u64 {
    unsafe { sys::promise_batch_then(p, to.len() as _, to.as_ptr() as _) }
}

fn and(ps: &[u64]) -> u64 {
    let b: Vec<u8> = ps.iter().flat_map(|p| p.to_le_bytes()).collect();
    unsafe { sys::promise_and(b.as_ptr() as _, ps.len() as _) }
}

/// Appends `c` to promise `p` (`c.receiver` is ignored).
fn append(p: u64, c: &Call) {
    let d = c.deposit.0;
    unsafe {
        sys::promise_batch_action_function_call_weight(
            p,
            c.method.len() as _,
            c.method.as_ptr() as _,
            c.args.len() as _,
            c.args.as_ptr() as _,
            &d as *const u128 as _,
            c.static_ggas * 1_000_000_000,
            c.weight,
        )
    }
}

fn call(c: &Call) -> u64 {
    let p = create(&to(c));
    append(p, c);
    p
}

fn set_refund_to(p: u64, a: &str) {
    unsafe { sys::promise_set_refund_to(p, a.len() as _, a.as_ptr() as _) }
}

/// A custom yield id: `tag` (at most 32 bytes), zero-padded to 32.
fn yid(tag: &str) -> [u8; 32] {
    let mut id = [0u8; 32];
    id[..tag.len()].copy_from_slice(tag.as_bytes());
    id
}

fn payload(bytes: u32) -> Vec<u8> {
    vec![b'x'; bytes as usize]
}

/// `promise_yield_create_with_id` for `on_yield(id, again)`; `None` when the
/// host answers `u64::MAX` (a yield with this id is pending).
fn yield_with_id(id: &str, again: bool, deposit: u128, cb_ggas: u64) -> Option<u64> {
    let m = "on_yield";
    let args = format!("{{\"id\":\"{id}\",\"again\":{again}}}");
    let y = yid(id);
    let p = unsafe {
        sys::promise_yield_create_with_id(
            m.len() as _,
            m.as_ptr() as _,
            args.len() as _,
            args.as_ptr() as _,
            &deposit as *const u128 as _,
            cb_ggas * 1_000_000_000,
            1,
            y.len() as _,
            y.as_ptr() as _,
        )
    };
    (p != u64::MAX).then_some(p)
}

#[near]
impl Probe2 {
    /// Creates the call `c` (its deposit from this account) and, with
    /// `refund_to`, sets that as its refund target.
    pub fn refund_call(&self, c: Call, refund_to: Option<AccountId>) {
        let p = call(&c);
        if let Some(a) = refund_to {
            set_refund_to(p, a.as_str());
        }
    }

    /// Logs "paid <deposit> refund_to <id> predecessor <id>"; panics with
    /// `fail`.
    #[payable]
    pub fn paid(&mut self, fail: Option<bool>) {
        unsafe { sys::refund_to_account_id(REG) };
        let rto = String::from_utf8(env::read_register(REG).unwrap_or_default()).unwrap_or_default();
        log!("paid {} refund_to {} predecessor {}", env::attached_deposit().as_yoctonear(), rto, env::predecessor_account_id());
        if fail.unwrap_or(false) {
            env::panic_str("paid fail");
        }
    }

    /// Creates `kids`, joins them with `promise_and` as `nest` says, then
    /// `cb` on the joint promise. `nest` (three kids k0, k1, k2 unless
    /// "flat"): "flat" (all at once), "left" ((k0 & k1) & k2), "right"
    /// (k0 & (k1 & k2)), "inner" ((k1 & k2) & k0). With `misuse`, before
    /// `cb`: "return" returns the joint promise, "append" appends `kids[0]`
    /// to it, "refund_to" sets its refund target to this account.
    pub fn join(&self, kids: Vec<Call>, nest: Option<String>, cb: Option<Call>, misuse: Option<String>) {
        let ps: Vec<u64> = kids.iter().map(call).collect();
        let j = match nest.as_deref().unwrap_or("flat") {
            "flat" => and(&ps),
            "left" => and(&[and(&ps[..2]), ps[2]]),
            "right" => and(&[ps[0], and(&ps[1..3])]),
            "inner" => and(&[and(&ps[1..3]), ps[0]]),
            _ => env::panic_str("unknown nest"),
        };
        match misuse.as_deref() {
            None => {}
            Some("return") => unsafe { sys::promise_return(j) },
            Some("append") => append(j, &kids[0]),
            Some("refund_to") => set_refund_to(j, env::current_account_id().as_str()),
            Some(_) => env::panic_str("unknown misuse"),
        }
        if let Some(c) = cb {
            let t = then(j, &to(&c));
            append(t, &c);
        }
    }

    /// A callback that reads result `i` only. Logs "result <i> of <n>:
    /// <len> bytes" or "...: failed" and returns the size, -1 for `Failed`.
    /// An index past the end is the host's error.
    pub fn on_at(&self, i: u64) -> i64 {
        let n = env::promise_results_count();
        let len = match unsafe { sys::promise_result(i, REG) } {
            1 => env::register_len(REG).unwrap_or(0) as i64,
            2 => -1,
            _ => env::panic_str("not ready"),
        };
        if len < 0 {
            log!("result {} of {}: failed", i, n);
        } else {
            log!("result {} of {}: {} bytes", i, n, len);
        }
        len
    }

    /// A callback that checks result `i`, the only one it reads: with
    /// `len`, its size (-1 for `Failed`); with `bytes`, that it is
    /// `Successful` with exactly these bytes. Panics "result <i> is
    /// failed", "... is <n> bytes" or "... is other bytes" otherwise, so
    /// its status shows the result; returns the size.
    pub fn on_expect(&self, i: u64, len: Option<i64>, bytes: Option<String>) -> i64 {
        let got = match unsafe { sys::promise_result(i, REG) } {
            1 => env::register_len(REG).unwrap_or(0) as i64,
            2 => -1,
            _ => env::panic_str("not ready"),
        };
        let is = |what: String| -> ! { env::panic_str(&format!("result {i} is {what}")) };
        let what = || if got < 0 { "failed".to_string() } else { format!("{got} bytes") };
        if len.is_some_and(|n| n != got) {
            is(what());
        }
        if let Some(b) = bytes {
            if got < 0 {
                is(what());
            }
            if env::read_register(REG).unwrap_or_default() != b.as_bytes() {
                is("other bytes".to_string());
            }
        }
        got
    }

    /// Logs "clock <tag> <block height> <block timestamp>"; with `kid`,
    /// then calls `clock(<tag>+)` on this account (static 5 Tgas, weight 1).
    pub fn clock(&self, tag: String, kid: Option<bool>) {
        log!("clock {} {} {}", tag, env::block_height(), env::block_timestamp());
        if kid.unwrap_or(false) {
            let c = Call {
                receiver: None,
                method: "clock".into(),
                args: format!("{{\"tag\":\"{tag}+\"}}"),
                static_ggas: 5000,
                weight: 1,
                deposit: U128(0),
            };
            call(&c);
        }
    }

    /// Creates two promises to `receiver`, A then B, then appends
    /// `receiver.method({"tag":"a"})` to A and `{"tag":"b"}` to B (static 0,
    /// weight 1) in the order of `order` ("ab" or "ba").
    pub fn interleave(&self, receiver: AccountId, method: String, order: String) {
        let (a, b) = (create(receiver.as_str()), create(receiver.as_str()));
        for t in order.chars() {
            let c = Call {
                receiver: None,
                method: method.clone(),
                args: format!("{{\"tag\":\"{t}\"}}"),
                static_ggas: 0,
                weight: 1,
                deposit: U128(0),
            };
            append(if t == 'a' { a } else { b }, &c);
        }
    }

    /// A `[Stake(amount, pk)]` receipt to this account, then `on_at(0)` on
    /// its result, or with `expect` `on_expect(0, expect)` (static
    /// `cb_ggas`, weight 1).
    pub fn stake_then(&self, amount: U128, pk: PublicKey, cb_ggas: u64, expect: Option<i64>) {
        let me = env::current_account_id();
        let p = create(me.as_str());
        let k = pk.as_bytes();
        unsafe { sys::promise_batch_action_stake(p, &amount.0 as *const u128 as _, k.len() as _, k.as_ptr() as _) };
        let (method, args) = match expect {
            Some(n) => ("on_expect", format!("{{\"i\":0,\"len\":{n}}}")),
            None => ("on_at", "{\"i\":0}".to_string()),
        };
        let c = Call {
            receiver: None,
            method: method.into(),
            args,
            static_ggas: cb_ggas,
            weight: 1,
            deposit: U128(0),
        };
        append(then(p, me.as_str()), &c);
    }

    /// Yields `on_yield` (static `cb_ggas`, weight 1). With `id`, by
    /// `promise_yield_create_with_id` under that custom id with `deposit`
    /// (from this account), and with `twice` once more with the same id;
    /// without, by `promise_yield_create`, its data id stored. Logs "yield
    /// created" or "yield duplicate" per attempt. With `ret`, returns the
    /// first yield. `again` is passed to the callback. `key` is only
    /// logged ("key <key>"), first: a marker a flow's `[[path_rule]]` reads
    /// to give this call its own burn key, with no effect on what it does.
    #[allow(clippy::too_many_arguments)]
    pub fn yield_id(
        &mut self,
        id: Option<String>,
        deposit: Option<U128>,
        cb_ggas: u64,
        twice: Option<bool>,
        ret: Option<bool>,
        again: Option<bool>,
        key: Option<String>,
    ) {
        if let Some(k) = key {
            log!("key {}", k);
        }
        let again = again.unwrap_or(false);
        let first = match &id {
            Some(t) => {
                let d = deposit.map_or(0, |d| d.0);
                let n = if twice.unwrap_or(false) { 2 } else { 1 };
                let ps: Vec<Option<u64>> = (0..n).map(|_| yield_with_id(t, again, d, cb_ggas)).collect();
                for p in &ps {
                    log!("{}", if p.is_some() { "yield created" } else { "yield duplicate" });
                }
                ps[0]
            }
            None => {
                let m = "on_yield";
                let args = format!("{{\"id\":\"\",\"again\":{again}}}");
                let p = unsafe {
                    sys::promise_yield_create(m.len() as _, m.as_ptr() as _, args.len() as _, args.as_ptr() as _, cb_ggas * 1_000_000_000, 1, REG)
                };
                env::storage_write(LAST, &env::read_register(REG).expect("data id"));
                log!("yield created");
                Some(p)
            }
        };
        if let (true, Some(p)) = (ret.unwrap_or(false), first) {
            unsafe { sys::promise_return(p) };
        }
    }

    /// Resumes the yield with custom id `id`, or the stored data id, with
    /// `bytes` bytes. Logs "resume ok" or "resume none" and returns the
    /// host's answer.
    pub fn resume(&mut self, id: Option<String>, bytes: u32) -> bool {
        let ok = match id {
            Some(t) => env::promise_yield_resume_with_yield_id(&yid(&t), payload(bytes)),
            None => {
                let d: [u8; 32] = env::storage_read(LAST).map(|v| v.try_into().expect("32 bytes")).unwrap_or([0u8; 32]);
                env::promise_yield_resume(&d, payload(bytes))
            }
        };
        log!("{}", if ok { "resume ok" } else { "resume none" });
        ok
    }

    /// The yield callback. Logs "on_yield signer <id> predecessor <id>
    /// deposit <yocto, 40 digits> payload <n>" (or "... timeout"), returns
    /// the payload. With `again`, re-creates the custom id `id` (static
    /// 5 Tgas) and logs "again created" or "again duplicate". Payable: a
    /// yield may carry a deposit.
    #[payable]
    pub fn on_yield(&mut self, id: String, again: bool) {
        let got = match unsafe { sys::promise_result(0, REG) } {
            1 => Some(env::read_register(REG).unwrap_or_default()),
            _ => None,
        };
        let what = match &got {
            Some(v) => format!("payload {}", v.len()),
            None => "timeout".to_string(),
        };
        log!(
            "on_yield signer {} predecessor {} deposit {:040} {}",
            env::signer_account_id(),
            env::predecessor_account_id(),
            env::attached_deposit().as_yoctonear(),
            what
        );
        if again {
            let p = yield_with_id(&id, false, 0, 5000);
            log!("{}", if p.is_some() { "again created" } else { "again duplicate" });
        }
        if let Some(v) = got {
            env::value_return(&v);
        }
    }
}
