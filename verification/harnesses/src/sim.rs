//! SIM-001/002/003: simulate-vs-execute parity.
//!
//! `Contract::simulate_intents` runs the engine over `self.cached()`
//! (`CachedState`, a read-through buffer) while `execute_intents` runs it over
//! the real state. Both live in `defuse_core`, so we can differentially test
//! parity directly: run the SAME intent sequence through
//!   * the "real" path  — engine over a mutable `MockState`, and
//!   * the "cached" path — engine over `CachedState<&MockState>`,
//! and assert identical per-intent success/failure (SIM-001), identical emitted
//! events (SIM-002), and identical resulting balances + finalize result
//! (SIM-003). A divergence would mean a simulation can predict a different
//! outcome than the real execution.

use defuse_core::{
    amounts::Amounts,
    engine::{Engine, Inspector, StateView},
    events::DefuseEvent,
    fees::Pips,
    intents::{
        token_diff::{TokenDeltas, TokenDiff},
        tokens::Transfer,
        ExecutableIntent,
    },
    token_id::TokenId,
    Nonce, Result, Timestamp,
};
use near_sdk::{serde_json::Value, AccountId, AccountIdRef, CryptoHash};
use std::collections::BTreeMap;

use crate::{ft, MockState};

const HASH: CryptoHash = [0u8; 32];
const SEED: u128 = 1000;

#[derive(Default)]
struct RecordInspector {
    events: Vec<Value>,
}
impl Inspector for RecordInspector {
    fn on_deadline(&mut self, _d: Timestamp) {}
    fn on_event(&mut self, e: DefuseEvent<'_>) {
        self.events.push(e.to_json());
    }
    fn on_intent_executed(&mut self, _s: &AccountIdRef, _h: CryptoHash, _n: Nonce) {}
}

#[derive(Debug, Clone)]
pub enum Op {
    Diff { signer: usize, deltas: [i128; 3] },
    Xfer { from: usize, to: usize, amounts: [u128; 3] },
}

fn accounts() -> [AccountId; 3] {
    ["a0.near", "a1.near", "a2.near"].map(|s| s.parse().unwrap())
}
fn tokens3() -> [TokenId; 3] {
    ["t1.near", "t2.near", "t3.near"].map(ft)
}

fn apply<S: defuse_core::engine::State, I: Inspector>(
    op: &Op,
    engine: &mut Engine<S, I>,
) -> Option<Result<()>> {
    let accs = accounts();
    let toks = tokens3();
    match op {
        Op::Diff { signer, deltas } => {
            let pairs: Vec<(TokenId, i128)> = toks
                .iter()
                .cloned()
                .zip(*deltas)
                .filter(|(_, d)| *d != 0)
                .collect();
            if pairs.is_empty() {
                return None;
            }
            let diff = TokenDiff {
                diff: TokenDeltas::default().with_apply_deltas(pairs).unwrap(),
                memo: None,
                referral: None,
            };
            Some(diff.execute_intent(accs[*signer].as_ref(), engine, HASH))
        }
        Op::Xfer { from, to, amounts } => {
            if from == to {
                return None;
            }
            let map: BTreeMap<TokenId, u128> = toks
                .iter()
                .cloned()
                .zip(*amounts)
                .filter(|(_, a)| *a != 0)
                .collect();
            if map.is_empty() {
                return None;
            }
            let xfer = Transfer {
                receiver_id: accs[*to].clone(),
                tokens: Amounts::new(map),
                memo: None,
                notification: None,
            };
            Some(xfer.execute_intent(accs[*from].as_ref(), engine, HASH))
        }
    }
}

fn seeded_state(pips: Pips) -> MockState {
    let mut m = MockState::new(pips);
    for a in accounts() {
        for t in tokens3() {
            m.set_balance(a.as_ref(), t, SEED);
        }
    }
    m
}

