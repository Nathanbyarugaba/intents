#!/usr/bin/env bash
# Reproduce all verification harnesses (proptest + Quint). Kani proofs are run
# separately (see note below).
set -euo pipefail
cd "$(dirname "$0")/.."

QUINT="${QUINT:-quint}"

echo "== proptest / unit harnesses (production defuse_core) =="
cargo test -p defuse-verification-harnesses -p defuse-verification-kani-arith

echo
echo "== Quint async models =="
"$QUINT" run verification/quint/defuse_ft_withdraw.qnt        --invariant=inv         --max-steps=14 --max-samples=300000
"$QUINT" run verification/quint/defuse_mt_deposit_resolve.qnt --invariant=inv_correct --max-steps=10 --max-samples=200000
"$QUINT" run verification/quint/defuse_nft_exclusivity.qnt    --invariant=inv         --max-steps=16 --max-samples=200000

cat <<'EOF'

== Kani (bounded proofs) ==
Kani's bundled toolchain (rustc 1.93-nightly) is older than the workspace MSRV.
To run:
  1) temporarily set workspace.package.rust-version = "1.85.0" in Cargo.toml (do NOT commit),
  2) cargo kani -p defuse-verification-kani-arith
  3) revert the rust-version change.
Expected: 2 successfully verified harnesses (def_fee_001_from_range, def_fee_001_invert_involution).
EOF
