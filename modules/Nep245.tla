------------------------------- MODULE Nep245 -------------------------------
(***************************************************************************)
(* NEP-245 multi-token core (one token id per call; batch variants not     *)
(* modelled) as in-spec handlers on mtk[r.to].                             *)
(*                                                                         *)
(* mt_transfer(receiver_id, token_id, amount)   1 yocto; returns EMPTY     *)
(* mt_transfer_call(receiver_id, token_id, amount, msg)  1 yocto; moves,   *)
(*   then receiver.mt_on_transfer(sender_id, [sender_id], [token_id],      *)
(*   [amount], msg).then(self.mt_resolve_transfer(...)); returns that.     *)
(* mt_resolve_transfer (private), NEP-245: per token,                       *)
(*   unused = Failed / unparsable / wrong length -> amount ;               *)
(*            ["v"] -> min(v, amount)                                      *)
(*   refund = min(unused, receiver balance) back to the sender;            *)
(*   returns [amount - refund].                                            *)
(* Result encoding: a one-element Vec<U128> ["v"] is the number v; any     *)
(* other shape is MAL.  Deviations (MtDev): "resolveIgnoresResult",        *)
(* "resolveNoCap".  NEP-245 has no storage standard of its own; receivers  *)
(* need no registration here.                                              *)
(*                                                                         *)
(* A contract that is itself a multi-token can use just the shared        *)
(* arithmetic ResolveRefund (TokenCommon) on its own ledger.               *)
(***************************************************************************)
EXTENDS TokenCommon

CONSTANTS
    MtAccts,        \* accounts running an external NEP-245 contract
    MtHolders,      \* [MtAccts -> SUBSET accounts]
    MtIds,          \* token ids
    MtDev,          \* [MtAccts -> SUBSET Deviations]
    MtCallReserve   \* [MtAccts -> Nat]: as TokCallReserve, for mt_transfer_call

VARIABLE mtk        \* [MtAccts -> [bal |-> [MtHolders[a] -> [MtIds -> Nat]]]]

MEv0 == [m |-> "", s |-> "", rc |-> "", tid |-> "", moved |-> 0, call |-> FALSE, refund |-> 0]
MAcc0(r) == [L |-> mtk[r.to], n |-> nid, rd |-> {}, ps |-> {}, out |-> 0,
             ret |-> RVal(EMPTY), err |-> "", ev |-> MEv0, key |-> r.m]
MLive(acc) == acc.err = ""
MAE(acc, e) == IF acc.err = "" THEN [acc EXCEPT !.err = e] ELSE acc
MYocto(acc, dep) ==
    IF TokYocto > 0 /\ dep # TokYocto THEN MAE(acc, "Requires attached deposit of exactly 1 yoctoNEAR") ELSE acc

MtXferAct(acc, r, s, rc, tid, amt) ==
    LET L == acc.L IN
    IF ~MLive(acc) THEN acc
    ELSE IF s = rc THEN MAE(acc, "Sender and receiver should be different")
    ELSE IF amt = 0 THEN MAE(acc, "zero amount")
    ELSE IF s \notin DOMAIN L.bal \/ rc \notin DOMAIN L.bal
         THEN Assert(FALSE, <<"MT transfer outside MtHolders", r.to, s, rc>>)
    ELSE IF L.bal[s][tid] < amt THEN MAE(acc, "insufficient balance")
    ELSE [acc EXCEPT !.L = [L EXCEPT !.bal[s][tid] = @ - amt, !.bal[rc][tid] = @ + amt],
                     !.ev.s = s, !.ev.rc = rc, !.ev.tid = tid, !.ev.moved = @ + amt]

MtOnStatic(r) == IF GasMode = "gas" THEN LastGas(r) - MtCallReserve[r.to] ELSE 0
MtReserveShort(r) == GasMode = "gas" /\ MtCallReserve[r.to] > 0 /\ LastGas(r) <= MtCallReserve[r.to]

MtTransferCallAct(acc, r) ==
    LET a == r.a
        a1 == IF MtReserveShort(r) /\ MLive(acc) THEN MAE(acc, "prepaid gas overflow")
              ELSE MtXferAct(acc, r, r.fr, a.rc, a.tid, a.amt)
        onT == WithCall(Rcpt(a1.n, r.tx, a.rc, r.to, "mt_on_transfer",
                             MtOnArgs(r.fr, a.rc, a.tid, a.amt, a.msg), 0, r.to, a1.n + 1),
                        <<MtOnStatic(r)>>, <<0>>)
        res == Rcpt(a1.n + 1, r.tx, r.to, r.to, "mt_resolve_transfer",
                    MtResArgs(r.fr, a.rc, a.tid, a.amt), 0, r.to, r.cb)
    IN IF ~MLive(a1) THEN a1
       ELSE [a1 EXCEPT !.rd = @ \cup {onT}, !.ps = @ \cup {res}, !.n = @ + 2,
                       !.ret = RProm, !.ev.call = TRUE]

MtResolveAct(acc, r) ==
    LET a == r.a  L == acc.L
        refund == ResolveRefund(r.res, a.amt, L.bal[a.rc][a.tid], MtDev[r.to])
        L1 == [L EXCEPT !.bal[a.rc][a.tid] = @ - refund, !.bal[a.s][a.tid] = @ + refund]
    IN IF ~MLive(acc) THEN acc
       ELSE IF r.fr # r.to THEN MAE(acc, "Method mt_resolve_transfer is private")
       ELSE [acc EXCEPT !.L = L1, !.ret = RVal(TMax(a.amt - refund, 0)),
                        !.ev.s = a.s, !.ev.rc = a.rc, !.ev.tid = a.tid, !.ev.refund = refund]

MtHandle(r) ==
    LET acc == MAcc0(r)  a == r.a
        f == CASE r.m = "mt_transfer"         -> LET b == MtXferAct(MYocto(acc, r.dep), r, r.fr, a.rc, a.tid, a.amt)
                                                 IN IF MLive(b) THEN [b EXCEPT !.ret = RVal(EMPTY)] ELSE b
               [] r.m = "mt_transfer_call"    -> MtTransferCallAct(MYocto(acc, r.dep), r)
               [] r.m = "mt_resolve_transfer" -> MtResolveAct(acc, r)
               [] OTHER                       -> MAE(acc, "method not found")
    IN [ready |-> f.rd, post |-> f.ps, ret |-> f.ret, out |-> f.out,
        ids |-> f.n - nid, err |-> f.err, gk |-> CallKey(r.to, f.key), sz |-> 0,
        mtk |-> [mtk EXCEPT ![r.to] = f.L], ev |-> [f.ev EXCEPT !.m = r.m]]

IsMtRcpt(r) == r.to \in MtAccts /\ ~IsBuiltin(r) /\ r.m \notin {"ADDKEY", "DELKEY"}

MtStep(r, O) ==
    /\ Exec(r, O)
    /\ mtk' = IF Ok(r, O) THEN O.mtk ELSE mtk

RECURSIVE MSum(_, _)
MSum(S, f) == IF S = {} THEN 0 ELSE LET x == CHOOSE y \in S : TRUE IN f[x] + MSum(S \ {x}, f)
MtTotal(t, id) == MSum(DOMAIN mtk[t].bal, [h \in DOMAIN mtk[t].bal |-> mtk[t].bal[h][id]])
=============================================================================
