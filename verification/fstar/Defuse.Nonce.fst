module Defuse.Nonce

/// FSM-4 — Nonce replay protection: at-most-once, cleanup safety, versioned
/// downgrade characterization.
///
/// Rust sources:
///   * crates/bitmap/src/b256.rs
///       get_bit / set_bit  : a 256-bit nonce = (248-bit word prefix, 8-bit index)
///       cleanup_by_prefix(p) = map.remove(p)   // removes the WHOLE word (all 256
///                                              // nonces sharing the prefix p)
///   * contracts/defuse/core/src/nonce/{versioned,expirable,salted}.rs
///       VersionedNonce::maybe_from(n): Some iff n starts with MAGIC(4) and the
///       next byte (borsh enum discriminant) == 0 (V1); layout thereafter is
///       salt(4) | deadline(i64,8) | random(15). A 32-byte input with MAGIC and
///       discriminant 0 ALWAYS deserializes (fixed-width fields), so the ONLY
///       "downgrade to legacy" is discriminant byte != 0 (DEF-NON-004).
///   * contracts/defuse/core/src/engine/mod.rs::verify_intent_nonce
///       legacy (maybe_from == None) -> Ok (no checks);
///       V1 -> require valid_salt(salt) /\ intent_deadline <= nonce.deadline
///                     /\ now <= nonce.deadline.
///   * contracts/defuse/src/contract/garbage_collector.rs::cleanup_nonces
///       DAO/GarbageCollector-gated; only removes a word after checking a witness
///       nonce is `is_nonce_cleanable` = versioned && (expired || invalid salt).
///   * contracts/defuse/src/contract/accounts/account/nonces.rs
///       cleanup only touches the NEW map; legacy nonces are never cleared.
///
/// KEY BYTE-LAYOUT FACT: MAGIC (bytes 0..3), version (byte 4), salt (bytes 5..8)
/// and deadline (bytes 9..16) all lie within the 248-bit word prefix (bytes
/// 0..30). Only the last random byte (index 31) is the in-word bit position.
/// Therefore `is_nonce_cleanable` is a function of the word prefix ALONE, so
/// clearing a whole word can only remove nonces that are ALL equally cleanable.

open FStar.List.Tot

type u8 = n:nat{ n < 256 }

/// ===========================================================================
/// BYTE-LEVEL model: a nonce as a total map index (0..31) -> byte.
/// ===========================================================================

let nonce_f = i:nat{ i < 32 } -> u8

/// maybe_from(..) succeeds  <=>  MAGIC prefix present AND version byte == 0.
let is_versioned (n:nonce_f) : bool =
  n 0 = 0x56 && n 1 = 0x28 && n 2 = 0xf6 && n 3 = 0xc6 && n 4 = 0

/// is_nonce_cleanable, parameterized by the (opaque) environment predicates that
/// depend only on the salt bytes (5..8) and the deadline bytes (9..16). Passing
/// them as arguments avoids any axiom: the theorem holds for ANY such predicates.
let cleanable
  (salt_invalid    : (u8 & u8 & u8 & u8) -> bool)
  (deadline_expired: (u8 & u8 & u8 & u8 & u8 & u8 & u8 & u8) -> bool)
  (n:nonce_f) : bool =
  is_versioned n &&
  ( deadline_expired (n 9, n 10, n 11, n 12, n 13, n 14, n 15, n 16)
    || salt_invalid (n 5, n 6, n 7, n 8) )

/// DEF-NON-002 (byte level): cleanability depends ONLY on the word prefix
/// (indices 0..30). Two nonces that share the prefix are equally cleanable.
let cleanable_prefix_invariance
  (si : (u8 & u8 & u8 & u8) -> bool)
  (de : (u8 & u8 & u8 & u8 & u8 & u8 & u8 & u8) -> bool)
  (a b : nonce_f)
  : Lemma (requires (forall (i:nat). i < 31 ==> a i == b i))
          (ensures  cleanable si de a == cleanable si de b)
  = ()