pub fn check_sim_parity(ops: Vec<Op>, pips_raw: u32) {
    let Some(pips) = Pips::from_pips(pips_raw) else {
        return;
    };
    let base = seeded_state(pips);

    // Real path: engine over a mutable copy of the state.
    let mut real = Engine::new(base.clone(), RecordInspector::default());
    // Cached path: engine over a read-through cache of the same base state.
    let mut cached = Engine::new((&base).cached(), RecordInspector::default());

    // On-chain, both `execute_intents` and `simulate_intents` run the intents
    // with `?` and revert the WHOLE batch on the first error. So the meaningful
    // parity is: (a) they agree on success/failure at each step and abort at the
    // same op, and (b) if the entire batch succeeds, state/events/finalize match.
    for (i, op) in ops.iter().enumerate() {
        let r = apply(op, &mut real);
        let c = apply(op, &mut cached);
        let (rk, ck) = (r.as_ref().map(Result::is_ok), c.as_ref().map(Result::is_ok));
        assert_eq!(
            rk, ck,
            "SIM-001: simulate/execute disagree on success at op {i}: real={:?} cached={:?}",
            r.as_ref().map(|x| x.as_ref().err().map(ToString::to_string)),
            c.as_ref().map(|x| x.as_ref().err().map(ToString::to_string)),
        );
        // If this op failed in both, the real batch would revert here — stop
        // comparing accumulated state (both roll back on-chain).
        if matches!(rk, Some(false)) {
            return;
        }
    }

    // SIM-002: identical event stream.
    assert_eq!(
        real.inspector.events, cached.inspector.events,
        "SIM-002: simulate/execute emitted different events"
    );

    // SIM-003: identical resulting balances.
    for a in accounts() {
        for t in tokens3() {
            assert_eq!(
                real.state.balance_of(a.as_ref(), &t),
                cached.state.balance_of(a.as_ref(), &t),
                "SIM-003: balance divergence for {a} / {t:?}"
            );
        }
    }

    // SIM-001: identical finalize outcome (and transfers on success).
    let rf = {
        let Engine { state, .. } = real;
        state.finalize()
    };
    let cf = {
        let Engine { state, .. } = cached;
        state.finalize()
    };
    assert_eq!(
        rf.is_ok(),
        cf.is_ok(),
        "SIM-001: finalize outcome differs (real ok={}, cached ok={})",
        rf.is_ok(),
        cf.is_ok()
    );
    if let (Ok(rt), Ok(ct)) = (rf, cf) {
        assert!(rt == ct, "finalize produced different transfers");
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use proptest::prelude::*;

    fn op_strategy() -> impl Strategy<Value = Op> {
        prop_oneof![
            (0usize..3, prop::array::uniform3(-2000i128..=2000i128))
                .prop_map(|(signer, deltas)| Op::Diff { signer, deltas }),
            (0usize..3, 0usize..3, prop::array::uniform3(0u128..=2000u128))
                .prop_map(|(from, to, amounts)| Op::Xfer { from, to, amounts }),
        ]
    }

    // NOTE: this broad parity check currently FAILS due to FINDING SIM-01 (see
    // `verification/reports/critical-review-a966.md`): `CachedState::balance_of`
    // returns a stale base-view balance once a cached balance is decremented to
    // exactly zero (the `Amounts`/`DefaultMap` cleanup removes the zero entry).
    // It is kept (ignored) so it will start passing once the bug is fixed.
    #[test]
    #[ignore = "FINDING SIM-01: CachedState stale-zero fallback breaks simulate/execute parity"]
    fn sim_execute_parity() {
        proptest!(|(
            ops in prop::collection::vec(op_strategy(), 0..6),
            pips in 0u32..=Pips::MAX.as_pips(),
        )| {
            check_sim_parity(ops, pips);
        });
    }

    /// FINDING SIM-01 (SIM-003) — deterministic reproduction.
    /// A balance spent to exactly 0 in the cache reads back as the stale
    /// on-chain (base) value instead of 0.
    #[test]
    fn finding_sim01_cached_stale_zero_readback() {
        let base = seeded_state(Pips::ZERO); // a2/t3 == 1000
        let a2 = accounts()[2].clone();
        let t3 = tokens3()[2].clone();

        // Real: credit +351 then debit -1351 => 1000 + 351 - 1351 = 0.
        let mut real = Engine::new(base.clone(), RecordInspector::default());
        apply(&Op::Diff { signer: 2, deltas: [0, 0, 351] }, &mut real).unwrap().unwrap();
        apply(&Op::Diff { signer: 2, deltas: [0, 0, -1351] }, &mut real).unwrap().unwrap();

        // Cached: identical ops.
        let mut cached = Engine::new((&base).cached(), RecordInspector::default());
        apply(&Op::Diff { signer: 2, deltas: [0, 0, 351] }, &mut cached).unwrap().unwrap();
        apply(&Op::Diff { signer: 2, deltas: [0, 0, -1351] }, &mut cached).unwrap().unwrap();

        let real_bal = real.state.balance_of(a2.as_ref(), &t3);
        let cached_bal = cached.state.balance_of(a2.as_ref(), &t3);

        assert_eq!(real_bal, 0, "execute path correctly reaches zero");
        // BUG: cached path reports the stale base value (1000) instead of 0.
        assert_eq!(
            cached_bal, 1000,
            "documents FINDING SIM-01; if this now equals 0 the bug is fixed — update the report"
        );
        assert_ne!(real_bal, cached_bal, "simulate/execute balance divergence");
    }

    /// FINDING SIM-01 (SIM-001) — security-relevant manifestation: `simulate`
    /// accepts a double-spend that `execute` correctly rejects.
    #[test]
    fn finding_sim01_cached_double_spend_accepted() {
        let base = seeded_state(Pips::ZERO); // a2/t1 == 1000

        // Real: spend 1000, then attempt to spend 1000 again.
        let mut real = Engine::new(base.clone(), RecordInspector::default());
        assert!(apply(&Op::Diff { signer: 2, deltas: [-1000, 0, 0] }, &mut real).unwrap().is_ok());
        let real_second = apply(&Op::Diff { signer: 2, deltas: [-1000, 0, 0] }, &mut real).unwrap();

        // Cached (simulate): same sequence.
        let mut cached = Engine::new((&base).cached(), RecordInspector::default());
        assert!(apply(&Op::Diff { signer: 2, deltas: [-1000, 0, 0] }, &mut cached).unwrap().is_ok());
        let cached_second = apply(&Op::Diff { signer: 2, deltas: [-1000, 0, 0] }, &mut cached).unwrap();

        assert!(real_second.is_err(), "execute correctly rejects the over-spend");
        // BUG: simulate accepts spending the same balance twice.
        assert!(
            cached_second.is_ok(),
            "documents FINDING SIM-01; if this is now Err the bug is fixed — update the report"
        );
    }

    /// Positive control: when NO balance is driven to exactly zero, simulate and
    /// execute agree — isolating the defect to the zero-cleanup fallback.
    #[test]
    fn parity_holds_without_zero_crossing() {
        check_sim_parity(
            vec![
                Op::Diff { signer: 0, deltas: [-100, 50, 0] },
                Op::Xfer { from: 1, to: 2, amounts: [10, 0, 0] },
                Op::Diff { signer: 2, deltas: [7, 0, -3] },
            ],
            Pips::ONE_BIP.as_pips(),
        );
    }
}
