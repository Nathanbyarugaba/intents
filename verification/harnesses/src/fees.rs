//! DEF-FEE-001 / DEF-FEE-002: fee boundedness and rounding.
//!
//! Properties:
//! * `fee(amount) <= fee_ceil(amount) <= amount` for any valid rate (`pips <= MAX`)
//! * `fee_ceil(amount) - fee(amount) ∈ {0, 1}` (ceil vs floor)
//! * `TokenDiff::token_fee` returns `ZERO` exactly for NFTs and for MT/IMT with
//!   `amount <= 1`, and the configured `fee` otherwise (NEP-141 always charged).

use defuse_core::{
    fees::Pips,
    intents::token_diff::TokenDiff,
    token_id::{
        nep141::Nep141TokenId, nep171::Nep171TokenId, nep245::Nep245TokenId, TokenId,
    },
};
use near_sdk::AccountId;

/// Check fee bounds/rounding for a given rate and amount.
pub fn check_fee_bounds(pips_raw: u32, amount: u128) {
    let Some(pips) = Pips::from_pips(pips_raw) else {
        return; // out-of-range rate is rejected at construction; not applicable
    };
    let floor = pips.fee(amount);
    let ceil = pips.fee_ceil(amount);

    assert!(floor <= amount, "floor fee {floor} exceeds amount {amount}");
    assert!(ceil <= amount, "ceil fee {ceil} exceeds amount {amount}");
    assert!(floor <= ceil, "floor {floor} > ceil {ceil}");
    assert!(
        ceil - floor <= 1,
        "ceil {ceil} - floor {floor} > 1 (bad rounding)"
    );
    // ceil must be a valid rounding of the exact fee: floor is exact iff no remainder.
    if ceil != floor {
        assert!(ceil == floor + 1, "ceil is not floor+1");
    }
}

/// Check `TokenDiff::token_fee` classification.
pub fn check_token_fee_classification(amount: u128, fee: Pips) {
    let ft: TokenId = Nep141TokenId::new(mk("ft.near")).into();
    let nft: TokenId = Nep171TokenId::new(mk("nft.near"), "1".to_string()).into();
    let mt: TokenId = Nep245TokenId::new(mk("mt.near"), "x".to_string()).into();

    // NEP-141: always the configured fee.
    assert_eq!(TokenDiff::token_fee(ft, amount, fee), fee);
    // NEP-171 (NFT): never charged.
    assert_eq!(TokenDiff::token_fee(nft, amount, fee), Pips::ZERO);
    // NEP-245 (MT): charged only when amount > 1 (documented split behavior).
    let expected_mt = if amount > 1 { fee } else { Pips::ZERO };
    assert_eq!(TokenDiff::token_fee(mt, amount, fee), expected_mt);
}

fn mk(s: &str) -> AccountId {
    s.parse().unwrap()
}

#[cfg(kani)]
mod proofs {
    use super::*;

    #[kani::proof]
    fn def_fee_001_bounds() {
        let pips: u32 = kani::any();
        let amount: u128 = kani::any();
        check_fee_bounds(pips, amount);
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use proptest::prelude::*;

    proptest! {
        #![proptest_config(ProptestConfig::with_cases(50_000))]

        #[test]
        fn def_fee_001_bounds(pips in 0u32..=Pips::MAX.as_pips(), amount in any::<u128>()) {
            check_fee_bounds(pips, amount);
        }

        #[test]
        fn def_fee_002_classification(amount in any::<u128>(), pips in 0u32..=Pips::MAX.as_pips()) {
            check_token_fee_classification(amount, Pips::from_pips(pips).unwrap());
        }
    }

    #[test]
    fn boundary_amounts() {
        for &a in &[0u128, 1, 2, u128::MAX] {
            check_fee_bounds(Pips::MAX.as_pips(), a);
            check_fee_bounds(1, a);
            check_fee_bounds(0, a);
        }
    }
}
