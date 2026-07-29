//! WAL-PRO-001: the wallet's action allow-list cannot be bypassed via a crafted
//! request.
//!
//! `WalletImpl::build_promise` only permits `FunctionCall | Transfer |
//! DeterministicStateInit`. Because a signed/extension request carries a
//! `NearPromise` whose actions are typed `NearAction`, the deeper guarantee is
//! that no *account-mutating* NEAR action (CreateAccount, DeployContract,
//! AddKey, DeleteKey, DeleteAccount, Stake, DeployGlobalContract, …) can even
//! be **represented / deserialized** as a `NearAction`. We check this at the
//! borsh boundary (the format used to carry signed requests):
//!
//! * only discriminants {2 = FunctionCall, 3 = Transfer, 11 =
//!   DeterministicStateInit} decode — matching nearcore's `Action` tags, so the
//!   wallet builds exactly the intended action kind;
//! * any other discriminant is rejected, so an account-mutating action can
//!   never be smuggled through a wallet request.

use borsh::BorshDeserialize;
use defuse_near_promise::{
    actions::{FunctionCall, NearAction, Transfer},
    NearToken,
};

/// nearcore `Action` tags that Defuse's wallet supports.
pub const ALLOWED_DISCRIMINANTS: [u8; 3] = [2, 3, 11];

/// An unsupported discriminant with ANY payload must never decode.
pub fn decode_rejects_unsupported(d: u8, payload: &[u8]) {
    if ALLOWED_DISCRIMINANTS.contains(&d) {
        return;
    }
    let mut bytes = vec![d];
    bytes.extend_from_slice(payload);
    assert!(
        NearAction::try_from_slice(&bytes).is_err(),
        "NearAction decoded an unsupported action (discriminant {d}) => wallet action allow-list bypass"
    );
}

/// Supported actions round-trip and carry the expected nearcore tag.
pub fn roundtrip_and_discriminant() {
    let cases: [(NearAction, u8); 2] = [
        (
            NearAction::FunctionCall(
                FunctionCall::name("do_thing").attach_deposit(NearToken::from_yoctonear(7)),
            ),
            2,
        ),
        (
            NearAction::Transfer(Transfer {
                amount: NearToken::from_yoctonear(9),
            }),
            3,
        ),
    ];
    for (action, disc) in cases {
        let bytes = borsh::to_vec(&action).expect("serialize");
        assert_eq!(
            bytes[0], disc,
            "NearAction discriminant drifted from nearcore Action tag"
        );
        let back = NearAction::try_from_slice(&bytes).expect("deserialize");
        assert_eq!(back, action, "round-trip mismatch");
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use proptest::prelude::*;

    #[test]
    fn wal_pro_001_supported_actions_roundtrip() {
        roundtrip_and_discriminant();
    }

    /// Exhaustively: every discriminant outside the allow-list is rejected
    /// (with an empty and a non-trivial payload).
    #[test]
    fn wal_pro_001_all_unsupported_discriminants_rejected() {
        for d in 0u8..=255 {
            decode_rejects_unsupported(d, &[]);
            decode_rejects_unsupported(d, &[0u8; 96]);
            decode_rejects_unsupported(d, &[0xffu8; 96]);
        }
    }

    proptest! {
        #![proptest_config(ProptestConfig::with_cases(50_000))]

        #[test]
        fn wal_pro_001_reject_unsupported_random(
            d in any::<u8>(),
            payload in prop::collection::vec(any::<u8>(), 0..96),
        ) {
            prop_assume!(!ALLOWED_DISCRIMINANTS.contains(&d));
            decode_rejects_unsupported(d, &payload);
        }
    }
}
