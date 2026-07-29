//! Verification harnesses for NEAR Intents (Defuse) custody/settlement invariants.
//!
//! This crate is verification-only. It drives **production** `defuse_core`
//! logic (the settlement engine, `TokenDiff`, fee math, nonce parsing) through
//! an in-memory [`MockState`] implementation of the `State`/`StateView` traits.
//!
//! - `cargo test` runs the proptest (randomized) harnesses.
//! - `cargo kani` runs the bounded model-checking proofs.
//!
//! No production behavior is modified.

// `kani` is a custom cfg set only when running under `cargo kani`.
#![allow(unexpected_cfgs)]

use std::{
    borrow::Cow,
    collections::{BTreeMap, BTreeSet},
};

use defuse_core::{
    DefuseError, Nonce, NoncePrefix, PublicKey, Result, Salt,
    amounts::Amounts,
    engine::{Inspector, State, StateView},
    events::DefuseEvent,
    fees::Pips,
    intents::tokens::{
        FtWithdraw, MtWithdraw, NativeWithdraw, NftWithdraw, NotifyOnTransfer, StorageDeposit,
    },
    token_id::{TokenId, nep141::Nep141TokenId},
    Timestamp,
};
use defuse_core::intents::auth::AuthCall;
use near_sdk::{AccountId, AccountIdRef, CryptoHash};

pub mod conservation;
pub mod fees;
pub mod nonce;
pub mod settlement;
pub mod wallet;

/// An [`Inspector`] that ignores every event (so no NEAR VM context is
/// required to run the engine off-chain).
#[derive(Debug, Default)]
pub struct NoopInspector;

impl Inspector for NoopInspector {
    #[inline]
    fn on_deadline(&mut self, _deadline: Timestamp) {}
    #[inline]
    fn on_event(&mut self, _event: DefuseEvent<'_>) {}
    #[inline]
    fn on_intent_executed(&mut self, _signer_id: &AccountIdRef, _hash: CryptoHash, _nonce: Nonce) {}
}

/// In-memory implementation of the production `State`/`StateView` traits.
///
/// Balances/locks/nonces/keys are tracked in ordered maps (deterministic for
/// Kani). Withdrawal/mint/burn behave like the real contract's inner state:
/// they mutate balances directly (i.e. they are treated as external transfers
/// and are NOT delta-matched by the `Deltas` wrapper).
#[derive(Debug, Clone)]
pub struct MockState {
    pub balances: BTreeMap<AccountId, BTreeMap<TokenId, u128>>,
    pub locked: BTreeSet<AccountId>,
    pub nonces: BTreeMap<AccountId, BTreeSet<Nonce>>,
    pub pubkeys: BTreeMap<AccountId, BTreeSet<PublicKey>>,
    pub auth_disabled: BTreeSet<AccountId>,
    pub fee: Pips,
    pub fee_collector: AccountId,
    pub wnear: AccountId,
    pub verifying_contract: AccountId,
}

impl MockState {
    #[must_use]
    pub fn new(fee: Pips) -> Self {
        Self {
            balances: BTreeMap::new(),
            locked: BTreeSet::new(),
            nonces: BTreeMap::new(),
            pubkeys: BTreeMap::new(),
            auth_disabled: BTreeSet::new(),
            fee,
            fee_collector: acc("fee-collector.near"),
            wnear: acc("wrap.near"),
            verifying_contract: acc("intents.near"),
        }
    }

    /// Seed a balance directly (setup helper).
    pub fn set_balance(&mut self, owner: &AccountIdRef, token: TokenId, amount: u128) {
        self.balances
            .entry(owner.to_owned())
            .or_default()
            .insert(token, amount);
    }

    #[must_use]
    pub fn bal(&self, owner: &AccountIdRef, token: &TokenId) -> u128 {
        self.balances
            .get(owner)
            .and_then(|m| m.get(token))
            .copied()
            .unwrap_or(0)
    }

    /// Total supply of `token` across *all* accounts currently tracked.
    #[must_use]
    pub fn total_supply(&self, token: &TokenId) -> Option<u128> {
        self.balances
            .values()
            .filter_map(|m| m.get(token).copied())
            .try_fold(0u128, u128::checked_add)
    }

    fn checked_add(&mut self, owner: &AccountIdRef, token: TokenId, amount: u128) -> Result<()> {
        let e = self
            .balances
            .entry(owner.to_owned())
            .or_default()
            .entry(token)
            .or_default();
        *e = e.checked_add(amount).ok_or(DefuseError::BalanceOverflow)?;
        Ok(())
    }

