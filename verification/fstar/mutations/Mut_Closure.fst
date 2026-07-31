module Mut_Closure

/// MUTATION (expected to FAIL verification) — non-vacuity check for FSM-3.
///
/// We break closure_supply_delta by dividing by the raw fee `f` instead of its
/// inverse `inv f = MAX - f`. This desynchronizes the euclid step (closure) from
/// the ceil step (supply_delta), so the round-trip no longer nets to zero for
/// token_out (delta > 0) deltas. The round-trip lemma must FAIL to verify.

open Defuse.Arith

let maxp : pos = 1000000
type pips = f:int{ 0 <= f /\ f <= maxp }
let inv (f:pips) : n:int{ 0 <= n /\ n <= maxp } = maxp - f

let supply_delta (f:pips) (d:i128) : option i128 =
  if d < 0 then checked_mul_div_ceil_i d (inv f) maxp else Some d

let closure_supply_delta_bad (f:pips) (d:i128) : option i128 =
  match checked_neg_i d with
  | None -> None
  // BUG: divide by `f` instead of `inv f`
  | Some c -> if c < 0 then checked_mul_div_euclid_i c maxp f else Some c

let closure_delta_bad (f:pips) (d:i128) : option i128 =
  match supply_delta f d with
  | None -> None
  | Some sd -> closure_supply_delta_bad f sd

#push-options "--z3rlimit 200 --fuel 2 --ifuel 2"
let roundtrip_bad (f:pips) (d:i128)
  : Lemma
      (requires Some? (closure_delta_bad f d) /\
                Some? (supply_delta f (Some?.v (closure_delta_bad f d))))
      (ensures  Some?.v (supply_delta f d)
                  + Some?.v (supply_delta f (Some?.v (closure_delta_bad f d))) == 0)
  = ()
#pop-options
