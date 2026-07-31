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
| FSM-6 | `Defuse.SigDomain.fst` | DEF-SIG-003 | **No cross-standard signature replay**: recovered-key **curve partition** (ed25519 / secp256k1 / p256) blocks replay across families; within the ed25519 family, the four "plain" standards (NEP-413/SEP-53/TonConnect/RawEd25519) sign **disjoint byte strings** (distinct SHA-256 domain prefixes modulo collision resistance, and length separation for the raw JSON); signer/key binding (`has_public_key`) modeled. | ✅ proved |
| FSM-7 | `Defuse.MtResolve.fst` | DEF-ASY-003 | MT `mt_resolve_transfer` per-item conservation `used + refund == amount` even under adversarial callbacks (over-reported refund, wrong-length vector → full-refund fallback); receiver→sender move is value-preserving; over a duplicated-token sequence the receiver is **never overdrawn**. | ✅ proved |
| FSM-8 | `Defuse.NftResolve.fst` | DEF-ASY-002 | NFT `nft_resolve_withdraw` unit is **either used or refunded, never both nor lost** (`receiver_units + sender_units == 1`); the failed-`nft_transfer_call` "keep" branch is characterized. | ✅ proved |
| FSM-9 | `Defuse.LockAuth.fst` | AUTH-002, DEF-ASY-005 | **Locked-account freeze**: a locked, non-forced account can never be debited, have its authorization changed (keys / auth-by-predecessor), or commit a nonce; its balances are **non-decreasing**; since every signed intent commits a nonce first, a locked account cannot execute any signed intent; the access-controlled **force** role is the sole lock bypass. | ✅ proved |
| FSM-11 | `Defuse.Migration.fst` | MIG-001/002/003 | Account migration: magic-prefix discriminator is unambiguous (legacy prefix < u32::MAX); `decode(encode(a)) == a`; `V0`/`V1 → Account` preserve balances, keys, nonces, flags & lock (V0 defaults characterized); a migrated (legacy) nonce stays used and **cleanup can never resurrect it**. | ✅ proved |
| FSM-12 | `Defuse.AsyncLifecycle.fst` | DEF-ASY-007/005/001 | **Async withdrawal lifecycle under an adversarial scheduler**: value is conserved (`Σ balance + in-flight + externally-settled` constant) across ANY interleaving of initiations/resolutions; each withdrawal settles **at most once** (repeat/late callbacks are no-ops); synchronous debit ⇒ no double-spend; refunds to accounts locked mid-flight stay conservative. | ✅ proved |
| FSM-13 | `Defuse.WalletPromise.fst` | WAL-PRO-001 | **Wallet cannot be made to take over its own account**: an accepted wallet promise never self-calls and carries only safe actions (FunctionCall/Transfer/DeterministicStateInit); dangerous/account-mutating actions are rejected (and aren't even representable in the flat 3-variant `NearAction`); every fan-out promise is checked. | ✅ proved |
| FSM-14 | `Defuse.WalletAuth.fst` | WAL-AUT-002 | **No lockout**: any op sequence preserves `signature_enabled ∨ extensions ≠ ∅` (at least one authorization path always remains); `check_lockout` blocks disabling the last path; redundant toggles are rejected. | ✅ proved |
| FSM-15 | `Defuse.WalletNonce.fst` | WAL-NON-001/002 | **Dual-window nonce**: a committed message cannot be replayed while still valid — retention (≥ `timeout`) provably exceeds the validity window (`min(self.timeout, msg.timeout) ≤ timeout`), so the used-bit test rejects a live replay across ANY adversarial cleanup/rotation schedule. | ✅ proved |
| FSM-16 | `Defuse.PoaAuth.fst` | AUTH-003 | **PoA bridge: no unauthorized mint** — a mint is reachable only by the token owner (= the factory) or a caller holding DAO\|TokenDepositer; `deploy_token` requires DAO\|TokenDeployer and the deployed token is owned by the factory (never attacker-pre-owned); paused ⇒ deploy/mint rejected; a role-less non-factory principal can neither mint nor deploy. | ✅ proved |
| FSM-17 | `Defuse.PoaToken.fst` | (PoA custody) | PoA token supply is conserved (`supply == acting_balance + rest`) across mint/burn/transfer; mint is owner-only; burn requires sufficient balance (no underflow); dot-free token names map **injectively** to account ids (no account spoofing). | ✅ proved |
| FSM-18 | `Defuse.SimRefine.fst` | SIM-001/002/003 | **`simulate_intents` faithfully predicts `execute_intents`**: the two `State` impls (`CachedState` vs `Contract`) make the **same accept/reject decision** for every mutating method (debit, auth, nonce), so a simulation cannot report a success/failure that real execution would contradict — **except** `internal_add_balance` at `amount == 0` (SIM-001, unreachable from a well-formed intent), which is characterized exactly. | ✅ proved |

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
# ==== Defuse.Arith.fst ====        All verification conditions discharged successfully
# ==== Defuse.Fees.fst ====         All verification conditions discharged successfully
# ==== Defuse.Settlement.fst ====   All verification conditions discharged successfully
# ==== Defuse.Closure.fst ====      All verification conditions discharged successfully
# ==== Defuse.Nonce.fst ====        All verification conditions discharged successfully
# ==== Defuse.AsyncResolve.fst ==== All verification conditions discharged successfully
# ==== Defuse.SigDomain.fst ====    All verification conditions discharged successfully   (Phase 2)
# ==== Defuse.MtResolve.fst ====    All verification conditions discharged successfully   (Phase 2)
# ==== Defuse.NftResolve.fst ====   All verification conditions discharged successfully   (Phase 2)
# ==== Defuse.LockAuth.fst ====     All verification conditions discharged successfully   (Phase 3)
# ==== Defuse.AsyncLifecycle.fst == All verification conditions discharged successfully   (Phase 4)
# ==== Defuse.Migration.fst ====    All verification conditions discharged successfully   (Phase 4)
# ==== Defuse.WalletPromise.fst === All verification conditions discharged successfully   (Phase 5)
# ==== Defuse.WalletAuth.fst ====   All verification conditions discharged successfully   (Phase 5)
# ==== Defuse.WalletNonce.fst ====  All verification conditions discharged successfully   (Phase 5)
# ==== Defuse.PoaAuth.fst ====      All verification conditions discharged successfully   (Phase 6)
# ==== Defuse.PoaToken.fst ====     All verification conditions discharged successfully   (Phase 6)
# ==== Defuse.SimRefine.fst ====    All verification conditions discharged successfully   (Phase 7)
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

# Phase 2 fidelity: signature domain prefixes + payload verify/hash
cargo test -p defuse-nep413 -p defuse-erc191 -p defuse-tip191 -p defuse-sep53   # all pass
cargo test -p defuse-core --lib -- payload
# test result: ok. 3 passed (payload::multi::raw_ed25519, payload::webauthn::{p256,ed25519})

# Phase 3/4 fidelity: account/lock + migration + cross-migration nonces
cargo test -p defuse-core --lib -- account          # 3 passed
cargo test -p defuse --lib -- entry nonces
# test result: ok. 8 passed (legacy_upgrade, versioned_upgrade::case_1_v0,
#   legacy_nonces_cant_be_cleared, commit_existing_legacy_nonce, new_from_legacy, ...)

# Phase 5 fidelity: wallet + flat NearPromise
cargo test -p defuse-wallet          # pass (incl. Nonces::commit doctest: dual-window used-bit reject)
cargo test -p defuse-near-promise    # 12 pass (incl. borsh_has_not_changed: flat promise layout)

# Phase 6 fidelity: PoA crates compile; behavior exercised by integration tests
cargo test -p defuse-poa-token -p defuse-poa-factory   # crates compile (unit tests: none)
#   PoA deploy/deposit/authorization are covered by integration tests in tests/src/tests/poa/mod.rs
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
  FSM-5/7/8 model the synchronous resolver decision tables only.
- **NEAR runtime assumptions (FSM-12).** The model trusts the NEAR guarantees that a `.then(...)`
  callback fires **exactly once** and that `#[private]` restricts it to the contract itself; the resolver
  removing/marking the pending withdrawal is what makes a repeat/late callback a no-op. The model is a
  single-token/-account operational abstraction; conservation generalizes pointwise across
  (account, token). Gas/storage are out of scope.
- **Migration assumptions (FSM-11).** A legacy `AccountV0` never begins with the 4-byte
  `VERSIONED_MAGIC_PREFIX = u32::MAX` (its leading bytes are a `Box<[u8]>` length `< u32::MAX`), as
  documented in `entry/mod.rs`. Balances/keys/state are modeled as opaque preserved fields.
- **Crypto assumptions (FSM-6).** `sha256` is modeled as **injective** (a symbolic stand-in for collision
  resistance) with a 32-byte output; `ed25519`/`secp256k1`/`p256` are trusted primitives (consistent with
  `verification/assumptions.md` #3). A well-formed `DefusePayload` JSON body is assumed `> 32` bytes
  (it must carry signer_id, verifying_contract, deadline, a 32-byte base64 nonce, and the message), which
  gives length separation between the raw-JSON standard and the 32-byte digest standards.

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

**Adversarial coverage (Phase 3).** An adversarial reading of the stateful/authorization paths
(`engine/state/cached.rs`, `contract/intents/state.rs`, `contract/tokens/mod.rs`, `accounts/account/mod.rs`,
and every `intents/*`) yielded **no custody/authorization bypass**:
- Every intent moves value only **from the authenticated signer** (`internal_sub_balance(signer, …)`),
  and `Transfer` rejects `sender == receiver` — there is no cross-account theft primitive.
- The account **lock** is enforced identically in both `State` impls; FSM-9 proves a locked non-forced
  account is fully frozen (no debit, no auth change, no nonce commit), with the access-controlled force
  role as the only documented bypass.
- Authorization for signed intents requires the recovered key to be registered for the signer
  (FSM-6 DS-3), and a locked signer cannot even commit a nonce (FSM-9 LA-2).
- **Wallet (Phase 5).** The recently-reworked wallet promise path (#320) was audited adversarially: a
  signed/extension request cannot make the wallet self-call or perform an account-mutating action —
  `NearAction` is a flat 3-variant enum (AddKey/DeleteKey/DeployContract/CreateAccount/Stake are not even
  representable) and `NearPromise` is flat (no nested-promise bypass), so `build_promise`'s single-level
  allow-list + self-call check is complete (FSM-13). The wallet cannot be bricked (FSM-14) and a live
  signed request cannot be replayed within its validity window (FSM-15).
- **PoA bridge (Phase 6).** Minting is gated end-to-end: the token's `ft_deposit` is owner-only, the
  factory owns every token it deploys, and the factory's mint trigger requires DAO|TokenDepositer; deploy
  requires DAO|TokenDeployer; both are pausable. No role-less principal can mint or deploy (FSM-16), token
  supply is conserved, and dot-free names map injectively to accounts so no bridged token can spoof
  another's account (FSM-17).

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
| `Mut_SigDomain.fst`  | give two standards the SAME domain prefix (no separation)   | rejected ✅ |
| `Mut_MtResolve.fst`  | drop the `min(amount)` refund cap (over-report inflates)    | rejected ✅ |
| `Mut_NftResolve.fst` | refund the NFT unit regardless of `used` (duplication)      | rejected ✅ |
| `Mut_LockAuth.fst`   | make `internal_sub_balance` skip the lock (drain frozen acct)| rejected ✅ |
| `Mut_AsyncLifecycle.fst`| drop the resolved-once guard (double-settle a withdrawal) | rejected ✅ |
| `Mut_Migration.fst`  | invert the `implicit_public_key_removed` flag on V0 migration| rejected ✅ |
| `Mut_WalletPromise.fst`| add the dangerous action to the allow-list                | rejected ✅ |
| `Mut_WalletAuth.fst` | drop `check_lockout` (allow bricking the wallet)            | rejected ✅ |
| `Mut_WalletNonce.fst`| shrink retention to a single window (allow valid replay)    | rejected ✅ |
| `Mut_PoaAuth.fst`    | drop the role gate on `factory.ft_deposit` (anyone mints)   | rejected ✅ |
| `Mut_PoaToken.fst`   | drop the owner check on mint (anyone mints)                 | rejected ✅ |
| `Mut_SimRefine.fst`  | make cached debit ignore the lock (sim accepts, real rejects)| rejected ✅ |

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

- **DEF-SIG-003 RawEd25519 tag-less signing.** `SignedRawEd25519Payload::verify` checks the ed25519
  signature over the **raw JSON bytes with no domain tag** (`payload.as_bytes()`), and
  `extract_defuse_payload` is `serde_json::from_str(payload)`. Consequently, *any* ed25519 signature a
  user ever produces over bytes that happen to form a valid `DefusePayload` JSON is a valid intent under
  that user's registered key. This is inherent to tag-less raw signing (the standard exists for wallets
  like Phantom that sign raw bytes) and is bounded by the per-account key registration
  (`has_public_key`) and single-use nonces. Off-chain key reuse/compromise is a **documented scope
  exclusion** (`verification/assumptions.md`), so this is recorded as a robustness observation, not a
  Critical/High finding. Optional hardening: require a fixed domain prefix inside the raw-signed bytes.
  Note the *contract-internal* standards remain mutually domain-separated (FSM-6 DS-1/DS-2).

- **SIM-001 simulate-vs-real add-zero divergence.** `CachedState::internal_add_balance` (used by
  `simulate_intents`) does **not** reject a `0` amount, whereas the real `Contract::internal_add_balance`
  returns `InvalidIntent` on `amount == 0`. A simulation of an intent that credits `0` could therefore
  report success while on-chain execution reverts. Reachability from a well-formed intent appears nil (the
  credit paths — `TokenDiff` positive deltas, fee collection, mint/deposit — all use `amount > 0`, and
  `TokenDiff` rejects `delta == 0`), and the impact is limited to a mis-optimistic simulation whose real
  transaction simply reverts (no custody loss). Recorded as a **robustness/consistency observation**, not
  a finding. Optional fix: reject `amount == 0` in `CachedState::internal_add_balance` to match production.
  FSM-18 formally proves this is the **only** simulate-vs-real decision divergence across all mutating
  methods (all other accept/reject decisions agree exactly).

---

## 8. Remaining gaps

- NEAR **async promise interleavings** for withdrawal/refund (DEF-ASY-004/005/006) are not modeled in pure
  F\*; FSM-5/7/8 cover only the synchronous resolver decision tables. A Quint model (per the repo plan)
  remains the right tool for interleavings.
- **FSM-6 scope:** DS-1 byte-disjointness is formally proved for the four "plain" ed25519 standards
  (NEP-413/SEP-53/TonConnect/RawEd25519). The **WebAuthn** assertion structure
  (`authenticatorData ‖ sha256(clientDataJSON)`, challenge = the payload hash) is not fully modeled; it is
  argued informally to be distinct (length ≥ 69 vs the 32-byte digests) and is separated from the
  secp256k1 standards by curve. A byte-exact WebAuthn model is a follow-up.
- FSM-12 abstracts NEAR promise scheduling into an operational state machine with an adversarial action
  interleaving; it does not model gas, receipt routing, or partial-batch rollback at the WASM level.
- FSM-11 models migration at the custody/authority-field level (balances/keys/nonces/flags/lock), not the
  byte-exact borsh layout of `AccountState`.
- FSM-13/14/15 model the wallet at the authorization/promise/nonce level; the wallet's per-schema
  signature verification (ed25519 / webauthn) and byte-exact `RequestMessage` hashing are trusted
  (analogous to FSM-6's crypto assumptions). FSM-15 abstracts the rotation clock into an adversarial list
  of cleanup times.
- FSM-16/17 model the PoA authorization matrix and custom supply transitions; the `near_plugins`
  `#[access_control_any]`/`#[only]` macro expansions and `near_contract_standards` NEP-141 internals are
  trusted libraries (not re-verified). PoA unit tests are absent; behavior is exercised by the
  integration suite (`tests/src/tests/poa/`).
- FSM-18 proves the simulate-vs-real refinement at the **per-method accept/reject decision** level (the
  SIM-001/002/003 essence, since both paths run the same engine); it does not re-model the entire engine
  state transition byte-for-byte.
- **Escrow** (`escrow-swap`) remains out of scope (excluded by request). The small `global-deployer` /
  `outlayer` / `treasury-logger` contracts and byte-exact WebAuthn are candidates for a future pass.
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
- `verification/fstar/Defuse.SigDomain.fst` — FSM-6 (Phase 2).
- `verification/fstar/Defuse.MtResolve.fst` — FSM-7 (Phase 2).
- `verification/fstar/Defuse.NftResolve.fst` — FSM-8 (Phase 2).
- `verification/fstar/Defuse.LockAuth.fst` — FSM-9 (Phase 3).
- `verification/fstar/Defuse.AsyncLifecycle.fst` — FSM-12 (Phase 4).
- `verification/fstar/Defuse.Migration.fst` — FSM-11 (Phase 4).
- `verification/fstar/Defuse.WalletPromise.fst` — FSM-13 (Phase 5).
- `verification/fstar/Defuse.WalletAuth.fst` — FSM-14 (Phase 5).
- `verification/fstar/Defuse.WalletNonce.fst` — FSM-15 (Phase 5).
- `verification/fstar/Defuse.PoaAuth.fst` — FSM-16 (Phase 6).
- `verification/fstar/Defuse.PoaToken.fst` — FSM-17 (Phase 6).
- `verification/fstar/Defuse.SimRefine.fst` — FSM-18 (Phase 7).
- `verification/fstar/mutations/*` — non-vacuity checks (17) + `run.sh`.
- `verification/fstar/{Makefile,README.md,install.sh,env.sh,.gitignore}` — reproducible toolchain.
- `verification/reports/fstar-report.md` — this report.
- `verification/proof-index.md` — cross-references to FSM-1..5 (doc update).
