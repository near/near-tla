//! A wNEAR-like token on near-contract-standards: NEP-141 + NEP-145 whose
//! supply is backed by the NEAR the contract holds.
//!
//! - `near_deposit()`: payable, deposit > 0. A registered predecessor is
//!   credited the whole deposit; an unregistered one must attach at least
//!   the storage minimum, is registered, and is credited the rest.
//! - `near_withdraw(amount)`: one yocto; burns `amount` of the
//!   predecessor's tokens and sends `amount` + 1 yocto back with a Transfer
//!   (the yocto is the attached one, returned).
use near_contract_standards::fungible_token::metadata::{
    FungibleTokenMetadata, FungibleTokenMetadataProvider, FT_METADATA_SPEC,
};
use near_contract_standards::fungible_token::{
    FungibleToken, FungibleTokenCore, FungibleTokenResolver,
};
use near_contract_standards::storage_management::{
    StorageBalance, StorageBalanceBounds, StorageManagement,
};
use near_sdk::json_types::U128;
use near_sdk::{
    assert_one_yocto, env, near, require, AccountId, NearToken, PanicOnDefault, Promise,
    PromiseOrValue,
};

#[near(contract_state)]
#[derive(PanicOnDefault)]
pub struct Wrap {
    token: FungibleToken,
}

#[near]
impl Wrap {
    #[init]
    pub fn new() -> Self {
        Self { token: FungibleToken::new(b"a".to_vec()) }
    }

    #[payable]
    pub fn near_deposit(&mut self) {
        let mut amount = env::attached_deposit().as_yoctonear();
        require!(amount > 0, "Requires positive attached deposit");
        let account_id = env::predecessor_account_id();
        if !self.token.accounts.contains_key(&account_id) {
            let min = self.token.storage_balance_bounds().min.as_yoctonear();
            require!(amount >= min, "ERR_DEPOSIT_TOO_SMALL");
            self.token.internal_register_account(&account_id);
            amount -= min;
        }
        self.token.internal_deposit(&account_id, amount);
    }

    #[payable]
    pub fn near_withdraw(&mut self, amount: U128) -> Promise {
        assert_one_yocto();
        let account_id = env::predecessor_account_id();
        self.token.internal_withdraw(&account_id, amount.0);
        Promise::new(account_id).transfer(NearToken::from_yoctonear(amount.0 + 1))
    }
}

#[near]
impl FungibleTokenCore for Wrap {
    #[payable]
    fn ft_transfer(&mut self, receiver_id: AccountId, amount: U128, memo: Option<String>) {
        self.token.ft_transfer(receiver_id, amount, memo)
    }

    #[payable]
    fn ft_transfer_call(
        &mut self,
        receiver_id: AccountId,
        amount: U128,
        memo: Option<String>,
        msg: String,
    ) -> PromiseOrValue<U128> {
        self.token.ft_transfer_call(receiver_id, amount, memo, msg)
    }

    fn ft_total_supply(&self) -> U128 {
        self.token.ft_total_supply()
    }

    fn ft_balance_of(&self, account_id: AccountId) -> U128 {
        self.token.ft_balance_of(account_id)
    }
}

#[near]
impl FungibleTokenResolver for Wrap {
    #[private]
    fn ft_resolve_transfer(
        &mut self,
        sender_id: AccountId,
        receiver_id: AccountId,
        amount: U128,
    ) -> U128 {
        let (used, _burned) =
            self.token.internal_ft_resolve_transfer(&sender_id, receiver_id, amount);
        used.into()
    }
}

#[near]
impl StorageManagement for Wrap {
    #[payable]
    fn storage_deposit(
        &mut self,
        account_id: Option<AccountId>,
        registration_only: Option<bool>,
    ) -> StorageBalance {
        self.token.storage_deposit(account_id, registration_only)
    }

    #[payable]
    fn storage_withdraw(&mut self, amount: Option<NearToken>) -> StorageBalance {
        self.token.storage_withdraw(amount)
    }

    #[payable]
    fn storage_unregister(&mut self, force: Option<bool>) -> bool {
        self.token.internal_storage_unregister(force).is_some()
    }

    fn storage_balance_bounds(&self) -> StorageBalanceBounds {
        self.token.storage_balance_bounds()
    }

    fn storage_balance_of(&self, account_id: AccountId) -> Option<StorageBalance> {
        self.token.storage_balance_of(account_id)
    }
}

#[near]
impl FungibleTokenMetadataProvider for Wrap {
    fn ft_metadata(&self) -> FungibleTokenMetadata {
        FungibleTokenMetadata {
            spec: FT_METADATA_SPEC.to_string(),
            name: "Wrapped NEAR probe".to_string(),
            symbol: "WPROBE".to_string(),
            icon: None,
            reference: None,
            reference_hash: None,
            decimals: 24,
        }
    }
}
