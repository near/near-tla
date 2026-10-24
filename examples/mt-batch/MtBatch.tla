------------------------------ MODULE MtBatch -------------------------------
(***************************************************************************)
(* A multi-id NEP-245 batch transfer_call (Nep245): U sends Amts of the    *)
(* ids Tids (each U holds U0) to an arbitrary receiver RX with             *)
(* mt_batch_transfer_call.  RX answers mt_on_transfer with any vector of   *)
(* RxVecs (wrong lengths and amounts above the amount sent included) or a  *)
(* label of RxResps (malformed, empty, panic).  RX starts with RxStart[i]  *)
(* of id i, and may spend 1 of SpendId to SpendTo at any time (its own     *)
(* mt_transfer), so its balance can be short when the resolver runs: then  *)
(* the refund is capped at it.  SpendTo = RX is a transfer to oneself      *)
(* (refused, or with MDev "selfTransferCredits" a credit, as               *)
(* near-sdk-contract-tools 4.0.0 does).                                    *)
(*                                                                         *)
(* Properties (per id, from the NEP-245 resolver rule, docs/SEMANTICS.md   *)
(* T5):                                                                    *)
(*   Conserved     each id's supply is constant                            *)
(*   NoGain        U never holds more of an id than it started with        *)
(*   Honored       once the transfer settles, U holds, of each id,         *)
(*                 U0 - amount + min(unused, RX's balance when the         *)
(*                 resolver ran), unused as the standard reads RX's answer *)
(*                 (gUnused, from the vector RX meant, so the vector       *)
(*                 encoding is checked too); a ledger check per id, not    *)
(*                 one total.  U0 when no resolver completed (the call     *)
(*                 failed at the gas floor, or panicked)                   *)
(*   AllUnusedBack U got back every unused token (false when RX spent:     *)
(*                 the balance cap binds; the must-fail run shows it)      *)
(*   FloorHolds    gas mode, MtGasShape "tools": once settled, a resolver  *)
(*                 completed iff U attached at least MtMinCallGas.  It     *)
(*                 records the resolver's successful run, so it holds only *)
(*                 where nothing past the floor runs out of gas: true of   *)
(*                 mt_batch_gas_std's menu and burns, not a general claim  *)
(*                                                                         *)
(* Gas mode (the run mt_batch_gas_std): U attaches any prepaid of GasMenu; *)
(* the token's burns and resolver split are the measured CalibStdMt table  *)
(* (near-sdk-contract-tools 4.0.0) with MtGasShape = "tools", RX's are     *)
(* illustrative.                                                           *)
(***************************************************************************)
EXTENDS Nep245
CONSTANTS U, MT, RX, K, Tids, Amts, U0, RxVecs, RxResps, SpendId, SpendTo, RxStart, MDev,
          GasMenu   \* prepaid gas U may attach (gas mode)
VARIABLES ntx, gUnused, gRxAt, spent, gPre
vars == <<platformVars, mtk, ntx, gUnused, gRxAt, spent, gPre>>
Accts == {U, MT, RX, K}
N == Len(Tids)
PFloor     == [a \in Accts |-> 0]
PMtHolders == [a \in {MT} |-> {U, RX, K}]
PMtReserve == [a \in {MT} |-> 0]
PMtDev     == [a \in {MT} |-> MDev]
NoGasTable == [x \in {} |-> 0]

\* Gas mode: the token side measured (CalibStdMt), RX's mt_on_transfer
\* illustrative (its exec fee is the one measured on the receiver probe).
Std == INSTANCE CalibStdMt
PMtShape == [t \in {MT} |-> "tools"]
PStdGasCall ==
       ("mt_on_transfer" :> [st |-> <<>>, wt |-> <<>>, fee |-> 889])
    @@ Std!StdMtGasCall(MT)
PStdGasBurn ==
       ("mt_on_transfer" :> [base |-> 300, per |-> 0])
    @@ Std!StdMtGasBurn(MT)
Holds0 == [h \in {U, RX, K} |-> [i \in MtIds |-> CASE h = U  -> U0
                                                   [] h = RX -> RxStart[i]
                                                   [] OTHER  -> 0]]

\* The standard's reading of RX's answer, from the vector RX meant (not
\* from its encoding, so Honored also checks MtVecCode / MtVecOf): per id
\* min(v_i, amount_i) for a vector of N entries; anything else (wrong
\* length, malformed, Failed) leaves every id unused.
UnusedOf(isVec, v) == IF isVec /\ Len(v) = N THEN [i \in 1..N |-> TMin(v[i], Amts[i])] ELSE Amts
\* The vector behind each label of MtRecvOutcome (MtRecvValue), if any.
LabelVec(x) ==
    CASE x = "keep"   -> [i \in 1..N |-> 0]
      [] x = "return" -> Amts
      [] x = "over"   -> [i \in 1..N |-> Amts[i] + 1]
      [] x = "short"  -> SubSeq(Amts, 1, N - 1)
      [] x = "long"   -> Amts \o <<0>>
      [] OTHER        -> <<>>
LabelIsVec(x) == x \in {"keep", "return", "over", "short", "long"}

\* RX's mt_on_transfer: any answer of the configured sets.  A receipt that
\* does not run (gas) answers Failed.
RxStep(r, O, uv) ==
    /\ Exec(r, O)
    /\ gUnused' = IF Ok(r, O) THEN uv ELSE Amts
    /\ UNCHANGED <<mtk, ntx, gRxAt, spent, gPre>>
RunRx(r) ==
    \/ \E v \in RxVecs : RxStep(r, MtRecvVecOutcome(v), UnusedOf(TRUE, v))
    \/ \E x \in RxResps : RxStep(r, MtRecvOutcome(r.a.amts, x),
                                 IF x = "panic" THEN Amts ELSE UnusedOf(LabelIsVec(x), LabelVec(x)))

\* The token; the resolver's successful run records RX's balances just
\* before it (RxNone, no balance, until then: a resolver that runs out of
\* gas records nothing).
RxNone == [i \in MtIds |-> -1]
RunMt(r) ==
    LET O == MtHandle(r) IN
    /\ MtStep(r, O)
    /\ gRxAt' = IF r.m = "mt_resolve_transfer" /\ Ok(r, O) THEN mtk[MT].bal[RX] ELSE gRxAt
    /\ UNCHANGED <<ntx, gUnused, spent, gPre>>

Run == \E r \in Runnable :
         IF r.m \in {XFER, REFND} THEN (ExecTransfer(r) \/ ExecTransferFail(r)) /\ UNCHANGED <<mtk, ntx, gUnused, gRxAt, spent, gPre>>
         ELSE IF IsMtRcpt(r) THEN RunMt(r)
         ELSE RunRx(r)

Start == /\ ntx = 0
         /\ \E p \in (IF GasMode = "gas" THEN GasMenu ELSE {0}) :
              LET c == Rcpt(nid, 1, MT, U, "mt_batch_transfer_call", MtBatchArgs(RX, Tids, Amts, ""), TokYocto, U, 0)
              IN /\ Submit(IF GasMode = "gas" THEN WithGas(c, p) ELSE c)
                 /\ gPre' = p
         /\ ntx' = 1 /\ UNCHANGED <<mtk, gUnused, gRxAt, spent>>
\* RX spends 1 of SpendId to SpendTo (once), at any time.
Spend == /\ ntx = 1 /\ ~spent /\ SpendId \in MtIds
         /\ LET c == Rcpt(nid, 2, MT, RX, "mt_transfer", MtArgs(SpendTo, SpendId, 1, ""), TokYocto, RX, 0)
            IN Submit(IF GasMode = "gas" THEN WithGas(c, 300000) ELSE c)
         /\ spent' = TRUE /\ UNCHANGED <<mtk, ntx, gUnused, gRxAt, gPre>>

Init == /\ PlatformInit([a \in Accts |-> 0], {1, 2})
        /\ mtk = [a \in {MT} |-> [bal |-> Holds0]]
        /\ ntx = 0 /\ gUnused = Amts /\ gRxAt = RxNone /\ spent = FALSE /\ gPre = 0
Next == Start \/ Spend \/ Run
Spec == Init /\ [][Next]_vars

Conserved == \A i \in MtIds : MtTotal(MT, i) = U0 + RxStart[i]
NoGain == \A i \in MtIds : mtk[MT].bal[U][i] <= U0
Settled == ntx = 1 /\ TxSettled(1)
\* No resolver completed (gas mode: the call failed at the floor; or the
\* call panicked, e.g. on a zero amount).
NoResolve == gRxAt = RxNone
Honored == Settled => \A j \in 1..N :
    mtk[MT].bal[U][Tids[j]] = IF NoResolve THEN U0 ELSE U0 - Amts[j] + TMin(gUnused[j], gRxAt[Tids[j]])
FloorHolds == Settled => (NoResolve <=> gPre < MtMinCallGas[MT])
AllUnusedBack == Settled => \A j \in 1..N : mtk[MT].bal[U][Tids[j]] = U0 - Amts[j] + gUnused[j]
\* Library sanity: NEAR conserved, and no orphans (a resolver never
\* scheduled leaves mt_on_transfer's result unconsumed).
Sane == NearConserved(0) /\ NoOrphans
=============================================================================
