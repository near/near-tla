------------------------------- MODULE MtConf -------------------------------
(***************************************************************************)
(* Conformance driver for the multi-token flows (conformance/flows/mt.toml,*)
(* the flow set mt of scripts/flowsets.py): ProbeConf's driver and world,  *)
(* plus the account "mt", the library's NEP-245 token (Nep245) with the    *)
(* near-sdk-contract-tools gas shape ("tools"; the cfg sets MtGasShape),  *)
(* and "mr", the NEP-245 receiver probe (conformance/probes/mtrecv).  The  *)
(* generated cfg replaces ProbeConf's Accts and ConfContracts by Accts3    *)
(* and ConfContracts3 and runs Init3 and Next3, so ProbeConf and every     *)
(* probes run stay as they are.                                            *)
(*                                                                         *)
(* mr's mt_on_transfer answers by msg (MtRecvOutcome): keep, return, over, *)
(* short, long, mal, empty, panic; burn20000 burns 20 Tgas, then keeps.    *)
(* Its burn key is "mr.mt_on_transfer/<msg>", its size the number of ids;  *)
(* a panic's key is its burn up to the panic.                              *)
(* As after the spec's setup: alice holds 1000 of each of t1, t2, t3.      *)
(***************************************************************************)
EXTENDS ProbeConf, Nep245

\* (listed in full: the cfg replaces Accts and ConfContracts by these)
Accts3 == {"alice", "dave", "p", "q", "y", "nobody", "nimp", "nimp_new", "eth", "eth_new", "mt", "mr"} \cup Toks
ConfContracts3 == {"p", "q", "y", "mt", "mr"} \cup Toks

MtAccts3 == {"mt"}
MtHolders3 == [t \in {"mt"} |-> {"alice", "dave", "mr"}]
MtIds3 == {"t1", "t2", "t3"}
MtDev3 == [t \in {"mt"} |-> {}]
MtReserve3 == [t \in {"mt"} |-> 0]
MtShape3 == [t \in {"mt"} |-> "tools"]
MtBal0 == [h \in {"alice", "dave", "mr"} |-> [i \in MtIds3 |-> IF h = "alice" THEN 1000 ELSE 0]]

HMtOn(r) ==
    LET msg == r.a.msg
        O == IF msg = "burn20000" THEN MtRecvOutcome(r.a.amts, "keep") ELSE MtRecvOutcome(r.a.amts, msg)
        k == r.to \o ".mt_on_transfer/" \o msg
    IN OSz(IF O.err # "" THEN OPanicKey(O, k) ELSE OKey(O, k), Len(r.a.amts))

Run3 ==
    \E r \in Runnable :
       /\ IF IsMtRcpt(r) THEN MtStep(r, MtHandle(r)) /\ UNCHANGED <<tk, keyVars>>
          ELSE IF r.m = "mt_on_transfer" THEN Exec(r, HMtOn(r)) /\ UNCHANGED <<tk, keyVars, mtk>>
          ELSE IF IsBuiltin(r) THEN ExecBuiltin(r) /\ UNCHANGED <<tk, keyVars, mtk>>
          ELSE IF IsDeleg(r) THEN ExecDelegate(r) /\ UNCHANGED <<tk, mtk>>
          ELSE IF IsTokRcpt(r) THEN \E ch \in TokChoices(r) : TokStep(r, TokHandle(r, ch)) /\ UNCHANGED <<keyVars, mtk>>
          ELSE Exec(r, PH(r)) /\ UNCHANGED <<tk, keyVars, mtk>>
       /\ UNCHANGED confVars

Init3 == Init /\ mtk = [t \in {"mt"} |-> [bal |-> MtBal0]]
Next3 == (Start /\ UNCHANGED mtk) \/ Run3 \/ (AfterStep /\ UNCHANGED mtk)
=============================================================================
