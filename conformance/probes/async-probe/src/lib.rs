//! The async conformance probe: yield/resume (NEP-519) and a joint callback
//! whose status shows the order of its results. It is a separate contract
//! so that the generic probe's code, and so every burn calibrated on it
//! (contract loading is charged per byte), stays as it is.
//!
//! - `yield_create`: yields `on_yield` with a chosen static gas and weight,
//!   stores its data id, and optionally resumes it in the same call;
//! - `resume`: resumes the stored data id (or a given one) with a payload of
//!   a chosen size, and logs and returns the host's answer;
//! - `on_yield`: the yield callback; logs whether it got a payload (and its
//!   size) or timed out (`PromiseResult::Failed`);
//! - `on_order`: a joint callback that panics iff its first result is
//!   `Failed`, so its status shows which input came first.
//!
//! Gas amounts in arguments are in Ggas (1 Tgas = 1000 Ggas).
use near_sdk::{env, log, near, CryptoHash, Gas, GasWeight, PromiseResult};

#[near(contract_state)]
#[derive(Default)]
pub struct AsyncProbe {}

/// Storage key of the last yield's data id.
const LAST: &[u8] = b"y";
const REG: u64 = 0;

fn payload(bytes: u32) -> Vec<u8> {
    vec![b'x'; bytes as usize]
}

#[near]
impl AsyncProbe {
    /// Yields `on_yield` (static `cb_ggas`, weight `cb_weight`, no
    /// arguments) and stores its data id. With `resume`, resumes it in the
    /// same call with that many bytes, twice with `twice`.
    pub fn yield_create(&mut self, cb_ggas: u64, cb_weight: u64, resume: Option<u32>, twice: Option<bool>) {
        let _ = env::promise_yield_create("on_yield", b"", Gas::from_ggas(cb_ggas), GasWeight(cb_weight), REG);
        let id: CryptoHash = env::read_register(REG).expect("data id").try_into().expect("32 bytes");
        env::storage_write(LAST, &id);
        if let Some(n) = resume {
            env::promise_yield_resume(&id, payload(n));
            if twice.unwrap_or(false) {
                env::promise_yield_resume(&id, payload(n));
            }
        }
    }

    /// Resumes the stored yield (or `data_id`, hex) with `bytes` bytes.
    /// Logs "resume ok" or "resume none" and returns the host's answer.
    pub fn resume(&mut self, bytes: u32, data_id: Option<String>) -> bool {
        let id: CryptoHash = match data_id {
            Some(h) => {
                let b: Vec<u8> = (0..h.len() / 2).map(|i| u8::from_str_radix(&h[2 * i..2 * i + 2], 16).expect("hex")).collect();
                b.try_into().expect("32 bytes")
            }
            None => env::storage_read(LAST).map(|v| v.try_into().expect("32 bytes")).unwrap_or([0u8; 32]),
        };
        let ok = env::promise_yield_resume(&id, payload(bytes));
        log!("{}", if ok { "resume ok" } else { "resume none" });
        ok
    }

    /// The yield callback: "payload <n>" and n for a resume, "timeout" and
    /// 0 for a timeout.
    pub fn on_yield(&self) -> u64 {
        #[allow(deprecated)]
        match env::promise_result(0) {
            PromiseResult::Successful(v) => {
                log!("payload {}", v.len());
                v.len() as u64
            }
            PromiseResult::Failed => {
                log!("timeout");
                0
            }
        }
    }

    /// A joint callback: panics iff its first result is `Failed`; returns
    /// the number of results.
    pub fn on_order(&self) -> u64 {
        #[allow(deprecated)]
        if let PromiseResult::Failed = env::promise_result(0) {
            env::panic_str("first result failed");
        }
        env::promise_results_count()
    }
}