/// DEF-NON-004: a MAGIC-prefixed nonce with a non-zero version byte parses as
/// NONE (=> handled as a legacy nonce; verify_intent_nonce returns Ok). This is
/// the entire "downgrade" surface.
let downgrade_is_legacy (n:nonce_f)
  : Lemma (requires n 0 = 0x56 /\ n 1 = 0x28 /\ n 2 = 0xf6 /\ n 3 = 0xc6 /\ n 4 <> 0)
          (ensures  not (is_versioned n))
  = ()

/// A versioned nonce (version byte 0) and a magic-prefixed downgraded nonce
/// (version byte != 0) can NEVER share a 248-bit word, because the version byte
/// (index 4 < 31) is part of the prefix. Hence cleaning a versioned word can
/// never clear a downgraded/legacy nonce sitting "next to it".
let versioned_downgrade_disjoint (a b : nonce_f)
  : Lemma (requires (forall (i:nat). i < 31 ==> a i == b i) /\
                    is_versioned a /\
                    b 0 = 0x56 /\ b 1 = 0x28 /\ b 2 = 0xf6 /\ b 3 = 0xc6 /\ b 4 <> 0)
          (ensures  False)
  = ()

/// ===========================================================================
/// SET-LEVEL model of the bitmap store: nonce = (word prefix, in-word bit).
/// ===========================================================================

type word = nat                       // abstracts the 248-bit prefix (decidable =)
type bit  = b:nat{ b < 256 }
type snonce = word & bit

let is_used (s:list snonce) (n:snonce) : bool = mem n s

let commit (s:list snonce) (n:snonce) : option (list snonce) =
  if mem n s then None else Some (n :: s)

/// cleanup_by_prefix removes EVERY nonce whose word == w (the whole map word).
let cleanup (s:list snonce) (w:word) : list snonce =
  filter (fun (m:snonce) -> fst m <> w) s

/// DEF-NON-001 — a nonce is committable at most once.
let commit_at_most_once (s:list snonce) (n:snonce)
  : Lemma
      ( (mem n s ==> commit s n == None) /\
        (not (mem n s) ==>
           (Some? (commit s n) /\
            is_used (Some?.v (commit s n)) n /\
            (forall (m:snonce). m =!= n ==>
               is_used (Some?.v (commit s n)) m == is_used s m))) )
  = ()

let rec mem_filter_intro (f:snonce -> bool) (s:list snonce) (n:snonce)
  : Lemma (requires mem n s /\ f n) (ensures mem n (filter f s))
  = match s with
    | [] -> ()
    | h :: t -> if h = n then () else mem_filter_intro f t n

/// DEF-NON-002 — cleanup cannot resurrect a still-valid nonce.
/// Given that the whole-word removal is justified by a cleanable witness in word
/// `w` (so `cw w` holds), any committed nonce `n` that is NOT cleanable survives
/// the cleanup. (Here `cw : word -> bool` is cleanability-as-a-function-of-word,
/// which `cleanable_prefix_invariance` proves is well-defined.)
let cleanup_preserves_valid (cw:word -> bool) (s:list snonce) (w:word) (n:snonce)
  : Lemma (requires cw w /\ mem n s /\ not (cw (fst n)))
          (ensures  is_used (cleanup s w) n)
  = // cw w = true and cw (fst n) = false => fst n <> w => the filter keeps n
    mem_filter_intro (fun (m:snonce) -> fst m <> w) s n

/// ===========================================================================
/// Witnesses (kani::cover! analogues).
/// ===========================================================================

let witness_double_commit_rejected () : Lemma (commit [((7 <: word), (3 <: bit))] (7, 3) == None) = ()
let witness_cleanup_removes_word ()
  : Lemma (not (is_used (cleanup [((1 <: word),(2 <: bit)); ((1 <: word),(9 <: bit))] 1) (1, 2)))
  = ()
