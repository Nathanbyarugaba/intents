// DEF-ASY-001/004/005/007 — asynchronous FT withdrawal + resolve settlement.
//
// Models the production flow in
//   contracts/defuse/src/contract/tokens/nep141/withdraw.rs
//     internal_ft_withdraw -> withdraw() (debit internal) -> ft_transfer[_call]
//     -> ft_resolve_withdraw (refund unused)
// against ALL promise outcomes, including a malicious/non-conforming token, and
// with arbitrarily interleaved concurrent withdrawals.
//
// Abstraction:
//   internal = aggregate internal (custodied) balance of ONE token for our users
//   external = real tokens defuse actually holds at the token contract
// Invariant of custody solvency: for a COMPLIANT token, internal <= external at
// all times (never credit more than we hold), with equality once every
// withdrawal has resolved. This rules out double-credit / refund-on-success and
// characterizes exactly where insolvency can occur (malicious token only).
module defuse_ft_withdraw {
  type Phase = Init | Transferred | Resolved

  // What `ft_resolve_withdraw` observes as the promise result.
  type Report =
    | RVoidOk        // ft_transfer (no msg) success
    | RVoidFail      // ft_transfer (no msg) failure
    | RUsed(int)     // ft_transfer_call returned this used amount (Ok(Ok))
    | RGarbage       // ft_transfer_call returned non-U128 (Ok(Err) -> used = 0)
    | RFail          // promise failed (Err -> used = amount, no refund)

  type Wd = {
    amount: int,
    isCall: bool,
    phase: Phase,
    usedActual: int,   // tokens actually kept externally by receiver
    report: Report,
  }

  pure val START: int = 5   // initial (solvent) balance: internal == external
  pure val CAP: int = 3     // max amount per withdrawal
  pure val NSLOTS: int = 2  // max concurrent in-flight withdrawals

  var internal: int
  var external: int
  var honest: bool          // whether the token contract is compliant
  var wds: List[Wd]

  // ----- production `ft_resolve_withdraw` `used` computation -----
  pure def usedResolve(w: Wd): int =
    match w.report {
      | RVoidOk   => w.amount
      | RVoidFail => 0
      | RUsed(u)  => if (u < w.amount) u else w.amount   // used.min(amount)
      | RGarbage  => 0                                    // Ok(Err) -> 0
      | RFail     => w.amount                             // Err -> no refund
    }

  action init = all {
    nondet h = oneOf(Set(false, true))
    honest' = h,
    internal' = START,
    external' = START,
    wds' = [],
  }

