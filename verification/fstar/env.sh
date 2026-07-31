#!/usr/bin/env bash
# Source this to put the pinned F* + Z3 toolchain on PATH.
#
#   source verification/fstar/env.sh
#
# The toolchain lives under verification/fstar/.tools/ (git-ignored) and is
# installed by verification/fstar/install.sh.

_here="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
export FSTAR_HOME="${_here}/.tools/fstar"

if [ ! -x "${FSTAR_HOME}/bin/fstar.exe" ]; then
  echo "F* not found at ${FSTAR_HOME}. Run: bash ${_here}/install.sh" >&2
fi

# F* auto-discovers its bundled z3 under lib/fstar/z3-*/bin, but we also expose
# it on PATH for convenience / reproducibility.
export PATH="${FSTAR_HOME}/bin:${FSTAR_HOME}/lib/fstar/z3-4.15.3/bin:${PATH}"
