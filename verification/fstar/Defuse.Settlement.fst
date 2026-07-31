module Defuse.Settlement

/// FSM-1 — Settlement conservation (custody-critical).
///
/// Rust source: contracts/defuse/core/src/engine/state/deltas.rs
///   * TokenTransferMatcher { deposits: map acct->u128, withdrawals: map acct->u128 }
///   * sub_add(sub, add, owner, amount): cancel against the opposite side first,
///     then add the remainder -> an account never holds BOTH a deposit and a
///     withdrawal simultaneously.
///   * TokenTransferMatcher::finalize_into: sort both sides descending, then
///     greedily transfer min(send, receive) sender->receiver, advancing whichever
///     side hits zero. Leftover senders  -> Err(negative sum);
///                       leftover receivers -> Err(positive sum);
///                       both exhausted     -> Ok(()).
///   * TransferMatcher::finalize: fold finalize_into over tokens; Err(0) is the
///     OVERFLOW sentinel; a non-zero unmatched delta -> UnmatchedDeltas; success
///     requires every token's unmatched delta to reconcile to zero.
///
/// Two layers are modeled:
///   (1) ACCOUNTING layer (sub_add / deposit / withdraw): each op moves an
///       account's net by exactly +/- amount and preserves the "never both
///       sides" invariant (also => the `unreachable!()` in sub_add is dead code).
///   (2) MATCHING layer (finalize_into / finalize): the greedy matcher's result
///       depends only on the per-account net sums; success <=> per-token net
///       zero; leftover == the true (non-zero) net difference. Hence a completed
///       batch cannot create or destroy value, and the Err(0) overflow sentinel
///       can never collide with a genuine unmatched delta.
///
/// NOTE (assumption, justified): map entries are always strictly positive,
/// because DefaultMap cleanup (crates/map-utils/src/cleanup.rs) removes any entry
/// that becomes 0, and sub_add never inserts a 0. We model amounts as `pos`.

open FStar.List.Tot

/// ===========================================================================
/// (1) ACCOUNTING LAYER — sub_add / deposit / withdraw
/// ===========================================================================

type acct = { dep : nat; wd : nat }

/// Invariant maintained by sub_add: an account never has both sides non-zero.
let inv (a:acct) : bool = a.dep = 0 || a.wd = 0
let net (a:acct) : int = a.dep - a.wd

let empty_acct : a:acct{inv a /\ net a == 0} = { dep = 0; wd = 0 }

/// deposit == sub_add(withdrawals -> deposits): cancel against withdrawal first.
let deposit (a:acct) (amt:nat) : acct =
  if a.wd >= amt then { dep = a.dep; wd = a.wd - amt }
  else { dep = a.dep + (amt - a.wd); wd = 0 }

/// withdraw == sub_add(deposits -> withdrawals): cancel against deposit first.
let withdraw (a:acct) (amt:nat) : acct =
  if a.dep >= amt then { dep = a.dep - amt; wd = a.wd }
  else { dep = 0; wd = a.wd + (amt - a.dep) }

/// deposit increases net by exactly `amt` and preserves the invariant.
let deposit_correct (a:acct) (amt:nat)
  : Lemma (requires inv a)
          (ensures inv (deposit a amt) /\ net (deposit a amt) == net a + amt)
  = ()

/// withdraw decreases net by exactly `amt` and preserves the invariant.
let withdraw_correct (a:acct) (amt:nat)
  : Lemma (requires inv a)
          (ensures inv (withdraw a amt) /\ net (withdraw a amt) == net a - amt)
  = ()

/// DEF-CON-004 (accounting part): the cancel step never underflows, so the
/// `sub.sub(..).unwrap_or_else(|| unreachable!())` in sub_add is truly dead code.
let sub_add_no_underflow (a:acct) (amt:nat)
  : Lemma (requires inv a)
          (ensures (a.wd >= amt \/ (deposit a amt).wd == 0) /\
                   (a.dep >= amt \/ (withdraw a amt).dep == 0))
  = ()

/// ===========================================================================
/// (2) MATCHING LAYER — finalize_into greedy matcher
/// ===========================================================================

type pos = x:int{ x > 0 }

let rec sum (l:list pos) : nat =
  match l with
  | [] -> 0
  | x :: xs -> x + sum xs

/// Result of the greedy matcher, mirroring finalize_into's return:
///   Matched          <-> Ok(())         (both sides fully consumed)
///   LeftSenders rem  <-> Err(-rem)       (only senders remain; rem = |delta|)
///   LeftReceivers rem<-> Err(+rem)       (only receivers remain; rem = delta)
type mres =
  | Matched      : mres
  | LeftSenders  : rem:pos -> mres
  | LeftReceivers: rem:pos -> mres

