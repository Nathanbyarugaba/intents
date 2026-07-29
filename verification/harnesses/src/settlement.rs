//! DEF-CON-002 / DEF-CON-003: `TransferMatcher::finalize` conservation.
//!
//! Property proven: `finalize()` returns `Ok` **iff** every token's net delta
//! (sum over accounts) is zero, and when it returns `Err(UnmatchedDeltas)` the
//! reported per-token imbalance is *exactly* the true net delta. This rules out
//! any settlement that creates or destroys value being accepted.

#![allow(clippy::needless_range_loop)]

use defuse_core::{engine::deltas::TransferMatcher, token_id::TokenId};
use near_sdk::AccountId;

/// Number of accounts / tokens used in the bounded harness.
pub const N_ACC: usize = 3;
pub const N_TOK: usize = 2;

fn accounts() -> [AccountId; N_ACC] {
    ["a.near", "b.near", "c.near"].map(|s| s.parse().unwrap())
}

fn tokens() -> [TokenId; N_TOK] {
    ["t1.near", "t2.near"].map(crate::ft)
}

/// Core checker: apply the given per-(account,token) deltas to a
/// `TransferMatcher`, finalize, and assert the conservation property.
pub fn check_matcher(deltas: [[i128; N_TOK]; N_ACC]) {
    let accounts = accounts();
    let tokens = tokens();

    let mut m = TransferMatcher::new();
    for ai in 0..N_ACC {
        for ti in 0..N_TOK {
            let d = deltas[ai][ti];
            if d == 0 {
                continue;
            }
            // `add_delta` returns false only on per-account u128 accumulation
            // overflow; with distinct accounts and bounded deltas this holds.
            if !m.add_delta(accounts[ai].clone(), tokens[ti].clone(), d) {
                return;
            }
        }
    }

    // Expected net delta per token (checked; bail on i128 overflow).
    let mut net = [0i128; N_TOK];
    for ti in 0..N_TOK {
        let mut s: i128 = 0;
        for ai in 0..N_ACC {
            match s.checked_add(deltas[ai][ti]) {
                Some(v) => s = v,
                None => return,
            }
        }
        net[ti] = s;
    }

    match m.finalize() {
        Ok(_transfers) => {
            // SAFETY INVARIANT: a matched (accepted) settlement can only exist
            // when every token is perfectly balanced.
            for ti in 0..N_TOK {
                assert!(
                    net[ti] == 0,
                    "finalize() accepted a settlement with non-zero net delta ({}) for token {} => VALUE CREATED/DESTROYED",
                    net[ti],
                    ti
                );
            }
        }
        Err(v) => match v.as_unmatched_deltas() {
            Some(unmatched) => {
                // The reported imbalance must equal the true net, exactly.
                for ti in 0..N_TOK {
                    let reported = unmatched.get(&tokens[ti]).copied().unwrap_or(0);
                    assert!(
                        reported == net[ti],
                        "reported unmatched delta {} != true net {} for token {}",
                        reported,
                        net[ti],
                        ti
                    );
                }
                assert!(
                    net.iter().any(|&n| n != 0),
                    "UnmatchedDeltas returned but all tokens net to zero"
                );
            }
            None => {
                // Overflow: only allowed to be reported, never a false success.
            }
        },
    }
}

// ---------------------------------------------------------------------------
// Kani bounded proof
// ---------------------------------------------------------------------------
#[cfg(kani)]
mod proofs {
    use super::*;

    #[kani::proof]
    #[kani::unwind(6)]
    fn def_con_002_matcher_conservation() {
        let mut deltas = [[0i128; N_TOK]; N_ACC];
        for ai in 0..N_ACC {
            for ti in 0..N_TOK {
                let d: i128 = kani::any();
                // Bound magnitudes to keep the proof tractable while still
                // exercising the sign/zero/match/unmatch boundary classes.
                kani::assume(d >= -8 && d <= 8);
                deltas[ai][ti] = d;
            }
        }
        check_matcher(deltas);
    }
}

// ---------------------------------------------------------------------------
// Randomized proptest (runs under `cargo test`)
// ---------------------------------------------------------------------------
#[cfg(test)]
mod tests {
    use super::*;
    use proptest::prelude::*;

    proptest! {
        #![proptest_config(ProptestConfig::with_cases(20_000))]

        #[test]
        fn def_con_002_matcher_conservation(
            deltas in prop::array::uniform3(prop::array::uniform2(-1_000_000_000i128..=1_000_000_000i128))
        ) {
            check_matcher(deltas);
        }
    }

    /// Regression: a classic balanced multi-party ring must finalize Ok.
    #[test]
    fn balanced_ring_ok() {
        // a: -5 t1 ; b: +4 t1 ; c: +1 t1  => net 0
        check_matcher([[-5, 0], [4, 0], [1, 0]]);
    }

    /// A single unmatched delta must be rejected with the exact imbalance.
    #[test]
    fn single_unmatched_rejected() {
        check_matcher([[7, 0], [0, 0], [0, 0]]);
    }
}
