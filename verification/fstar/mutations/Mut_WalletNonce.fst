module Mut_WalletNonce

/// MUTATION (expected to FAIL verification) — non-vacuity check for FSM-15.
///
/// We shrink retention to a SINGLE window: a rotation clears the nonce
/// immediately (Cur -> Gone) instead of Cur -> Old -> Gone. Then a nonce can be
/// fully cleared within `T` of commit, so a still-valid message could be
/// replayed. The retention-within-window lemma must FAIL.

type slot = | Cur | Old | Gone

/// BUG: single-window — a rotation clears the nonce right away.
let rotate_bad (t_out:nat) (s:slot) (lc:nat) (t:nat) : (slot & nat) =
  if lc + t_out < t then (Gone, t) else (s, lc)

let rec rotate_all_bad (t_out:nat) (s:slot) (lc:nat) (ts:list nat) : Tot (slot & nat) (decreases ts) =
  match ts with
  | [] -> (s, lc)
  | t :: rest -> let (s', lc') = rotate_bad t_out s lc t in rotate_all_bad t_out s' lc' rest

/// FALSE under the mutation: retention holds through the validity window.
let retention_within_window_bad (t_out now1 now2 lc0 : nat) (ts:list nat)
  : Lemma
      (requires t_out > 0 /\ lc0 + t_out >= now1 /\ lc0 <= now2 /\ now2 <= now1 + t_out /\
                (forall (t:nat). List.Tot.mem t ts ==> t <= now2))
      (ensures  (let (s', _) = rotate_all_bad t_out Cur lc0 ts in s' <> Gone))
  = ()
