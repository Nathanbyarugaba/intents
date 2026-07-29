# Critical Vulnerability Review — NEAR Intents (Defuse)

**Commit:** `3c2388e` · **Branch:** `cursor/critical-vulnerability-report-a966`
**Scope (in):** custody, authorization, replay, settlement conservation, async refund
resolution, migration integrity, wallet control.
**Scope (out):** escrow-swap; DoS; griefing without attacker profit; unbounded gas/storage;
**Protocol-fee bypass for NEP-245 fungible MT splits and all variants** (the
`TokenDiff::token_fee` `amount == 1 ⇒ Pips::ZERO` behavior — known/excluded).

## Verdict

**No Critical/High *custody* vulnerability was found or reproduced within the stated scope.**
Real settlement, replay, and async custody paths are solvent/conservative under all tested
interleavings. Differential testing did surface **one Medium simulation-correctness bug**
(FINDING SIM-01) — a violation of the documented SIM invariant that affects only the read-only
`simulate_intents` view, not real execution. See §Findings.

The core custody invariants were checked with machine-assisted methods driving **production**
`defuse_core` code:

- randomized property harnesses (proptest) over the real engine (100k+ cases each),
- Kani bounded proofs of the crypto-free fee-rate algebra,
- Quint models of the asynchronous FT withdraw/resolve, deposit-refund, and NFT-exclusivity
  lifecycles under adversarial promise interleavings.

One lower-severity, out-of-scope trust-boundary observation is documented in §Observations.

---

## 1. Properties checked

| ID | Property | Method | Result |
|----|----------|--------|--------|
| DEF-CON-002/004 | `TransferMatcher::finalize` accepts a settlement **iff** every token nets to zero; reported imbalance equals the true net | proptest (real matcher) | holds, 20k cases |
| DEF-CON-001 | End-to-end `TokenDiff` + fee + production `closure_deltas` counter-order conserves total supply of every token and finalizes | proptest (real `Engine`/`Deltas`) | holds, 30k cases |
| DEF-CON-001 | **Multi-party** (N signers + `closure_many` counter-order) conserves every token and finalizes | proptest (real `Engine`) | holds, 30k cases |
| DEF-CON-001 | Internal `Transfer` conserves total supply and finalizes | proptest (real `Engine`) | holds |
| DEF-FEE-001 | `Pips::from_pips` accepts exactly `0..=MAX`; `invert` is an involution complementing to `MAX` | **Kani (exhaustive)** | proved |
| DEF-FEE-001 | `fee(a) ≤ fee_ceil(a) ≤ a`, rounding gap ≤ 1 | proptest | holds, 100k cases |
| DEF-CON-003 | `CheckedMulDiv` (256-bit) ceil/floor relation & no false success | proptest | holds, 100k cases |
| DEF-FEE-002 | `token_fee` classification (NEP-141 always; NFT never; MT iff `amount>1`) | proptest | holds, 50k cases |
| DEF-NON-004 | `VersionedNonce::maybe_from` is prefix-gated and a faithful round-trip bijection | proptest | holds, 50k cases |
| DEF-NON-001 | Production `Nonces` bitmap accepts each nonce at most once; cleanup clears | unit (real `Nonces`) | holds |
| DEF-ASY-001/007 | FT withdraw/resolve keeps defuse **solvent** (`internal ≤ external`) under all interleavings with a compliant token; callback settles once | Quint model-check | holds, 300k runs |
| DEF-ASY-003/006 | Deposit + `resolve_deposit_internal` refund (`min(requested, deposited, balance_left)`) preserves solvency even when the receiver spends the deposit before resolve; the `balance_left` cap is load-bearing (mutant without it → insolvency) | Quint model-check + mutant | holds, 200k runs |
| DEF-ASY-002 | NFT internal supply is always in {0,1} (no duplication) and never held internally while gone externally, across deposit/withdraw/resolve cycles | Quint model-check | holds, 200k runs |
| WAL-PRO-001 | No account-mutating NEAR action can be represented/deserialized as a `NearAction`; only nearcore tags {2 FunctionCall, 3 Transfer, 11 DeterministicStateInit} decode | proptest + exhaustive discriminant scan | holds |
| SIM-001/003 | `simulate` (CachedState) vs `execute` (real) parity on success/failure, events, and balances | differential proptest + regression | **VIOLATED** → FINDING SIM-01 (simulation-only) |

