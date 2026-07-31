module Defuse.SimRefine

/// FSM-18 — simulate_intents vs execute_intents decision refinement (SIM-001/002/003).
///
/// Rust sources:
///   contracts/defuse/src/contract/intents/mod.rs — execute_intents uses `Engine::new(self, ..)`
///     (State = `Contract`); simulate_intents uses `Engine::new(self.cached(), ..)`
///     (State = `CachedState<&Contract>`). BOTH run the same `execute_signed_intents`.
///   contracts/defuse/core/src/engine/state/cached.rs   (CachedState methods)
///   contracts/defuse/src/contract/intents/state.rs      (Contract methods)
///
/// So SIM correctness reduces to: do the two `State` impls make the SAME accept/reject decision for each
/// mutating method, given the same starting Contract state? Notes:
///   * `CachedState` seeds a fresh cache entry from the view via `get_or_create`
///     (bal_c = present ? bal : 0 ; locked_c = present ? locked : false), whereas `Contract` rejects
///     absent accounts with `AccountNotFound` on debit paths.
///   * Promise side effects (withdrawals scheduling promises, notify_on_transfer) are EXCLUDED by SIM.
///   * Non-`InvariantViolated` errors panic in BOTH paths, so different error variants collapse to the
///     same observable "reject".
///
/// Result: the decisions agree everywhere EXCEPT `internal_add_balance` at `amount == 0` (SIM-001),
/// which is unreachable from a well-formed intent.

/// A per-account, per-token view of the starting (real) Contract state.
type mstate = { present : bool; locked : bool; bal : nat }

type decision = | Accept | Reject

/// What `CachedState.get_or_create` sees after seeding from the view.
let bal_c    (s:mstate) : nat  = if s.present then s.bal else 0
let locked_c (s:mstate) : bool = if s.present then s.locked else false

/// -------- internal_sub_balance (debit / withdraw / burn path) --------
let sub_real (s:mstate) (amt:nat) : decision =
  if not s.present then Reject           // AccountNotFound
  else if s.locked then Reject           // AccountLocked
  else if amt = 0 then Reject            // InvalidIntent
  else if s.bal < amt then Reject        // BalanceOverflow (underflow)
  else Accept

let sub_cached (s:mstate) (amt:nat) : decision =
  // get_or_create then get_mut (lock), then amount==0, then seeded-underflow
  if locked_c s then Reject
  else if amt = 0 then Reject
  else if bal_c s < amt then Reject
  else Accept

/// SR-1: the debit decision is identical in simulation and real execution.
let sr1_sub_agree (s:mstate) (amt:nat)
  : Lemma (sub_real s amt == sub_cached s amt)
  = ()

/// -------- auth-mutating / nonce methods (lock-gated identically) --------
/// add/remove key, commit_nonce, set_auth_by_predecessor: both reject iff locked (given the op is
/// otherwise applicable, captured by `applicable`). Decisions agree.
let auth_real   (s:mstate) (applicable:bool) : decision =
  if s.locked then Reject else if applicable then Accept else Reject
let auth_cached (s:mstate) (applicable:bool) : decision =
  if locked_c s then Reject else if applicable then Accept else Reject

/// SR-2: auth/nonce decisions agree whenever the account is present (the only case an authenticated
/// signer's own account reaches these — a signed intent's signer account exists once it has a key/nonce).
let sr2_auth_agree (s:mstate) (applicable:bool)
  : Lemma (requires s.present) (ensures auth_real s applicable == auth_cached s applicable)
  = ()

/// -------- internal_add_balance (credit path) --------
let add_real (s:mstate) (amt:nat) : decision =
  if amt = 0 then Reject else Accept       // InvalidIntent on 0; else credit (no lock check)
let add_cached (s:mstate) (amt:nat) : decision =
  Accept                                   // CachedState does NOT reject amount==0

/// SR-3a: for amount > 0 the credit decision agrees.
let sr3_add_agree_pos (s:mstate) (amt:nat)
  : Lemma (requires amt > 0) (ensures add_real s amt == add_cached s amt)
  = ()

/// SR-3b: the ONLY divergence is at amount == 0 (real Reject, cached Accept) — SIM-001.
let sr3_add_divergence_iff_zero (s:mstate) (amt:nat)
  : Lemma (add_real s amt <> add_cached s amt <==> amt = 0)
  = ()

/// -------- Composite: the accept/reject decision of a whole method set agrees, except add(0). --------
/// For every method EXCEPT a zero-amount credit, simulation faithfully predicts real acceptance.
let refinement_holds_except_add_zero (s:mstate) (amt:nat)
  : Lemma (requires amt > 0)   // excludes the single unreachable divergence
          (ensures sub_real s amt == sub_cached s amt /\
                   add_real s amt == add_cached s amt)
  = ()

/// Witnesses.
let witness_sub_absent_rejected_both ()
  : Lemma (sub_real ({ present = false; locked = false; bal = 0 }) 5 == Reject /\
           sub_cached ({ present = false; locked = false; bal = 0 }) 5 == Reject)
  = ()
let witness_sub_locked_rejected_both ()
  : Lemma (sub_real ({ present = true; locked = true; bal = 100 }) 5 == Reject /\
           sub_cached ({ present = true; locked = true; bal = 100 }) 5 == Reject)
  = ()
let witness_add_zero_divergence ()
  : Lemma (add_real ({ present = true; locked = false; bal = 0 }) 0 == Reject /\
           add_cached ({ present = true; locked = false; bal = 0 }) 0 == Accept)
  = ()
