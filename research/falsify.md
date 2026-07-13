# Adjudicating properties

If Alice has a TokenDiff of `{"FT": -100, "FT2": 50}`:
- Her net contribution is -100 `FT`, +50 `FT2`.
- A protocol fee of 1% (for example) will take 1 `FT` as fee.
- Thus, the total `FT` available in the match pool is `100` (Alice's out) - `1` (Fee) = `99 FT`? Wait, no.

Let's look at `TokenDiff` `execute_intent` in `token_diff.rs`:
```rust
for (token_id, delta) in &self.diff {
    engine.state.internal_apply_deltas(signer_id, [(token_id, *delta)])?;
    if *delta < 0 {
        let amount = delta.unsigned_abs();
        let fee = Self::token_fee(token_id, amount, protocol_fee).fee_ceil(amount);
        fees_collected.add(token_id.clone(), fee);
    }
}
if !fees_collected.is_empty() {
    engine.state.internal_add_balance(engine.state.fee_collector().into_owned(), fees_collected)?;
}
```

Wait, `engine.state.internal_apply_deltas` actually delegates to `Deltas::internal_apply_deltas`. Let's check `Deltas` implementation.
Oh, it says:
```rust
    fn internal_apply_deltas(
        &mut self,
        owner_id: &AccountIdRef,
        tokens: impl IntoIterator<Item = (TokenId, i128)>,
    ) -> Result<()> {
        for (token_id, delta) in tokens {
            self.deltas.add_delta(owner_id.to_owned(), token_id, delta);
        }
        Ok(())
    }
```
Wait, no. `Deltas::internal_apply_deltas` is in `deltas.rs`? Or does it use `StateView` / `State` default from `state/mod.rs`?
If it uses `deltas.add_delta`, it just records the user's intent to withdraw or deposit `amount`.
Then if `fee` is added to `fee_collector` via `internal_add_balance`:
```rust
    fn internal_add_balance(
        &mut self,
        owner_id: AccountId,
        tokens: impl IntoIterator<Item = (TokenId, u128)>,
    ) -> Result<()> {
        for (token_id, amount) in tokens {
            self.deltas.add_delta(owner_id.clone(), token_id, amount as i128);
        }
        Ok(())
    }
```
So, Alice's delta for `FT` is -100.
Fee collector's delta for `FT` is +1.
The net withdrawal of `FT` is 100.
The net deposit of `FT` is 1 (to the fee collector).
If Bob tries to match with +100 `FT` (so he can receive Alice's 100 `FT`), his delta is +100.
Total deposits = 101 (Bob 100 + FeeCollector 1).
Total withdrawals = 100 (Alice 100).
This leads to `leftover_deposits = 1`.
Because the transfers will try to fulfill 101 deposits with only 100 withdrawals.
This will fail with `UnmatchedDeltas`!

Wait, `Deltas::internal_add_balance` adds to `Deltas::deposits` (because it calls `self.deltas.deposit`).
`Deltas::internal_sub_balance` adds to `Deltas::withdrawals`.

Thus, if Alice has a `TokenDiff` of `-100 FT`, that goes through `internal_apply_deltas`:
Since `-100` is negative, it calls `internal_sub_balance(..., 100)`.
So Alice's `withdrawals` for `FT` is 100.
Then fee is calculated: `fee_ceil(100) = 1` (assuming 1%).
Then `fees_collected` adds `1 FT`.
Then `internal_add_balance(fee_collector, 1 FT)`.
So Fee Collector's `deposits` for `FT` is +1.
Now we have:
Alice withdrawal: 100
Fee Collector deposit: 1
If Bob has `TokenDiff` of `+100 FT` (meaning he wants to receive 100 FT), he adds to `deposits` with 100.
Total deposits = 101.
Total withdrawals = 100.
This fails with `UnmatchedDeltas`!

But users are supposed to figure this out and construct their intents properly!
Is this the expected behavior?
Wait, look at `closure_delta` in `token_diff.rs`:
```rust
    pub fn closure_supply_delta(token_id: &TokenId, delta: i128, fee: Pips) -> Option<i128> {
        let closure = delta.checked_neg()?;
        if closure < 0 {
            // fee is taken only on negative deltas (i.e. token_in)
            closure.checked_mul_div_euclid(
                Pips::MAX.as_pips().into(),
                Self::token_fee(token_id, delta.unsigned_abs(), fee)
                    .invert()
                    .as_pips()
                    .into(),
            )
        } else {
            // token_out
            Some(closure)
        }
    }
```
Yes, this implies the counterparties MUST adjust their requested deltas to explicitly account for the protocol fee. The users themselves build intents that perfectly balance out, which implies the solver constructs intents where the total matched perfectly zeroizes!

Is there any flaw?
What if `fee` causes an overflow?
No, the property holds: Total deposits must be LESS THAN OR EQUAL to total withdrawals (wait, if leftover withdrawals exist, they are returning an error too!).
Wait!
```rust
        // only sender(s) left
        if let Some((_, send)) = withdraw {
            return Err(withdrawals ... i128::checked_neg);
        }
        // only receiver(s) left
        if let Some((_, receive)) = deposit {
            return Err(deposits ... );
        }
```
Any mismatch returns `UnmatchedDeltas`.

Let's look at `finalize()`:
```rust
        if let Some((_, send)) = withdraw {
            return Err(...)
        }
        if let Some((_, receive)) = deposit {
            return Err(...)
        }
```
So it STRICTLY requires `total_deposits == total_withdrawals`!
Is there any scenario where a malicious user could exploit `Pips::fee_ceil` to create tokens?

Let's test if we can manipulate integer math to make `total_deposits > total_withdrawals`.
Since `fees_collected` adds to deposits:
Total withdrawals = Sum(user_withdrawals)
Total deposits = Sum(user_deposits) + Sum(fees_collected)
We want:
`total_withdrawals == total_deposits` for the transaction to succeed.
Does `fees_collected` exactly equal the gap between user withdrawals and user deposits? Yes, if the solver constructed it that way.

What if a user specifies a massive `delta` such that `fee_ceil(amount)` overflows?
`Pips::MAX.as_pips()` is `1000000`.
`amount.checked_mul_div_ceil(..., 1000000)`.
In `Pips::fee_ceil(self, amount)`:
```rust
    pub fn fee_ceil(self, amount: u128) -> u128 {
        amount
            .checked_mul_div_ceil(self.as_pips().into(), Self::MAX.as_pips().into())
            .unwrap_or_else(|| unreachable!())
    }
```
`defuse_num_utils::CheckedMulDiv` uses `u128`? Wait, `checked_mul_div_ceil` could overflow if `amount * pips > u128::MAX`.
But `amount` is `u128`, `pips` is `u32`.
Does it cast to `u256` or `bnum`?
Let's check `defuse_num_utils`.

So the math handles 256-bit precision using `BUint<4>` internally for `u128`, which prevents intermediate overflow!

Let's check `Amount` operations inside `Deltas`.
Wait, in `TokenDiff` it processes deltas in `i128`.
```rust
pub type TokenDeltas = Amounts<BTreeMap<TokenId, i128>>;
```
When a user intent is processed:
```rust
for (token_id, delta) in &self.diff {
    engine.state.internal_apply_deltas(signer_id, [(token_id, *delta)])?;
    if *delta < 0 {
        let amount = delta.unsigned_abs(); // Converts to u128
        let fee = Self::token_fee(token_id, amount, protocol_fee).fee_ceil(amount);
        fees_collected.add(token_id.clone(), fee).ok_or(DefuseError::BalanceOverflow)?;
    }
}
```
Wait! `internal_apply_deltas` works with `i128` delta, and `amount` uses `unsigned_abs()`.
If `delta` is `-100`, `unsigned_abs()` is `100`.
Then `Deltas::internal_apply_deltas`:
```rust
    fn internal_apply_deltas(
        &mut self,
        owner_id: &AccountIdRef,
        tokens: impl IntoIterator<Item = (TokenId, i128)>,
    ) -> Result<()> {
        for (token_id, delta) in tokens {
            let tokens = [(token_id, delta.unsigned_abs())];
            if delta.is_negative() {
                self.internal_sub_balance(owner_id, tokens)?;
            } else {
                self.internal_add_balance(owner_id.to_owned(), tokens)?;
            }
        }
        Ok(())
    }
```
Wait, wait!
If `delta` is `i128::MIN` (`-170141183460469231731687303715884105728`)
`unsigned_abs()` gives `170141183460469231731687303715884105728` (`1 << 127`).
This is perfectly valid, it doesn't overflow `u128`.

Is there any flaw in `TransferMatcher`?
```rust
    fn sub_add(
        sub: &mut AccountAmounts,
        add: &mut AccountAmounts,
        owner_id: AccountId,
        mut amount: u128,
    ) -> bool {
        let s = sub.amount_for(&owner_id);
        if s > 0 {
            let a = s.min(amount);
            sub.sub(owner_id.clone(), a)
                .unwrap_or_else(|| unreachable!());
            amount = amount.saturating_sub(a);
            if amount == 0 {
                return true;
            }
        }
        add.add(owner_id, amount).is_some()
    }
```
If a user is both withdrawing and depositing the SAME token in the same `execute_intents` call, `sub_add` matches them locally and cancels them out!
For example, if Alice withdraws 50 and then deposits 100, `sub_add` cancels 50 and records +50 as net deposit!

Wait, `engine.state.internal_apply_deltas(signer_id, [(token_id, *delta)])` happens for every Intent.
What if a single user submits MULTIPLE `TokenDiff` intents for the SAME token?
Say Alice signs Intent 1: `-100 FT`.
Alice signs Intent 2: `+100 FT`.
Net is 0.
But what about FEES?
In Intent 1, `delta < 0`, so `fee` is calculated on `100 FT`. Let's say 1 FT fee.
In Intent 2, `delta > 0`, so no fee is collected!
So total withdrawals (Alice) = 100.
Total deposits (Alice) = 100.
Total fees collected = 1.
So Alice's `Deltas` has `deposit(100)` and `withdraw(100)`. Net is 0.
Fee collector has `deposit(1)`.
Total deposits across all = 1.
Total withdrawals = 0.
This fails with `UnmatchedDeltas`!
Is this expected? Yes, because Alice paid a fee but no one funded the fee! Alice expected to receive 100 but only put in 100 without covering the fee, so it correctly fails.

Let's verify what happens if `fees_collected` adds to an existing balance.
`fees_collected` is collected PER Intent in `execute_intent` for `TokenDiff`, then it adds to the fee collector:
```rust
        if !fees_collected.is_empty() {
            engine
                .state
                .internal_add_balance(engine.state.fee_collector().into_owned(), fees_collected)?;
        }
```
Wait! `fees_collected` is a local variable to the `execute_intent` function call!
```rust
    fn execute_intent<S, I>(
        self,
        signer_id: &AccountIdRef,
        engine: &mut Engine<S, I>,
        intent_hash: CryptoHash,
    ) -> Result<()>
    where ... {
        // ...
        let mut fees_collected: Amounts = Amounts::default();
        for (token_id, delta) in &self.diff {
             // ... calculates fee ... adds to fees_collected
        }
        // ...
        if !fees_collected.is_empty() {
            engine
                .state
                .internal_add_balance(engine.state.fee_collector().into_owned(), fees_collected)?;
        }
    }
```
So each intent individually pays fees.

Is there any issue with `internal_add_balance`?
```rust
    fn internal_add_balance(
        &mut self,
        owner_id: AccountId,
        tokens: impl IntoIterator<Item = (TokenId, u128)>,
    ) -> Result<()> {
        for (token_id, amount) in tokens {
            self.state
                .internal_add_balance(owner_id.clone(), [(token_id.clone(), amount)])?;
            if !self.deltas.deposit(owner_id.clone(), token_id, amount) {
                return Err(DefuseError::BalanceOverflow);
            }
        }
        Ok(())
    }
```
Wait! It calls `self.state.internal_add_balance` BEFORE adding to `self.deltas`?
Wait, what is `self.state` in `Deltas<S>`?
It is the underlying State!
Let's look at `StateView for Deltas<S>` and `State for Deltas<S>` again.
Wait! Why does `Deltas` call `self.state.internal_add_balance` during execution?!

Let's read `contracts/defuse/core/src/engine/state/deltas.rs` fully.

Wait, `Deltas::internal_add_balance` modifies BOTH `self.state` (which is the actual underlying storage, `Contract` via `cached` in `simulate_intents` and `CachedState` in `execute_intents`) AND `self.deltas` (which is the `TransferMatcher`).
Wait. If it modifies the underlying state, does that mean the user's balances are modified during intent execution?
Yes! In `Engine::execute_signed_intent`:
`intents.execute_intent(&signer_id, self, hash)?;`
This calls `TokenDiff::execute_intent`, which calls `internal_apply_deltas`.
This calls `internal_sub_balance` for `FT` on Alice.
Alice's balance in `self.state.accounts` immediately decreases by 100 FT!
Then it calls `fees_collected.add(...)` and `internal_add_balance` on fee collector.
Fee collector's balance in `self.state.accounts` immediately increases by 1 FT!
Then if Alice's `TokenDiff` doesn't match with anything, the loop finishes.
Then `self.finalize()` is called!
```rust
    #[inline]
    fn finalize(self) -> Result<Transfers> {
        self.state
            .finalize()
            .map_err(DefuseError::InvariantViolated)
    }
```
`Deltas::finalize()` calls `self.deltas.finalize()`, which is `TransferMatcher::finalize()`.
If `TransferMatcher::finalize()` returns an error (e.g. `UnmatchedDeltas`), it maps to `DefuseError::InvariantViolated`.
Then `execute_signed_intents` returns this `Err`.
```rust
        if let Some(event) = Engine::new(self, ExecuteInspector::default())
            .execute_signed_intents(signed)
            .unwrap_or_else(|e| e.panic())
```
Wait!
If `execute_signed_intents` returns `Err(DefuseError::InvariantViolated(v))`, then it panics via `.unwrap_or_else(|e| e.panic())`!
Because it panics, the entire NEAR transaction REVERTS!
So all changes made to `self.state` (Alice's balance decreasing, Fee collector's balance increasing) are wiped out!

So the mechanism is safe from creating tokens from thin air, because if there's any mismatch in Deltas, the transaction fails entirely.

Is there any concurrency vulnerability?
Since NEAR smart contracts are single-threaded and lock state per transaction, there is no concurrency between `execute_intents` calls on the same contract instance.

Are there cross-layer assumptions?
The tokens are deposited/withdrawn using `ft_transfer_call`, `mt_transfer`, etc.
When deposited, the user gets balances on `accounts`.
When an Intent executes, it runs purely in-memory over the balances in the contract.
If it succeeds, events are emitted. But wait! `Transfers` is returned by `finalize()`.
```rust
        if let Some(event) = Engine::new(self, ExecuteInspector::default())
            .execute_signed_intents(signed)
            .unwrap_or_else(|e| e.panic())
            .as_mt_event()
        {
            // NOTE: Not all `mt_transfer` events are refundable, but it's safe to check them
            // all at once since non-refundable transfers only increase the potential refund
            // log size without affecting correctness. This can actually prevent resolve transfer
            // from failing due to too long event log !!!
            event
                .check_refund()
                .unwrap_or_else(|err| err.panic())
                .emit();
        }
```
Wait, the `as_mt_event()` returns an event to emit. It does NOT transfer external tokens!
The `Transfers` returned by `Engine::finalize` only describe how ownership changed internally! It emits `MtTransferEvent` just to notify off-chain indexers of the internal swaps!
External tokens are transferred via `ft_withdraw`, `native_withdraw`, etc., which are separate intents!
Let's check `ft_withdraw`:

Let's check `internal_ft_withdraw` in `contracts/defuse/src/contract/tokens/ft.rs`.
Does it invoke a promise? Yes, it returns `PromiseOrValue`. `detach` runs it!
Wait! Does `ft_withdraw` add to `Deltas::withdrawals`?
Let's see `Deltas::ft_withdraw`.
```rust
    #[inline]
    fn ft_withdraw(&mut self, owner_id: &AccountIdRef, withdraw: FtWithdraw) -> Result<()> {
        self.state.ft_withdraw(owner_id, withdraw)
    }
```
No! `ft_withdraw` bypasses `Deltas::withdraw` because it directly modifies the `State` balance inside `internal_ft_withdraw` by subtracting the balance and scheduling a cross-contract call (`Promise`).
This implies that `ft_withdraw` does NOT participate in the zero-sum `TransferMatcher`.
Is this correct?
Yes, `ft_withdraw` is for withdrawing tokens from the Defuse contract to the external NEAR account. It's a completely separate intent type from `TokenDiff`.
`TokenDiff` is specifically for in-contract atomic swaps between users.
So `TransferMatcher` only balances `TokenDiff` intents.

Wait, if Alice uses `TokenDiff` to withdraw 100 FT (i.e. delta -100) and no one deposits 100 FT, the transaction fails.
If Alice uses `FtWithdraw` for 100 FT, it bypasses `TransferMatcher`, directly subtracts 100 FT from her internal balance, and initiates an external token transfer. This is safe as long as she actually had the 100 FT balance!

What if she has 50 FT, uses `TokenDiff` to receive 50 FT (delta +50), and in the SAME batch uses `FtWithdraw` for 100 FT?
`execute_signed_intents` executes intents sequentially based on the order in the array.
If `TokenDiff` (+50) runs first:
- `internal_add_balance(Alice, 50)` increases her balance to 100.
- `Deltas` records `deposit(+50)`.
Then `FtWithdraw` runs:
- `internal_sub_balance` is called inside `internal_ft_withdraw` for 100 FT.
- Alice's balance becomes 0.
- Promise is scheduled.
Then `finalize()` runs:
- `TransferMatcher` sees `deposit(+50)`.
- If Bob provided a `TokenDiff` (-50) that executed earlier or later, it matches.
- If it matches, transaction succeeds.
Is this exploitable?
If Bob's `TokenDiff` fails to match perfectly, the transaction reverts, Alice's balance resets to 50, and the `Promise`... WAIT!
If the transaction panics, do scheduled Promises get cancelled?
Yes! In NEAR, if a transaction panics, all Promises attached to that receipt are discarded, and state changes revert.
So it is completely atomic and safe!

So the system model:
- Actors: Signers
- Transitions: `TokenDiff` applies deltas, collects fees, checks invariant (total sum = 0).
- `finalize` reverts if invariant violated.
- Other Intents (`FtWithdraw`) execute effects that only materialize if `finalize` succeeds.

The core property holds because:
1. `Deltas` rigorously enforces matching.
2. `CheckedMulDiv` ensures precision without intermediate overflow.
3. Transaction reverting aborts all scheduled actions and state changes if the invariant is violated.

I will formalize the invariant and transitions for `TokenDiff` matching in Rocq.
