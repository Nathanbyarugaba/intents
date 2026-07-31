module Mut_MtResolve

/// MUTATION (expected to FAIL verification) — non-vacuity check for FSM-7.
///
/// We drop the `refund.min(amount)` cap, so a malicious callback that reports a
/// refund larger than the requested amount inflates `refund` beyond `amount`.
/// Then `used = amount - refund` underflows and per-item conservation
/// (used + refund == amount with refund <= amount) must FAIL.

let min (a b:nat) : nat = if a <= b then a else b

/// BUG: cap only at balance, not at the requested amount.
let refund_of_bad (amount reported bal : nat) : nat = min reported bal

let item_conserves_bad (amount reported bal : nat)
  : Lemma (let r = refund_of_bad amount reported bal in
           r <= amount /\ amount - r + r == amount)
  = ()
