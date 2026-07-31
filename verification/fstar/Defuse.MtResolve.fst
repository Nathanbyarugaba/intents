module Defuse.MtResolve

/// FSM-7 — Multi-token (NEP-245) resolve conservation & vector-shape safety (DEF-ASY-003).
///
/// Rust source: contracts/defuse/src/contract/tokens/nep245/resolver.rs::mt_resolve_transfer
///   let mut refunds = promise_result_checked_json_with_len::<Vec<U128>>(0, amounts.len())
///       .ok().and_then(Result::ok)
///       .filter(|refund| refund.len() == amounts.len())   // shape guard
///       .unwrap_or_else(|| amounts.clone());               // fallback: full refund
///   for ((token_id, prev_owner), (amount, refund)) in ... {
///       refund.0 = refund.0.min(amount.0);                 // cap at requested
///       let receiver = ... else { return amounts; };       // receiver gone -> nothing to claw back
///       let receiver_balance = receiver.token_balances.amount_for(&token_id);
///       refund.0 = refund.0.min(receiver_balance);         // cap at balance
///       if refund.0 == 0 { continue; }
///       receiver.token_balances.sub(token_id, refund.0).unwrap();  // move receiver -> sender
///       self.accounts...add(token_id, refund.0).unwrap();
///       amount.0 -= refund.0;                              // used = requested - refund
///   }
///   amounts   // == used amounts
///
/// Threat model (AGENTS.md): the callback may return a vector of the WRONG length or values LARGER than
/// requested. We prove the resolver stays conservative under all such adversarial inputs.
///
/// Properties (Model proof):
///   * MT-1 (per-item conservation): refund <= amount, refund <= receiver_balance, and
///     used + refund == amount  (no value creation, even for over-reporting callbacks).
///   * value move: receiver loses exactly `refund`, sender gains exactly `refund` (net zero).
///   * MT-2 (shape safety): a wrong-length callback -> full-refund fallback (reported == amount) is safe.
///   * duplicates / running balance: over a sequence of items on the SAME token, total refunded never
///     exceeds the initial receiver balance (no overdraw), and the receiver's balance stays non-negative.
///   * MT-3 (receiver missing): with nothing to claw back, used == amount and no underflow.

let min (a b:nat) : nat = if a <= b then a else b

/// refund actually applied for one item = min(min(reported, amount), balance).
let refund_of (amount reported bal : nat) : nat = min (min reported amount) bal
let used_of   (amount reported bal : nat) : nat = amount - refund_of amount reported bal

/// MT-1: per-item conservation, for ANY adversarial `reported` value.
let item_conserves (amount reported bal : nat)
  : Lemma (let r = refund_of amount reported bal in
           r <= amount /\ r <= bal /\ used_of amount reported bal + r == amount)
  = ()

/// Over-reporting is capped at the requested amount (then at balance).
let over_report_capped (amount reported bal : nat)
  : Lemma (requires reported >= amount)
          (ensures  refund_of amount reported bal == min amount bal)
  = ()

/// MT-2: wrong-length callback -> full-refund fallback (`reported = amount`) is safe and conservative.
let fallback_safe (amount bal : nat)
  : Lemma (refund_of amount amount bal == min amount bal /\
           used_of   amount amount bal == amount - min amount bal)
  = ()

/// MT-3: receiver has nothing (bal == 0) -> no refund, used == amount, no underflow.
let receiver_empty (amount reported : nat)
  : Lemma (refund_of amount reported 0 == 0 /\ used_of amount reported 0 == amount)
  = ()

/// ---------------------------------------------------------------------------
/// Running-balance model over a sequence of items on the SAME token (covers
/// duplicate token_ids, which re-read the balance each iteration).
/// ---------------------------------------------------------------------------

type item = { amount : nat; reported : nat }

/// Process items against a running receiver balance; returns (total_refunded, final_balance).
let rec process (items : list item) (bal:nat) : Tot (nat & nat) (decreases items) =
  match items with
  | [] -> (0, bal)
  | it :: rest ->
      let r = refund_of it.amount it.reported bal in    // r <= bal (min _ bal)
      let (tot, fin) = process rest (bal - r) in
      (r + tot, fin)

/// The receiver is never overdrawn: total refunded <= initial balance, and the final balance is exactly
/// the initial balance minus everything refunded (which the sender gains). Value is conserved.
let rec no_overdraw (items : list item) (bal:nat)
  : Lemma (ensures (let (tot, fin) = process items bal in tot <= bal /\ fin == bal - tot))
          (decreases items)
  = match items with
    | [] -> ()
    | it :: rest ->
        let r = refund_of it.amount it.reported bal in
        no_overdraw rest (bal - r)

/// ---------------------------------------------------------------------------
/// Witnesses (kani::cover! analogues).
/// ---------------------------------------------------------------------------

/// Adversarial: callback reports a refund larger than requested AND larger than balance.
let witness_over_report () : Lemma (refund_of 100 1000 40 == 40 /\ used_of 100 1000 40 == 60) = ()
/// Full-refund fallback with sufficient balance.
let witness_full_refund () : Lemma (refund_of 100 100 250 == 100 /\ used_of 100 100 250 == 0) = ()
/// Duplicates on one token deplete but never overdraw the balance.
let witness_duplicates () : Lemma (process [ {amount=60; reported=60}; {amount=60; reported=60} ] 100
                                    == (100, 0)) =
  no_overdraw [ {amount=60; reported=60}; {amount=60; reported=60} ] 100
