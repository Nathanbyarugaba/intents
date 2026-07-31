# F* verification of NEAR Intents (defuse) custody-critical pure logic.
#
# Usage:
#   make install     # download pinned F* + Z3 toolchain into .tools/
#   make verify      # typecheck (prove) every model
#   make <Name>      # typecheck a single module, e.g. `make Defuse.Fees`
#   make clean

FSTAR_HOME ?= $(CURDIR)/.tools/fstar
FSTAR      := $(FSTAR_HOME)/bin/fstar.exe

# Deterministic, reproducible checking flags.
FSTAR_FLAGS := \
  --z3version 4.15.3 \
  --warn_error -321 \
  --ext context_pruning \
  --z3rlimit 60

MODULES := \
  Defuse.Arith.fst \
  Defuse.Fees.fst \
  Defuse.Settlement.fst \
  Defuse.Closure.fst \
  Defuse.Nonce.fst \
  Defuse.AsyncResolve.fst \
  Defuse.SigDomain.fst \
  Defuse.MtResolve.fst \
  Defuse.NftResolve.fst \
  Defuse.LockAuth.fst \
  Defuse.AsyncLifecycle.fst \
  Defuse.Migration.fst \
  Defuse.WalletPromise.fst \
  Defuse.WalletAuth.fst \
  Defuse.WalletNonce.fst

.PHONY: all verify install clean $(basename $(MODULES))

all: verify

install:
	bash $(CURDIR)/install.sh

verify:
	@for m in $(MODULES); do \
	  echo "==== $$m ===="; \
	  $(FSTAR) $(FSTAR_FLAGS) $$m || exit 1; \
	done
	@echo "ALL F* MODULES VERIFIED"

# Per-module target: `make Defuse.Fees`
%:
	$(FSTAR) $(FSTAR_FLAGS) $@.fst

clean:
	rm -f *.checked *.checked.lax
	rm -rf _output extracted
