module Defuse.WalletNonce

/// FSM-15 — Wallet dual-window nonce replay protection (WAL-NON-001/002 + WAL-SIG created_at binding).
///
/// Rust source: contracts/wallet/src/nonces.rs
///   commit(nonce, created_at, msg_timeout):
///     check_cleanup();  // rotate current->old (mem::take); clear old if 2*timeout elapsed
///     let W = min(self.timeout, msg_timeout);
///     require now - W <= created_at <= now;             // validity window
///     if old.get_bit(nonce) || current.set_bit(nonce) { Err(AlreadyUsed) }  // dual-window test-and-set
///   check_cleanup():
///     if last_cleaned < now - timeout { old = take(current);
///                                       if last_cleaned < now - 2*timeout { old = {} };
///                                       last_cleaned = now }
///
/// The security goal: a signed message `(nonce, created_at)` cannot be REPLAYED while it is still valid.
/// This rests on RETENTION (a committed nonce stays in current∨old long enough) exceeding the VALIDITY
/// window. We model the retention state machine of a single tracked nonce and prove:
///   * retention: a nonce committed at `now1` (with `last_cleaned >= now1 - T` post-commit) is never
///     fully cleared before `now1 + T`;
///   * window arithmetic: a valid replay at `now2` satisfies `now2 <= now1 + T` (since `W <= T` and
///     `created_at <= now1`);
///   * hence WN-1: while valid, the nonce is still present, so the dual-window test rejects the replay.

/// Which slot the tracked nonce occupies.
type slot = | Cur | Old | Gone

/// One `check_cleanup` at time `t` applied to the tracked nonce's (slot, last_cleaned).
/// A rotation moves current->old; the 2*T clear then wipes `old` (which just received current).
let rotate (t_out:nat) (tt:nat) (s:slot) (lc:nat) (t:nat) : (slot & nat) =
  // t_out = timeout T ; tt unused placeholder kept for clarity
  if lc + t_out < t then
    let s1 = (match s with | Cur -> Old | Old -> Gone | Gone -> Gone) in
    let s2 = if lc + 2 * t_out < t then Gone else s1 in
    (s2, t)
  else (s, lc)

/// Retention invariant relative to the commit time `now1` and timeout `T`.
let inv (t_out now1 : nat) (s:slot) (lc:nat) : bool =
  match s with
  | Cur  -> lc + t_out >= now1        // post-commit: last_cleaned >= now1 - T
  | Old  -> lc >= now1                // the rotation into Old happened after now1
  | Gone -> lc > now1 + t_out         // full clear only happens strictly after now1 + T

let rotate_preserves (t_out now1 : nat) (s:slot) (lc:nat) (t:nat)
  : Lemma (requires inv t_out now1 s lc /\ t_out > 0)
          (ensures (let (s', lc') = rotate t_out 0 s lc t in inv t_out now1 s' lc'))
  = ()

/// Fold rotations over an arbitrary (adversarial) list of cleanup times.
let rec rotate_all (t_out now1 : nat) (s:slot) (lc:nat) (ts:list nat) : Tot (slot & nat) (decreases ts) =
  match ts with
  | [] -> (s, lc)
  | t :: rest -> let (s', lc') = rotate t_out 0 s lc t in rotate_all t_out now1 s' lc' rest

let rec inv_preserved_all (t_out now1 : nat) (s:slot) (lc:nat) (ts:list nat)
  : Lemma (requires inv t_out now1 s lc /\ t_out > 0)
          (ensures (let (s', lc') = rotate_all t_out now1 s lc ts in inv t_out now1 s' lc'))
          (decreases ts)
  = match ts with
    | [] -> ()
    | t :: rest ->
        rotate_preserves t_out now1 s lc t;
        let (s', lc') = rotate t_out 0 s lc t in
        inv_preserved_all t_out now1 s' lc' rest

/// `last_cleaned` after rotations is bounded by the largest cleanup time considered (and the initial lc).
let rec lc_bounded (t_out now1 bound : nat) (s:slot) (lc:nat) (ts:list nat)
  : Lemma (requires lc <= bound /\ (forall (t:nat). List.Tot.mem t ts ==> t <= bound))
          (ensures (let (_, lc') = rotate_all t_out now1 s lc ts in lc' <= bound))
          (decreases ts)
  = match ts with
    | [] -> ()
    | t :: rest ->
        let (s', lc') = rotate t_out 0 s lc t in
        lc_bounded t_out now1 bound s' lc' rest

/// RETENTION: starting from the post-commit state (Cur, lc0 with lc0 + T >= now1), after ANY sequence of
/// cleanups all occurring no later than `now2`, if `now2 <= now1 + T` then the nonce is NOT fully cleared.
let retention_within_window (t_out now1 now2 lc0 : nat) (ts:list nat)
  : Lemma
      (requires t_out > 0 /\ lc0 + t_out >= now1 /\ lc0 <= now2 /\ now2 <= now1 + t_out /\
                (forall (t:nat). List.Tot.mem t ts ==> t <= now2))
      (ensures  (let (s', _) = rotate_all t_out now1 Cur lc0 ts in s' <> Gone))
  = inv_preserved_all t_out now1 Cur lc0 ts;
    lc_bounded t_out now1 now2 Cur lc0 ts
    // if s' = Gone then inv gives lc' > now1 + t_out >= now2, contradicting lc' <= now2

/// WINDOW ARITHMETIC: a valid replay happens within `T` of the original commit.
/// `W = min(T, msg_timeout) <= T`; validity at now2 is `created_at + W >= now2`; commit needs
/// `created_at <= now1`. Hence `now2 <= created_at + W <= now1 + T`.
let valid_replay_within_T (t_out w created_at now1 now2 : nat)
  : Lemma (requires w <= t_out /\ created_at <= now1 /\ created_at + w >= now2)
          (ensures  now2 <= now1 + t_out)
  = ()

/// WN-1 (composition): while a committed message is still valid, its nonce is still present in the
/// dual-window store, so a replay is rejected by the used-bit test.
let wn1_no_valid_replay (t_out w created_at now1 now2 lc0 : nat) (ts:list nat)
  : Lemma
      (requires t_out > 0 /\ w <= t_out /\ created_at <= now1 /\ created_at + w >= now2 /\
                lc0 + t_out >= now1 /\ lc0 <= now2 /\
                (forall (t:nat). List.Tot.mem t ts ==> t <= now2))
      (ensures  (let (s', _) = rotate_all t_out now1 Cur lc0 ts in s' <> Gone))
  = valid_replay_within_T t_out w created_at now1 now2;
    retention_within_window t_out now1 now2 lc0 ts

/// WN-2: the effective validity window never exceeds `self.timeout` (the `min`).
let wn2_window_bound (self_timeout msg_timeout : nat)
  : Lemma (let w = (if self_timeout <= msg_timeout then self_timeout else msg_timeout) in w <= self_timeout)
  = ()

/// Witnesses.
let witness_no_rotation_present ()
  : Lemma (fst (rotate_all 10 100 Cur 95 [102; 105]) <> Gone)
  = ()
let witness_late_clear_gone ()
  : Lemma (fst (rotate_all 10 100 Cur 95 [140]) == Gone)
  = ()   // 95 + 2*10 = 115 < 140 -> Cur wiped (t=140 > now1+T=110), consistent with retention bound