    fn checked_sub(&mut self, owner: &AccountIdRef, token: TokenId, amount: u128) -> Result<()> {
        let m = self
            .balances
            .get_mut(owner)
            .ok_or_else(|| DefuseError::AccountNotFound(owner.to_owned()))?;
        let e = m.get_mut(&token).ok_or(DefuseError::BalanceOverflow)?;
        *e = e.checked_sub(amount).ok_or(DefuseError::BalanceOverflow)?;
        Ok(())
    }
}

impl StateView for MockState {
    fn verifying_contract(&self) -> Cow<'_, AccountIdRef> {
        Cow::Borrowed(self.verifying_contract.as_ref())
    }
    fn wnear_id(&self) -> Cow<'_, AccountIdRef> {
        Cow::Borrowed(self.wnear.as_ref())
    }
    fn fee(&self) -> Pips {
        self.fee
    }
    fn fee_collector(&self) -> Cow<'_, AccountIdRef> {
        Cow::Borrowed(self.fee_collector.as_ref())
    }
    fn has_public_key(&self, account_id: &AccountIdRef, public_key: &PublicKey) -> bool {
        self.pubkeys
            .get(account_id)
            .is_some_and(|s| s.contains(public_key))
    }
    fn iter_public_keys(&self, account_id: &AccountIdRef) -> impl Iterator<Item = PublicKey> + '_ {
        self.pubkeys
            .get(account_id)
            .into_iter()
            .flatten()
            .copied()
    }
    fn is_nonce_used(&self, account_id: &AccountIdRef, nonce: Nonce) -> bool {
        self.nonces
            .get(account_id)
            .is_some_and(|s| s.contains(&nonce))
    }
    fn balance_of(&self, account_id: &AccountIdRef, token_id: &TokenId) -> u128 {
        self.bal(account_id, token_id)
    }
    fn is_account_locked(&self, account_id: &AccountIdRef) -> bool {
        self.locked.contains(account_id)
    }
    fn is_auth_by_predecessor_id_enabled(&self, account_id: &AccountIdRef) -> bool {
        !self.auth_disabled.contains(account_id)
    }
    fn is_valid_salt(&self, _salt: Salt) -> bool {
        true
    }
}

impl State for MockState {
    fn add_public_key(&mut self, account_id: AccountId, public_key: PublicKey) -> Result<()> {
        if self.locked.contains(&account_id) {
            return Err(DefuseError::AccountLocked(account_id));
        }
        if !self.pubkeys.entry(account_id.clone()).or_default().insert(public_key) {
            return Err(DefuseError::PublicKeyExists(account_id, public_key));
        }
        Ok(())
    }

    fn remove_public_key(&mut self, account_id: AccountId, public_key: PublicKey) -> Result<()> {
        if self.locked.contains(&account_id) {
            return Err(DefuseError::AccountLocked(account_id));
        }
        if !self
            .pubkeys
            .entry(account_id.clone())
            .or_default()
            .remove(&public_key)
        {
            return Err(DefuseError::PublicKeyNotExist(account_id, public_key));
        }
        Ok(())
    }

    fn commit_nonce(&mut self, account_id: AccountId, nonce: Nonce) -> Result<()> {
        if self.locked.contains(&account_id) {
            return Err(DefuseError::AccountLocked(account_id));
        }
        if !self.nonces.entry(account_id).or_default().insert(nonce) {
            return Err(DefuseError::NonceUsed);
        }
        Ok(())
    }

    fn cleanup_nonce_by_prefix(
        &mut self,
        account_id: &AccountIdRef,
        prefix: NoncePrefix,
    ) -> Result<bool> {
        let Some(set) = self.nonces.get_mut(account_id) else {
            return Err(DefuseError::AccountNotFound(account_id.to_owned()));
        };
        let before = set.len();
        set.retain(|n| n[..31] != prefix[..]);
        Ok(set.len() != before)
    }

    fn internal_add_balance(
        &mut self,
        owner_id: AccountId,
        tokens: impl IntoIterator<Item = (TokenId, u128)>,
    ) -> Result<()> {
        for (token_id, amount) in tokens {
            if amount == 0 {
                return Err(DefuseError::InvalidIntent);
            }
            self.checked_add(owner_id.as_ref(), token_id, amount)?;
        }
        Ok(())
    }

