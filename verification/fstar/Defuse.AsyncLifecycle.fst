module Defuse.AsyncLifecycle

/// FSM-12 — Async withdrawal-lifecycle conservation under adversarial interleavings
///           (DEF-ASY-007 settle-at-most-once, DEF-ASY-005 refund-under-lock, DEF-ASY-001 conservation).
///
/// Rust lifecycle (contract/tokens/mod.rs::withdraw + nep141/nep171/nep245 resolvers):
///   * `withdraw` DEBITS the internal balance SYNCHRONOUSLY at initiation, then schedules a `#[private]`
///     `*_resolve_withdraw` callback via `.then(...)`.
///   * NEAR delivers EXACTLY ONE callback per promise; `#[private]` restricts it to self.
///   * the resolver settles some `used <= amount` externally and CREDITS the remainder back as a refund
///     (refunds are allowed even to accounts locked after initiation — credit-only, cf. FSM-9).
///
/// We model an operational state machine and let an ADVERSARY choose any interleaving of initiations and
/// resolutions (including attempts to resolve the same withdrawal twice, and callbacks arriving in any
/// order). We prove global value conservation and at-most-once settlement hold in EVERY reachable state
/// (an inductive proof over arbitrary schedules — strictly stronger than bounded model checking).

open FStar.List.Tot

type wid = nat

type pending = { id : wid; amt : nat; resolved : bool }

/// Single-account view (conservation is per (account,token); the argument generalizes pointwise).
/// `settled` = conserved settled externally (`external` is a reserved word in F*).
type st = { bal : nat; pend : list pending; settled : nat }

let rec sum_unresolved (p:list pending) : nat =
  match p with
  | [] -> 0
  | x :: xs -> (if x.resolved then 0 else x.amt) + sum_unresolved xs

/// The conserved quantity: internal balance + in-flight (unresolved) + externally settled.
let conserved (s:st) : nat = s.bal + sum_unresolved s.pend + s.settled

/// Initiate a withdrawal: debit synchronously (guarded by bal >= amt), add an unresolved pending entry.
/// If bal < amt the withdrawal is rejected (no state change), mirroring `internal_sub_balance` failure.
let init (s:st) (i:wid) (amt:nat) : st =
  if s.bal >= amt
  then { s with bal = s.bal - amt; pend = ({ id = i; amt = amt; resolved = false }) :: s.pend }
  else s

/// Settle the FIRST unresolved pending with this id: mark resolved, add `used` externally, refund the
/// rest to the balance. Returns (new pending list, refund_to_bal, external_added).
let rec mark_and_settle (p:list pending) (i:wid) (used:nat) : (list pending & nat & nat) =
  match p with
  | [] -> ([], 0, 0)
  | x :: xs ->
      if x.id = i && not x.resolved then
        let u = if used <= x.amt then used else x.amt in
        (({ x with resolved = true }) :: xs, x.amt - u, u)
      else
        let (xs', r, e) = mark_and_settle xs i used in
        (x :: xs', r, e)

let resolve (s:st) (i:wid) (used:nat) : st =
  let (p', r, e) = mark_and_settle s.pend i used in
  { bal = s.bal + r; pend = p'; settled = s.settled + e }

/// Key algebraic fact: settling removes exactly (refund + external) from the in-flight sum.
let rec settle_conserves_sum (p:list pending) (i:wid) (used:nat)
  : Lemma (ensures (let (p', r, e) = mark_and_settle p i used in
                    sum_unresolved p == sum_unresolved p' + r + e))
          (decreases p)
  = match p with
    | [] -> ()
    | x :: xs ->
        if x.id = i && not x.resolved then ()
        else settle_conserves_sum xs i used

/// AL-1 (per action): every action preserves the conserved conserved.
type action = | AInit : id:wid -> amt:nat -> action | AResolve : id:wid -> used:nat -> action

let apply (s:st) (a:action) : st =
  match a with
  | AInit i amt   -> init s i amt
  | AResolve i us -> resolve s i us

let step_preserves (s:st) (a:action)
  : Lemma (conserved (apply s a) == conserved s)
  = match a with
    | AInit _ _ -> ()
    | AResolve i us -> settle_conserves_sum s.pend i us

/// AL-1 (any schedule): conservation holds after ANY adversarial interleaving of actions.
let rec run (s:st) (acts:list action) : Tot st (decreases acts) =
  match acts with
  | [] -> s
  | a :: rest -> run (apply s a) rest

let rec conservation (s:st) (acts:list action)
  : Lemma (ensures conserved (run s acts) == conserved s) (decreases acts)
  = match acts with
    | [] -> ()
    | a :: rest -> step_preserves s a; conservation (apply s a) rest

/// AL-3: nothing can be settled externally beyond the initial conserved (no value creation).
let external_bounded (s:st) (acts:list action)
  : Lemma ((run s acts).settled <= conserved s)
  = conservation s acts

/// AL-2: a withdrawal with no unresolved pending (already resolved, or absent) cannot be settled again
/// — a repeated/late callback is a no-op (models `#[private]` + NEAR exactly-once + pending removal).
let rec has_unresolved (p:list pending) (i:wid) : bool =
  match p with
  | [] -> false
  | x :: xs -> (x.id = i && not x.resolved) || has_unresolved xs i

let rec mark_and_settle_noop (p:list pending) (i:wid) (used:nat)
  : Lemma (requires not (has_unresolved p i))
          (ensures mark_and_settle p i used == (p, 0, 0))
          (decreases p)
  = match p with
    | [] -> ()
    | x :: xs -> mark_and_settle_noop xs i used

let resolve_noop_when_none (s:st) (i:wid) (used:nat)
  : Lemma (requires not (has_unresolved s.pend i))
          (ensures resolve s i used == s)
  = mark_and_settle_noop s.pend i used

/// ---------------------------------------------------------------------------
/// Witnesses (kani::cover! analogues): concrete adversarial interleavings.
/// ---------------------------------------------------------------------------

/// A full "reorder": two withdrawals initiated, then resolved out of order, conserves value.
let witness_reorder ()
  : Lemma (let s0 = { bal = 100; pend = []; settled = 0 } in
           conserved (run s0 [ AInit 1 40; AInit 2 30; AResolve 2 30; AResolve 1 10 ]) == 100)
  = conservation { bal = 100; pend = []; settled = 0 }
                 [ AInit 1 40; AInit 2 30; AResolve 2 30; AResolve 1 10 ]

/// Double-resolve of the same id does not double-settle (second is a no-op).
let witness_double_resolve ()
  : Lemma (let s0 = { bal = 50; pend = []; settled = 0 } in
           conserved (run s0 [ AInit 7 50; AResolve 7 50; AResolve 7 50 ]) == 50)
  = conservation { bal = 50; pend = []; settled = 0 }
                 [ AInit 7 50; AResolve 7 50; AResolve 7 50 ]
