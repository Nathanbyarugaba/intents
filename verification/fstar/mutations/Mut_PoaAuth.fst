module Mut_PoaAuth

/// MUTATION (expected to FAIL verification) — non-vacuity check for FSM-16.
///
/// We drop the role gate on `factory.ft_deposit`, so ANY caller can trigger a
/// mint (infinite-money bug). The PA-1 authority lemma must FAIL.

type principal = nat
type role = | DAO | TokenDeployer | TokenDepositer | PauseManager | UnpauseManager
type roles = principal -> role -> bool

let factory : principal = 0
let direct_mint_ok (owner caller : principal) : bool = caller = owner

/// BUG: no role check — anyone can mint via the factory.
let factory_ft_deposit_ok_bad (_has:roles) (_caller:principal) (paused:bool) : bool = not paused

let mint_occurs_bad (has:roles) (caller:principal) (paused:bool) : bool =
  direct_mint_ok factory caller || factory_ft_deposit_ok_bad has caller paused

let pa1_mint_authority_bad (has:roles) (caller:principal) (paused:bool)
  : Lemma (requires mint_occurs_bad has caller paused)
          (ensures  caller = factory \/ has caller DAO \/ has caller TokenDepositer)
  = ()
