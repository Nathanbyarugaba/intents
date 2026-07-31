module Mut_Nonce

/// MUTATION (expected to FAIL verification) — non-vacuity check for FSM-4.
///
/// We make cleanability depend on the in-word bit (index 31), which is NOT part
/// of the 248-bit word prefix. Then two nonces sharing the prefix could differ
/// in cleanability, so `cleanable_prefix_invariance` must FAIL -- i.e. clearing
/// a whole word by prefix could remove a still-valid nonce (a real replay bug).

open FStar.List.Tot

type u8 = n:nat{ n < 256 }
let nonce_f = i:nat{ i < 32 } -> u8

let is_versioned (n:nonce_f) : bool =
  n 0 = 0x56 && n 1 = 0x28 && n 2 = 0xf6 && n 3 = 0xc6 && n 4 = 0

/// BUG: reads index 31 (the in-word bit), outside the prefix.
let cleanable_bad (n:nonce_f) : bool =
  is_versioned n && (n 31 > 128)

let cleanable_prefix_invariance_bad (a b : nonce_f)
  : Lemma (requires (forall (i:nat). i < 31 ==> a i == b i))
          (ensures  cleanable_bad a == cleanable_bad b)
  = ()
