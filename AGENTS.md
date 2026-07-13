# NEAR Intents Security Verification Instructions

## Mission

Use this repository to find and eliminate **Critical or High severity** defects affecting custody, authorization, replay resistance, settlement conservation, asynchronous refund resolution, escrow lifecycle, migration integrity, or wallet control.

Jules is the coding and orchestration agent. Kani/Quint outputs and deterministic implementation reproductions are the evidence. Do not treat the model's prose as proof.

## Default change policy

Unless the task explicitly says “patch production code,” do not modify production behavior under `contracts/` or `crates/`.

Permitted by default:

- `verification/**` proof models, harnesses, plans, traces, and reports;
- narrowly scoped test-only code or `cfg(kani)` annotations that do not affect production artifacts;
- documentation and CI drafts;
- verification-only workspace crates that call production code.

Forbidden unless explicitly authorized:

- weakening assertions, invariants, postconditions, or assumptions to make a proof pass;
- replacing production logic with an unverified copy;
- stubbing the function being proved;
- changing production code and the specification in the same step without showing the original counterexample;
- reporting a vulnerability before establishing reachability and a deterministic reproduction.

## Repository orientation

Primary custody contract:

- `contracts/defuse/`
- core intent engine: `contracts/defuse/core/src/engine/`
- settlement deltas: `contracts/defuse/core/src/engine/state/deltas.rs`
- token-diff and fee logic: `contracts/defuse/core/src/intents/token_diff.rs`
- nonce logic: `contracts/defuse/core/src/nonce/`
- signature payloads: `contracts/defuse/core/src/payload/`
- account nonce storage: `contracts/defuse/src/contract/accounts/account/nonces.rs`
- async token withdrawal/resolution: `contracts/defuse/src/contract/tokens/`
- account/admin/force paths: `contracts/defuse/src/contract/accounts/` and adjacent admin modules

Other high-risk contracts:

- escrow: `contracts/escrow-swap/`
- wallet: `contracts/wallet/` and `crates/wallet/core/`
- signature crates: `crates/signatures/`
- fee primitives: `crates/primitives/fees/`

The workspace uses Rust 1.96.0, edition 2024, and the `wasm32-unknown-unknown` target.

## Baseline commands

Run and record the exact command and result relevant to the changed scope:

```bash
cargo fmt --all --check
RUST_LOG=warn taplo format --check
cargo clippy --workspace --all-targets --no-deps
cargo test --all
make check-contracts
```

For a small verification task, begin with scoped tests and run broader commands before finalizing. Never claim a command passed unless it was actually run in the current task.

Important contract build variants include:

- Defuse: `contract`; `contract,far`; and relevant `imt` configurations.
- Escrow: default `auth_call,nep141,nep245` plus supported reduced feature combinations.
- Wallet: `contract,ed25519`; `contract,webauthn-ed25519`; `contract,webauthn-p256`; and `contract` no-sign mode.

## Threat model

Model these principals separately:

- arbitrary external account;
- legitimate signer whose signed payload may be observed and replayed;
- malicious matcher/relayer;
- malicious or nonconforming token contract/receiver;
- account that becomes locked between asynchronous steps;
- authorized force role;
- DAO/upgrade authority;
- callback receipts executing in any order permitted by NEAR;
- honest cryptographic primitive with adversarial bytes around it.

Do not assume callbacks arrive successfully, return valid JSON, return vectors of the correct length, or return values bounded by the requested amount. Do not invent synchronous EVM-style reentrancy; instead model NEAR promise interleavings and validate runtime assumptions.

## Evidence labels

Use one label in every proof/finding report:

- **Implementation proof**: actual Rust code checked by Kani, within named assumptions/bounds.
- **Model proof**: Quint model checked; implementation correspondence is separate.
- **Refinement evidence**: traces/model-based tests compare model and implementation.
- **Testing evidence**: unit/property/fuzz/sandbox result only.
- **Hypothesis**: not yet reachable/reproduced.

## Kani requirements

Each Kani harness must:

1. State one security property.
2. Invoke production code or a justified adapter.
3. List all assumptions and collection/loop bounds.
4. Add `kani::cover!` or equivalent witnesses for relevant branches and boundary classes.
5. Complete with no failed unwinding checks.
6. Include a separate full-width arithmetic harness where collection bounds would otherwise reduce numeric scope.
7. Produce concrete playback or a deterministic Rust test for a failure.
8. Pass a mutation test: deliberately remove or invert the relevant protection and confirm the harness fails.

Avoid broad harnesses that time out. Prove small lemmas and compose them. Experimental Kani contracts/stubs must be identified as such, and a target function must not be replaced by an unverified stub.

## Quint requirements

Each Quint model must:

1. Link every action and state variable to implementation paths/functions.
2. Declare the abstraction and omitted behavior.
3. Model arbitrary legal asynchronous ordering and explicit promise outcomes.
4. Start with safety invariants; state fairness assumptions for any liveness property.
5. Include sanity witnesses showing success, failure, refund, terminal, and adversarial branches are reachable.
6. Run simulation for model debugging, then model checking for the claimed bounded scope.
7. Export a counterexample trace on failure.
8. Replay representative and failing traces against Rust/NEAR tests.

A verified Quint model is not an implementation proof by itself.

## Critical invariants

### Settlement

For every token, a completed batch cannot create value. Debits must equal credits, fees, and explicit external transfers; unmatched deltas cause failure. Checked arithmetic and conversions cannot change sign or wrap.

### Replay/signatures

An accepted signed request is usable at most once in its authorization scope. Signature bytes bind signer/key, verifying contract, standard/domain, deadline, nonce, and exact message. Cleanup cannot resurrect a still-valid replay.

### Async transfer resolution

For each debited amount:

```text
amount = externally used + internally refunded + explicitly modeled irrecoverable/lost
```

Never both external use and full internal refund; never duplicate callback settlement.

### Escrow

Funded value equals state-held value plus in-flight value plus final payouts/refunds/lost-found plus fees. Cleanup is permitted only after all pending and recoverable value is zero under the implementation's definition.

### Authorization

Every mutating entry point has an explicit authority predicate. Locks and role gates cannot be bypassed except documented force/refund behavior. Wallet signatures and extensions cannot be confused or replayed.

### Migration/simulation

Migration preserves all custody and authority fields. Cached simulation matches real synchronous success/error/state/event decisions, excluding only documented promise side effects.

## Finding standard

Do not call something a finding unless the report contains:

- affected commit, feature set, and paths/lines;
- violated invariant;
- public entry point and complete call chain;
- attacker prerequisites and trusted-role assumptions;
- deterministic reproduction or executable counterexample;
- before/after asset or authority state;
- NEAR semantic validation;
- severity rationale and maximum plausible impact;
- minimal remediation direction;
- regression property/test.

Prioritize Critical/High. Record lower-severity observations separately without distracting the main task.

## Output format for each task

End with:

1. Properties checked.
2. Evidence and exact commands.
3. Assumptions and bounds.
4. Counterexamples or “none within stated scope.”
5. Coverage/witness results.
6. Mutation result.
7. Remaining gaps.
8. Files changed.

Never say “formally verified” without qualifying the exact property, code/model, assumptions, bounds, tool version, and feature configuration.
