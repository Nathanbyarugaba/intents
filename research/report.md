# NEAR Intents (Defuse) - Protocol Verify Report

## Phase 1: Triage
The highest-risk mechanism was identified in `contracts/defuse/core/src/engine/mod.rs` and `contracts/defuse/core/src/engine/state/deltas.rs`. Specifically, the execution of `TokenDiff` intents which handle token swaps among multiple participants. The risk lies in ensuring no tokens are minted or burnt improperly during swaps, and that fees are handled without introducing imbalances that allow theft or inflation.

## Phase 2: Model
We reconstructed the `execute_intents` matching engine as a state-transition system.
- **Actors**: Signers supplying intents, Verifying Contract (Engine), and Fee Collector.
- **State**: Account Balances, Nonces, and the in-flight `Deltas` object (represented by `TransferMatcher` consisting of `deposits` and `withdrawals`).
- **Transitions**:
  - Verification of signatures, salts, and nonces.
  - Execution of `TokenDiff`: For each token delta, negative deltas correspond to user withdrawals (sending tokens into the pool), from which a protocol fee is subtracted and assigned to the fee collector as a deposit. Positive deltas correspond to deposits (receiving tokens from the pool).
  - Finalization: Reverting the transaction entirely if total deposits do not perfectly equal total withdrawals across the pool for any token.
- **Exceptions**: `InvariantViolated::UnmatchedDeltas`, `Overflow`.
- **Assumptions**: Signatures securely authenticate user intent, and `checked_mul_div` avoids silent overflow.

## Phase 3: Specify
**Property (Total Value Conservation)**: During a successful `execute_intents` execution, the total amount of any token extracted from signers (withdrawals) must exactly equal the total amount deposited to other signers plus the total fees collected.

## Phase 4 & 5: Falsify, Adjudicate & Refine
We attempted to falsify the property via combinatorial boundary testing (implemented in Python inside the sandbox environment):
- **Findings**:
  - `TransferMatcher`'s logic (`deposits` and `withdrawals` mappings) strictly enforces zero sum by computing the mismatch iteratively until both sides reach 0. Any leftover on either side yields an error.
  - Users are responsible for covering the fee manually by adjusting their requested deltas (e.g. asking for slightly less output or providing slightly more input), which the solver typically orchestrates off-chain.
  - Fees are rounded up `fee_ceil` to ensure the protocol does not lose dust.
  - Potential integer overflows in `fee = amount * pips / MAX_PIPS` are defended against via the `defuse_num_utils::CheckedMulDiv` trait which casts `u128` to a 256-bit arbitrary precision integer (`BUint<4>`) internally during computation.
  - Other intents like `FtWithdraw` interact directly with balances and bypass `TransferMatcher`. However, since they run in the same atomic receipt, if `TransferMatcher`'s `finalize()` fails for `TokenDiff`s, the *entire receipt panics*, discarding all generated Promises and reverting state.

Therefore, the property holds safely.

## Phase 6: Prove
The extracted model was formalized in Rocq (`Coq`).
File: `research/proofs/Model.v`
- **Definition `sum_deltas`**: Represents the logic of `internal_apply_deltas` applying positive/negative amounts and allocating fees.
- **Lemma `sum_deltas_decomposition`**: Decomposes the aggregate delta into withdrawals (`sum_negative_abs`), deposits (`sum_positive`), and fees (`sum_fees`).
- **Theorem `value_conservation`**: Proves that if `sum_deltas` is equal to 0 (the invariant check passed in `finalize`), then `sum_negative_abs tok diffs = sum_positive tok diffs + sum_fees tok diffs`.
**Status**: MACHINE_CHECKED_PROOF. `coqc` compiled and verified the proofs successfully without `Admitted`.

## Conclusion
The NEAR Intents (Defuse) Verifier securely processes batched intents and atomic swaps. The mathematical properties governing its core balancing engine (`TransferMatcher`) strictly ensure value conservation under adversarial configurations.
