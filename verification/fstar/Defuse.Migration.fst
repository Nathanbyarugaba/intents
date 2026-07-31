module Defuse.Migration

/// FSM-11 — Account migration integrity (MIG-001/002/003).
///
/// Rust sources:
///   contracts/defuse/src/contract/accounts/account/entry/{mod.rs,v0.rs,v1.rs}
///   contracts/defuse/src/contract/accounts/account/nonces.rs (MaybeLegacyNonces)
///
/// Storage layout: an `AccountEntry` is borsh-decoded by reading a 4-byte discriminator; if it equals
/// `VERSIONED_MAGIC_PREFIX = u32::MAX` the bytes are a `VersionedAccountEntry` (V0 | V1 | Latest),
/// otherwise they are a legacy `AccountV0` (whose first 4 bytes are a `Box<[u8]>` length < u32::MAX).
/// Serialization always writes the `Latest` form with the magic prefix.
///
/// Conversions (must preserve all custody/authority fields):
///   AccountV0 -> Account : implicit_public_key_removed:bool -> IMPLICIT_PUBLIC_KEY_REMOVED flag;
///                          nonces moved into the LEGACY map; lock = unlocked; auth-by-predecessor = enabled.
///   AccountV1 -> Account : flags (incl. lock) preserved verbatim; nonces moved into the LEGACY map.
///
/// Properties (Model proof):
///   * MIG-003 disambiguation: the magic discriminator is unambiguous given legacy prefix < u32::MAX.
///   * round-trip: decode(encode(a)) == a (all fields preserved).
///   * MIG-001/002 field preservation for V0-> and V1->Account.
///   * cross-migration replay protection: a migrated (legacy) nonce stays used forever and cleanup can
///     NEVER resurrect it (cleanup touches only the new map).

open FStar.List.Tot

/// Custody/authority-relevant projection of an account.
type flags = { implicit_removed : bool; auth_pred_disabled : bool }

type acct = {
  keys          : list nat;   // public key ids
  bal           : nat;        // representative custody balance (AccountState)
  legacy_nonces : list nat;   // nonces in the legacy map
  new_nonces    : list nat;   // nonces in the optimized/new map
  fl            : flags;
  locked        : bool;
}

/// Legacy V0 (no flags/lock/auth-by-predecessor concept).
type v0 = { v0_implicit_removed : bool; v0_keys : list nat; v0_bal : nat; v0_nonces : list nat }
/// V1 (has flags; wrapped in a Lock).
type v1 = { v1_keys : list nat; v1_bal : nat; v1_nonces : list nat; v1_fl : flags }

let from_v0 (a:v0) : acct = {
  keys = a.v0_keys;
  bal = a.v0_bal;
  legacy_nonces = a.v0_nonces;
  new_nonces = [];
  fl = { implicit_removed = a.v0_implicit_removed; auth_pred_disabled = false };
  locked = false;
}

let from_v1 (locked:bool) (a:v1) : acct = {
  keys = a.v1_keys;
  bal = a.v1_bal;
  legacy_nonces = a.v1_nonces;
  new_nonces = [];
  fl = a.v1_fl;
  locked;
}

type versioned = | EncV0 : v0 -> versioned | EncV1 : bool -> v1 -> versioned | EncLatest : acct -> versioned

let decode_versioned (v:versioned) : acct =
  match v with
  | EncV0 a     -> from_v0 a
  | EncV1 l a   -> from_v1 l a
  | EncLatest a -> a

/// Serialization always writes the Latest form.
let encode (a:acct) : versioned = EncLatest a

/// Round-trip: no custody/authority field is lost across encode/decode.
let roundtrip (a:acct) : Lemma (decode_versioned (encode a) == a) = ()

/// ---------------------------------------------------------------------------
/// MIG-003 — discriminator disambiguation.
/// ---------------------------------------------------------------------------

let magic : nat = 4294967295   // u32::MAX

/// A legacy AccountV0 begins with a `Box<[u8]>` length, which is strictly less than u32::MAX; hence it can
/// never be mistaken for the versioned magic prefix. (Declared assumption on legacy storage.)
let disambiguation (legacy_prefix_len : nat)
  : Lemma (requires legacy_prefix_len < magic) (ensures legacy_prefix_len <> magic)
  = ()

/// ---------------------------------------------------------------------------
/// MIG-001/002 — field preservation.
/// ---------------------------------------------------------------------------

let v0_preserves (a:v0)
  : Lemma (let r = from_v0 a in
           r.keys == a.v0_keys /\ r.bal == a.v0_bal /\
           r.legacy_nonces == a.v0_nonces /\
           r.fl.implicit_removed == a.v0_implicit_removed /\
           r.fl.auth_pred_disabled == false /\   // auth-by-predecessor enabled by default
           r.locked == false)                    // V0 accounts migrate as unlocked
  = ()

let v1_preserves (locked:bool) (a:v1)
  : Lemma (let r = from_v1 locked a in
           r.keys == a.v1_keys /\ r.bal == a.v1_bal /\
           r.legacy_nonces == a.v1_nonces /\
           r.fl == a.v1_fl /\ r.locked == locked)
  = ()

/// ---------------------------------------------------------------------------
/// MaybeLegacyNonces — cross-migration replay protection.
/// ---------------------------------------------------------------------------

let is_used (a:acct) (n:nat) : bool = mem n a.legacy_nonces || mem n a.new_nonces

let commit (a:acct) (n:nat) : option acct =
  if mem n a.legacy_nonces || mem n a.new_nonces
  then None
  else Some ({ a with new_nonces = n :: a.new_nonces })

/// cleanup_by_prefix clears from the NEW map only (legacy map is never touched).
let cleanup (a:acct) (n:nat) : acct =
  { a with new_nonces = filter (fun m -> m <> n) a.new_nonces }

/// A migrated (legacy) nonce is always considered used.
let legacy_nonce_used (a:acct) (n:nat)
  : Lemma (requires mem n a.legacy_nonces) (ensures is_used a n)
  = ()

/// Committing a legacy nonce always fails (no replay across migration).
let legacy_commit_fails (a:acct) (n:nat)
  : Lemma (requires mem n a.legacy_nonces) (ensures commit a n == None)
  = ()

/// Cleanup can NEVER resurrect a legacy nonce (it only filters the new map).
let cleanup_cannot_resurrect_legacy (a:acct) (n cleaned:nat)
  : Lemma (requires mem n a.legacy_nonces) (ensures is_used (cleanup a cleaned) n)
  = ()   // legacy_nonces is untouched by cleanup, so `mem n legacy` still holds

/// A V0-migrated account keeps all its former nonces used.
let v0_nonces_preserved (a:v0) (n:nat)
  : Lemma (requires mem n a.v0_nonces) (ensures is_used (from_v0 a) n)
  = ()

/// ---------------------------------------------------------------------------
/// Witnesses.
/// ---------------------------------------------------------------------------

let witness_v0_roundtrip ()
  : Lemma (let a = { v0_implicit_removed = true; v0_keys = [1;2]; v0_bal = 500; v0_nonces = [9] } in
           let m = from_v0 a in
           decode_versioned (encode m) == m /\ is_used m 9 /\ not m.locked)
  = ()
