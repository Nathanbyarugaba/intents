# Critical/High Attack Hypotheses and Map

## Top 10 Attack Hypotheses

1.  **Hypothesis: Unmatched Delta Bypass in Settlement (`DEF-CON-002`)**: A malicious relayer constructs a batch of intents where intermediate `TokenDiff` executions cause arithmetic overflow/underflow or exploit fee rounding during `finalize_into`. If the error handling is flawed, the system might finalize the batch while an unmatched delta (e.g., negative balance for a user without corresponding tokens) remains, leading to unauthorized value creation or theft.
    *   *Entry point*: `execute_signed_intents` -> `finalize`.
    *   *Validation*: Kani proof of `Deltas::finalize` with bounded inputs and forced overflows.

2.  **Hypothesis: Fee Rounding Exploitation (`DEF-FEE-002`)**: An attacker submits many small trades where the fee calculation (`token_fee.fee_ceil(amount)`) consistently rounds down to zero (if flawed) or up excessively, bypassing the intended fee structure or draining user balances beyond the intended amount.
    *   *Entry point*: `execute_signed_intents` -> `TokenDiff::execute_intent`.
    *   *Validation*: Kani proof covering all boundary values for fee calculation.

3.  **Hypothesis: Signature Domain Confusion (`DEF-SIG-003`)**: A payload signed for the `wallet` contract or a different NEAR application (or even a different chain) can be parsed and executed by the `defuse` engine due to weak domain separation or flexible parsing of the `DefusePayload`.
    *   *Entry point*: `execute_signed_intents` -> `signed.extract_defuse_payload()`.
    *   *Validation*: Matrix testing of payload extractors against valid payloads for other domains.

4.  **Hypothesis: Versioned Nonce Downgrade (`DEF-NON-004`)**: A 32-byte nonce begins with `VERSIONED_MAGIC_PREFIX` but contains invalid version data. The parsing logic falls back to treating it as a legacy nonce instead of rejecting it, bypassing expiry or salt protections intended by the signer.
    *   *Entry point*: `execute_signed_intents` -> `verify_intent_nonce`.
    *   *Validation*: Kani proof of nonce parsing logic with malformed magic-prefix bytes.

5.  **Hypothesis: Async Withdrawal Double Credit (`DEF-ASY-001/007`)**: A user initiates a NEP-141 withdrawal. The `withdraw` function debits the internal balance and makes a cross-contract call. The token contract fails, and the callback `ft_resolve_transfer` is invoked. If the attacker can manipulate the callback arguments or if the resolution logic fails to accurately distinguish between "used" and "refunded" (especially if `mem::take` or similar patterns are flawed), the user might receive a refund *and* keep the withdrawn tokens (if the external failure was faked or manipulated).
    *   *Entry point*: `withdraw` -> `ft_resolve_transfer`.
    *   *Validation*: Quint model checking of withdrawal interleavings, particularly with malicious token contract responses.

6.  **Hypothesis: Locked Account Refund Bypass (`DEF-ASY-005`)**: A user initiates a withdrawal, and their account is subsequently locked (e.g., via an intent or force action). The withdrawal fails externally, and the refund callback executes. If the refund logic strictly checks the lock status and panics, the refund might fail, permanently locking/losing the funds. Conversely, if it bypasses the lock to refund, it might be exploitable to move funds *out* of a locked account if the attacker can control the refund destination.
    *   *Entry point*: `ft_resolve_transfer` on a locked account.
    *   *Validation*: Quint model checking and deterministic testing of refund paths for locked accounts.

7.  **Hypothesis: Escrow Cleanup Value Destruction (`ESC-CLN-001`)**: The `cleanup` function in the escrow contract deletes state. If an attacker can trigger `cleanup` while `in_flight` > 0 or while recoverable `maker_dst_lost` exists (e.g., due to a race condition or flawed state checks), pending callbacks will fail to resolve, or users will lose the ability to claim lost funds.
    *   *Entry point*: Escrow `cleanup`.
    *   *Validation*: Quint model checking of the escrow lifecycle, asserting cleanup is only possible in a truly terminal state.

8.  **Hypothesis: Escrow In-flight Accounting Underflow (`ESC-ASY-001`)**: In the escrow contract, if a specific failure path or malformed callback allows `in_flight` to be decremented twice for the same transfer, `in_flight` will underflow (or become inaccurate). This could falsely indicate a terminal state, allowing premature `cleanup` or `close`.
    *   *Entry point*: Escrow `resolve` callbacks.
    *   *Validation*: Quint model checking and Kani arithmetic proofs on escrow state counters.

9.  **Hypothesis: Migration State Corruption (`MIG-001/002`)**: During an account state migration (e.g., from v0 to v1), a specific combination of legacy flags, balances, or public keys is misinterpreted by the deserialization or migration logic, resulting in lost balances, locked accounts becoming unlocked, or incorrect nonce state.
    *   *Entry point*: Lazy migration triggered by account interaction.
    *   *Validation*: Differential property testing of state serialization/deserialization across versions.

10. **Hypothesis: Wallet Unsupported Promise Action Bypass (`WAL-PRO-001`)**: The `build_promise` logic in the wallet contract attempts to restrict actions. If an attacker constructs a complex payload (e.g., a function call that acts as a self-call, or a batch of actions where one is subtly unsupported), they might bypass the restrictions to mutate the wallet's keys or state directly without the required extension permissions.
    *   *Entry point*: Wallet signature/extension execution -> `build_promise`.
    *   *Validation*: Symbolic execution or extensive property testing of the promise building logic.

## Recommended Proof Architecture

*   **`verification/kani/settlement/`**: Small, focused Kani harnesses for `token_fee`, `TokenDiff::closure`, `TransferMatcher::finalize_into`, and `Engine::verify_intent_nonce`. These should use bounded mock states where necessary but verify the core arithmetic and logic exactly.
*   **`verification/quint/defuse_withdrawals.qnt`**: A Quint model representing the state machine of an intent, a withdrawal, and the corresponding callbacks (NEP-141/171/245). Actions map to `withdraw`, `ft_resolve_transfer`, etc.
*   **`verification/quint/escrow_swap.qnt`**: A Quint model for the escrow lifecycle (`fund`, `fill`, `close`, `resolve`, `lost_found`, `cleanup`).
*   **`verification/tests/differential/`**: Rust integration tests for migration serialization/deserialization and simulation vs. actual execution state changes.
*   **`verification/tests/signatures/`**: Matrix tests constructing payloads for different domains/standards and ensuring they are rejected by the target verifiers.