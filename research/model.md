# NEAR Intents `execute_intents` State-Transition System Model

## Actors
- `User / Signer`: A principal submitting an intent.
- `Contract`: The Defuse Verifier contract enforcing execution logic.
- `Fee Collector`: The designated account for collecting protocol fees.

## State
- `Balances`: Mapping from `(AccountId, TokenId) -> u128`.
- `Nonces`: Set of nonces consumed by accounts to prevent replay attacks.
- `PublicKeys`: Mapping from `AccountId -> Set(PublicKey)` indicating allowed signers.
- `Deltas`: Represents the in-flight state differences for each account across a single execution step. For each user, records net token additions/subtractions across all intents they sign.
- `Transfers`: Raw derived token movements after intent execution resolution.
- `Fees`: Total fees aggregated over execution, eventually transferred to the fee collector.

## Views
- `verifying_contract()`
- `fee()`
- `fee_collector()`
- `balance_of(account, token)`
- `is_valid_salt(salt)`

## Transitions
The primary transition `execute_intents` takes a batch of `SignedIntents`.
For each intent:
1. Verification: Validate signature, extract signer, verify deadline.
2. Nonce consumption: Ensure nonce wasn't used and salt is valid.
3. Intent execution (`execute_intent`): Apply the semantic operation onto the `Deltas` state map.
    - If `TokenDiff`, for each token $T$ and amount $\Delta$, apply $\Delta$ to the signer's `Deltas`. Calculate and subtract fees if $\Delta < 0$ (token outflow).
4. Finalization (`finalize()`):
    - Resolve the `Deltas` mapping into concrete `Transfers`.
    - Enforce the **Zero-Sum** (value conservation) invariant: No token is artificially created or destroyed within the system. The sum of all deltas for any specific token across all actors must be $\leq 0$ (meaning some are matched exactly, or there's an excess outflow from some that isn't collected, which fails if left unmatched). Wait, strictly speaking, all tokens must sum to exactly zero, UNLESS it's an overflow error. Wait, unmatched deltas mean someone expects an inflow without a matching outflow. The system throws `InvariantViolated::UnmatchedDeltas`.

## Time
- Bounded by block timestamps relative to intent `deadline`.

## Exceptions
- `InvalidSignature`, `WrongVerifyingContract`, `DeadlineExpired`, `NonceExpired`, `InvariantViolated::UnmatchedDeltas`, `InvariantViolated::Overflow`, etc.

## Assumptions
- Hashing and signatures are secure.
- Unmatched deltas result in strict reversion to ensure no tokens are created from thin air.

## Properties
**Total Value Conservation**: During `execute_intents`, the total quantity of any token $T$ added to any account's balance (excluding the fee collector) must be strictly less than or equal to the total quantity subtracted from all other accounts. Any excess subtraction that isn't matched to an addition should be rejected as `UnmatchedDeltas`. The system must never permit total additions to exceed total subtractions (no tokens from thin air). Formally, for a given execution step, $\sum_{A \in Accounts} \Delta(A, T) + \Delta(FeeCollector, T) = 0$.
