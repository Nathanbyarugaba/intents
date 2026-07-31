module Defuse.PoaToken

/// FSM-17 — PoA token supply conservation + token name → account injectivity.
///
/// Rust source: contracts/poa/token/src/contract.rs
///   ft_deposit(owner, amt): owner-only MINT -> balance[owner] += amt ; total_supply += amt
///   ft_transfer(to == self, memo starts with WITHDRAW_MEMO_PREFIX): BURN caller's own tokens ->
///     internal_withdraw(caller, amt) [requires balance[caller] >= amt] ; total_supply -= amt
///   ft_transfer (regular): move amt between two DISTINCT accounts (supply unchanged)
///   contracts/poa/factory: token_id(name) = "{name}.{factory}" with require!(!name.contains('.'))
///
/// Conservation is stated over `supply == acting_balance + rest_of_supply`, where `acting` is the account
/// being minted-to / burning / sending, and `rest` aggregates everyone else. Every custom transition
/// preserves it. (The generic NEP-141 machinery is trusted; we model the PoA-specific mint/burn/transfer.)

open FStar.List.Tot

type account = nat

/// supply, the acting account's balance, and the summed balance of all other accounts.
type tok = { supply : nat; bal : nat; rest : nat }

let conserved (t:tok) : bool = t.supply = t.bal + t.rest

/// A well-formed token state carries the conservation invariant `supply == bal + rest`. Each transition
/// returns a `wf`, so F* must re-establish conservation on every constructed state (that IS the proof).
type wf = t:tok{ conserved t }

/// MINT (owner-only): +amt to the owner's balance and to supply.
let mint (t:wf) (owner caller : account) (amt:nat) : option wf =
  if caller <> owner then None                          // #[only(self, owner)]
  else Some ({ t with supply = t.supply + amt; bal = t.bal + amt })

/// PT-2: a non-owner can never mint.
let pt2_mint_only_owner (t:wf) (owner caller : account) (amt:nat)
  : Lemma (requires caller <> owner) (ensures mint t owner caller amt == None)
  = ()

/// PT-1 (mint): minting preserves `supply == bal + rest` (enforced by the `wf` return type).
let pt1_mint_conserves (t:wf) (owner caller : account) (amt:nat)
  : Lemma (requires Some? (mint t owner caller amt))
          (ensures  conserved (Some?.v (mint t owner caller amt)))
  = ()

/// BURN (self-transfer with withdraw memo): reduce the caller's balance and supply by amt.
/// Requires the caller holds >= amt (internal_withdraw panics otherwise) and amt > 0.
/// `supply >= amt` follows from conservation (supply = bal + rest >= bal >= amt).
let burn (t:wf) (amt:nat) : option wf =
  if amt = 0 || t.bal < amt then None
  else Some ({ t with supply = t.supply - amt; bal = t.bal - amt })

/// PT-1 (burn): conservation preserved; supply drops by exactly `amt`.
let pt1_burn_conserves (t:wf) (amt:nat)
  : Lemma (requires Some? (burn t amt))
          (ensures  conserved (Some?.v (burn t amt)) /\
                    (Some?.v (burn t amt)).supply == t.supply - amt)
  = ()

/// TRANSFER (regular, to a DISTINCT account): move amt from acting balance into `rest`; supply unchanged.
let transfer_out (t:wf) (amt:nat) : option wf =
  if t.bal < amt then None
  else Some ({ t with bal = t.bal - amt; rest = t.rest + amt })

/// PT-1 (transfer): conservation preserved and supply is unchanged.
let pt1_transfer_conserves (t:wf) (amt:nat)
  : Lemma (requires Some? (transfer_out t amt))
          (ensures  conserved (Some?.v (transfer_out t amt)) /\
                    (Some?.v (transfer_out t amt)).supply == t.supply)
  = ()

/// ---------------------------------------------------------------------------
/// PT-3 — token name -> account id injectivity (dot-free names).
/// token_id(name) = name ++ "." ++ factory. Since names are dot-free and the delimiter is the first '.',
/// the mapping is injective in `name`.
/// ---------------------------------------------------------------------------

type byte = n:nat{ n < 256 }
let dot : byte = 46   // ascii '.'

let dot_free (name:list byte) : bool = not (mem dot name)

let token_id (factory:list byte) (name:list byte) : list byte = name @ (dot :: factory)

let rec pt3_token_id_injective (factory a b : list byte)
  : Lemma (requires dot_free a /\ dot_free b /\ token_id factory a == token_id factory b)
          (ensures  a == b)
          (decreases a)
  = match a, b with
    | [], [] -> ()
    | [], _ :: _ -> ()          // a-id starts with '.', b-id starts with a non-'.' head -> contradiction
    | _ :: _, [] -> ()
    | _ :: xs, _ :: ys -> pt3_token_id_injective factory xs ys

/// Witnesses.
let witness_mint_then_burn ()
  : Lemma (let t0 = { supply = 0; bal = 0; rest = 0 } in
           let t1 = Some?.v (mint t0 5 5 100) in           // owner=5 mints 100 to itself
           conserved t1 /\ t1.supply == 100 /\
           (Some?.v (burn t1 40)).supply == 60)
  = ()
let witness_overburn_rejected ()
  : Lemma (burn ({ supply = 10; bal = 10; rest = 0 }) 20 == None)
  = ()
let witness_nonowner_cannot_mint ()
  : Lemma (mint ({ supply = 0; bal = 0; rest = 0 }) 5 6 100 == None)
  = ()
