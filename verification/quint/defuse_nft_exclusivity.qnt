// DEF-ASY-002 — NFT ownership exclusivity.
//
// Models the NEP-171 lifecycle for a single NFT across
//   deposit()        (contracts/defuse/src/contract/tokens/mod.rs) — guarded so
//                     total_supply can never exceed 1 (NftAlreadyDeposited),
//   nft_withdraw()    — debits the single unit, schedules a promise,
//   nft_resolve_withdraw() — re-credits iff the external transfer failed.
//
// Safety: the internal supply of the NFT is always in {0,1} — it can never be
// duplicated (no double-credit), and it is never held internally AND gone
// externally at the same time (exclusivity). The `deposit` guard (supply == 0)
// and the single-shot resolve (refund only when `used == 0`) are what enforce it.
module defuse_nft_exclusivity {
  type Phase = Idle | Withdrawing

  var supply: int        // internal units of the NFT held by users (must be 0/1)
  var externalGone: bool // NFT has been transferred out to a receiver
  var phase: Phase

  action init = all {
    supply' = 0,
    externalGone' = false,
    phase' = Idle,
  }

  // A fresh deposit: only allowed when not already present (production guard:
  // total_supply > 1 after add => NftAlreadyDeposited). Requires the unit to be
  // externally backed (not already gone).
  action deposit = all {
    phase == Idle,
    supply == 0,
    not(externalGone),
    supply' = 1,
    externalGone' = false,
    phase' = Idle,
  }

  // Begin a withdrawal: debit the internal unit, promise in flight.
  action withdraw = all {
    phase == Idle,
    supply == 1,
    supply' = 0,
    externalGone' = externalGone,
    phase' = Withdrawing,
  }

  // Resolve callback (runs once): the external transfer either succeeded
  // (used = true => NFT gone, no refund) or failed (used = false => re-credit).
  action resolve = {
    nondet used = oneOf(Set(false, true))
    all {
      phase == Withdrawing,
      supply' = if (used) supply else supply + 1,
      externalGone' = used,
      phase' = Idle,
    }
  }

  action step = any { deposit, withdraw, resolve }

  // ---------------- invariants ----------------
  // EXCLUSIVITY: the NFT is never duplicated.
  val no_duplication = supply >= 0 and supply <= 1
  // Never both held internally and already gone externally.
  val exclusive = not(supply == 1 and externalGone)
  val inv = no_duplication and exclusive
}
