from math import ceil

def fee_ceil(amount, pips):
    MAX_PIPS = 1000000 # 100% is ONE_PERCENT * 100 = (1 * 100 * 100 * 100) = 1_000_000
    return ceil((amount * pips) / MAX_PIPS)

# Let's verify a transaction:
# Alice has 100 FT in her account. She wants to trade it for 50 FT2.
# Bob has 50 FT2 in his account. He wants to trade it for 100 FT.
# TokenDiffs:
# Alice: {"FT": -100, "FT2": 50}
# Bob: {"FT2": -50, "FT": 100}

pips = 1000 # 0.1%

# For Alice:
delta_ft = -100
delta_ft2 = 50

# Fees collected:
fees_collected = 0
if delta_ft < 0:
    fee = fee_ceil(abs(delta_ft), pips)
    fees_collected += fee
print(f"Alice pays fee: {fee}")

# Wait, if Alice pays a fee, she needs to cover it. In rust:
# The delta is applied directly.
# BUT wait! `amounts.sub(token_id, amount)` is used where?
# In `execute_intent` for `TokenDiff`:
# self.diff has the deltas.
# It iterates:
# engine.state.internal_apply_deltas(signer_id, self.diff.items())
# Wait, internal_apply_deltas applies the original requested deltas to the account's state!
# But then it takes the fee from the delta? No!
# Let's read `execute_intent` again. It adds the delta to the Deltas object via `with_apply_delta`.
# And it takes fees?
