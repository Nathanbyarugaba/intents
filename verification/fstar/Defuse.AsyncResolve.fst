module Defuse.AsyncResolve

/// FSM-5 — Async FT withdrawal resolution conservation (decision table).
///
/// Rust source: contracts/defuse/src/contract/tokens/nep141/withdraw.rs
///   fn ft_resolve_withdraw(token, sender_id, amount, is_call) -> U128 {
///     let used = if is_call {
///        match promise_result_checked_json::<U128>(0) {
///          Ok(Ok(used))  => used.0.min(amount.0),   // token reported success amount
///          Ok(Err(_))    => 0,                       // malformed JSON -> full refund
///          Err(_)        => amount.0,                // ft_transfer_call FAILED ->
///        }                                           //   keep as used (NO refund):
///     } else {                                       //   NEP-141 gas-vuln mitigation
///        if promise_result_checked_void(0).is_ok() { amount.0 } else { 0 }
///     };
///     let refund = amount.0.saturating_sub(used);
///     if refund > 0 { deposit(sender_id, refund); }
///     U128(used)
///   }
///
/// Threat model note (AGENTS.md): a malicious/nonconforming token may return a
/// value LARGER than requested; `used.min(amount)` is the guard that keeps the
/// resolution conservative. We prove conservation holds even for adversarial
/// return values.
///
/// Properties (Model proof):
///   * DEF-ASY-001 : used <= amount  and  used + refund == amount  (no value
///                   created or destroyed by resolution).
///   * DEF-ASY-007 : used and refund partition `amount`; never simultaneously a
///                   full external use AND a full internal refund.

let min (a b:nat) : nat = if a <= b then a else b

/// Possible results of an `ft_transfer_call` promise, incl. adversarial ones.
type call_outcome =
  | CallOk        : returned:nat -> call_outcome   // token reported `returned`
  | CallDeserErr  : call_outcome                   // malformed JSON
  | CallPromiseErr: call_outcome                   // promise itself failed

type void_outcome =
  | VoidOk  : void_outcome
  | VoidErr : void_outcome

let used_call (amount:nat) (o:call_outcome) : nat =
  match o with
  | CallOk r       -> min r amount     // guard against over-reporting token
  | CallDeserErr   -> 0
  | CallPromiseErr -> amount

let used_void (amount:nat) (o:void_outcome) : nat =
  match o with
  | VoidOk  -> amount
  | VoidErr -> 0

/// amount.saturating_sub(used)
let refund (amount used:nat) : nat = if amount >= used then amount - used else 0

/// DEF-ASY-001 (ft_transfer_call path): conservation, even for adversarial
/// `returned` values (CallOk with returned > amount).
let call_conserves (amount:nat) (o:call_outcome)
  : Lemma (let u = used_call amount o in
           u <= amount /\ u + refund amount u == amount)
  = ()

/// DEF-ASY-001 (ft_transfer path): conservation.
let void_conserves (amount:nat) (o:void_outcome)
  : Lemma (let u = used_void amount o in
           u <= amount /\ u + refund amount u == amount)
  = ()

/// DEF-ASY-007: used and refund partition the amount; the extremes are mutually
/// exclusive (no double settlement).
let no_double_settle_call (amount:nat) (o:call_outcome)
  : Lemma (let u = used_call amount o in let r = refund amount u in
           u + r == amount /\ (r == amount ==> u == 0) /\ (u == amount ==> r == 0))
  = ()

/// The intentional "no refund on failed ft_transfer_call" branch (documented
/// NEP-141 gas-vulnerability mitigation): funds stay debited (used == amount).
let promise_err_keeps_funds (amount:nat)
  : Lemma (used_call amount CallPromiseErr == amount /\
           refund amount (used_call amount CallPromiseErr) == 0)
  = ()

/// Malformed callback JSON => full refund, nothing used.
let deser_err_full_refund (amount:nat)
  : Lemma (used_call amount CallDeserErr == 0 /\
           refund amount (used_call amount CallDeserErr) == amount)
  = ()

/// Witness: an over-reporting token cannot extract more than `amount`.
let witness_over_report (amount:nat)
  : Lemma (used_call amount (CallOk (amount + 1000)) == amount)
  = ()
