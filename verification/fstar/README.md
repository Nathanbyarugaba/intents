# F\* verification of NEAR Intents (defuse)

This directory contains an **independent F\* modeling layer** that mechanically checks the
custody-critical *pure logic* of the `contracts/defuse` settlement engine and its arithmetic.

It complements (does not replace) the repo's Kani/Quint plans. Per `AGENTS.md`, every result here is
labeled **Model proof**: F\* proves properties over faithful hand-written models of the Rust code. A
failed proof is only a **Hypothesis** until reproduced deterministically against the production Rust
code. No production code is modified.

Target commit: `3c2388ed3e93441379824b490eb40ac02feef45b`.

## Toolchain (pinned)

- F\* `v2026.07.24` (OCaml 5.3.0 build)
- Z3 `4.15.3` (bundled inside the F\* release)

Both are installed into `.tools/` (git-ignored) by `install.sh`. We pin exact versions so proofs are
reproducible.

## Quick start

```bash
bash verification/fstar/install.sh      # one-time: download F* + Z3 (~247 MB)
source verification/fstar/env.sh        # put fstar.exe / z3 on PATH
make -C verification/fstar verify       # typecheck (prove) every model
make -C verification/fstar Defuse.Fees  # prove a single module
```

## Modules and proof obligations

| File                     | Obligation IDs           | Property (informal)                                                    |
|--------------------------|--------------------------|------------------------------------------------------------------------|
| `Defuse.Arith.fst`       | (shared)                 | Faithful `checked_mul_div{,_ceil,_euclid}` over 256-bit widening.      |
| `Defuse.Fees.fst`        | DEF-FEE-001, FSM-2       | `fee_ceil a <= a`, monotonicity, no-panic (`unreachable!` unreachable). |
| `Defuse.Settlement.fst`  | DEF-CON-001/002/004, FSM-1| Transfer matcher conserves value; success ⇒ per-token net zero.        |
| `Defuse.Closure.fst`     | FSM-3                    | `supply_delta`/`closure` round-trip nets to zero (solver-facing).      |
| `Defuse.Nonce.fst`       | DEF-NON-001/002/004, FSM-4| Nonce at-most-once, cleanup safety, versioned-downgrade characterization.|
| `Defuse.AsyncResolve.fst`| DEF-ASY-001/007, FSM-5   | `used + refund == amount`; never double-settle.                         |
| `Defuse.SigDomain.fst`   | DEF-SIG-003, FSM-6       | No cross-standard signature replay (curve partition + disjoint signed bytes). |
| `Defuse.MtResolve.fst`   | DEF-ASY-003, FSM-7       | MT resolve per-item conservation & callback vector-shape safety.        |
| `Defuse.NftResolve.fst`  | DEF-ASY-002, FSM-8       | NFT resolve: unit is either used or refunded, never both nor lost.      |
| `Defuse.LockAuth.fst`    | AUTH-002/DEF-ASY-005, FSM-9 | Locked account is frozen (no debit/auth-change/nonce); force is the sole bypass. |
| `Defuse.Migration.fst`   | MIG-001/002/003, FSM-11  | Migration disambiguation/round-trip/field preservation; legacy nonces never resurrected. |
| `Defuse.AsyncLifecycle.fst`| DEF-ASY-007/005/001, FSM-12 | Async withdrawal value conservation + at-most-once settlement under any interleaving. |
| `Defuse.WalletPromise.fst`| WAL-PRO-001, FSM-13     | Wallet promise can't self-call or perform account-mutating actions. |
| `Defuse.WalletAuth.fst`  | WAL-AUT-002, FSM-14      | Wallet keeps ≥1 authorization path (no lockout/bricking). |
| `Defuse.WalletNonce.fst` | WAL-NON-001/002, FSM-15  | Dual-window nonce: no replay of a still-valid signed request. |

## Explicit exclusions (by request)

- `escrow-swap` contract (all `ESC-*`).
- **Known issue** — protocol-fee bypass via NEP-245 fungible MT "split" (`token_fee` zeroes fees for
  `amount <= 1`). Treated as opaque/known; not reported.
- Unbounded gas / storage (models are gas/storage-agnostic).

See `../reports/fstar-report.md` for results, assumptions, counterexamples, coverage, and mutation
outcomes.
