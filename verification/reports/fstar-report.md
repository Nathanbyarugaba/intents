# F\* Verification Report — NEAR Intents (defuse)

**Audited commit:** `3c2388ed3e93441379824b490eb40ac02feef45b`
**Contract in scope:** `contracts/defuse` (the "Verifier") + shared crates it depends on
(`crates/num-utils`, `crates/primitives/fees`, `crates/bitmap`).
**Toolchain:** F\* `2026.07.24` (OCaml 5.3.0 build) + Z3 `4.15.3` (bundled).
**Evidence label:** **Model proof** — F\* mechanically proves security properties over faithful,
hand-written models of the Rust logic. Per `AGENTS.md`, a Model proof is *not* an implementation proof;
where a proof would only become a finding via a counterexample, that counterexample must be reproduced
against production Rust before being reported. **No counterexample was found in scope**, so there are no
Critical/High findings from this pass (see §4). Two subtle "looks dangerous but is safe" results and one
informational observation are documented.

---

## 1. Properties checked

| ID    | Module | Obligation (proof-index) | Property (Model proof) | Result |
|-------|--------|--------------------------|------------------------|--------|
| ARITH | `Defuse.Arith.fst` | (shared) | `checked_mul_div{,_ceil,_euclid}` faithfully modeled over the 256-bit widening; the widened product never overflows, so the only failures are `div==0` / `try_into` range. | ✅ proved |
| FSM-2 | `Defuse.Fees.fst` | DEF-FEE-001 | `fee_ceil(a) <= a` for all `pips∈[0,MAX]`, all `a<2^128`; `fee <= fee_ceil <= fee+1`; monotone in pips and amount; **no-panic** (`unwrap_or_else(unreachable!)` is provably unreachable). | ✅ proved |
| FSM-1 | `Defuse.Settlement.fst` | DEF-CON-001/002/004 | The `sub_add` accounting moves an account's net by exactly ±amount and never holds both sides (⇒ `sub_add`'s `unreachable!` is dead); the greedy `finalize_into` matcher's result depends only on the per-account net sums; **`finalize` accepts a batch ⇔ every token nets to zero** (no value creation/destruction); order-independence; **overflow sentinel `Err(0)` can never collide with a genuine unmatched delta** (residual is always > 0 when unmatched). | ✅ proved |
| FSM-3 | `Defuse.Closure.fst` | FSM-3 (solver) | The advertised `supply_delta(d) + supply_delta(closure_delta(d)) == 0` round-trip holds for **all** `i128` deltas and **all** valid fees whenever the option computations are defined; definedness at extremes (`inv==0`, `i128::MIN`) returns `None` (no panic). | ✅ proved |
| FSM-4 | `Defuse.Nonce.fst` | DEF-NON-001/002/004 | Commit is at-most-once; **cleanup-by-prefix cannot resurrect a still-valid nonce** because cleanability is a function of the 248-bit word prefix alone (version/salt/deadline all lie in the prefix); versioned vs. downgraded-legacy nonces can never share a word; DEF-NON-004 downgrade characterized precisely. | ✅ proved |
| FSM-5 | `Defuse.AsyncResolve.fst` | DEF-ASY-001/007 | `used <= amount` and `used + refund == amount` in every branch — even for an over-reporting malicious token; `used`/`refund` partition the amount (no double settlement); the intentional "no refund on failed `ft_transfer_call`" branch is characterized. | ✅ proved |

Every module also contains `kani::cover!`-style **witnesses** proving each relevant branch/boundary class
is reachable (see §5).

---

## 2. Evidence and exact commands

Toolchain install (downloads pinned F\*+Z3 into `verification/fstar/.tools/`, git-ignored):

```bash
bash verification/fstar/install.sh
source verification/fstar/env.sh
```

Proofs (all modules typecheck / all properties discharged):

```bash
make -C verification/fstar verify
# ==== Defuse.Arith.fst ====      All verification conditions discharged successfully
# ==== Defuse.Fees.fst ====       All verification conditions discharged successfully
# ==== Defuse.Settlement.fst ==== All verification conditions discharged successfully
# ==== Defuse.Closure.fst ====    All verification conditions discharged successfully
# ==== Defuse.Nonce.fst ====      All verification conditions discharged successfully
# ==== Defuse.AsyncResolve.fst == All verification conditions discharged successfully
# ALL F* MODULES VERIFIED
```

