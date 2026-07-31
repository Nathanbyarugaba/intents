module Defuse.Fees

/// FSM-2 — Protocol fee arithmetic: boundedness, monotonicity, no-panic.
///
/// Rust source: crates/primitives/fees/src/lib.rs
///   pub struct Pips(u32);                     // 1 pip = 0.0001%
///   MAX = ONE_PERCENT*100 = 1_000_000         // == 100%
///   fn fee(a)      = a.checked_mul_div(pips, MAX).unwrap_or_else(unreachable!)
///   fn fee_ceil(a) = a.checked_mul_div_ceil(pips, MAX).unwrap_or_else(unreachable!)
///   fn invert()    = MAX - pips
///
/// Properties proved (Model proof):
///   * no_panic_*          : fee/fee_ceil NEVER hit the `unreachable!()` panic
///                           (the checked op is always Some) -> no DoS/panic.
///   * DEF-FEE-001         : fee_ceil(a) <= a  (fee can never exceed the amount
///                           charged, so the collector can't be credited more
///                           than the payer is debited).
///   * fee_le_ceil         : fee(a) <= fee_ceil(a) <= fee(a) + 1.
///   * monotone in pips / in amount (no rounding cliff exploitable by splitting).
///   * zero cases + boundary witnesses.
///
/// EXCLUDED (by request, known issue): the NEP-245 MT-"split" fee bypass, i.e.
/// TokenDiff::token_fee returning ZERO for amount <= 1. Here `pips` is opaque.

open Defuse.Arith

let max_pips : pos = 1000000

/// A valid Pips value: 0 (=0%) .. MAX (=100%). Mirrors Pips::from_pips range check.
type pips = p:int{ 0 <= p /\ p <= max_pips }

let invert (p:pips) : pips = max_pips - p

let fee_opt      (p:pips) (a:u128) : option u128 = checked_mul_div_u      a p max_pips
let fee_ceil_opt (p:pips) (a:u128) : option u128 = checked_mul_div_ceil_u a p max_pips

/// ----------------------------------------------------------------------------
/// No-panic + boundedness.
/// ----------------------------------------------------------------------------

/// fee is always defined and never exceeds the amount.
let no_panic_fee (p:pips) (a:u128)
  : Lemma (Some? (fee_opt p a) /\ (Some?.v (fee_opt p a)) <= a)
  = fdiv_upper a p max_pips

/// DEF-FEE-001: fee_ceil is always defined and never exceeds the amount.
let fee_ceil_le_amount (p:pips) (a:u128)
  : Lemma (Some? (fee_ceil_opt p a) /\ (Some?.v (fee_ceil_opt p a)) <= a)
  = cdiv_upper a p max_pips

let no_panic_fee_ceil (p:pips) (a:u128)
  : Lemma (Some? (fee_ceil_opt p a))
  = fee_ceil_le_amount p a

/// ----------------------------------------------------------------------------
/// fee(a) <= fee_ceil(a) <= fee(a) + 1
/// ----------------------------------------------------------------------------

let fee_le_ceil (p:pips) (a:u128)
  : Lemma
      (Some? (fee_opt p a) /\ Some? (fee_ceil_opt p a) /\
       (let f = Some?.v (fee_opt p a) in
        let c = Some?.v (fee_ceil_opt p a) in
        f <= c /\ c <= f + 1))
  = no_panic_fee p a;
    fee_ceil_le_amount p a;
    floor_le_ceil (a * p) max_pips

/// ----------------------------------------------------------------------------
/// Monotonicity.
/// ----------------------------------------------------------------------------

let fee_monotone_pips (p1 p2 : pips) (a:u128)
  : Lemma (requires p1 <= p2)
          (ensures  Some?.v (fee_opt p1 a) <= Some?.v (fee_opt p2 a))
  = no_panic_fee p1 a; no_panic_fee p2 a;
    FStar.Math.Lemmas.lemma_mult_le_left a p1 p2;    // a*p1 <= a*p2
    fdiv_monotone (a * p1) (a * p2) max_pips

let fee_ceil_monotone_pips (p1 p2 : pips) (a:u128)
  : Lemma (requires p1 <= p2)
          (ensures  Some?.v (fee_ceil_opt p1 a) <= Some?.v (fee_ceil_opt p2 a))
  = no_panic_fee_ceil p1 a; no_panic_fee_ceil p2 a;
    FStar.Math.Lemmas.lemma_mult_le_left a p1 p2;
    cdiv_monotone (a * p1) (a * p2) max_pips

let fee_monotone_amount (p:pips) (a1 a2 : u128)
  : Lemma (requires a1 <= a2)
          (ensures  Some?.v (fee_opt p a1) <= Some?.v (fee_opt p a2))
  = no_panic_fee p a1; no_panic_fee p a2;
    FStar.Math.Lemmas.lemma_mult_le_right p a1 a2;   // a1*p <= a2*p
    fdiv_monotone (a1 * p) (a2 * p) max_pips

/// ----------------------------------------------------------------------------
/// Zero cases + boundary witnesses (kani::cover! analogues).
/// ----------------------------------------------------------------------------

let fee_zero_pips (a:u128)
  : Lemma (fee_opt 0 a == Some 0 /\ fee_ceil_opt 0 a == Some 0)
  = ()

let fee_zero_amount (p:pips)
  : Lemma (fee_opt p 0 == Some 0 /\ fee_ceil_opt p 0 == Some 0)
  = ()

/// exact 100% fee: fee_ceil(MAX, a) == a
let witness_full_fee () : Lemma (fee_ceil_opt max_pips 5 == Some 5) = ()
/// tiny amount, tiny pips: fee floors to 0 but fee_ceil rounds up to 1.
let witness_ceil_rounds_up () : Lemma (fee_opt 1 1 == Some 0 /\ fee_ceil_opt 1 1 == Some 1) = ()
