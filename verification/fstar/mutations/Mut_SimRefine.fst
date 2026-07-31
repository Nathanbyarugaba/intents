module Mut_SimRefine

/// MUTATION (expected to FAIL verification) — non-vacuity check for FSM-18.
///
/// We make the cached (simulation) debit decision IGNORE the account lock, so
/// simulation would ACCEPT a debit that real execution REJECTS (a locked-account
/// withdraw). The refinement lemma SR-1 must FAIL — this is exactly the kind of
/// simulate-vs-real divergence that could mislead a solver into submitting a
/// batch that reverts on-chain.

type mstate = { present : bool; locked : bool; bal : nat }
type decision = | Accept | Reject

let bal_c    (s:mstate) : nat  = if s.present then s.bal else 0

let sub_real (s:mstate) (amt:nat) : decision =
  if not s.present then Reject
  else if s.locked then Reject
  else if amt = 0 then Reject
  else if s.bal < amt then Reject
  else Accept

/// BUG: cached ignores present + lock.
let sub_cached_bad (s:mstate) (amt:nat) : decision =
  if amt = 0 then Reject else if bal_c s < amt then Reject else Accept

let sr1_sub_agree_bad (s:mstate) (amt:nat)
  : Lemma (sub_real s amt == sub_cached_bad s amt)
  = ()
