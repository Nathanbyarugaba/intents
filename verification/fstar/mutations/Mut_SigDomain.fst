module Mut_SigDomain

/// MUTATION (expected to FAIL verification) — non-vacuity check for FSM-6.
///
/// We give two standards the SAME domain prefix (i.e. remove domain separation).
/// Then two distinct standards produce identical signed byte strings for the same
/// body, so the disjointness lemma DS-1 must FAIL -- exactly the cross-standard
/// replay a domain tag is meant to prevent.

open FStar.List.Tot

type byte  = n:nat{ n < 256 }
type bytes = list byte

assume val sha256 : bytes -> bytes
assume val sha256_len : m:bytes -> Lemma (length (sha256 m) == 32) [SMTPat (sha256 m)]
assume val sha256_inj : a:bytes -> b:bytes ->
  Lemma (requires sha256 a == sha256 b) (ensures a == b)

/// BUG: identical prefixes for two different standards.
let pfx_a : bytes = [0x9D; 0x01]
let pfx_b : bytes = [0x9D; 0x01]

let signed_a (body:bytes) : bytes = sha256 (pfx_a @ body)
let signed_b (body:bytes) : bytes = sha256 (pfx_b @ body)

/// FALSE under the mutation: with equal prefixes, signed_a body == signed_b body.
let ds1_a_b (body : bytes)
  : Lemma (signed_a body =!= signed_b body)
  = ()
