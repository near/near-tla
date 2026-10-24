---------------------------- MODULE BatchPayout ----------------------------
(***************************************************************************)
(* A batch payout whose event grows with the batch.                        *)
(*                                                                         *)
(* A distributor D owes a recipient R a reward of N ids of each of two     *)
(* kinds on a NEP-245 token MT (near-sdk-contract-tools 4.0.0): AmtA of    *)
(* each id of class "ca" and AmtB of each id of class "cb" (Nep245 id      *)
(* classes: MtIdCount gives each class N ids, so the batch has 2N ids      *)
(* while its vectors have two entries).  U calls D.payout(); D sends one   *)
(* mt_batch_transfer of all of them to R and then runs on_payout, which    *)
(* records the payout as done or, if the batch failed, as still owed.      *)
(*                                                                         *)
(* The token's mt_transfer event lists every id and amount, so its length  *)
(* grows with N (Nep245 MtTransferLog): the ids are 12 bytes, the amounts  *)
(* 19 and 20 digits (EvAmtExp 18), D's and R's ids 16 and 14 bytes.  At    *)
(* 175 + 75 N bytes it is over nearcore's 16384 from N = 217 (434 ids):    *)
(* the batch fails with TotalLogLengthExceeded (R6), nothing moves, and    *)
(* on_payout sees Failed.                                                  *)
(*                                                                         *)
(* Correct: on_payout records "owed" again when the batch failed, so D's   *)
(* books match the ledger (Books).  Wrong (Bug = "ignore"): on_payout      *)
(* records the payout as done whatever the result; past the edge R is     *)
(* recorded paid and holds nothing.                                        *)
(*                                                                         *)
(* NeverPaid (R never receives the reward) is the size sweep's success    *)
(* condition: the least N at which it holds is the batch size at which    *)
(* the event no longer fits (runs.toml, sweep payout_edge).                *)
(***************************************************************************)
EXTENDS Nep245

CONSTANTS U, D, R, MT,
          N,          \* ids per class
          AmtA, AmtB, \* the reward per id of each class (model units, x 10^18)
          MaxTx,      \* payout calls
          Bug         \* "none" | "ignore"

VARIABLES st, ntx
mine == <<mtk, st, ntx>>
vars == <<platformVars, mine>>

Accts == {U, D, R, MT}
TxIds == 1..MaxTx
PFloor     == [a \in Accts |-> 0]
NoGasTable == [x \in {} |-> 0]
PMtHolders == [a \in {MT} |-> {D, R}]
PMtDev     == [a \in {MT} |-> {"zeroAmountSkipped", "selfTransferCredits"}]
PMtReserve == [a \in {MT} |-> 0]
\* Event lengths: two classes of N ids of 12 bytes (e.g. "reward-00001"),
\* amounts with 18 decimals, D and R as 16- and 14-byte ids.
PIdCount == [i \in {"ca", "cb"} |-> N]
PIdLen   == [i \in {"ca", "cb"} |-> 12]
PAmtExp  == [t \in {MT} |-> 18]
PAcctLen == [a \in {D, R} |-> IF a = D THEN 16 ELSE 14]

Kinds == <<"ca", "cb">>
Pay   == <<AmtA, AmtB>>
Out0  == Outcome({}, {}, RVal(EMPTY), 0, 0)

(* ---- distributor D ----------------------------------------------------- *)
\* payout(): if the reward is owed, send it in one batch, then on_payout.
H_payout(r) ==
    LET b  == Rcpt(nid, r.tx, MT, D, "mt_batch_transfer", MtBatchArgs(R, Kinds, Pay, ""), TokYocto, D, nid + 1)
        cb == WithOwed(Rcpt(nid + 1, r.tx, D, D, "on_payout", TA0, 0, D, r.cb))
    IN IF st # "owed" THEN [O |-> Out0, st |-> st]
       ELSE [O |-> Outcome({b}, {cb}, RProm, 0, 2), st |-> "sending"]
\* on_payout(): done if the batch went through, else owed again.
H_on_payout(r) ==
    [O |-> Out0, st |-> IF r.res.ok \/ Bug = "ignore" THEN "paid" ELSE "owed"]

RunD(r) ==
    LET h == IF r.m = "payout" THEN H_payout(r) ELSE H_on_payout(r) IN
    /\ Exec(r, h.O)
    /\ st' = IF Ok(r, h.O) THEN h.st ELSE st
    /\ UNCHANGED <<mtk, ntx>>

(* ---- transactions, Next -------------------------------------------------- *)
Call == /\ ntx < MaxTx
        /\ Submit(Rcpt(nid, ntx + 1, D, U, "payout", TA0, 0, U, 0))
        /\ ntx' = ntx + 1
        /\ UNCHANGED <<mtk, st>>

Run == \E r \in Runnable :
         CASE IsBuiltin(r) -> ExecBuiltin(r) /\ UNCHANGED mine
           [] IsMtRcpt(r)  -> MtStep(r, MtHandle(r)) /\ UNCHANGED <<st, ntx>>
           [] OTHER        -> RunD(r)

Init == /\ PlatformInit([a \in Accts |-> 0], TxIds)
        /\ mtk = [t \in {MT} |-> [bal |-> [h \in {D, R} |->
                     [i \in MtIds |-> IF h = D THEN (IF i = "ca" THEN AmtA ELSE AmtB) ELSE 0]]]]
        /\ st = "owed" /\ ntx = 0
Next == Call \/ Run
Spec == Init /\ [][Next]_vars

(* ---- properties ---------------------------------------------------------- *)
Holds(h) == <<mtk[MT].bal[h]["ca"], mtk[MT].bal[h]["cb"]>>
\* D's record matches the ledger whenever no payout is in flight: paid, R
\* holds the reward per id; owed, D does.
Books == st # "sending" =>
           IF st = "paid" THEN Holds(R) = Pay /\ Holds(D) = <<0, 0>>
           ELSE Holds(D) = Pay /\ Holds(R) = <<0, 0>>
\* Once idle, the payout is not left half-way.
Settles == Idle => st # "sending"
\* The sweep's success condition: R never receives the reward.
NeverPaid == Holds(R) = <<0, 0>>
Sane == NearConserved(0) /\ NoOrphans
=============================================================================
