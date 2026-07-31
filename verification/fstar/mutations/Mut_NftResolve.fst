module Mut_NftResolve

/// MUTATION (expected to FAIL verification) — non-vacuity check for FSM-8.
///
/// We make the resolver refund the NFT unit REGARDLESS of whether it was used
/// (as if the `if !used` guard were dropped). Then when the transfer succeeded
/// (used == true) the unit exists BOTH at the receiver and back at the sender:
/// duplication. Unit conservation (receiver + sender == 1) must FAIL.

let refunded_bad (_used:bool) : bool = true   // BUG: always refund

let receiver_units (used:bool) : nat = if used then 1 else 0
let sender_units   (used:bool) : nat = if refunded_bad used then 1 else 0

let unit_conserved_bad (used:bool)
  : Lemma (receiver_units used + sender_units used == 1)
  = ()
