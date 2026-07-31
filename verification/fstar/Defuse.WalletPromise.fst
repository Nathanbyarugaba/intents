module Defuse.WalletPromise

/// FSM-13 — Wallet promise authorization (WAL-PRO-001).
///
/// Rust sources:
///   contracts/wallet/src/contract.rs :: WalletImpl::build_promise / execute_request
///   crates/near/promise/src/lib.rs            (NearPromise: FLAT { receiver_id; actions })
///   crates/near/promise/src/actions/mod.rs    (NearAction: 3 variants only)
///
///   fn build_promise(p) -> Result<Promise> {
///     if p.receiver_id == env::current_account_id() { return Err(SelfCallsNotAllowed); }
///     if !p.actions.iter().all(|a| matches!(a,
///            FunctionCall(_) | Transfer(_) | DeterministicStateInit(_))) {
///        return Err(UnsupportedPromiseAction);
///     }
///     Ok(p.build())
///   }
///
/// Two facts make wallet account-takeover impossible:
///   (1) `NearAction` is a 3-variant enum — AddKey/DeleteKey/DeployContract/CreateAccount/Stake/
///       DeleteAccount are NOT REPRESENTABLE; and `build_promise` allow-lists exactly those 3 (defensive
///       against future variants).
///   (2) `NearPromise` is FLAT (no nested `.then`/batch), so the single-level check is complete; and
///       self-calls are rejected.
///
/// We model a `Dangerous` action standing for any hypothetical future account-mutating action, to give
/// the allow-list real force, and prove a wallet promise can never self-call nor carry a dangerous action.

open FStar.List.Tot

type account = nat   // abstract account id

/// The real enum's 3 safe variants + a synthetic `Dangerous` (any future account-mutating action).
type near_action =
  | FunctionCall
  | Transfer
  | DeterministicStateInit
  | Dangerous              // NOT representable in the real 3-variant enum; models a future/unsafe action

let is_safe (a:near_action) : bool =
  match a with
  | FunctionCall | Transfer | DeterministicStateInit -> true
  | Dangerous -> false

/// A flat NEAR promise (mirrors the Rust struct: no nesting).
type near_promise = { receiver_id : account; actions : list near_action }

type perr = | SelfCallsNotAllowed | UnsupportedPromiseAction

/// build_promise as a total function returning either Ok or a rejection reason.
let build_promise (me:account) (p:near_promise) : either perr near_promise =
  if p.receiver_id = me then Inl SelfCallsNotAllowed
  else if not (for_all is_safe p.actions) then Inl UnsupportedPromiseAction
  else Inr p

let rec mem_dangerous_unsafe (l:list near_action)
  : Lemma (requires mem Dangerous l) (ensures not (for_all is_safe l))
  = match l with
    | [] -> ()
    | x :: xs -> if x = Dangerous then () else mem_dangerous_unsafe xs

let rec for_all_safe_no_dangerous (l:list near_action)
  : Lemma (requires for_all is_safe l) (ensures not (mem Dangerous l))
  = match l with
    | [] -> ()
    | _ :: xs -> for_all_safe_no_dangerous xs

/// WP-1: an ACCEPTED wallet promise never self-calls and carries only safe actions.
let wp1_accepted_is_safe (me:account) (p:near_promise)
  : Lemma (requires Inr? (build_promise me p))
          (ensures  p.receiver_id <> me /\ for_all is_safe p.actions)
  = ()

/// WP-2: any promise with a dangerous action, or targeting self, is rejected.
let wp2_dangerous_rejected (me:account) (p:near_promise)
  : Lemma (requires p.receiver_id = me \/ mem Dangerous p.actions)
          (ensures  Inl? (build_promise me p))
  = if mem Dangerous p.actions then mem_dangerous_unsafe p.actions

/// Corollary: no accepted wallet promise can perform a `Dangerous` (key/code/account-mutating) action.
let no_account_mutation (me:account) (p:near_promise)
  : Lemma (requires Inr? (build_promise me p)) (ensures not (mem Dangerous p.actions))
  = wp1_accepted_is_safe me p;
    for_all_safe_no_dangerous p.actions

/// WP-3 (fan-out): building a whole request's external promises succeeds only if EVERY promise is safe;
/// hence no promise in an accepted request self-calls or mutates the wallet account.
let rec build_all (me:account) (ps:list near_promise) : bool =
  match ps with
  | [] -> true
  | p :: rest -> Inr? (build_promise me p) && build_all me rest

let rec wp3_fanout_all_safe (me:account) (ps:list near_promise) (p:near_promise)
  : Lemma (requires build_all me ps /\ mem p ps)
          (ensures  p.receiver_id <> me /\ for_all is_safe p.actions)
  = match ps with
    | [] -> ()
    | q :: rest -> if q = p then wp1_accepted_is_safe me p else wp3_fanout_all_safe me rest p

/// Witnesses.
let witness_self_call_rejected ()
  : Lemma (Inl? (build_promise 1 ({ receiver_id = 1; actions = [FunctionCall] }))) = ()
let witness_transfer_ok ()
  : Lemma (Inr? (build_promise 1 ({ receiver_id = 2; actions = [Transfer; FunctionCall] }))) = ()
let witness_dangerous_rejected ()
  : Lemma (Inl? (build_promise 1 ({ receiver_id = 2; actions = [FunctionCall; Dangerous] })))
  = wp2_dangerous_rejected 1 ({ receiver_id = 2; actions = [FunctionCall; Dangerous] })
