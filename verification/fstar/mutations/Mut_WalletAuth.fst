module Mut_WalletAuth

/// MUTATION (expected to FAIL verification) — non-vacuity check for FSM-14.
///
/// We drop `check_lockout` from the disable/remove paths, so the wallet can be
/// driven into the bricked state (signature off AND no extensions). The
/// invariant-preservation lemma WA-1 must FAIL.

open FStar.List.Tot

type account = nat
type wstate = { signature_enabled : bool; extensions : list account }
let has_auth_path (s:wstate) : bool = s.signature_enabled || Cons? s.extensions
type wop = | SetSignatureMode : enable:bool -> wop | RemoveExtension : a:account -> wop

/// BUG: no check_lockout guard.
let step_bad (s:wstate) (o:wop) : option wstate =
  match o with
  | SetSignatureMode enable ->
      if s.signature_enabled = enable then None
      else Some ({ s with signature_enabled = enable })
  | RemoveExtension a ->
      if not (mem a s.extensions) then None
      else Some ({ s with extensions = filter (fun x -> x <> a) s.extensions })

let wa1_step_preserves_bad (s:wstate) (o:wop)
  : Lemma (requires has_auth_path s)
          (ensures (match step_bad s o with Some s' -> has_auth_path s' | None -> True))
  = ()
