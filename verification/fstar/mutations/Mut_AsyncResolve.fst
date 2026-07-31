module Mut_AsyncResolve

/// MUTATION (expected to FAIL verification) — non-vacuity check for FSM-5.
///
/// We drop the `.min(amount)` guard so a malicious token that over-reports its
/// transferred amount inflates `used` beyond `amount`. Then `used + refund`
/// (with saturating refund) no longer equals `amount`, i.e. the resolution
/// double-counts. The conservation lemma must FAIL.

let min (a b:nat) : nat = if a <= b then a else b

type call_outcome = | CallOk : returned:nat -> call_outcome | CallDeserErr | CallPromiseErr

/// BUG: use the token-reported value directly, without `.min(amount)`.
let used_call_bad (amount:nat) (o:call_outcome) : nat =
  match o with
  | CallOk r -> r
  | CallDeserErr -> 0
  | CallPromiseErr -> amount

let refund (amount used:nat) : nat = if amount >= used then amount - used else 0

let call_conserves_bad (amount:nat) (o:call_outcome)
  : Lemma (let u = used_call_bad amount o in u <= amount /\ u + refund amount u == amount)
  = ()
