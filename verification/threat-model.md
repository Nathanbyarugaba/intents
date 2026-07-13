# Threat Model

## Actors and Principals

1.  **Arbitrary External Account**: Can interact with public endpoints of the contracts (e.g., `execute_intents`, `withdraw`). Unauthenticated beyond their own account ID.
2.  **Legitimate Signer**: A user who creates valid signed intents (payloads) authorizing specific actions (e.g., token swaps, withdrawals). Their signed payloads are public once submitted or observed in the mempool.
3.  **Malicious Matcher/Relayer**: Submits batches of signed intents for execution. May attempt to reorder intents, submit partial batches, inject their own intents, exploit fee calculations, or attempt to extract value from other users' intents.
4.  **Malicious Token/Receiver (Callback targets)**: NEP-141/171/245 contracts or receiver accounts that can behave maliciously during callbacks. This includes failing unexpectedly, returning malformed JSON, returning incorrect amounts (e.g., more than requested), reentering (if possible, though NEAR is async), or mutating their state/locks between a call and a callback.
5.  **Locked Account**: An account whose state transitions to "locked" (e.g., via authorization changes) between steps of an asynchronous operation (e.g., withdrawal initiated -> account locked -> refund attempted).
6.  **Authorized Force Role**: Accounts with special privileges (e.g., `FAR` specific roles, admin roles) that can execute forced actions (e.g., forced withdrawals, lock bypasses).
7.  **DAO/Upgrade Authority**: The highest privilege role, capable of upgrading the contract or changing fundamental parameters. Assumed to be honest but potentially a target for takeover.
8.  **Arbitrary Legal Callback Scheduling**: The NEAR runtime environment, which guarantees promise execution but not synchronous execution. Callbacks can arrive in various orders, and other transactions can interleave between a promise and its callback.

## Trust Assumptions & Environment Boundaries

1.  **Cryptography**: Ed25519, P-256 (WebAuthn), and secp256k1 signature verification primitives are assumed to be mathematically secure. The threat model focuses on how these primitives are *used* (domain separation, exact bytes signed, canonical encoding, replay protection).
2.  **NEAR Runtime Atomicity**: A single receipt execution (a single synchronous function call) is atomic. If it panics, state changes within that receipt are rolled back.
3.  **NEAR Async Promises**: Cross-contract calls are asynchronous. State changes *before* a promise is created are committed immediately if the current receipt succeeds, even if the promise later fails.
4.  **Callback Privacy**: Callbacks must verify their predecessor (`env::predecessor_account_id() == env::current_account_id()`) to ensure they are only invoked by the contract itself as a result of a promise.
5.  **Gas Limitations**: Transactions and promises have gas limits. Operations must complete within these limits. A malicious actor might try to cause out-of-gas errors in specific paths (e.g., during refunds).

## Key Assets

1.  **Internal Token Balances**: Custodied NEP-141, NEP-171, NEP-245, and Native (wNEAR) tokens tracked by the `defuse` contract.
2.  **Escrow Balances**: Tokens held in the `escrow-swap` contract.
3.  **In-flight Transfers**: Tokens currently locked or in a pending state during asynchronous operations (withdrawals, escrow fills).
4.  **Authorization State**: Public keys, nonces, account locks, and role assignments that control access to assets.
5.  **Fee Collector Balances**: Accrued protocol fees.
