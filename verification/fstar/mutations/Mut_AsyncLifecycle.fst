module Mut_AsyncLifecycle

/// MUTATION (expected to FAIL verification) — non-vacuity check for FSM-12.
///
/// We drop the "resolved-once" guard so a resolve settles a matching id even if
/// it was ALREADY resolved (models a duplicated/late callback that is NOT made a
/// no-op). A second resolve then refunds + settles again while the in-flight sum
/// stays 0, so the conserved total INCREASES — value creation. The conservation
/// lemma must FAIL.

type wid = nat
type pending = { id : wid; amt : nat; resolved : bool }
type st = { bal : nat; pend : list pending; settled : nat }

let rec sum_unresolved (p:list pending) : nat =
  match p with
  | [] -> 0
  | x :: xs -> (if x.resolved then 0 else x.amt) + sum_unresolved xs

let conserved (s:st) : nat = s.bal + sum_unresolved s.pend + s.settled

/// BUG: matches on id ignoring `resolved`, so an already-resolved entry is settled again.
let rec mark_and_settle_bad (p:list pending) (i:wid) (used:nat) : (list pending & nat & nat) =
  match p with
  | [] -> ([], 0, 0)
  | x :: xs ->
      if x.id = i then
        let u = if used <= x.amt then used else x.amt in
        (({ x with resolved = true }) :: xs, x.amt - u, u)
      else
        let (xs', r, e) = mark_and_settle_bad xs i used in
        (x :: xs', r, e)

let resolve_bad (s:st) (i:wid) (used:nat) : st =
  let (p', r, e) = mark_and_settle_bad s.pend i used in
  { bal = s.bal + r; pend = p'; settled = s.settled + e }

/// FALSE under the mutation: resolving preserves the conserved total.
let resolve_preserves_bad (s:st) (i:wid) (used:nat)
  : Lemma (conserved (resolve_bad s i used) == conserved s)
  = ()