/// Faithful transliteration of the finalize_into while-loop:
///   transfer min(send, receive); the exhausted side advances; the partially
///   filled side keeps its remainder as the new head.
/// `ws` = withdrawals (senders), `ds` = deposits (receivers).
let rec gmatch (ws ds : list pos) : Tot mres (decreases (length ws + length ds)) =
  match ws, ds with
  | [], [] -> Matched
  | [], _ :: _ -> LeftReceivers (sum ds)
  | _ :: _, [] -> LeftSenders (sum ws)
  | w :: ws', d :: ds' ->
      if w = d then gmatch ws' ds'
      else if w < d then gmatch ws' ((d - w) :: ds')
      else gmatch ((w - d) :: ws') ds'

/// The core characterization: the matcher result is determined entirely by the
/// two sums. In particular:
///   * Matched               <=> sum ws == sum ds        (per-token NET ZERO)
///   * LeftSenders rem        => rem == sum ws - sum ds > 0
///   * LeftReceivers rem      => rem == sum ds - sum ws > 0
///
/// Consequences (custody):
///   - No value creation/destruction: value only moves via transfers, and a
///     completed match requires the two sides to be exactly equal.
///   - Order independence: the result depends only on the sums, so the descending
///     sort in the Rust code cannot change acceptance/rejection or the residual.
///   - Sentinel soundness: whenever the matcher does NOT match, the residual is
///     strictly positive, so Err(0) can never denote a genuine unmatched delta
///     (Err(0) arises only from the overflow/try_into failure path).
let rec gmatch_sum_char (ws ds : list pos)
  : Lemma (ensures
      (match gmatch ws ds with
       | Matched          -> sum ws == sum ds
       | LeftSenders rem  -> sum ws > sum ds /\ rem == sum ws - sum ds
       | LeftReceivers rem-> sum ds > sum ws /\ rem == sum ds - sum ws))
      (decreases (length ws + length ds))
  = match ws, ds with
    | [], [] -> ()
    | [], _ :: _ -> ()
    | _ :: _, [] -> ()
    | w :: ws', d :: ds' ->
        if w = d then gmatch_sum_char ws' ds'
        else if w < d then gmatch_sum_char ws' ((d - w) :: ds')
        else gmatch_sum_char ((w - d) :: ws') ds'

/// Restatement of the acceptance criterion (DEF-CON-002, single token).
let gmatch_ok_iff_net_zero (ws ds : list pos)
  : Lemma (Matched? (gmatch ws ds) <==> sum ws == sum ds)
  = gmatch_sum_char ws ds

/// Sentinel soundness (explicit): a non-matching token always yields residual > 0.
let residual_positive (ws ds : list pos)
  : Lemma (requires ~(Matched? (gmatch ws ds)))
          (ensures (match gmatch ws ds with
                    | LeftSenders rem -> rem > 0
                    | LeftReceivers rem -> rem > 0
                    | Matched -> False))
  = gmatch_sum_char ws ds

/// ===========================================================================
/// FINALIZE across all tokens.
/// ===========================================================================

/// A batch is a list of tokens, each with its (withdrawals, deposits) lists.
let token = list pos & list pos

let rec all_net_zero (b:list token) : bool =
  match b with
  | [] -> true
  | (ws, ds) :: rest -> (sum ws = sum ds) && all_net_zero rest

/// TransferMatcher::finalize succeeds iff every token's greedy match is Matched.
/// (Both failure sub-paths — the Err(0) overflow sentinel and a non-zero
/// UnmatchedDeltas — reject the batch, so acceptance requires ALL tokens Matched.)
let rec finalize_ok (b:list token) : bool =
  match b with
  | [] -> true
  | (ws, ds) :: rest -> Matched? (gmatch ws ds) && finalize_ok rest

/// DEF-CON-001/002: the batch is accepted IFF every token conserves value
/// (per-token deposits total == withdrawals total). Success cannot admit any
/// token that creates or destroys value.
let rec finalize_conserves (b:list token)
  : Lemma (finalize_ok b <==> all_net_zero b)
  = match b with
    | [] -> ()
    | (ws, ds) :: rest ->
        gmatch_ok_iff_net_zero ws ds;
        finalize_conserves rest

/// ===========================================================================
/// Witnesses (kani::cover! analogues): every branch class is reachable.
/// ===========================================================================

let witness_matched () : Lemma (gmatch [5;3] [3;5] == Matched) =
  gmatch_sum_char [5;3] [3;5]
let witness_left_senders () : Lemma (LeftSenders? (gmatch [10] [3])) =
  gmatch_sum_char [10] [3]
let witness_left_receivers () : Lemma (LeftReceivers? (gmatch [3] [10])) =
  gmatch_sum_char [3] [10]
let witness_multi_token () : Lemma (finalize_ok [([5],[5]); ([2;3],[4;1])]) =
  finalize_conserves [([5],[5]); ([2;3],[4;1])]