  action initiate = {
    nondet amt = oneOf(1.to(CAP))
    nondet call = oneOf(Set(false, true))
    all {
      length(wds) < NSLOTS,
      internal >= amt,
      internal' = internal - amt,
      external' = external,
      honest' = honest,
      wds' = wds.append({ amount: amt, isCall: call, phase: Init,
                          usedActual: 0, report: RVoidOk }),
    }
  }

  // Perform the external transfer for an Init withdrawal, choosing an outcome.
  action transfer = {
    val idxs = wds.indices().filter(i => wds[i].phase == Init)
    all {
      idxs != Set(),
      nondet i = oneOf(idxs)
      val w = wds[i]
      // usedActual: how many tokens really left defuse (0..amount)
      nondet ua = oneOf(0.to(w.amount))
      // pick a report consistent with honesty & isCall
      val reports =
        if (not(w.isCall))
          // ft_transfer: honest reports success iff it moved everything, else fail.
          // A malicious token may lie either way.
          Set(RVoidOk, RVoidFail)
        else
          // ft_transfer_call:
          //  honest -> RUsed(ua) (faithful) or RFail (NEP-141 gas vuln, tokens may
          //            have moved but resolve can't read the result)
          //  malicious -> anything, incl. RGarbage / mismatched RUsed
          Set(RUsed(ua), RFail, RGarbage)
      nondet rep = oneOf(reports)
      all {
        // a transfer can never move more than defuse actually holds
        external >= ua,
        // Compliant-token consistency constraints:
        //  - non-call: report reflects reality (RVoidOk <=> moved full amount)
        //  - call:     RUsed faithfully equals ua ; RFail allowed; RGarbage forbidden
        honest implies (
          (not(w.isCall) and ((rep == RVoidOk and ua == w.amount)
                              or (rep == RVoidFail and ua == 0)))
          or (w.isCall and (rep == RUsed(ua) or rep == RFail))
        ),
        internal' = internal,
        external' = external - ua,
        honest' = honest,
        wds' = wds.replaceAt(i, { ...w, phase: Transferred, usedActual: ua, report: rep }),
      }
    }
  }

  // Resolve callback: refund `amount - used` to internal balance. Runs once.
  action resolve = {
    val idxs = wds.indices().filter(i => wds[i].phase == Transferred)
    all {
      idxs != Set(),
      nondet i = oneOf(idxs)
      val w = wds[i]
      val refund = w.amount - usedResolve(w)
      all {
        internal' = internal + refund,
        external' = external,
        honest' = honest,
        wds' = wds.replaceAt(i, { ...w, phase: Resolved }),
      }
    }
  }

  action step = any { initiate, transfer, resolve }

  // ---------------- invariants ----------------

  // Never underflow.
  val nonneg = internal >= 0 and external >= 0

  // CUSTODY SOLVENCY: a compliant token can never make defuse credit more
  // internally than it holds externally (no double-credit / refund-on-success).
  val solvency_honest = honest implies (internal <= external)

  // Unguarded solvency: HOLDS for honest tokens (see `inv`), but is expected to
  // be VIOLATED once a malicious token is allowed — the counterexample witnesses
  // that insolvency requires a non-compliant token (isolated to its own pool).
  val solvency_always = internal <= external

  // No withdrawal is resolved twice (structural: single Transferred->Resolved).
  val allInflightBounded = wds.foldl(true, (acc, w) => acc and w.usedActual <= w.amount)

  // NOTE: exact equality at rest does NOT hold: when an `ft_transfer` promise
  // fails (RFail) the code intentionally does not refund (NEP-141 gas-vuln
  // rationale). If the transfer really failed, that leaves a SURPLUS
  // (external > internal) — a documented user-loss case that is *safe*
  // (over-collateralised, never insolvent). Hence the custody-safety property
  // is solvency (internal <= external), not equality.
  val no_over_credit_at_rest =
    (honest and wds.indices().filter(i => wds[i].phase != Resolved) == Set())
      implies (internal <= external)

  // Combined CUSTODY-SAFETY invariant used for model checking.
  // (No insolvency / no double-credit under any interleaving with a
  //  compliant token.)
  val inv = nonneg and solvency_honest and allInflightBounded and no_over_credit_at_rest

  // ------- adversarial witness: insolvency requires a MALICIOUS token -------
  // Shows the boundary is real & the invariant is non-vacuous: a non-compliant
  // token that keeps tokens (usedActual>0) yet returns garbage (Ok(Err)) drives
  // internal > external (isolated to that token's pool).
  run malicious_insolvency_witness = {
    init.then(all {
      honest' = false, internal' = 5, external' = 5,
      wds' = [{ amount: 3, isCall: true, phase: Init, usedActual: 0, report: RVoidOk }],
    })
    .then(all {
      // token keeps all 3 externally but returns malformed result
      internal' = internal, external' = external - 3, honest' = honest,
      wds' = wds.replaceAt(0, { ...wds[0], phase: Transferred, usedActual: 3, report: RGarbage }),
    })
    .then(all {
      // resolve refunds full amount (used=0) -> internal restored -> insolvent
      internal' = internal + (wds[0].amount - usedResolve(wds[0])),
      external' = external, honest' = honest,
      wds' = wds.replaceAt(0, { ...(wds[0]), phase: Resolved }),
    })
    .then(all {
      assert(internal > external),   // 5 > 2 : insolvency, only because !honest
      internal' = internal, external' = external, honest' = honest, wds' = wds,
    })
  }
}
