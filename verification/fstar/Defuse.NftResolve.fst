module Defuse.NftResolve

/// FSM-8 — NFT (NEP-171) withdrawal resolve: ownership exclusivity (DEF-ASY-002).
///
/// Rust source: contracts/defuse/src/contract/tokens/nep171/withdraw.rs::nft_resolve_withdraw
///   let used = if is_call {
///       match promise_result_checked_json::<bool>(0) {
///         Ok(Ok(used))  => used,     // nft_transfer_call returned success bool
///         Ok(Err(_))    => false,    // malformed -> treat as not transferred (refund)
///         Err(_)        => true,     // promise failed -> keep (NO refund): NEP-141 mitigation
///       }
///   } else {
///       promise_result_checked_void(0).is_ok()   // nft_transfer: empty result == success
///   };
///   if !used { self.deposit(sender_id, [(nft, 1)], REFUND_MEMO); }   // refund the single unit
///   used
///
/// The withdrawn NFT is a single, indivisible unit. It must end up EITHER transferred to the receiver
/// (used) OR refunded to the sender (!used) -- never both (duplication) and never neither (loss).
///
/// Properties (Model proof):
///   * exclusivity: refunded == not used (exactly one of used/refunded holds).
///   * unit conservation: sender_units + receiver_units == 1 in every branch.
///   * promise-error branch keeps the unit as used (documented NEP-141 mitigation, no refund).

type call_outcome = | COk : b:bool -> call_outcome | CDeserErr | CPromiseErr
type void_outcome = | VOk | VErr

let used_call (o:call_outcome) : bool =
  match o with
  | COk b       -> b
  | CDeserErr   -> false
  | CPromiseErr -> true

let used_void (o:void_outcome) : bool =
  match o with VOk -> true | VErr -> false

let refunded (used:bool) : bool = not used

/// Where the single unit ends up.
let receiver_units (used:bool) : nat = if used then 1 else 0
let sender_units   (used:bool) : nat = if refunded used then 1 else 0

/// Exclusivity: exactly one of {used, refunded}.
let exclusive_call (o:call_outcome)
  : Lemma (let u = used_call o in refunded u == not u /\ u <> refunded u)
  = ()

let exclusive_void (o:void_outcome)
  : Lemma (let u = used_void o in refunded u == not u /\ u <> refunded u)
  = ()

/// Unit conservation: the NFT is neither duplicated nor lost, in every branch.
let unit_conserved (used:bool)
  : Lemma (receiver_units used + sender_units used == 1)
  = ()

/// The failed-`nft_transfer_call` branch keeps the unit as used (no refund).
let promise_err_keeps_unit ()
  : Lemma (used_call CPromiseErr == true /\ sender_units (used_call CPromiseErr) == 0)
  = ()

/// Malformed callback JSON -> not used -> refunded to sender.
let deser_err_refunds ()
  : Lemma (used_call CDeserErr == false /\ sender_units (used_call CDeserErr) == 1)
  = ()

/// Witnesses.
let witness_used ()   : Lemma (receiver_units true  + sender_units true  == 1) = ()
let witness_refund () : Lemma (receiver_units false + sender_units false == 1) = ()
