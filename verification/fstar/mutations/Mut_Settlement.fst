module Mut_Settlement

/// MUTATION (expected to FAIL verification) — non-vacuity check for FSM-1.
///
/// We break finalize_into so that leftover receivers are (incorrectly) reported
/// as a full match. This models a matcher that "accepts" a batch even though
/// deposits exceed withdrawals -> value creation. The conservation lemma
/// (Matched => sum ws == sum ds) must then FAIL to verify.
///
/// Expected result: F* reports an error. If it verified, our real FSM-1
/// conservation proof would be vacuous.

open FStar.List.Tot

type pos = x:int{ x > 0 }

let rec sum (l:list pos) : nat =
  match l with [] -> 0 | x :: xs -> x + sum xs

type mres = | Matched : mres | LeftSenders : rem:pos -> mres | LeftReceivers : rem:pos -> mres

/// BUG: the `[], _::_` case returns Matched instead of LeftReceivers.
let rec gmatch_bad (ws ds : list pos) : Tot mres (decreases (length ws + length ds)) =
  match ws, ds with
  | [], [] -> Matched
  | [], _ :: _ -> Matched                              // <-- injected bug
  | _ :: _, [] -> LeftSenders (sum ws)
  | w :: ws', d :: ds' ->
      if w = d then gmatch_bad ws' ds'
      else if w < d then gmatch_bad ws' ((d - w) :: ds')
      else gmatch_bad ((w - d) :: ws') ds'

/// FALSE under the mutation (e.g. gmatch_bad [] [5] = Matched but 0 <> 5).
let gmatch_bad_conserves (ws ds : list pos)
  : Lemma (Matched? (gmatch_bad ws ds) ==> sum ws == sum ds)
  = ()
