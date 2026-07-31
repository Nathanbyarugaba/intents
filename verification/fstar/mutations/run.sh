#!/usr/bin/env bash
# Non-vacuity (mutation) checks for the F* proofs.
#
# Each mutation deliberately breaks a model or property; F* MUST reject it. If a
# mutation were to verify, the corresponding real proof would be vacuous.
#
#   source ../env.sh && bash run.sh
set -u

here="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
FSTAR_HOME="${FSTAR_HOME:-$here/../.tools/fstar}"
FSTAR="$FSTAR_HOME/bin/fstar.exe"
FLAGS="--z3version 4.15.3 --warn_error -321 --ext context_pruning --z3rlimit 200 --include $here/.."

fail=0
for m in Mut_Fees Mut_Settlement Mut_Closure Mut_Nonce Mut_AsyncResolve \
         Mut_SigDomain Mut_MtResolve Mut_NftResolve Mut_LockAuth \
         Mut_AsyncLifecycle Mut_Migration; do
  echo "==== $m (expect REJECTION) ===="
  if "$FSTAR" $FLAGS "$here/$m.fst" >/dev/null 2>&1; then
    echo "  UNEXPECTED: $m verified (proof would be VACUOUS)"; fail=1
  else
    echo "  OK: $m correctly rejected"
  fi
done

if [ "$fail" -eq 0 ]; then
  echo "ALL MUTATIONS CORRECTLY REJECTED (proofs are non-vacuous)"
else
  echo "MUTATION CHECK FAILED"; exit 1
fi
