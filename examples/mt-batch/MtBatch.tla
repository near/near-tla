------------------------------ MODULE MtBatch -------------------------------
(***************************************************************************)
(* A multi-id NEP-245 batch transfer_call (Nep245): U sends Amts of the    *)
(* ids Tids (each U holds U0) to an arbitrary receiver RX with             *)
(* mt_batch_transfer_call.  RX answers mt_on_transfer with any vector of   *)
(* RxVecs (wrong lengths and amounts above the amount sent included) or a  *)
(* label of RxResps (malformed, empty, panic).  RX starts with RxStart[i] *)
(* of id i, and may spend 1 of SpendId to K at any time (its own           *)
(* mt_transfer), so its balance can be short when the resolver runs: then  *)
(* the refund is capped at it.                                             *)
(*                                                                         *)
(* Properties (per id, from the NEP-245 resolver rule, docs/SEMANTICS.md   *)
(* T5):                                                                    *)
(*   Conserved     each id's supply is constant                            *)
(*   NoGain        U never holds more of an id than it started with        *)
(*   Honored       once the transfer settles, U holds, of each id,         *)
(*                 U0 - amount + min(unused, RX's balance when the         *)
(*                 resolver ran), unused as the standard reads RX's answer *)
(*                 (gUnused); a ledger check per id, not one total         *)
(*   AllUnusedBack U got back every unused token (false when RX spent:     *)
(*                 the balance cap binds; the must-fail run shows it)      *)
(***************************************************************************)
EXTENDS Nep245
CONSTANTS U, MT, RX, K, Tids, Amts, U0, RxVecs, RxResps, SpendId, RxStart, MDev
VARIABLES ntx, gUnused, gRxAt, spent
vars == <<platformVars, mtk, ntx, gUnused, gRxAt, spent>>
Accts == {U, MT, RX, K}
N == Len(Tids)
PFloor     == [a \in Accts |-> 0]
PMtHolders == [a \in {MT} |-> {U, RX, K}]
PMtReserve == [a \in {MT} |-> 0]
PMtDev     == [a \in {MT} |-> MDev]
NoGasTable == [x \in {} |-> 0]
Holds0 == [h \in {U, RX, K} |-> [i \in MtIds |-> CASE h = U  -> U0
                                                   [] h = RX -> RxStart[i]
                                                   [] OTHER  -> 0]]

\* The standard's reading of RX's answer: per id min(v_i, amount_i) for a
\* vector of N entries; anything else (wrong length, malformed, Failed)
\* leaves every id unused.
Unused(res) ==
    LET vec == MtVecOf(res) IN
    IF vec.ok /\ Len(vec.v) = N THEN [i \in 1..N |-> TMin(vec.v[i], Amts[i])] ELSE Amts

\* RX's mt_on_transfer: any answer of the configured sets.
RxStep(r, O) ==
    /\ Exec(r, O)
    /\ gUnused' = Unused(IF O.err # "" THEN [ok |-> FALSE, v |-> 0] ELSE [ok |-> TRUE, v |-> O.ret.v])
    /\ UNCHANGED <<mtk, ntx, gRxAt, spent>>
RunRx(r) ==
    \/ \E v \in RxVecs : RxStep(r, MtRecvVecOutcome(v))
    \/ \E x \in RxResps : RxStep(r, MtRecvOutcome(r.a.amts, x))

\* The token; the resolver's run records RX's balances just before it.
RunMt(r) ==
    /\ MtStep(r, MtHandle(r))
    /\ gRxAt' = IF r.m = "mt_resolve_transfer" THEN mtk[MT].bal[RX] ELSE gRxAt
    /\ UNCHANGED <<ntx, gUnused, spent>>

Run == \E r \in Runnable :
         IF r.m \in {XFER, REFND} THEN (ExecTransfer(r) \/ ExecTransferFail(r)) /\ UNCHANGED <<mtk, ntx, gUnused, gRxAt, spent>>
         ELSE IF IsMtRcpt(r) THEN RunMt(r)
         ELSE RunRx(r)

Start == /\ ntx = 0
         /\ Submit(Rcpt(nid, 1, MT, U, "mt_batch_transfer_call", MtBatchArgs(RX, Tids, Amts, ""), TokYocto, U, 0))
         /\ ntx' = 1 /\ UNCHANGED <<mtk, gUnused, gRxAt, spent>>
\* RX spends 1 of SpendId to K (once), at any time.
Spend == /\ ntx = 1 /\ ~spent /\ SpendId \in MtIds
         /\ Submit(Rcpt(nid, 2, MT, RX, "mt_transfer", MtArgs(K, SpendId, 1, ""), TokYocto, RX, 0))
         /\ spent' = TRUE /\ UNCHANGED <<mtk, ntx, gUnused, gRxAt>>

Init == /\ PlatformInit([a \in Accts |-> 0], {1, 2})
        /\ mtk = [a \in {MT} |-> [bal |-> Holds0]]
        /\ ntx = 0 /\ gUnused = Amts /\ gRxAt = [i \in MtIds |-> 0] /\ spent = FALSE
Next == Start \/ Spend \/ Run
Spec == Init /\ [][Next]_vars

Conserved == \A i \in MtIds : MtTotal(MT, i) = U0 + RxStart[i]
NoGain == \A i \in MtIds : mtk[MT].bal[U][i] <= U0
Settled == ntx = 1 /\ TxSettled(1)
Honored == Settled => \A j \in 1..N : mtk[MT].bal[U][Tids[j]] = U0 - Amts[j] + TMin(gUnused[j], gRxAt[Tids[j]])
AllUnusedBack == Settled => \A j \in 1..N : mtk[MT].bal[U][Tids[j]] = U0 - Amts[j] + gUnused[j]
\* Library sanity: NEAR conserved, and no orphans (a resolver never
\* scheduled leaves mt_on_transfer's result unconsumed).
Sane == NearConserved(0) /\ NoOrphans
=============================================================================
