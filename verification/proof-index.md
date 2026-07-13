# Proof-Obligation Index

Use a unique identifier in harness names, Quint invariants, tests, and findings.

## DEFUSE settlement

- **DEF-CON-001 — Batch conservation:** for each token, final positive deltas, negative deltas, assessed fees, and transfers reconcile exactly.
- **DEF-CON-002 — No unmatched delta acceptance:** `Deltas::finalize` cannot return success while an unmatched token delta remains.
- **DEF-CON-003 — Checked arithmetic closure:** no overflow/underflow/sign inversion can turn an invalid settlement into success.
- **DEF-CON-004 — Transfer matcher correctness:** `sub_add`/`finalize_into` preserve value and ownership mapping under all represented entries.
- **DEF-FEE-001 — Fee boundedness:** fee is nonnegative and never exceeds the charged amount under valid rate configuration.
- **DEF-FEE-002 — Fee rounding:** ceiling/floor behavior and closure exceptions match the specification at all boundaries.
- **DEF-FEE-003 — Fee collector credit:** every assessed fee is credited exactly once to the intended collector.

## DEFUSE replay and signature binding

- **DEF-NON-001 — Commit at most once:** a nonce commit succeeds once and subsequent commits fail.
- **DEF-NON-002 — Cleanup safety:** cleanup cannot make a nonce reusable while the corresponding signed request remains valid.
- **DEF-NON-003 — Legacy/versioned coherence:** dual stores and version parsing cannot allow the same effective nonce twice.
- **DEF-NON-004 — Magic-prefix policy:** malformed bytes with the versioned magic prefix cannot create an unintended security downgrade.
- **DEF-SIG-001 — Contract binding:** a valid signature for contract A is rejected by contract B.
- **DEF-SIG-002 — Signer/key binding:** a valid payload cannot execute for a different account or unauthorized key.
- **DEF-SIG-003 — Domain separation:** no cross-standard/cross-chain signature replay among supported payload types.
- **DEF-SIG-004 — Exact message binding:** extraction/hash/verification operate over consistent bytes and canonical fields.
- **DEF-SIG-005 — Failure atomicity:** invalid signature or failed execution cannot leave a durable exploitable nonce/state change.

## DEFUSE async custody

- **DEF-ASY-001 — FT resolve conservation.**
- **DEF-ASY-002 — NFT resolve ownership exclusivity.**
- **DEF-ASY-003 — MT per-item resolve conservation and vector-shape safety.**
- **DEF-ASY-004 — Malformed callback policy cannot benefit an attacker beyond stated trust assumptions.**
- **DEF-ASY-005 — Locked-account refunds remain safe and cannot become an outgoing-transfer bypass.**
- **DEF-ASY-006 — Storage-deposit/unwrap failure composes correctly with withdrawal refund.**
- **DEF-ASY-007 — Callback settlement occurs at most once under all reachable invocation paths.**

## Escrow

- **ESC-CON-001 — Global value conservation.**
- **ESC-CON-002 — Price and fill bounds.**
- **ESC-CON-003 — Fee boundedness and exact attribution.**
- **ESC-ASY-001 — `in_flight` accurately represents unresolved transfers.**
- **ESC-ASY-002 — Callback success/refund changes state exactly once.**
- **ESC-CLS-001 — Close authority and expiry rules do not seize counterparty value.**
- **ESC-CLN-001 — Cleanup only deletes a value-free, callback-free terminal state.**
- **ESC-LAF-001 — Lost-and-found retries cannot duplicate payout or erase recoverable value.**

## Authorization, migration, and simulation

- **AUTH-001 — Entry-point authorization matrix completeness.**
- **AUTH-002 — Lock semantics across direct, intent, callback, refund, and force paths.**
- **AUTH-003 — Role/feature separation for FAR and force methods.**
- **AUTH-004 — Key/predecessor-auth transitions cannot cause unauthorized takeover.**
- **MIG-001 — Account migration preserves balances and token identities.**
- **MIG-002 — Account migration preserves keys, nonces, flags, and lock state.**
- **MIG-003 — Version-prefix decoding is unambiguous for supported legacy values.**
- **SIM-001 — Cached and real state return the same synchronous result/error.**
- **SIM-002 — Cached and real state make the same event-emission decisions.**
- **SIM-003 — Cached balance/auth/nonce deltas equal real pre-promise deltas.**

## Wallet

- **WAL-NON-001 — Dual-window nonce is accepted at most once while valid.**
- **WAL-NON-002 — Rotation/cleanup cannot resurrect a valid request.**
- **WAL-SIG-001 — Signer/chain/domain/request binding.**
- **WAL-AUT-001 — Only signature mode or enabled extensions execute requests.**
- **WAL-AUT-002 — Removing the last authorization path is rejected.**
- **WAL-PRO-001 — Self-calls and unsupported account-mutating promise actions are unreachable.**
- **WAL-VAR-001 — Ed25519, WebAuthn variants, and no-sign mode preserve intended separation.**