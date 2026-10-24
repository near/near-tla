------------------------------ MODULE MtSmoke -------------------------------
(* Smoke test of Nep245: U mt_transfer_calls 1 of "t1" to an arbitrary      *)
(* receiver RX (which already holds 1); the resolver refunds what RX asks   *)
(* back, capped at the amount (standard) or not ("resolveNoCap").           *)
EXTENDS Nep245
CONSTANTS U, MT, RX, RxResps, MDev
VARIABLES ntx, gR
vars == <<platformVars, mtk, ntx, gR>>
Accts == {U, MT, RX}
PFloor     == [a \in Accts |-> 0]
PMtHolders == [a \in {MT} |-> {U, RX}]
PMtDev     == [a \in {MT} |-> MDev]
PMtReserve == [a \in {MT} |-> 0]
NoGasTable == [x \in {} |-> 0]

RunRx(r) == \E resp \in RxResps :
    /\ Exec(r, RecvOutcome(r.a.amt, resp))
    /\ gR' = CASE resp = "keep" -> 0 [] resp = "over" -> r.a.amt + 1 [] OTHER -> r.a.amt
    /\ UNCHANGED <<mtk, ntx>>
Run == \E r \in Runnable :
         IF r.m \in {XFER, REFND} THEN (ExecTransfer(r) \/ ExecTransferFail(r)) /\ UNCHANGED <<mtk, ntx, gR>>
         ELSE IF IsMtRcpt(r) THEN MtStep(r, MtHandle(r)) /\ UNCHANGED <<ntx, gR>>
         ELSE RunRx(r)
Start == /\ ntx = 0
         /\ Submit(Rcpt(nid, 1, MT, U, "mt_transfer_call", MtArgs(RX, "t1", 1, ""), TokYocto, U, 0))
         /\ ntx' = 1 /\ UNCHANGED <<mtk, gR>>
Init == /\ PlatformInit([a \in Accts |-> 0], {1})
        /\ mtk = [a \in {MT} |-> [bal |-> [h \in {U, RX} |-> [i \in MtIds |-> 1]]]]
        /\ ntx = 0 /\ gR = 1
Next == Start \/ Run
Spec == Init /\ [][Next]_vars
Conserved == MtTotal(MT, "t1") = 2
\* U started with 1 and sent it: once settled it holds exactly the capped refund RX asked for
Honored == (ntx = 1 /\ TxSettled(1)) => mtk[MT].bal[U]["t1"] = TMin(gR, 1)
=============================================================================