## 2. Evidence & exact commands

```bash
# Randomized property harnesses over production defuse_core (via in-memory State mock)
cargo test -p defuse-verification-harnesses

# Kani bounded proofs (fee-rate algebra). NOTE: Kani's bundled toolchain is
# rustc 1.93-nightly; the workspace MSRV (1.95) must be *temporarily* lowered to
# run Kani (do NOT commit that change). defuse-crypto uses `cfg_select` (1.96 std)
# so Kani cannot compile the defuse-core tree — hence the isolated leaf crate.
#   (temporarily set workspace.package.rust-version = "1.85.0", then:)
cargo kani -p defuse-verification-kani-arith
cargo test -p defuse-verification-kani-arith     # proptest side, real toolchain

# SIM parity differential harness (surfaces FINDING SIM-01)
cargo test -p defuse-verification-harnesses sim::tests::finding_sim01_cached_stale_zero_readback
cargo test -p defuse-verification-harnesses sim::tests::finding_sim01_cached_double_spend_accepted
cargo test -p defuse-verification-harnesses -- --ignored sim_execute_parity   # broad parity (fails until fixed)

# Quint async models (withdraw/resolve, deposit-refund, NFT exclusivity)
quint run verification/quint/defuse_ft_withdraw.qnt      --invariant=inv         --max-steps=14 --max-samples=300000
quint run verification/quint/defuse_mt_deposit_resolve.qnt --invariant=inv_correct --max-steps=10 --max-samples=200000
quint run verification/quint/defuse_nft_exclusivity.qnt  --invariant=inv         --max-steps=16 --max-samples=200000
```

Observed results: all proptest suites `ok` (14 + 3 tests); Kani `2 successfully verified
harnesses, 0 failures`; Quint `inv`: `[ok] No violation found` over 300k traces.

## 3. Assumptions & bounds

- Cryptographic primitives (`ed25519_dalek`, `p256`, host `keccak`) are trusted.
- The `MockState` faithfully mirrors the inner contract state semantics the engine relies on
  (checked balances; deposits allowed to locked accounts; sub/withdraw rejected on locked;
  withdraw/mint/burn are external and not delta-matched).
- Kani proofs are exhaustive over their input types (`u32` rate space) but are limited to the
  crypto/`bnum`-free algebra (see §Gaps).
- Quint model: one token abstracted as aggregate `internal`/`external` integers; ≤2 concurrent
  in-flight withdrawals; per-withdrawal amount ≤3; start balance 5; ≤14 steps. Promise outcomes
  modeled: `ft_transfer` ok/fail, `ft_transfer_call` `Ok(Ok(used))`/`Ok(Err)`/`Err`.

## 4. Counterexamples

- **FINDING SIM-01** (simulate/execute divergence): `finding_sim01_cached_stale_zero_readback`
  and `finding_sim01_cached_double_spend_accepted` in `verification/harnesses/src/sim.rs` — see
  §Findings. Deterministic.
- **Within scope (compliant token, async custody):** none. `inv` holds across 300k randomized
  interleavings.
- **Trust-boundary witness (out of scope):** with a **malicious/non-conforming** token, the
  unguarded `solvency_always` invariant is violated — a token that keeps the transferred amount
  yet returns malformed data (`Ok(Err)`) from `ft_transfer_call` drives `internal > external`.
  This is isolated to that token's own pool (a malicious token can already rug its own holders)
  and matches the documented trust model; it is **not** a cross-asset theft and requires no
  action. See `run malicious_insolvency_witness` and the `solvency_always` counterexample.
- The model also surfaced that exact `internal == external` at rest does **not** always hold:
  a genuinely failed `ft_transfer` is intentionally **not** refunded (NEP-141 gas-vuln
  rationale), yielding a **surplus** (`external > internal`) — over-collateralized and safe; a
  documented user-loss case (out of scope). Hence the safety property is solvency, not equality.

## 5. Coverage / witnesses