Per-module flags used: `--z3version 4.15.3 --warn_error -321 --ext context_pruning --z3rlimit 60`
(FSM-3 round-trip uses `--z3rlimit 200 --fuel 2 --ifuel 2`).

Mutation / non-vacuity checks (each deliberately-broken model MUST be rejected):

```bash
source verification/fstar/env.sh && bash verification/fstar/mutations/run.sh
# OK: Mut_Fees correctly rejected
# OK: Mut_Settlement correctly rejected
# OK: Mut_Closure correctly rejected
# OK: Mut_Nonce correctly rejected
# OK: Mut_AsyncResolve correctly rejected
# ALL MUTATIONS CORRECTLY REJECTED (proofs are non-vacuous)
```

Fidelity cross-check against production Rust (the models were built to match these, and they pass on the
audited commit):

```bash
cargo test -p defuse-core --lib -- token_diff deltas amounts
# test result: ok. 52 passed; 0 failed; ... (closure_delta round-trip, deltas transfer conservation,
#                                             deltas unmatched, amounts invariant)
```

---

## 3. Assumptions and bounds

- **Transliteration assumption.** The F\* models are hand-written transliterations of the Rust; the
  transliteration itself is trusted. Mitigations: (i) each checked operation mirrors the exact rounding
  (`div`/`div_ceil`/`div_euclid`), the 256-bit widening, and the `Option` failure modes; (ii) models are
  cross-checked against the production unit tests (§2); (iii) each property has a mutation check (§6).
- **Full-width arithmetic.** FSM-2/FSM-3 reason over the full `u128`/`i128` ranges (not bounded samples),
  using unbounded-`int` models with explicit `[0,2^128)` / `[-2^127,2^127)` range checks. This is stronger
  than the sampled Rust `#[test]`s (e.g. FSM-3 covers all deltas/fees, not ~40 points).
- **Positive map entries (FSM-1).** `TokenTransferMatcher` maps are assumed to contain only strictly
  positive amounts, justified because `DefaultMap` cleanup removes zeroed entries and `sub_add` never
  inserts a 0. Modeled as `list pos`.
- **Environment predicates (FSM-4).** `is_valid_salt` and "current time" are modeled as opaque parameters
  (passed as arguments, so no axioms are introduced); the cleanup-safety theorem holds for *any* such
  predicates that read only prefix bytes.
- **Abstraction boundaries.** The pure models intentionally omit NEAR promise interleavings, gas/storage,
  serialization byte-exactness (beyond the nonce layout needed for FSM-4), and cross-contract effects.
  FSM-5 models the synchronous resolver decision table only.

---

## 4. Counterexamples

**None within the stated scope.** All stated properties were discharged by F\*/Z3. In particular the two
properties most likely to hide a custody bug were actively probed and proven safe:

- **FSM-1 overflow sentinel (`Err(0)`).** `TransferMatcher::finalize` treats a `finalize_into` residual of
  `0` as an overflow and rejects the batch. We proved the greedy matcher's residual is **strictly
  positive whenever it does not fully match** (`residual_positive`), so `Err(0)` can only originate from
  the genuine overflow/`try_into` path — it can never mask a real unmatched delta. Both the overflow and
  the non-zero-unmatched paths *reject* the batch, so a non-conserving batch cannot be accepted.
- **FSM-4 whole-word cleanup.** `cleanup_by_prefix` removes an entire 248-bit word (up to 256 nonces at
  once), which superficially looks like it could clear a still-valid nonce. We proved this is safe:
  `is_nonce_cleanable` depends only on MAGIC/version/salt/deadline, **all of which sit inside the 248-bit
  word prefix**, so every nonce sharing a word has identical cleanability; and a valid versioned nonce
  (version byte `0`) can never share a word with a downgraded/legacy nonce (version byte `≠0`) because the
  version byte is in the prefix. (Additionally, legacy nonces live in a separate map that cleanup never
  touches — `MaybeLegacyNonces::cleanup_by_prefix` only clears the new map.)

**Excluded (by request):** `escrow-swap`; the **known** NEP-245 MT-"split" protocol-fee bypass
(`TokenDiff::token_fee` returns `ZERO` for `amount <= 1`); and unbounded gas/storage. These were not
modeled and are not reported.

---

## 5. Coverage / witness results

Each module proves reachability witnesses (analogue of `kani::cover!`):

