module Mut_WalletPromise

/// MUTATION (expected to FAIL verification) — non-vacuity check for FSM-13.
///
/// We add the `Dangerous` action to the allow-list (i.e. accept account-mutating
/// actions). Then an accepted promise may carry a dangerous action, so WP-1
/// ("accepted ⇒ only safe actions") must FAIL — this is the account-takeover
/// bug the allow-list is meant to prevent.

open FStar.List.Tot

type account = nat
type near_action = | FunctionCall | Transfer | DeterministicStateInit | Dangerous

/// BUG: treat Dangerous as safe.
let is_safe_bad (a:near_action) : bool = true

type near_promise = { receiver_id : account; actions : list near_action }
type perr = | SelfCallsNotAllowed | UnsupportedPromiseAction

let build_promise_bad (me:account) (p:near_promise) : either perr near_promise =
  if p.receiver_id = me then Inl SelfCallsNotAllowed
  else if not (for_all is_safe_bad p.actions) then Inl UnsupportedPromiseAction
  else Inr p

let is_safe (a:near_action) : bool = not (Dangerous? a)

let wp1_accepted_is_safe_bad (me:account) (p:near_promise)
  : Lemma (requires Inr? (build_promise_bad me p))
          (ensures  for_all is_safe p.actions)
  = ()
