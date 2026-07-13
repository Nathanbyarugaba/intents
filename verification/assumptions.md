# Assumptions

## Formal Verification Environment Assumptions

1.  **Kani Bounded Verification**: Kani proofs are bounded. They provide guarantees only within the specified loop unwind limits and collection size bounds. Properties verified with bounded collections (e.g., maximum 3 tokens in a batch) are assumed to generalize to larger collections unless specifically contradicted by a full-width property (e.g., full `u128` arithmetic proofs).
2.  **Quint Model Abstraction**: Quint models abstract away certain implementation details (e.g., exact serialization formats, complex string parsing) to focus on state transitions and asynchronous interleavings. The model is an assumption of the system's behavior; the `refinement evidence` (trace playback) is required to bridge the gap to the implementation.
3.  **Cryptographic Primitives**: `ed25519_dalek`, `p256`, and NEAR's built-in crypto host functions behave correctly and securely. Verification focuses on the payload construction, hashing, and signature validation logic built *around* these primitives.
4.  **NEAR Runtime Correctness**: The NEAR protocol itself (consensus, networking, WASM execution environment) functions as documented. Specifically, receipt routing, promise resolution, and rollback-on-panic semantics are assumed to be correct.

## Contract-Specific Assumptions

1.  **Honest DAO/Admin (within limits)**: The upgrade authority and critical admin roles (if any) will not intentionally deploy malicious code or drain funds. However, their actions must still be authorized correctly, and the threat model includes the risk of an attacker *taking over* these roles.
2.  **Token Standard Compliance**: External token contracts (NEP-141, NEP-171, NEP-245) generally follow the standard interfaces. However, the system must remain safe (no loss of *other* users' funds, no protocol insolvency) even if a specific token contract behaves maliciously (e.g., fails transfers, returns bad values).
3.  **Time Progresses**: `env::block_timestamp()` monotonically increases.
4.  **No Synchronous Reentrancy**: NEAR does not support EVM-style synchronous reentrancy. Cross-contract calls always yield execution and resume in a separate callback receipt.

## Scope Exclusions

1.  Gas optimization and non-exploitable out-of-gas errors.
2.  Front-running/MEV that does not violate explicit intent parameters (e.g., price limits, deadlines).
3.  Phishing or off-chain key compromise of end-users.
