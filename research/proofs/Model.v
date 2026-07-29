Require Import Coq.ZArith.ZArith.
Require Import Coq.Lists.List.
Require Import Coq.micromega.Lia.
Import ListNotations.
Open Scope Z_scope.

(* Tokens are just Z *)
Definition TokenId := Z.
(* Accounts are just Z *)
Definition AccountId := Z.

(* An intent is just a list of deltas for a specific account *)
Record TokenDiff := {
  account : AccountId;
  token : TokenId;
  delta : Z; (* Positive = deposit (receive), Negative = withdraw (send) *)
}.

(* Fee collector account id *)
Definition fee_collector : AccountId := 0.

(* State is a list of token diffs to process *)
Definition State := list TokenDiff.

(* Calculate fee for a given amount *)
(* Abstracting the exact division, we assume fee >= 0 and fee <= amount *)
Parameter calc_fee : Z -> Z.
Axiom calc_fee_nonneg : forall a, a >= 0 -> calc_fee a >= 0.
Axiom calc_fee_le : forall a, a >= 0 -> calc_fee a <= a.

(* Apply a token diff, yielding the net effect on deposits/withdrawals *)
(* We model this by tracking the global sum of all deltas for a specific token *)
(* In the real system, deposits sum to X and withdrawals sum to Y, and X must equal Y. *)
(* This is equivalent to saying the sum of all deltas (including fees) must be 0 *)

Fixpoint sum_deltas (tok : TokenId) (diffs : list TokenDiff) : Z :=
  match diffs with
  | [] => 0
  | d :: ds =>
      if Z.eq_dec (token d) tok then
        if Z_lt_dec (delta d) 0 then
          (* Negative delta means withdrawal *)
          let fee := calc_fee (- (delta d)) in
          (* User delta is applied as is (negative) *)
          (* Fee is added to fee collector (positive) *)
          (delta d) + fee + sum_deltas tok ds
        else
          (* Positive delta means deposit, no fee *)
          (delta d) + sum_deltas tok ds
      else
        sum_deltas tok ds
  end.

(* The finalize function requires that for all tokens, the sum of deltas is 0 *)
(* UnmatchedDeltas error is raised if sum_deltas != 0 *)
Definition finalize_valid (tok : TokenId) (diffs : list TokenDiff) : Prop :=
  sum_deltas tok diffs = 0.

(* Theorem: If finalize is valid for a token, then the total value in the system is conserved. *)
(* Specifically, the sum of all withdrawals equals the sum of all deposits plus fees collected. *)
(* We can define positive and negative components explicitly to prove this. *)

Fixpoint sum_positive (tok : TokenId) (diffs : list TokenDiff) : Z :=
  match diffs with
  | [] => 0
  | d :: ds =>
      if Z.eq_dec (token d) tok then
        if Z_ge_dec (delta d) 0 then
          (delta d) + sum_positive tok ds
        else
          sum_positive tok ds
      else
        sum_positive tok ds
  end.

Fixpoint sum_negative_abs (tok : TokenId) (diffs : list TokenDiff) : Z :=
  match diffs with
  | [] => 0
  | d :: ds =>
      if Z.eq_dec (token d) tok then
        if Z_lt_dec (delta d) 0 then
          (- (delta d)) + sum_negative_abs tok ds
        else
          sum_negative_abs tok ds
      else
        sum_negative_abs tok ds
  end.

Fixpoint sum_fees (tok : TokenId) (diffs : list TokenDiff) : Z :=
  match diffs with
  | [] => 0
  | d :: ds =>
      if Z.eq_dec (token d) tok then
        if Z_lt_dec (delta d) 0 then
          calc_fee (- (delta d)) + sum_fees tok ds
        else
          sum_fees tok ds
      else
        sum_fees tok ds
  end.

Lemma sum_deltas_decomposition : forall (tok : TokenId) (diffs : list TokenDiff),
  sum_deltas tok diffs = sum_positive tok diffs - sum_negative_abs tok diffs + sum_fees tok diffs.
Proof.
  intros.
  induction diffs.
  - simpl. reflexivity.
  - simpl. destruct (Z.eq_dec (token a) tok).
    + destruct (Z_lt_dec (delta a) 0).
      * rewrite IHdiffs.
        destruct (Z_ge_dec (delta a) 0).
        -- (* contradiction *)
           lia.
        -- lia.
      * rewrite IHdiffs.
        destruct (Z_ge_dec (delta a) 0).
        -- lia.
        -- (* contradiction *)
           lia.
    + rewrite IHdiffs. reflexivity.
Qed.

Theorem value_conservation : forall (tok : TokenId) (diffs : list TokenDiff),
  finalize_valid tok diffs ->
  sum_negative_abs tok diffs = sum_positive tok diffs + sum_fees tok diffs.
Proof.
  intros.
  unfold finalize_valid in H.
  rewrite sum_deltas_decomposition in H.
  lia.
Qed.

Definition ZERO_SUM_ACHIEVED := value_conservation.