- FSM-2: `witness_full_fee` (100% fee: `fee_ceil(MAX,5)=5`), `witness_ceil_rounds_up`
  (`fee(1,1)=0`, `fee_ceil(1,1)=1`), plus zero-pips / zero-amount cases.
- FSM-1: `witness_matched`, `witness_left_senders`, `witness_left_receivers`, `witness_multi_token` —
  all four matcher outcome classes and a multi-token success are reachable.
- FSM-3: `witness_out` (a token_out delta round-trips through a fee-bearing closure); definedness at
  `inv==0` and `i128::MIN`.
- FSM-4: `witness_double_commit_rejected`, `witness_cleanup_removes_word`.
- FSM-5: `witness_over_report` (an over-reporting token is capped at `amount`); the deser-error and
  promise-error branches are characterized.

---

## 6. Mutation results

For each property a deliberately-broken variant lives in `verification/fstar/mutations/` and is **rejected**
by F\* (confirming the real proofs are non-vacuous):

| Mutation file        | Injected defect                                              | F\* result |
|----------------------|-------------------------------------------------------------|-----------|
| `Mut_Fees.fst`       | fee divisor `MAX-1` instead of `MAX`                        | rejected ✅ |
| `Mut_Settlement.fst` | matcher reports leftover receivers as `Matched`             | rejected ✅ |
| `Mut_Closure.fst`    | closure divides by fee `f` instead of `inv f = MAX-f`      | rejected ✅ |
| `Mut_Nonce.fst`      | cleanability reads the in-word bit (index 31, not in prefix)| rejected ✅ |
| `Mut_AsyncResolve.fst`| drop `.min(amount)` guard on the token-reported amount     | rejected ✅ |

Reproduce: `source verification/fstar/env.sh && bash verification/fstar/mutations/run.sh`.

---

## 7. Observations (informational — not Critical/High findings)

- **DEF-NON-004 versioned-nonce downgrade.** A 32-byte nonce beginning with `VERSIONED_MAGIC_PREFIX`
  (`5628f6c6`) but whose 5th byte (borsh enum discriminant) is `≠ 0` fails `VersionedNonce::maybe_from`
  and is therefore treated as a **legacy** nonce, so `verify_intent_nonce` performs no salt/expiry check
  (`Defuse.Nonce.downgrade_is_legacy`). Impact assessment: the signer chooses their own nonce, legacy
  nonces remain permitted at the audited commit, and (per §4) such a nonce cannot be resurrected via
  cleanup. This is a **specification/robustness observation**, not a custody vulnerability. Suggested
  hardening (optional): reject nonces that carry the magic prefix but fail versioned parsing, instead of
  silently downgrading to legacy.

---

## 8. Remaining gaps

- NEAR **async promise interleavings** for withdrawal/refund (DEF-ASY-004/005/006) are not modeled in pure
  F\*; FSM-5 covers only the synchronous resolver decision table. A Quint model (per the repo plan) remains
  the right tool for interleavings.
- **Escrow** (`escrow-swap`), **wallet**, **migration/simulation** (MIG-*/SIM-*), and multi-standard
  **signature domain separation** (DEF-SIG-*) are out of scope for this F\* pass.
- FSM-1's account-level conservation is proved at the net-sum granularity; a byte-exact model of the
  `HashMap` iteration order and `Transfers` event assembly is not attempted (not needed for the
  value-conservation property, which is order-independent).
- These are **Model proofs**; elevating any to an *implementation proof* would require either a Kani
  harness on the Rust directly or refinement evidence (trace equivalence) linking model and code.

---

## 9. Files changed

Added under `verification/` only (no production code modified):

- `verification/fstar/Defuse.Arith.fst` — checked-arithmetic primitives + division lemmas.
- `verification/fstar/Defuse.Fees.fst` — FSM-2.
- `verification/fstar/Defuse.Settlement.fst` — FSM-1.
- `verification/fstar/Defuse.Closure.fst` — FSM-3.
- `verification/fstar/Defuse.Nonce.fst` — FSM-4.
- `verification/fstar/Defuse.AsyncResolve.fst` — FSM-5.
- `verification/fstar/mutations/*` — non-vacuity checks + `run.sh`.
- `verification/fstar/{Makefile,README.md,install.sh,env.sh,.gitignore}` — reproducible toolchain.
- `verification/reports/fstar-report.md` — this report.
- `verification/proof-index.md` — cross-references to FSM-1..5 (doc update).
