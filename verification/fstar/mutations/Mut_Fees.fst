module Mut_Fees

/// MUTATION (expected to FAIL verification) — non-vacuity check for FSM-2.
///
/// We deliberately break the fee model by using an under-sized divisor
/// (max_pips - 1 instead of max_pips == 100%). With the wrong divisor,
/// fee_ceil(a) can exceed `a`, so the boundedness lemma DEF-FEE-001 must fail.
///
/// Expected result: F* reports an error (assertion / postcondition not provable).
/// If this module were to verify, our real DEF-FEE-001 proof would be vacuous.

open Defuse.Arith

let bad_div : pos = 999999   // == max_pips - 1  (BUG: not 100%)

let fee_ceil_bad (p:int{0 <= p /\ p <= 1000000}) (a:u128) : option u128 =
  checked_mul_div_ceil_u a p bad_div

// Claim (FALSE under the mutation): fee_ceil(a) <= a for all valid pips.
let fee_ceil_le_amount_bad (p:int{0 <= p /\ p <= 1000000}) (a:u128)
  : Lemma (Some? (fee_ceil_bad p a) /\ (Some?.v (fee_ceil_bad p a)) <= a)
  = cdiv_upper a p bad_div   // precondition p <= bad_div does NOT hold for p in (bad_div, MAX]
