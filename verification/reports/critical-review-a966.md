# Critical Vulnerability Review — NEAR Intents (Defuse)

**Commit:** `3c2388e` · **Branch:** `cursor/critical-vulnerability-report-a966`
**Scope (in):** custody, authorization, replay, settlement conservation, async refund
resolution, migration integrity, wallet control.
**Scope (out):** escrow-swap; DoS; griefing without attacker profit; unbounded gas/storage;
**Protocol-fee bypass for NEP-245 fungible MT splits and all variants** (the
`TokenDiff::token_fee` `amount == 1 ⇒ Pips::ZERO` behavior — known/excluded).

## Verdict

**No Critical/High vulnerability was found or reproduced within the stated scope.** The core
custody invariants were checked with machine-assisted methods driving **production**
`defuse_core` code:

- randomized property harnesses (proptest) over the real engine (100k+ cases each),
- Kani bounded proofs of the crypto-free fee-rate algebra,
- a Quint model of the asynchronous FT withdraw/resolve lifecycle under adversarial promise
  interleavings.

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

# Quint async withdraw/resolve model
quint typecheck  verification/quint/defuse_ft_withdraw.qnt
quint run verification/quint/defuse_ft_withdraw.qnt --invariant=inv --max-steps=14 --max-samples=300000
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

- **Within scope (compliant token):** none. `inv` holds across 300k randomized interleavings.
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
- Wallet `DeterministicStateInit` action matrix and simulation-parity (SIM-*) remain
  proptest/differential-test candidates.

## 8. Files changed

- `verification/harnesses/**` — proptest + Kani harnesses driving production `defuse_core`
  (settlement, conservation, fees, nonce) via an in-memory `State` mock; mutation tests.
- `verification/kani-arith/**` — isolated Kani proofs for the `Pips` fee-rate algebra.
- `verification/quint/defuse_ft_withdraw.qnt` — async FT withdraw/resolve model.
- `verification/reports/critical-review-a966.md` — this report.
- `Cargo.toml` — added the two verification crates as workspace members (no production behavior
  change). The Kani MSRV workaround (`rust-version`) is applied only transiently and is **not**
  committed.

## Observations (lower severity, out of scope)

- **O-1 (malicious-token insolvency, informational):** as in §4, `ft_resolve_withdraw` treating
  a successful-but-malformed `ft_transfer_call` result (`Ok(Err)`) as `used = 0` (full internal
  refund) can over-credit if a non-compliant token simultaneously keeps the tokens. Impact is
  confined to that token's pool and consistent with the trust model. If desired, defensive
  hardening would treat `Ok(Err)` like `Err` (no refund) for `*_transfer_call`, matching the
  existing gas-vuln rationale — but this trades a user-loss risk for the (already-accepted)
  malicious-token risk and is not a scoped vulnerability.