- proptest exercises: matched/unmatched/overflow settlements; zero/`u128::MAX` fee amounts;
  every `token_fee` token class; legacy vs versioned nonces; commit/cleanup.
- Quint reachability witnesses: success, refund, failed-transfer, malformed-callback, and the
  adversarial insolvency branch are all reachable.

## 6. Mutation results (non-vacuity)

- `settlement::tests::mutation_accepting_unbalanced_is_caught` — feeding the harness the `Ok`
  a buggy matcher would return for a `+7` unbalanced batch **panics** (“VALUE CREATED/DESTROYED”). ✔
- `settlement::tests::mutation_misreported_imbalance_is_caught` — a matcher that under-reports
  the imbalance is **caught**. ✔
- Quint: the `solvency_always` counterexample and the `settled_balanced→no_over_credit_at_rest`
  correction confirm the invariants are live (not vacuously true).
- Quint (deposit refund): the `capByBalance=false` mutant of `resolve_deposit_internal` reaches a
  negative receiver balance / insolvency, proving the production `balance_left` cap is
  load-bearing. ✔

## 7. Remaining gaps

- **Kani + `bnum`:** the wide `fee_ceil`/`mul_div` (256-bit `BUint<4>`) proofs are intractable
  under Kani (data-dependent shift loops explode CBMC unwinding). Covered by 100k-case proptest
  instead. A future improvement is a hand-abstracted mul-div spec for Kani.
- **Kani + defuse-core:** `cfg_select` in `defuse-crypto` blocks Kani from compiling the full
  engine; the end-to-end conservation proof therefore uses proptest rather than Kani.
- **NEP-171/NEP-245 async & sandbox:** the Quint model covers the FT lifecycle; the NFT/MT
  resolve variants and a `near-workspaces` sandbox reproduction with an adversarial token remain
  as follow-ups (the code paths are structurally analogous and were reviewed statically).
- Wallet: the action allow-list is now covered at the deserialization boundary (WAL-PRO-001).
  The self-call guard (`receiver_id == current_account_id`) and lockout (WAL-AUT-002) require a
  near-sdk VM context and remain unit-test candidates in the wallet crate.
- Simulation-parity (SIM-*) is now differentially tested at the core level and produced
  FINDING SIM-01. Extending to auth/nonce deltas (SIM-003 full) and event-decision parity under
  more intent kinds remains a follow-up.

## 8. Files changed

- `verification/harnesses/**` — proptest + Kani harnesses driving production `defuse_core`
  (settlement, conservation, fees, nonce) via an in-memory `State` mock; mutation tests.
- `verification/kani-arith/**` — isolated Kani proofs for the `Pips` fee-rate algebra.
- `verification/quint/defuse_ft_withdraw.qnt` — async FT withdraw/resolve model.
- `verification/quint/defuse_mt_deposit_resolve.qnt` — deposit + `resolve_deposit_internal`
  refund model (balance-cap load-bearing).
- `verification/quint/defuse_nft_exclusivity.qnt` — NFT ownership-exclusivity model.
- `verification/harnesses/src/wallet.rs` — wallet action allow-list (decode-boundary) harness.
- `verification/harnesses/src/sim.rs` — simulate/execute differential parity harness (found
  FINDING SIM-01) + regression tests + positive control.
- `verification/reports/critical-review-a966.md` — this report.
- `Cargo.toml` — added the two verification crates as workspace members (no production behavior
  change). The Kani MSRV workaround (`rust-version`) is applied only transiently and is **not**
  committed.

## Findings

### FINDING SIM-01 — `CachedState::balance_of` returns a stale balance after a cached value reaches zero (simulation-only). Severity: **Medium**

- **Affected commit / feature / paths:** `3c2388e`; feature `contract`;
  `contracts/defuse/core/src/engine/state/cached.rs` (`CachedState::balance_of`,
  `CachedState::internal_sub_balance`/`internal_add_balance`), interacting with
  `contracts/defuse/core/src/amounts.rs` (`Amounts` over `DefaultMap`, which deletes
  zero-valued entries). Reached via `Contract::simulate_intents`
  (`contracts/defuse/src/contract/intents/mod.rs:47`, the only `.cached()` caller).
- **Violated invariant:** SIM-001 / SIM-003 — "cached (simulate) and real (execute) return the
  same synchronous result/error and the same balance deltas."
