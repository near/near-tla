//! A plain NEP-245 multi token on near-sdk-contract-tools 4.0.0 (its
//! `Nep245` derive, unmodified: no hooks, no approvals, no storage
//! management): what the model's `Nep245` with the "tools" gas shape
//! encodes. `new` creates the given token ids and mints `supply` of each to
//! `owner_id`.
use near_sdk::json_types::U128;
use near_sdk::{near, AccountId, PanicOnDefault};
use near_sdk_contract_tools::mt::{Nep245, Nep245Controller, Nep245Mint};

#[derive(Nep245, PanicOnDefault)]
#[near(contract_state)]
pub struct Mt {}

#[near]
impl Mt {
    #[init]
    pub fn new(owner_id: AccountId, token_ids: Vec<String>, supply: U128) -> Self {
        let mut this = Self {};
        for t in token_ids {
            this.create_token(t.clone()).unwrap_or_else(|e| near_sdk::env::panic_str(&e.to_string()));
            this.mint(&Nep245Mint::single(t, supply.0, owner_id.clone()))
                .unwrap_or_else(|e| near_sdk::env::panic_str(&e.to_string()));
        }
        this
    }
}
