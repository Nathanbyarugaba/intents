module Mut_PoaToken

/// MUTATION (expected to FAIL verification) — non-vacuity check for FSM-17.
///
/// We drop the owner check on MINT, so any caller can mint. The owner-only lemma
/// PT-2 must FAIL (an unauthorized caller can inflate supply — infinite money).

type account = nat
type tok = { supply : nat; bal : nat; rest : nat }
let conserved (t:tok) : bool = t.supply = t.bal + t.rest
type wf = t:tok{ conserved t }

/// BUG: no owner check — anyone mints.
let mint_bad (t:wf) (owner caller : account) (amt:nat) : option wf =
  Some ({ t with supply = t.supply + amt; bal = t.bal + amt })

let pt2_mint_only_owner_bad (t:wf) (owner caller : account) (amt:nat)
  : Lemma (requires caller <> owner) (ensures mint_bad t owner caller amt == None)
  = ()
