module Defuse.Closure

/// FSM-3 — TokenDiff closure round-trip (solver-facing arithmetic).
///
/// Rust source: contracts/defuse/core/src/intents/token_diff.rs
///   fn supply_delta(delta, fee): if delta < 0
///        { delta.checked_mul_div_ceil(token_fee.invert().as_pips(), MAX) }
///        else { Some(delta) }
///   fn closure_supply_delta(delta, fee):
///        let closure = delta.checked_neg()?;                    // None on i128::MIN
///        if closure < 0 { closure.checked_mul_div_euclid(MAX, token_fee.invert().as_pips()) }
///        else { Some(closure) }
///   fn closure_delta(delta, fee) = closure_supply_delta(supply_delta(delta, fee)?, fee)
///
/// Advertised invariant (asserted by the Rust unit test only on ~40 sampled
/// points):  supply_delta(delta) + supply_delta(closure_delta(delta)) == 0.
///
/// SCOPE: `closure*`/`supply_delta` are used ONLY inside token_diff.rs and the
/// test suite; they are NOT on the on-chain settlement path (which uses
/// internal_apply_deltas + fee_ceil, protected by FSM-1's net-zero requirement).
/// A round-trip defect would be a solver-correctness issue, not a custody bypass.
///
/// EXCLUSION (by request, known issue): token_fee's amount<=1 fee-zeroing (the
/// NEP-245 MT-split bypass). We model the fungible (NEP-141) case where the
/// effective fee equals the protocol fee `f` regardless of amount; `f` is opaque.
///
/// Result: the round-trip is proved for ALL i128 deltas and ALL valid fees,
/// whenever the option computations are defined (Some) -- a strictly stronger
/// statement than the sampled Rust test. No counterexample exists in scope.

open Defuse.Arith

let maxp : pos = 1000000
type pips = f:int{ 0 <= f /\ f <= maxp }
let inv (f:pips) : n:int{ 0 <= n /\ n <= maxp } = maxp - f

let supply_delta (f:pips) (d:i128) : option i128 =
  if d < 0 then checked_mul_div_ceil_i d (inv f) maxp
  else Some d

let closure_supply_delta (f:pips) (d:i128) : option i128 =
  match checked_neg_i d with
  | None -> None
  | Some c -> if c < 0 then checked_mul_div_euclid_i c maxp (inv f) else Some c

let closure_delta (f:pips) (d:i128) : option i128 =
  match supply_delta f d with
  | None -> None
  | Some sd -> closure_supply_delta f sd

/// supply_delta is always defined: token_out (d>=0) -> Some d; token_in (d<0) ->
/// ceil(d*inv/MAX) whose magnitude is <= |d|, so it always fits i128.
let supply_delta_total (f:pips) (d:i128)
  : Lemma (Some? (supply_delta f d) /\ (Some?.v (supply_delta f d)) <= (if d < 0 then 0 else d))
  = if d < 0 then begin
      // q = cdiv (d*inv) MAX ; |q| <= |d| since inv <= MAX
      ceil_bounds ((- d) * (inv f)) maxp;
      FStar.Math.Lemmas.lemma_mult_le_left (- d) (inv f) maxp
    end else ()

/// ---------------------------------------------------------------------------
/// The round-trip theorem.
/// ---------------------------------------------------------------------------

#push-options "--z3rlimit 200 --fuel 2 --ifuel 2"
let roundtrip (f:pips) (d:i128)
  : Lemma
      (requires Some? (closure_delta f d) /\
                Some? (supply_delta f (Some?.v (closure_delta f d))))
      (ensures  Some? (supply_delta f d) /\
                Some?.v (supply_delta f d)
                  + Some?.v (supply_delta f (Some?.v (closure_delta f d))) == 0)
  = supply_delta_total f d;
    if d = 0 then ()
    else if d < 0 then
      // sd <= 0, closure = -sd >= 0 -> closure_delta = -sd -> supply_delta(-sd) = -sd
      ()
    else begin
      // d > 0: sd = d ; closure_delta = -(cdiv (d*MAX) inv) ; supply_delta of it = -d
      let iv = inv f in
      // premise forces iv > 0 (else closure_supply_delta d = None)
      assert (iv > 0);
      let q = cdiv (d * maxp) iv in
      // ceil_floor_roundtrip: fdiv (q*iv) MAX == d, hence the final ceil == -d
      ceil_floor_roundtrip d iv maxp
    end
#pop-options

/// ---------------------------------------------------------------------------
/// Definedness characterization at the extremes.
/// ---------------------------------------------------------------------------

/// A 100% fee (inv == 0) makes closure undefined for any token_out delta > 0
/// (division by zero in checked_mul_div_euclid) -> Rust `?` returns None (no panic).
let closure_undefined_full_fee (d:i128)
  : Lemma (requires d > 0) (ensures closure_delta maxp d == None)
  = ()

/// closure of i128::MIN token_in is undefined (checked_neg fails) -> None, no panic.
let closure_undefined_i128_min (f:pips)
  : Lemma (requires inv f == maxp)   // fee == 0 so supply_delta i128_min == i128_min
          (ensures closure_delta f i128_min == None)
  = ()

/// ---------------------------------------------------------------------------
/// Witnesses (kani::cover! analogues).
/// ---------------------------------------------------------------------------

/// token_out delta round-trips through a fee-bearing closure (fee = 1 bip).
let witness_out () : Lemma (Some? (closure_delta 100 1000000)) = ()
