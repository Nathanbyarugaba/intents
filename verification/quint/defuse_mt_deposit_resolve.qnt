// DEF-ASY-003 / DEF-ASY-006 — deposit + `resolve_deposit_internal` refund path
// for NEP-245 / NEP-141 receiver flows.
//
// Models the production logic in
//   contracts/defuse/src/contract/tokens/mod.rs::resolve_deposit_internal
// where, after crediting a deposit and (optionally) running the receiver's
// `mt_on_transfer`/intents (which may SPEND the just-credited tokens), the
// refund is:
//     refund_i = min(requested_i, deposited_i, balance_left_i)
// The `balance_left` cap is the load-bearing protection against a receiver both
// spending a deposit AND getting it refunded (which would send out tokens the
// contract no longer backs internally = insolvency / double-spend).
//
// Abstraction: one token item; `recv` = receiver's internal balance,
// `other` = some other internal account (destination of any spend);
// `external` = real tokens defuse holds. Solvency = (recv + other) <= external.
module defuse_mt_deposit_resolve {
  type Phase = Idle | Deposited | Resolved

  pure val START: int = 4   // solvent start: internal == external
  pure val CAP: int = 3     // deposit size bound

  var recv: int
  var other: int
  var external: int
  var deposited: int        // amount of the in-flight deposit
  var phase: Phase
  // Mutation switch: when true, drop the `balance_left` cap (models the bug).
  var capByBalance: bool

  val internal = recv + other

  action init = {
    nondet cap = oneOf(Set(false, true))
    all {
      recv' = START,
      other' = 0,
      external' = START,
      deposited' = 0,
      phase' = Idle,
      capByBalance' = cap,
    }
  }

  // A deposit of `amt` arrives: real tokens received, receiver credited.
  action deposit = {
    nondet amt = oneOf(1.to(CAP))
    all {
      phase == Idle,
      external' = external + amt,
      recv' = recv + amt,
      deposited' = amt,
      phase' = Deposited,
      other' = other,
      capByBalance' = capByBalance,
    }
  }

  // Receiver spends part of its (now larger) balance via executed intents,
  // moving tokens to another internal account. Models `mt_on_transfer`/intents
  // running between deposit-credit and the resolve callback.
  action spend = {
    nondet s = oneOf(1.to(recv))
    all {
      phase == Deposited,
      recv >= s,
      recv' = recv - s,
      other' = other + s,
      external' = external,
      deposited' = deposited,
      phase' = phase,
      capByBalance' = capByBalance,
    }
  }

  // Resolve callback: refund unused deposit back to the token contract.
  action resolve = {
    // requested refund from the receiver's `on_transfer` return (0..deposited),
    // or a malicious over-report (> deposited).
    nondet req = oneOf(0.to(deposited + 2))
    val cappedByDeposit = if (req < deposited) req else deposited
    // production: also cap by current balance; mutant: skip the balance cap.
    val refund =
      if (capByBalance and cappedByDeposit > recv) recv else cappedByDeposit
    all {
      phase == Deposited,
      recv' = recv - refund,
      external' = external - refund,
      other' = other,
      deposited' = deposited,
      phase' = Resolved,
      capByBalance' = capByBalance,
    }
  }

  action step = any { deposit, spend, resolve }

  // ---------------- invariants ----------------
  val nonneg = recv >= 0 and other >= 0 and external >= 0
  // CUSTODY SOLVENCY: never credit/keep more internally than held externally.
  val solvency = internal <= external

  // Correct implementation (production): solvency always holds.
  val inv_correct = capByBalance implies (nonneg and solvency)
  // Combined (used to demonstrate the mutant breaks it): the mutant (no balance
  // cap) can violate solvency once a spend precedes the resolve.
  val inv = nonneg and solvency
}
