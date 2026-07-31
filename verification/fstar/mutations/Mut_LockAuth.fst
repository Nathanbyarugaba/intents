module Mut_LockAuth

/// MUTATION (expected to FAIL verification) — non-vacuity check for FSM-9.
///
/// We make `internal_sub_balance` skip the lock (as if it used
/// `as_inner_unchecked_mut()` instead of `get_mut()`), so a LOCKED account can be
/// debited. The freeze invariant LA-1 (locked && !forced => never Debited) must
/// then FAIL -- exactly the lock-bypass an attacker would exploit to drain a
/// frozen account.

type op = | SubBalance : amt:nat -> op | AddBalance : amt:nat -> op | CommitNonce : op
type outcome = | Rejected : outcome | Credited : amt:nat -> outcome
              | Debited : amt:nat -> outcome | NonceCommitted : outcome

/// BUG: SubBalance ignores the lock entirely.
let step_bad (locked forced : bool) (o:op) : outcome =
  match o with
  | AddBalance a -> Credited a
  | SubBalance a -> Debited a                 // <-- lock bypass
  | CommitNonce  -> if locked then Rejected else NonceCommitted

let la1_freeze_bad (o:op)
  : Lemma (~(Debited? (step_bad true false o)))
  = ()
