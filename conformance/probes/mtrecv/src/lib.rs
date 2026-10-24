//! A NEP-245 receiver for the conformance suite: `mt_on_transfer` answers
//! as `msg` says, so a test or flow can give the token's resolver any
//! result.
//!
//! `msg`: "keep" (or "": every amount used, `["0", ..]`), "return" (all
//! unused: the amounts), "over" (each amount + 1), "short" (one entry
//! fewer than the ids), "long" (one more, "0"), "mal" (not a vector:
//! `"x"`), "empty" (no bytes), "panic", "burn:<ggas>" (burn that much gas,
//! then keep), "vec:<a>,<b>,.." (exactly those numbers).
use near_sdk::json_types::U128;
use near_sdk::{env, near, AccountId};

#[near(contract_state)]
#[derive(Default)]
pub struct MtRecv {}

fn burn_to(ggas: u64) {
    let target = ggas.saturating_mul(1_000_000_000);
    let mut x: u64 = 0;
    while env::used_gas().as_gas() < target {
        x = x.wrapping_add(1);
    }
    let _ = x;
}

fn vec_json(v: &[u128]) -> Vec<u8> {
    let items: Vec<String> = v.iter().map(|x| format!("\"{x}\"")).collect();
    format!("[{}]", items.join(",")).into_bytes()
}

#[near]
impl MtRecv {
    pub fn mt_on_transfer(
        &mut self,
        sender_id: AccountId,
        previous_owner_ids: Vec<AccountId>,
        token_ids: Vec<String>,
        amounts: Vec<U128>,
        msg: String,
    ) {
        let _ = (sender_id, previous_owner_ids, token_ids);
        let a: Vec<u128> = amounts.iter().map(|x| x.0).collect();
        let out: Vec<u8> = match msg.as_str() {
            "" | "keep" => vec_json(&vec![0; a.len()]),
            "return" => vec_json(&a),
            "over" => vec_json(&a.iter().map(|x| x + 1).collect::<Vec<_>>()),
            "short" => vec_json(&a[..a.len().saturating_sub(1)]),
            "long" => vec_json(&[a.clone(), vec![0]].concat()),
            "mal" => b"\"x\"".to_vec(),
            "empty" => vec![],
            "panic" => env::panic_str("receiver panicked"),
            m if m.starts_with("burn:") => {
                burn_to(m[5..].parse().unwrap_or(0));
                vec_json(&vec![0; a.len()])
            }
            m if m.starts_with("vec:") => {
                let v: Vec<u128> = m[4..].split(',').filter(|s| !s.is_empty()).map(|s| s.parse().unwrap()).collect();
                vec_json(&v)
            }
            _ => env::panic_str("unknown msg"),
        };
        env::value_return(&out);
    }
}
