module Defuse.Arith

/// Faithful models of the checked fixed-width arithmetic primitives that the
/// defuse contract relies on for custody-critical rounding.
///
/// Rust sources modeled here:
///   * crates/num-utils/src/mul_div.rs
///       - CheckedMulDiv for u128 (widened to BUint<4>, i.e. 256-bit) and
///         i128 (widened to BInt<4>).
///       - checked_mul_div       : (self*mul) / div            (truncating/floor)
///       - checked_mul_div_ceil  : (self*mul).div_ceil(div)    (toward +inf)
///       - checked_mul_div_euclid: (self*mul).div_euclid(div)  (rem >= 0)
///   * crates/num-utils/src/add_sub.rs (checked_add / checked_sub range checks)
///
/// KEY MODELING FACT (documented as `widen_never_overflows` below):
///   Both operands are < 2^128 in magnitude, so the widened product fits in the
///   256-bit intermediate with room to spare; therefore the intermediate
///   multiplication CANNOT overflow. The ONLY numeric failure modes of the Rust
///   functions are:
///     (a) `div == 0`               -> None  (checked_div / explicit guard)
///     (b) final `try_into()` fails -> None  (result out of the 128-bit range)
///   We model over F*'s unbounded `int` and reproduce exactly (a) and (b).

/// ----------------------------------------------------------------------------
/// Fixed-width ranges
/// ----------------------------------------------------------------------------

let pow2_128 : pos = 340282366920938463463374607431768211456        // 2^128
let pow2_127 : pos = 170141183460469231731687303715884105728        // 2^127

let u128_max : int = pow2_128 - 1
let i128_min : int = - pow2_127
let i128_max : int = pow2_127 - 1

type u128 = x:int{ 0 <= x /\ x <= u128_max }
type i128 = x:int{ i128_min <= x /\ x <= i128_max }

let in_u128 (x:int) : bool = 0 <= x && x <= u128_max
let in_i128 (x:int) : bool = i128_min <= x && x <= i128_max

/// ----------------------------------------------------------------------------
/// Floor / ceil division for arbitrary integers.
///
/// F*'s primitive `/` on `int` is only used here on NON-NEGATIVE dividends with
/// POSITIVE divisors, where it coincides with mathematical floor. We build the
/// signed variants explicitly on top of that so the rounding direction is
/// unambiguous and matches bnum/Rust.
/// ----------------------------------------------------------------------------

/// floor(n / d) for d > 0
let fdiv (n:int) (d:pos) : int =
  if n >= 0 then n / d
  else - (((- n) + d - 1) / d)

/// ceil(n / d) for d > 0
let cdiv (n:int) (d:pos) : int =
  if n >= 0 then (n + d - 1) / d
  else - ((- n) / d)

/// General (any nonzero divisor) floor, ceil, and Euclidean division, matching
/// bnum's `div`, `div_ceil`, `div_euclid` respectively.
let fdiv_g (n:int) (d:int{d <> 0}) : int =
  if d > 0 then fdiv n d else fdiv (- n) (- d)

let cdiv_g (n:int) (d:int{d <> 0}) : int =
  if d > 0 then cdiv n d else cdiv (- n) (- d)

/// Euclidean division: unique q with n = d*q + r and 0 <= r < |d|.
///   d > 0 -> floor(n/d);   d < 0 -> ceil(n/d).
let ediv_g (n:int) (d:int{d <> 0}) : int =
  if d > 0 then fdiv n d else cdiv_g n d

/// ----------------------------------------------------------------------------
/// The checked_mul_div family (u128), as used by Pips::fee / Pips::fee_ceil.
/// ----------------------------------------------------------------------------

let checked_mul_div_u (a mul div : u128) : option u128 =
  if div = 0 then None
  else
    let q = fdiv (a * mul) div in
    if in_u128 q then Some q else None

let checked_mul_div_ceil_u (a mul div : u128) : option u128 =
  if div = 0 then None
  else
    let q = cdiv (a * mul) div in
    if in_u128 q then Some q else None

/// ----------------------------------------------------------------------------
/// The checked_mul_div family (i128), as used by TokenDiff::supply_delta /
/// closure_supply_delta.
/// ----------------------------------------------------------------------------

let checked_mul_div_i (a mul div : i128) : option i128 =
  if div = 0 then None
  else
    let q = fdiv_g (a * mul) div in
    if in_i128 q then Some q else None

let checked_mul_div_ceil_i (a mul div : i128) : option i128 =
  if div = 0 then None
  else
    let q = cdiv_g (a * mul) div in
    if in_i128 q then Some q else None

let checked_mul_div_euclid_i (a mul div : i128) : option i128 =
  if div = 0 then None
  else
    let q = ediv_g (a * mul) div in
    if in_i128 q then Some q else None

/// checked negation of i128: None exactly for i128::MIN (no positive counterpart).
let checked_neg_i (a:i128) : option i128 =
  if a = i128_min then None else Some (- a)

/// ----------------------------------------------------------------------------
/// Foundational lemmas
/// ----------------------------------------------------------------------------

/// The widened 256-bit product of two 128-bit values is representable; hence the
/// Rust intermediate multiplication never overflows and the only failures are
/// div==0 or the final try_into range check (which our `option` encodes).
let widen_never_overflows (a mul : u128)
  : Lemma (0 <= a * mul /\ a * mul < pow2_128 * pow2_128)
  = ()

let widen_never_overflows_i (a mul : i128)
  : Lemma (- (pow2_127 * pow2_127) <= a * mul /\ a * mul <= pow2_127 * pow2_127)
  = ()

/// Sanity: floor <= ceil, and they differ by at most 1 when d > 0.
let floor_le_ceil (n:int) (d:pos)
  : Lemma (fdiv n d <= cdiv n d /\ cdiv n d <= fdiv n d + 1)
  = ()

/// Ceil is exact iff d divides n (for n >= 0); otherwise it rounds strictly up.
let ceil_bounds (n:nat) (d:pos)
  : Lemma (d * (cdiv n d) >= n /\ d * (cdiv n d) < n + d)
  = ()
