import itertools

class TransferMatcher:
    def __init__(self):
        self.deposits = {}
        self.withdrawals = {}

    def deposit(self, owner_id, amount):
        s = self.withdrawals.get(owner_id, 0)
        if s > 0:
            a = min(s, amount)
            self.withdrawals[owner_id] = s - a
            amount -= a
            if amount == 0:
                return True

        self.deposits[owner_id] = self.deposits.get(owner_id, 0) + amount
        return True

    def withdraw(self, owner_id, amount):
        s = self.deposits.get(owner_id, 0)
        if s > 0:
            a = min(s, amount)
            self.deposits[owner_id] = s - a
            amount -= a
            if amount == 0:
                return True

        self.withdrawals[owner_id] = self.withdrawals.get(owner_id, 0) + amount
        return True

    def add_delta(self, owner_id, delta):
        amount = abs(delta)
        if delta < 0:
            return self.withdraw(owner_id, amount)
        else:
            return self.deposit(owner_id, amount)

    def finalize(self):
        # Emulate rust logic
        deposits_sorted = sorted(self.deposits.items(), key=lambda x: x[1], reverse=True)
        withdrawals_sorted = sorted(self.withdrawals.items(), key=lambda x: x[1], reverse=True)

        deposits_iter = (list(x) for x in deposits_sorted if x[1] > 0)
        withdrawals_iter = (list(x) for x in withdrawals_sorted if x[1] > 0)

        dep = next(deposits_iter, None)
        wth = next(withdrawals_iter, None)

        while dep is not None and wth is not None:
            sender, send_amt = wth
            receiver, recv_amt = dep

            transfer = min(send_amt, recv_amt)
            wth[1] -= transfer
            dep[1] -= transfer

            if wth[1] == 0:
                wth = next(withdrawals_iter, None)
            if dep[1] == 0:
                dep = next(deposits_iter, None)

        # Returns leftovers
        leftover_withdrawals = 0
        if wth is not None:
            leftover_withdrawals += wth[1]
            for w in withdrawals_iter:
                leftover_withdrawals += w[1]

        leftover_deposits = 0
        if dep is not None:
            leftover_deposits += dep[1]
            for d in deposits_iter:
                leftover_deposits += d[1]

        if leftover_withdrawals > 0:
            return -leftover_withdrawals
        if leftover_deposits > 0:
            return leftover_deposits
        return 0

# Test combinations
matcher = TransferMatcher()
# What if two users deposit and withdraw to the same token, balancing perfectly
matcher.add_delta("alice", 100)
matcher.add_delta("bob", -100)
print(f"Basic balanced: {matcher.finalize()}") # Should be 0

# What if unbalanced?
matcher = TransferMatcher()
matcher.add_delta("alice", 100)
matcher.add_delta("bob", -50)
print(f"Unbalanced (extra deposit): {matcher.finalize()}") # Should be > 0

# But wait, looking at Rust code:
# if delta < 0, it calls withdraw() -> meaning negative delta = withdraw (sending out token)
# if delta > 0, it calls deposit() -> meaning positive delta = deposit (receiving token)
# A positive delta in TokenDiff means the user wants TO RECEIVE the token.
# A negative delta means the user wants TO GIVE the token.

# In rust, if there are only senders left (negative delta unmatched), it returns an error with negative amount.
# if there are only receivers left (positive delta unmatched), it returns an error with positive amount.
# Does finalize() really balance correctly? Yes, because total send == total receive.

def rust_fee_logic(token_diffs, fee_pips):
    fees_collected = 0
    total_delta = 0
    for delta in token_diffs:
        if delta < 0:
            # fee is taken only on negative deltas (i.e. token_in)
            amount = abs(delta)
            # In Rust: fee = (amount * fee_pips + MAX_PIPS - 1) / MAX_PIPS
            MAX_PIPS = 10000 # 100% in basis points (just guessing, let's look at fees.rs)
            # The exact definition of fee_ceil is needed
            pass
