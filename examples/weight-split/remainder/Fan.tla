-------------------------------- MODULE Fan --------------------------------
(***************************************************************************)
(* The whole-Ggas remainder of the unused-gas split.  nearcore gives each  *)
(* weighted call floor(U * w / W) in gas units and the last one also the   *)
(* remainder, fewer than n gas units for n calls                           *)
(* (runtime/runtime/src/receipt_manager.rs:679-719 @ bc4e9e8).  The model  *)
(* splits a U in whole Ggas, which is at most nearcore's U (fees rounded   *)
(* up, burns an upper envelope).  Handing the model's remainder (up to     *)
(* n - 1 Ggas) to the last call can then give it more than nearcore does; *)
(* under NearFees.FeeRounding = "up" (the default) the model hands out no  *)
(* remainder, so no call gets more than in nearcore.                       *)
(*                                                                         *)
(* S.fan() creates six calls W.k1() .. W.k6(), static 1 Tgas, weight 1     *)
(* each.  Illustrative table (Ggas, not measured): fan burns 2000, each    *)
(* call costs its creator a 300 exec fee, k1..k5 burn 500, k6 burns       *)
(* 1169.9 Ggas in nearcore, 1170 in the table (rounded up).  Prepaid       *)
(* 10801: Need(fan) = 2000 + 6 * (300 + 1000) = 9800, U = 1001.            *)
(* nearcore's leftover is taken to be 1009.84125084 Ggas (a review's       *)
(* arithmetic, about 8.8 Ggas of rounded-up fees above the model's): each  *)
(* call gets 168.30687514 Ggas in nearcore.                                *)
(*   "up":      every call 1000 + floor(1001 / 6) = 1166 <= 1168.31;       *)
(*              k6 runs out of gas (1166 < 1170), as in nearcore           *)
(*              (1168.31 < 1169.9).  Run remainder_up_ok.                  *)
(*   "nearest": k6, the last, 1000 + 1001 - 5 * 166 = 1171 > 1168.31:     *)
(*              SharesLeNearcore fails (remainder_nearest_over), and k6    *)
(*              succeeds where nearcore runs out of gas: NoFalseOk fails   *)
(*              (remainder_nearest_false_ok).                              *)
(*                                                                         *)
(* nearcore's figures are in uGgas (1000 gas units), rounded down so they  *)
(* stay below TLC's 2^31 and below nearcore's real shares: the checks are  *)
(* at least as strict as the exact ones.                                   *)
(***************************************************************************)
EXTENDS NearAsync

CONSTANTS U, S, W, Prepaid

VARIABLES got, okd, sent
vars == <<platformVars, got, okd, sent>>

Accts == {U, S, W}
PFloor == [a \in Accts |-> 0]
N == 6
St == 1000
Fee == 300
Calls == <<"k1", "k2", "k3", "k4", "k5", "k6">>
GC == [st |-> <<St>>, wt |-> <<1>>, fee |-> Fee]
B(x) == [base |-> x, per |-> 0]
PGasCall == [m \in {Calls[i] : i \in 1..N} |-> GC]
PGasBurn == ("fan" :> B(2000)) @@ [m \in {Calls[i] : i \in 1..5} |-> B(500)] @@ ("k6" :> B(1170))
Idx(m) == CHOOSE i \in 1..N : Calls[i] = m

\* nearcore, in uGgas: the leftover, each call's share (the last also gets
\* the remainder), and k6's exact burn.
Mu == 1000000
NearLeftU == 1009841250              \* 1009.84125084 Ggas, rounded down
NearShareU(i) == IF i < N THEN NearLeftU \div N ELSE NearLeftU - (N - 1) * (NearLeftU \div N)
K6BurnU == 1169900000                \* 1169.9 Ggas
\* The premise of the "up" rule: the model's leftover is at most nearcore's.
ModelLeft == Prepaid - (2000 + N * (Fee + St))
ASSUME ModelLeft * Mu <= NearLeftU

Start == /\ ~sent
         /\ Submit(WithGas(Rcpt(nid, 1, S, U, "fan", [n |-> 0], 0, U, 0), Prepaid))
         /\ sent' = TRUE
         /\ UNCHANGED <<got, okd>>

HFan(r) ==
    Outcome({Rcpt(nid + i - 1, r.tx, W, S, Calls[i], [n |-> 0], 0, S, 0) : i \in 1..N},
            {}, RVal(0), 0, N)

Step(r) ==
    LET O == IF r.m = "fan" THEN HFan(r) ELSE Outcome({}, {}, RVal(0), 0, 0) IN
    /\ Exec(r, O)
    /\ got' = IF r.m = "fan" THEN got ELSE [got EXCEPT ![r.m] = GasOf(r)]
    /\ okd' = IF r.m # "fan" /\ Ok(r, O) THEN okd \cup {r.m} ELSE okd
    /\ UNCHANGED sent

Run == \E r \in Runnable :
         IF IsBuiltin(r) THEN ExecBuiltin(r) /\ UNCHANGED <<got, okd, sent>> ELSE Step(r)

Init == /\ PlatformInit([a \in Accts |-> 0], {1})
        /\ got = [m \in {Calls[i] : i \in 1..N} |-> -1]
        /\ okd = {}
        /\ sent = FALSE

Next == Start \/ Run
Spec == Init /\ [][Next]_vars

\* Directional: no call gets more gas in the model than in nearcore.
SharesLeNearcore ==
    \A m \in DOMAIN got : got[m] # -1 => got[m] * Mu <= St * Mu + NearShareU(Idx(m))
\* A call the model lets succeed has enough gas in nearcore.
NoFalseOk == "k6" \in okd => St * Mu + NearShareU(N) >= K6BurnU
\* The "up" split, written out: floor(1001 / 6) = 166 for every call.
UpSplit == \A m \in DOMAIN got : got[m] # -1 => got[m] = St + ModelLeft \div N
\* Every call ran; k1..k5 succeeded, k6 ran out of gas.
Settled == (sent /\ Idle) =>
    /\ \A m \in DOMAIN got : got[m] # -1
    /\ okd = {Calls[i] : i \in 1..5}
    /\ oog = {<<1, "k6">>}
\* Library sanity: NEAR conserved, gas bounded by the prepaid gas, and no
\* orphans (fan has no callback; listed so that Idle in Settled stays meaningful).
Sane == NearConserved(0) /\ GasBounded(LAMBDA t : Prepaid) /\ NoOrphans
=============================================================================
