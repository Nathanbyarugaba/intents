module Mut_Migration

/// MUTATION (expected to FAIL verification) — non-vacuity check for FSM-11.
///
/// We corrupt the V0->Account migration by INVERTING the
/// `implicit_public_key_removed` flag. This silently flips whether the implicit
/// key is usable (an authorization change on migration). The field-preservation
/// lemma must FAIL.

type flags = { implicit_removed : bool; auth_pred_disabled : bool }
type acct = { keys : list nat; bal : nat; legacy_nonces : list nat;
              new_nonces : list nat; fl : flags; locked : bool }
type v0 = { v0_implicit_removed : bool; v0_keys : list nat; v0_bal : nat; v0_nonces : list nat }

/// BUG: `implicit_removed = not a.v0_implicit_removed`
let from_v0_bad (a:v0) : acct = {
  keys = a.v0_keys; bal = a.v0_bal;
  legacy_nonces = a.v0_nonces; new_nonces = [];
  fl = { implicit_removed = not a.v0_implicit_removed; auth_pred_disabled = false };
  locked = false;
}

let v0_preserves_bad (a:v0)
  : Lemma ((from_v0_bad a).fl.implicit_removed == a.v0_implicit_removed)
  = ()
