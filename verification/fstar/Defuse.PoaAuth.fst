module Defuse.PoaAuth

/// FSM-16 — PoA bridge mint/deploy authorization matrix (AUTH-003; "no unauthorized mint").
///
/// Rust sources:
///   contracts/poa/token/src/contract.rs   : ft_deposit (MINT) is #[only(self, owner)]
///   contracts/poa/factory/src/contract.rs : deploy_token = #[access_control_any(DAO, TokenDeployer)]
///                                           ft_deposit   = #[access_control_any(DAO, TokenDepositer)]
///                                           both #[pause]; deploy_token calls token `new` WITHOUT an
///                                           owner ⇒ owner defaults to predecessor = the FACTORY.
///
/// Mint authority chain: DAO|TokenDepositer → factory.ft_deposit → (factory == token owner) →
/// token.ft_deposit. We model the intended authorization matrix (the `#[only]`/`#[access_control_any]`
/// macro expansions are trusted) and prove no principal outside the authorized roles can cause a mint or
/// deploy a pre-owned token.

type principal = nat
type role = | DAO | TokenDeployer | TokenDepositer | PauseManager | UnpauseManager

/// Role assignment: does principal `p` hold role `r`?
type roles = principal -> role -> bool

/// ---- Token-level mint gate: only the token's owner may mint. ----
let token_can_mint (owner:principal) (caller:principal) : bool = caller = owner

/// ---- Factory: the deployed token's owner is always the factory itself. ----
let factory : principal = 0

/// A mint on a token owned by `owner`, attempted directly by `caller`, mints iff caller == owner.
let direct_mint_ok (owner caller : principal) : bool = token_can_mint owner caller

/// Factory gate for `ft_deposit` (mint trigger): requires DAO or TokenDepositer, and not paused.
let factory_ft_deposit_ok (has:roles) (caller:principal) (paused:bool) : bool =
  not paused && (has caller DAO || has caller TokenDepositer)

/// Factory gate for `deploy_token`: requires DAO or TokenDeployer, and not paused.
let factory_deploy_ok (has:roles) (caller:principal) (paused:bool) : bool =
  not paused && (has caller DAO || has caller TokenDeployer)

/// A mint actually occurs on a factory-deployed token (owner == factory) iff EITHER the caller is the
/// factory directly (owner), OR the caller goes through `factory.ft_deposit` with the right role while the
/// factory (as owner) performs the token mint.
let mint_occurs (has:roles) (caller:principal) (paused:bool) : bool =
  // path (a): caller is the token owner (the factory) and calls token.ft_deposit directly
  direct_mint_ok factory caller
  // path (b): caller invokes factory.ft_deposit (role-gated); the factory then mints as owner
  || factory_ft_deposit_ok has caller paused

/// PA-1: no principal without DAO|TokenDepositer (and who is not the factory itself) can cause a mint.
let pa1_mint_authority (has:roles) (caller:principal) (paused:bool)
  : Lemma (requires mint_occurs has caller paused)
          (ensures  caller = factory \/ has caller DAO \/ has caller TokenDepositer)
  = ()

/// PA-3 (mint): when paused, only the factory-owner direct path could apply; an external role-based mint
/// is rejected.
let pa3_mint_paused (has:roles) (caller:principal)
  : Lemma (requires caller <> factory)
          (ensures  not (mint_occurs has caller true))
  = ()

/// ---- Deploy authority + ownership chain. ----

/// Deploy returns the new token's owner (= factory) on success; None if unauthorized/paused.
let deploy (has:roles) (caller:principal) (paused:bool) : option principal =
  if factory_deploy_ok has caller paused then Some factory else None

/// PA-2: deploy succeeds only for DAO|TokenDeployer, and the deployed token is owned by the factory
/// (never pre-owned by an attacker).
let pa2_deploy_authority (has:roles) (caller:principal) (paused:bool)
  : Lemma (requires Some? (deploy has caller paused))
          (ensures  (has caller DAO \/ has caller TokenDeployer) /\
                    Some?.v (deploy has caller paused) == factory)
  = ()

/// PA-3 (deploy): paused ⇒ deploy rejected.
let pa3_deploy_paused (has:roles) (caller:principal)
  : Lemma (deploy has caller true == None)
  = ()

/// Corollary: an attacker with NO roles who is not the factory can neither mint nor deploy.
let attacker_powerless (has:roles) (caller:principal) (paused:bool)
  : Lemma (requires caller <> factory /\
                    not (has caller DAO) /\ not (has caller TokenDepositer) /\
                    not (has caller TokenDeployer))
          (ensures  not (mint_occurs has caller paused) /\ None? (deploy has caller paused))
  = ()

/// Witnesses.
let witness_depositer_can_mint (has:roles) (c:principal)
  : Lemma (requires has c TokenDepositer /\ c <> factory)
          (ensures  mint_occurs has c false)
  = ()
let witness_random_cannot_mint ()
  : Lemma (let has : roles = (fun _ _ -> false) in not (mint_occurs has 7 false))
  = ()
