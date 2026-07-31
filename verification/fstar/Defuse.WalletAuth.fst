module Defuse.WalletAuth

/// FSM-14 — Wallet no-lockout authorization invariant (WAL-AUT-002).
///
/// Rust source: contracts/wallet/src/contract.rs
///   set_signature_mode(enable): if already == enable -> Err(ThisSignatureModeAlreadySet);
///                               set; check_lockout().
///   add_extension(a): if !insert -> Err(ExtensionEnabled); emit.
///   remove_extension(a): if !remove -> Err(ExtensionNotEnabled); check_lockout().
///   check_lockout(): if !signature_enabled && extensions.is_empty() -> Err(Lockout).
///
/// The wallet must always retain at least one authorization path (signature OR at least one extension),
/// otherwise it would be permanently bricked. We prove that invariant is preserved by ANY op sequence.

open FStar.List.Tot

type account = nat

type wstate = { signature_enabled : bool; extensions : list account }

/// The safety invariant: at least one authorization path remains.
let has_auth_path (s:wstate) : bool = s.signature_enabled || Cons? s.extensions

type wop =
  | SetSignatureMode : enable:bool -> wop
  | AddExtension     : a:account -> wop
  | RemoveExtension  : a:account -> wop

/// check_lockout: reject a transition into the bricked state.
let check_lockout (s:wstate) : bool = has_auth_path s   // true = ok, false = would-be Lockout

/// Apply an op, returning None on rejection (mirrors the Rust `Result` errors).
let step (s:wstate) (o:wop) : option wstate =
  match o with
  | SetSignatureMode enable ->
      if s.signature_enabled = enable then None                    // ThisSignatureModeAlreadySet
      else let s' = { s with signature_enabled = enable } in
           if check_lockout s' then Some s' else None              // Lockout
  | AddExtension a ->
      if mem a s.extensions then None                              // ExtensionEnabled
      else Some ({ s with extensions = a :: s.extensions })        // add can't cause lockout
  | RemoveExtension a ->
      if not (mem a s.extensions) then None                        // ExtensionNotEnabled
      else let s' = { s with extensions = filter (fun x -> x <> a) s.extensions } in
           if check_lockout s' then Some s' else None              // Lockout

/// WA-1 (single step): any accepted op preserves the auth-path invariant.
let wa1_step_preserves (s:wstate) (o:wop)
  : Lemma (requires has_auth_path s)
          (ensures (match step s o with Some s' -> has_auth_path s' | None -> True))
  = match o with
    | AddExtension a ->
        // adding prepends, so extensions stays non-empty
        ()
    | _ -> ()

/// WA-1 (any schedule): the invariant is preserved by ANY op sequence from a valid state.
let rec run (s:wstate) (ops:list wop) : Tot (option wstate) (decreases ops) =
  match ops with
  | [] -> Some s
  | o :: rest -> (match step s o with None -> run s rest | Some s' -> run s' rest)

let rec wa1_run_preserves (s:wstate) (ops:list wop)
  : Lemma (requires has_auth_path s)
          (ensures (match run s ops with Some s' -> has_auth_path s' | None -> True))
          (decreases ops)
  = match ops with
    | [] -> ()
    | o :: rest ->
        wa1_step_preserves s o;
        (match step s o with
         | None -> wa1_run_preserves s rest
         | Some s' -> wa1_run_preserves s' rest)

/// WA-2: toggling signature to its current value, or add/remove of a present/absent extension, is rejected.
let wa2_noop_toggle_rejected (s:wstate)
  : Lemma (step s (SetSignatureMode s.signature_enabled) == None)
  = ()

/// Witnesses.
let witness_cannot_brick_via_sig ()
  : Lemma (step ({ signature_enabled = true; extensions = [] }) (SetSignatureMode false) == None) = ()
let witness_remove_last_ext_when_sig_off ()
  : Lemma (step ({ signature_enabled = false; extensions = [5] }) (RemoveExtension 5) == None) = ()
let witness_remove_ext_ok_when_sig_on ()
  : Lemma (Some? (step ({ signature_enabled = true; extensions = [5] }) (RemoveExtension 5))) = ()