    fn internal_sub_balance(
        &mut self,
        owner_id: &AccountIdRef,
        tokens: impl IntoIterator<Item = (TokenId, u128)>,
    ) -> Result<()> {
        if self.locked.contains(owner_id) {
            return Err(DefuseError::AccountLocked(owner_id.to_owned()));
        }
        for (token_id, amount) in tokens {
            if amount == 0 {
                return Err(DefuseError::InvalidIntent);
            }
            self.checked_sub(owner_id, token_id, amount)?;
        }
        Ok(())
    }

    fn ft_withdraw(&mut self, owner_id: &AccountIdRef, withdraw: FtWithdraw) -> Result<()> {
        // external transfer: reduce internal balance
        self.internal_sub_balance(
            owner_id,
            std::iter::once((Nep141TokenId::new(withdraw.token).into(), withdraw.amount.0)).chain(
                withdraw
                    .storage_deposit
                    .map(|a| (Nep141TokenId::new(self.wnear.clone()).into(), a.as_yoctonear())),
            ),
        )
    }

    fn nft_withdraw(&mut self, owner_id: &AccountIdRef, withdraw: NftWithdraw) -> Result<()> {
        use defuse_core::token_id::nep171::Nep171TokenId;
        self.internal_sub_balance(
            owner_id,
            [(
                Nep171TokenId::new(withdraw.token, withdraw.token_id).into(),
                1u128,
            )],
        )
    }

    fn mt_withdraw(&mut self, owner_id: &AccountIdRef, withdraw: MtWithdraw) -> Result<()> {
        use defuse_core::token_id::nep245::Nep245TokenId;
        if withdraw.token_ids.len() != withdraw.amounts.len() || withdraw.token_ids.is_empty() {
            return Err(DefuseError::InvalidIntent);
        }
        let items: Vec<(TokenId, u128)> = withdraw
            .token_ids
            .into_iter()
            .map(|tid| Nep245TokenId::new(withdraw.token.clone(), tid).into())
            .zip(withdraw.amounts.iter().map(|a| a.0))
            .collect();
        self.internal_sub_balance(owner_id, items)
    }

    fn native_withdraw(&mut self, owner_id: &AccountIdRef, withdraw: NativeWithdraw) -> Result<()> {
        self.internal_sub_balance(
            owner_id,
            [(
                Nep141TokenId::new(self.wnear.clone()).into(),
                withdraw.amount.as_yoctonear(),
            )],
        )
    }

    fn notify_on_transfer(
        &self,
        _sender_id: &AccountIdRef,
        _receiver_id: AccountId,
        _tokens: Amounts,
        _notification: NotifyOnTransfer,
    ) {
    }

    fn storage_deposit(
        &mut self,
        owner_id: &AccountIdRef,
        storage_deposit: StorageDeposit,
    ) -> Result<()> {
        self.internal_sub_balance(
            owner_id,
            [(
                Nep141TokenId::new(self.wnear.clone()).into(),
                storage_deposit.amount.as_yoctonear(),
            )],
        )
    }

    fn set_auth_by_predecessor_id(&mut self, account_id: AccountId, enable: bool) -> Result<bool> {
        if self.locked.contains(&account_id) {
            return Err(DefuseError::AccountLocked(account_id));
        }
        let was_enabled = !self.auth_disabled.contains(&account_id);
        if enable {
            self.auth_disabled.remove(&account_id);
        } else {
            self.auth_disabled.insert(account_id);
        }
        Ok(was_enabled)
    }

    fn auth_call(&mut self, signer_id: &AccountIdRef, auth_call: AuthCall) -> Result<()> {
        if !auth_call.attached_deposit.is_zero() {
            self.internal_sub_balance(
                signer_id,
                [(
                    Nep141TokenId::new(self.wnear.clone()).into(),
                    auth_call.attached_deposit.as_yoctonear(),
                )],
            )?;
        }
        Ok(())
    }

    fn mint(&mut self, owner_id: AccountId, tokens: Amounts, _memo: Option<String>) -> Result<()> {
        self.internal_add_balance(owner_id, tokens)
    }

    fn burn(
        &mut self,
        owner_id: &AccountIdRef,
        tokens: Amounts,
        _memo: Option<String>,
    ) -> Result<()> {
        self.internal_sub_balance(owner_id, tokens)
    }
}

/// Parse an account id (panics on invalid — only used with valid literals).
#[must_use]
pub fn acc(s: &str) -> AccountId {
    s.parse().unwrap_or_else(|_| panic!("invalid account id: {s}"))
}

/// Build a NEP-141 token id from a contract account id string.
#[must_use]
pub fn ft(s: &str) -> TokenId {
    Nep141TokenId::new(acc(s)).into()
}
