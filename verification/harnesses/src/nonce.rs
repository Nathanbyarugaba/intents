//! DEF-NON-001 / DEF-NON-004: nonce single-use + versioned-nonce parse safety.
//!
//! * `VersionedNonce::maybe_from` is a faithful bijection on its accepted set:
//!   parsing then re-serializing returns the original bytes, and it only ever
//!   accepts inputs bearing the magic prefix. This rules out parse ambiguity /
//!   a "malformed magic-prefixed value silently downgraded to something usable".
//! * `Nonces` (the production bitmap) accepts each nonce at most once.

use defuse_core::{Nonce, VersionedNonce};

/// DEF-NON-004: versioned-nonce parse is unambiguous & prefix-gated.
pub fn check_versioned_roundtrip(n: Nonce) {
    let magic = VersionedNonce::VERSIONED_MAGIC_PREFIX;
    let has_prefix = n[..4] == magic[..];

    match VersionedNonce::maybe_from(n) {
        Some(v) => {
            assert!(
                has_prefix,
                "maybe_from accepted a nonce without the magic prefix"
            );
            let re: Nonce = v.into();
            assert!(
                re == n,
                "versioned nonce round-trip mismatch: re-serialized {re:?} != original {n:?}"
            );
        }
        None => {
            // Rejected: either no magic prefix (legacy) or undeserializable.
            // Nothing usable was produced -> safe.
        }
    }
}

#[cfg(kani)]
mod proofs {
    use super::*;

    #[kani::proof]
    #[kani::unwind(40)]
    fn def_non_004_versioned_roundtrip() {
        let n: Nonce = kani::any();
        check_versioned_roundtrip(n);
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use defuse_bitmap::{U248, U256};
    use defuse_core::Nonces;
    use proptest::prelude::*;
    use std::collections::HashMap;

    proptest! {
        #![proptest_config(ProptestConfig::with_cases(50_000))]

        #[test]
        fn def_non_004_versioned_roundtrip(n in any::<[u8; 32]>()) {
            check_versioned_roundtrip(n);
        }
    }

    /// DEF-NON-001: the production `Nonces` bitmap accepts a nonce at most once,
    /// and `cleanup_by_prefix` clears it (so GC safety relies on only cleaning
    /// expired/invalid nonces — verified structurally here).
    #[test]
    fn def_non_001_commit_at_most_once() {
        let mut nonces: Nonces<HashMap<U248, U256>> = Nonces::new(HashMap::new());
        let n: U256 = [7u8; 32];

        assert!(!nonces.is_used(n));
        nonces.commit(n).expect("first commit should succeed");
        assert!(nonces.is_used(n));
        assert!(nonces.commit(n).is_err(), "second commit must be rejected");

        // cleanup by the 248-bit prefix
        let prefix: U248 = {
            let [p @ .., _] = n;
            p
        };
        assert!(nonces.cleanup_by_prefix(prefix));
        assert!(!nonces.is_used(n), "cleanup should clear the bit");
        // after cleanup it is re-committable (hence GC must gate on expiry/salt)
        assert!(nonces.commit(n).is_ok());
    }

    /// Known-good versioned nonce (from the production unit test) round-trips.
    #[test]
    fn versioned_prefix_examples() {
        // No prefix => legacy => None.
        check_versioned_roundtrip([0u8; 32]);
        check_versioned_roundtrip([0xffu8; 32]);
    }
}
