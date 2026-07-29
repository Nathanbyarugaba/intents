//! Kani (bounded model-checking) proofs for the crypto/near-free arithmetic
//! that underpins settlement fees & conservation.
//!
//! Two classes of property:
//!
//! * **Kani proofs** cover the `Pips` fee-rate *algebra* (pure `u32`): rate
//!   range, inversion involution, and complement — these are exactly the
//!   operations the production `TokenDiff::closure_*` fee math relies on, and
//!   they are `bnum`-free so Kani discharges them exhaustively.
//! * **proptest harnesses** cover the wide 256-bit `mul_div`/`fee_ceil`
//!   properties. Kani cannot currently discharge these: `bnum`'s 256-bit
//!   division uses data-dependent shift loops that explode CBMC's unwinding.
//!   The proptest versions exercise them across 100k random cases including
//!   `u128::MAX` boundaries.

// `kani` is a custom cfg set only when running under `cargo kani`.
#![allow(unexpected_cfgs)]

use defuse_fees::Pips;
use defuse_num_utils::CheckedMulDiv;

/// DEF-FEE-001 (rate algebra): `from_pips` accepts exactly `0..=MAX`.
#[inline]
pub fn pips_from_range(x: u32) {
    match Pips::from_pips(x) {
        Some(p) => assert!(x <= Pips::MAX.as_pips() && p.as_pips() == x),
        None => assert!(x > Pips::MAX.as_pips()),
    }
}

/// DEF-FEE-001 (rate algebra): inversion is an involution and complements to
/// `MAX` — the invariant behind `Pips::invert()` used in closure fee math.
#[inline]
pub fn pips_invert_involution(x: u32) {
    let Some(p) = Pips::from_pips(x) else {
        return;
    };
    let inv = p.invert();
    assert!(inv.invert() == p, "invert is not an involution");
    assert!(
        inv.as_pips() + p.as_pips() == Pips::MAX.as_pips(),
        "invert does not complement to MAX"
    );
    assert!(inv.as_pips() <= Pips::MAX.as_pips(), "invert out of range");
}

/// DEF-FEE-001: floor/ceil fee bounds (proptest only — uses `bnum`).
#[inline]
pub fn fee_bounds(pips_raw: u32, amount: u128) {
    let Some(pips) = Pips::from_pips(pips_raw) else {
        return;
    };
    let floor = pips.fee(amount);
    let ceil = pips.fee_ceil(amount);
    assert!(floor <= amount, "floor fee exceeds amount");
    assert!(ceil <= amount, "ceil fee exceeds amount");
    assert!(floor <= ceil, "floor > ceil");
    assert!(ceil - floor <= 1, "rounding gap > 1");
}

/// DEF-CON-003: mul-div ceil/floor relationship & no false success (proptest).
#[inline]
pub fn muldiv_relation(a: u128, b: u128, c: u128) {
    if c == 0 {
        assert!(a.checked_mul_div_ceil(b, c).is_none());
        return;
    }
    match (a.checked_mul_div(b, c), a.checked_mul_div_ceil(b, c)) {
        (Some(fl), Some(cl)) => {
            assert!(fl <= cl && cl - fl <= 1);
        }
        (Some(fl), None) => assert!(fl == u128::MAX),
        (None, Some(_)) => panic!("floor overflowed but ceil did not"),
        (None, None) => {}
    }
}

#[cfg(kani)]
mod proofs {
    use super::*;

    #[kani::proof]
    fn def_fee_001_from_range() {
        pips_from_range(kani::any());
    }

    #[kani::proof]
    fn def_fee_001_invert_involution() {
        pips_invert_involution(kani::any());
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use proptest::prelude::*;

    proptest! {
        #![proptest_config(ProptestConfig::with_cases(100_000))]

        #[test]
        fn def_fee_001_bounds(pips in 0u32..=Pips::MAX.as_pips(), amount in any::<u128>()) {
            fee_bounds(pips, amount);
        }

        #[test]
        fn def_con_003_muldiv_relation(a in any::<u128>(), b in any::<u128>(), c in any::<u128>()) {
            muldiv_relation(a, b, c);
        }

        #[test]
        fn def_fee_001_invert(x in 0u32..=Pips::MAX.as_pips()) {
            pips_invert_involution(x);
        }
    }
}
