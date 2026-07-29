//! DEF-CON-001: end-to-end settlement conservation driven through the REAL
//! engine (`TokenDiff`/`Transfer` `execute_intent` + fee accounting + `finalize`).
//!
//! We use the production `TokenDiff::closure_deltas` to build a counter-order,
//! then assert that executing both orders and finalizing (a) succeeds and
//! (b) leaves the total supply of every token unchanged — i.e. the settlement
//! neither mints nor destroys value, including the protocol fee leg.

#![allow(clippy::needless_range_loop)]

use std::collections::BTreeMap;

use defuse_core::{
    amounts::Amounts,
    engine::{Engine, StateView},
    fees::Pips,
    intents::{
        token_diff::{TokenDeltas, TokenDiff},
        tokens::Transfer,
        ExecutableIntent,
    },
    token_id::TokenId,
};
use near_sdk::{AccountId, CryptoHash};

use crate::{ft, MockState, NoopInspector};

/// A large per-account seed balance; chosen so subtractions never underflow and
/// totals never overflow (3 accounts * 1e30 << u128::MAX).
const B0: u128 = 1_000_000_000_000_000_000_000_000_000_000;
const HASH: CryptoHash = [0u8; 32];

fn traders() -> [AccountId; 2] {
    ["alice.near", "bob.near"].map(|s| s.parse().unwrap())
}

fn tokens3() -> [TokenId; 3] {
    ["t1.near", "t2.near", "t3.near"].map(ft)
}

fn to_deltas(pairs: Vec<(TokenId, i128)>) -> TokenDeltas {
    TokenDeltas::default()
        .with_apply_deltas(pairs)
        .expect("delta accumulation overflow")
}

/// DEF-CON-001 via `TokenDiff` + fee + closure counter-order.
pub fn check_token_diff_conservation(a_deltas: [i128; 3], pips_raw: u32) {
    let Some(fee) = Pips::from_pips(pips_raw) else {
        return;
    };
    let tokens = tokens3();
    let [alice, bob] = traders();

    let a_pairs: Vec<(TokenId, i128)> = tokens
        .iter()
        .cloned()
        .zip(a_deltas)
        .filter(|(_, d)| *d != 0)
        .collect();
    if a_pairs.is_empty() {
        return;
    }

    // Production closure: the counter-order that balances `a_pairs` under `fee`.
    let Some(b_map) = TokenDiff::closure_deltas(a_pairs.clone(), fee) else {
        return; // e.g. fee == 100% (invert == 0) or overflow: not applicable
    };
    let b_pairs: Vec<(TokenId, i128)> = b_map.into_iter().collect();
    if b_pairs.is_empty() {
        return;
    }

    // Seed alice, bob, fee_collector uniformly.
    let mut mock = MockState::new(fee);
    let fee_collector = mock.fee_collector.clone();
    let all_accts = [alice.clone(), bob.clone(), fee_collector];
    for acct in &all_accts {
        for tok in &tokens {
            mock.set_balance(acct.as_ref(), tok.clone(), B0);
        }
    }
    let initial_total: u128 = (all_accts.len() as u128) * B0;

    let a_diff = TokenDiff {
        diff: to_deltas(a_pairs),
        memo: None,
        referral: None,
    };
    let b_diff = TokenDiff {
        diff: to_deltas(b_pairs),
        memo: None,
        referral: None,
    };

    let mut engine = Engine::new(mock, NoopInspector);
    if a_diff.execute_intent(alice.as_ref(), &mut engine, HASH).is_err() {
        return; // insufficient balance etc. — not a conservation case
    }
    if b_diff.execute_intent(bob.as_ref(), &mut engine, HASH).is_err() {
        return;
    }

    // Totals per token AFTER execution (before consuming state in finalize).
    let mut totals = [0u128; 3];
    for (ti, tok) in tokens.iter().enumerate() {
        let mut s = 0u128;
        for acct in &all_accts {
            s = s
                .checked_add(engine.state.balance_of(acct.as_ref(), tok))
                .expect("total overflow");
        }
        totals[ti] = s;
    }

    let Engine { state, .. } = engine;
    let res = state.finalize();

    // The closure is *defined* to make this settlement match exactly.
    assert!(
        res.is_ok(),
        "closure-derived counter-order failed to finalize (fee={pips_raw} pips): {:?}",
        res.err()
    );

    for ti in 0..3 {
        assert!(
            totals[ti] == initial_total,
            "token {ti}: post-settlement total {} != initial {} => VALUE CREATED/DESTROYED (fee={pips_raw} pips)",
            totals[ti],
            initial_total
        );
    }
}

/// DEF-CON-001 via internal `Transfer` (must always conserve & finalize Ok).
pub fn check_transfer_conservation(amount: u128) {
    if amount == 0 {
        return;
    }
    let tokens = tokens3();
    let [alice, bob] = traders();
    let mut mock = MockState::new(Pips::ZERO);
    let all_accts = [alice.clone(), bob.clone()];
    for acct in &all_accts {
        for tok in &tokens {
            mock.set_balance(acct.as_ref(), tok.clone(), B0);
        }
    }
    if amount > B0 {
        return;
    }

    let transfer = Transfer {
        receiver_id: bob.clone(),
        tokens: Amounts::new(BTreeMap::from([(tokens[0].clone(), amount)])),
        memo: None,
        notification: None,
    };

    let mut engine = Engine::new(mock, NoopInspector);
    transfer
        .execute_intent(alice.as_ref(), &mut engine, HASH)
        .expect("transfer should succeed with sufficient balance");

    let mut totals = [0u128; 3];
    for (ti, tok) in tokens.iter().enumerate() {
        let mut s = 0u128;
        for acct in &all_accts {
            s += engine.state.balance_of(acct.as_ref(), tok);
        }
        totals[ti] = s;
    }

    let Engine { state, .. } = engine;
    assert!(state.finalize().is_ok(), "internal transfer must finalize");
    assert!(totals[0] == 2 * B0, "transfer changed total supply of t1");
    assert!(totals[1] == 2 * B0 && totals[2] == 2 * B0);
}

#[cfg(kani)]
mod proofs {
    use super::*;

    #[kani::proof]
    #[kani::unwind(4)]
    fn def_con_001_token_diff_conservation() {
        let mut d = [0i128; 3];
        for i in 0..3 {
            let x: i128 = kani::any();
            kani::assume(x >= -1000 && x <= 1000);
            d[i] = x;
        }
        let pips: u32 = kani::any();
        kani::assume(pips <= Pips::MAX.as_pips());
        check_token_diff_conservation(d, pips);
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use proptest::prelude::*;

    proptest! {
        #![proptest_config(ProptestConfig::with_cases(30_000))]

        #[test]
        fn def_con_001_token_diff_conservation(
            d in prop::array::uniform3(-1_000_000_000i128..=1_000_000_000i128),
            pips in 0u32..=Pips::MAX.as_pips(),
        ) {
            check_token_diff_conservation(d, pips);
        }

        #[test]
        fn def_con_001_transfer_conservation(amount in any::<u128>()) {
            check_transfer_conservation(amount);
        }
    }

    #[test]
    fn simple_swap_conserves() {
        // alice: -100 t1, +50 t2 ; closure balances it under 1 bip fee.
        check_token_diff_conservation([-100, 50, 0], Pips::ONE_BIP.as_pips());
        check_token_diff_conservation([-1_000_000, 999_000, 0], 0);
    }
}