- **Public entry point & call chain:** `simulate_intents(signed)` → `Engine::new(self.cached())`
  → `execute_signed_intents` → `TokenDiff`/`Transfer`/withdraw `execute_intent` →
  `Deltas::internal_sub_balance` → `CachedState::internal_sub_balance` /
  `CachedState::balance_of`.
- **Root cause:** `CachedState` is a two-layer buffer (cache map over a read-only base view).
  `Amounts` uses a `DefaultMap` that **removes an entry once it becomes 0**. So when a cached
  balance is debited to exactly `0`, its cache entry is deleted. Subsequently:
  - `balance_of` finds no cache entry and **falls back to the base view**
    (`self.view.balance_of(...)`), returning the *original* on-chain balance instead of `0`;
  - `internal_sub_balance`/`internal_add_balance` see `token_amounts.get(id).is_none()` and
    **re-copy the base balance**, so the spent-to-zero amount is re-initialised from on-chain.
  The real single-layer `Contract` state has no base-view fallback (`amount_for` returns `0` for
  an absent entry), so execution is correct — the defect is exclusive to `CachedState`.
- **Attacker prerequisites / trusted roles:** none beyond crafting signed intents; no special
  role. But see impact/scope below.
- **Deterministic reproduction:** `verification/harnesses/src/sim.rs`:
  - `finding_sim01_cached_stale_zero_readback` — after crediting `+351` then debiting `-1351`
    on a balance of `1000` (net `0`), execute reports `0` while simulate reports `1000`.
  - `finding_sim01_cached_double_spend_accepted` — spending `1000` then `1000` again:
    `execute` rejects the second (insufficient), `simulate` **accepts** it.
  - `parity_holds_without_zero_crossing` (positive control) — parity holds when no balance is
    driven to exactly zero, isolating the defect to the zero-cleanup fallback.
- **Before/after state:** simulate can report a batch as solvent/successful (and emit transfer
  previews) for intents that real execution correctly rejects with `BalanceOverflow` /
  `InvariantViolated`.
- **NEAR semantic validation:** `simulate_intents` is a view call; it does not persist state or
  move funds. `execute_intents` uses the real state and is unaffected.
- **Impact / severity rationale:** **No direct loss of funds or unauthorized access** — real
  execution is correct, so custody is safe. Impact is limited to inaccurate simulation:
  integrators (relayers/solvers) that rely on `simulate_intents` to pre-check solvency or preview
  transfers can be misled into submitting a batch that then fails on-chain (wasted gas) or into
  mispricing. Because the only attacker-facing exploitation (feeding a solver a batch that
  simulates-OK but executes-FAIL) yields no attacker profit, that vector is out of scope
  (griefing); the underlying **invariant violation is in scope** (simulation must match
  execution) and is a genuine correctness defect → Medium.
- **Minimal remediation direction:** make the cache layer distinguish "absent" from
  "explicitly zero". Options: (a) have `CachedState` track the set of *touched* tokens per
  account and, for touched tokens, treat a missing map entry as `0` (do not fall back to the
  view / do not re-copy the base); or (b) use a non-cleaning map for the cache layer so a `0`
  entry is retained; or (c) store `Option<u128>`/a "shadowed" marker in the cache.
- **Regression property/test:** the three `sim.rs` tests above; when fixed, the two `finding_*`
  tests (which currently assert the buggy values) will fail and must be updated to assert parity,
  and the ignored `sim_execute_parity` proptest should be un-ignored.

## Observations (lower severity, out of scope)

- **O-1 (malicious-token insolvency, informational):** as in §4, `ft_resolve_withdraw` treating
  a successful-but-malformed `ft_transfer_call` result (`Ok(Err)`) as `used = 0` (full internal
  refund) can over-credit if a non-compliant token simultaneously keeps the tokens. Impact is
  confined to that token's pool and consistent with the trust model. If desired, defensive
  hardening would treat `Ok(Err)` like `Err` (no refund) for `*_transfer_call`, matching the
  existing gas-vuln rationale — but this trades a user-loss risk for the (already-accepted)
  malicious-token risk and is not a scoped vulnerability.
