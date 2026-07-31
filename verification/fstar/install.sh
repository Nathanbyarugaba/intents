#!/usr/bin/env bash
# Install the pinned F* + Z3 toolchain used by this verification pass.
#
# Downloads the official F* binary release (which bundles the exact Z3 build F*
# expects) into verification/fstar/.tools/ (git-ignored). Idempotent.
set -euo pipefail

FSTAR_VERSION="v2026.07.24"
PLATFORM="Linux-x86_64"
here="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
tools="${here}/.tools"
mkdir -p "${tools}"

if [ -x "${tools}/fstar/bin/fstar.exe" ]; then
  echo "F* already installed at ${tools}/fstar"
  "${tools}/fstar/bin/fstar.exe" --version | head -1
  exit 0
fi

url="https://github.com/FStarLang/FStar/releases/download/${FSTAR_VERSION}/fstar-${FSTAR_VERSION}-${PLATFORM}.tar.gz"
echo "Downloading ${url}"
curl -sSL -o "${tools}/fstar.tar.gz" "${url}"
tar xzf "${tools}/fstar.tar.gz" -C "${tools}"
rm -f "${tools}/fstar.tar.gz"

"${tools}/fstar/bin/fstar.exe" --version | head -1
echo "Installed F* ${FSTAR_VERSION} at ${tools}/fstar"
