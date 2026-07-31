module Defuse.LockAuth

/// FSM-9 — Account lock / authorization FREEZE invariant (AUTH-002, DEF-ASY-005).
///
/// Adversarial question: can a LOCKED account be debited, have its authorization changed, or execute a
/// signed intent (without the access-controlled force role)?
///
/// Rust sources (both `State` impls agree):
///   contracts/defuse/core/src/engine/state/cached.rs   (CachedState<W>, simulation + engine)
///   contracts/defuse/src/contract/intents/state.rs      (Contract, real execution)
///   contracts/defuse/src/contract/tokens/mod.rs          (withdraw(force) -> get_mut_maybe_forced)
///   contracts/defuse/core/src/engine/mod.rs              (execute_signed_intent commits nonce first)
///
/// Gating pattern observed:
///   * value-DEBIT (`internal_sub_balance`, withdraw/burn), AUTH changes (`add/remove_public_key`,
///     `set_auth_by_predecessor_id`) and `commit_nonce` all go through `get_mut()` -> reject when locked
///     (withdraw uses `get_mut_maybe_forced(force)` -> bypasses lock ONLY when `force==true`).
///   * `internal_add_balance` (credit) and `cleanup_nonce_by_prefix` (DAO/GC-gated, expired-only) use
///     `as_inner_unchecked_mut()` -> no lock check (documented, safe: credit-only / GC-gated).
///
/// Because `execute_signed_intent` calls `commit_nonce` BEFORE executing any intent, and `commit_nonce`
/// is lock-checked, a locked (non-forced) account is FROZEN for all signed-intent execution.
///
/// Properties (Model proof):
///   * LA-1 freeze: locked && !forced  =>  no Debit, no AuthChange, no NonceCommit.
///   * LA-1' balances of a locked non-forced account are NON-DECREASING over any op sequence.
///   * LA-2 frozen-from-intents: a signed intent (which must commit a nonce first) is aborted for a
///     locked account.
///   * LA-3 force is the ONLY lock bypass: a locked account is Debited only when forced==true.

type op =
  | SubBalance  : amt:nat -> op    // internal_sub_balance / burn / withdraw body
  | AddBalance  : amt:nat -> op    // internal_add_balance / deposit / mint (credit)
  | AddKey      : op
  | RemoveKey   : op
  | CommitNonce : op
  | SetAuthPred : op
  | Cleanup     : op               // cleanup_nonce_by_prefix (GC-gated)

type outcome =
  | Rejected       : outcome
  | Credited       : amt:nat -> outcome
  | Debited        : amt:nat -> outcome
  | AuthChanged    : outcome
  | NonceCommitted : outcome
  | Cleaned        : outcome

/// Faithful transliteration of the get_mut()/get_mut_maybe_forced(force)/as_inner_unchecked_mut() gating.
/// (`forced` is only meaningful for the withdraw/sub path; auth ops & commit are never forced via intents.)
let step (locked forced : bool) (o:op) : outcome =
  match o with
  | AddBalance a -> Credited a                                   // no lock check (credit)
  | Cleanup      -> Cleaned                                      // no lock check (GC-gated)
  | SubBalance a -> if locked && not forced then Rejected else Debited a
  | AddKey       -> if locked then Rejected else AuthChanged
  | RemoveKey    -> if locked then Rejected else AuthChanged
  | CommitNonce  -> if locked then Rejected else NonceCommitted
  | SetAuthPred  -> if locked then Rejected else AuthChanged

/// LA-1: a locked, non-forced account is never debited and its authorization never changes.
let la1_freeze (o:op)
  : Lemma (let r = step true false o in
           ~(Debited? r) /\ ~(AuthChanged? r) /\ ~(NonceCommitted? r))
  = ()

/// LA-3: the ONLY way a locked account is debited is via the access-controlled force path.
let la3_force_only (o:op) (forced:bool)
  : Lemma (requires Debited? (step true forced o))
          (ensures  forced == true)
  = ()

/// LA-2: a signed intent commits a nonce first; for a locked account that commit is rejected, so the
/// whole signed-intent execution is aborted (no state change for that signer).
let execute_signed_aborted (locked:bool) : bool = Rejected? (step locked false CommitNonce)

let la2_frozen_from_intents ()
  : Lemma (execute_signed_aborted true == true)
  = ()

/// ---------------------------------------------------------------------------
/// LA-1': balances of a locked, non-forced account are non-decreasing over any
/// sequence of operations an adversary may attempt.
/// ---------------------------------------------------------------------------

let apply (locked forced : bool) (bal:nat) (o:op) : nat =
  match step locked forced o with
  | Credited a -> bal + a
  | Debited  a -> if bal >= a then bal - a else bal
  | _          -> bal

let rec run (locked forced : bool) (bal:nat) (ops:list op) : Tot nat (decreases ops) =
  match ops with
  | [] -> bal
  | o :: rest -> run locked forced (apply locked forced bal o) rest

let rec locked_balance_nondecreasing (ops:list op) (bal:nat)
  : Lemma (ensures run true false bal ops >= bal) (decreases ops)
  = match ops with
    | [] -> ()
    | o :: rest ->
        la1_freeze o;                       // step true false o is never Debited
        locked_balance_nondecreasing rest (apply true false bal o)

/// ---------------------------------------------------------------------------
/// Witnesses (kani::cover! analogues) — the boundary classes are reachable.
/// ---------------------------------------------------------------------------

let witness_locked_sub_rejected ()  : Lemma (step true  false (SubBalance 5) == Rejected)   = ()
let witness_forced_sub_debited ()   : Lemma (step true  true  (SubBalance 5) == Debited 5)  = ()
let witness_locked_credit_ok ()     : Lemma (step true  false (AddBalance 7) == Credited 7) = ()
let witness_unlocked_sub_ok ()      : Lemma (step false false (SubBalance 5) == Debited 5)  = ()
let witness_locked_addkey_reject () : Lemma (step true  false AddKey == Rejected)           = ()
let witness_locked_commit_reject () : Lemma (step true  false CommitNonce == Rejected)      = ()
