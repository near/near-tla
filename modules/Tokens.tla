------------------------------- MODULE Tokens -------------------------------
(***************************************************************************)
(* Top of the FT stack: EXTEND this from a contract model.                 *)
(*   NearAsync <- TokenCommon <- Nep145 <- Nep141 <- WNear <- Tokens       *)
(* (Nep245 is a separate branch on TokenCommon; extend it as well if the   *)
(*  model has an external multi-token contract.)                           *)
(*                                                                         *)
(* Provides                                                                *)
(*   IsTokRcpt(r)       r is a function call on a token account            *)
(*   TokChoices(r)      nondeterministic choices of that receipt           *)
(*   TokHandle(r, ch)   outcome record (+ fields tk, ev)                   *)
(*   TokStep(r, O)      platform Exec + tk' ; the contract conjoins its    *)
(*                      own ghost update from O.ev and UNCHANGED of the    *)
(*                      rest                                               *)
(*   TokSupplyOK        sanity: sup = sum of balances, on every token      *)
(*                                                                         *)
(* Methods: ft_transfer, ft_transfer_call, ft_resolve_transfer,            *)
(* ft_balance_of, ft_total_supply, storage_deposit, storage_balance_of,    *)
(* near_deposit / near_withdraw (on WNearAccts), and "batch":              *)
(* [near_deposit?, storage_deposit?, ft_transfer|ft_transfer_call?] in one *)
(* atomic receipt (args BatchArgs).  Each action of a batch carries its    *)
(* own deposit (nd, sd, TokYocto); a receipt whose total deposit differs   *)
(* from nd + sd + TokYocto fails (the ft_transfer action would carry the   *)
(* wrong attachment and panic).                                            *)
(*                                                                         *)
(* Gas burn keys (GasBurn, gas mode): "<acct>.<method>", and for a batch   *)
(* "<acct>.batch/<shape>" with shape = [D][S](T|C) for the actions present.*)
(***************************************************************************)
EXTENDS WNear

BatchKey(a) ==
    "batch/" \o (IF a.nd > 0 THEN "D" ELSE "") \o (IF a.sd > 0 THEN "S" ELSE "")
             \o (CASE a.xf = "ft_transfer" -> "T" [] a.xf = "ft_transfer_call" -> "C" [] OTHER -> "")

BatchAct(acc, r, ch) ==
    LET a  == r.a
        a1 == IF a.nd > 0 THEN NearDepositAct(acc, r, a.nd) ELSE acc
        a2 == IF a.sd > 0 THEN SdAct(a1, r, a.sdAcct, a.sd) ELSE a1
        a3 == CASE a.xf = "ft_transfer"      -> FtTransferAct(a2, r, a.rc, a.amt, ch)
                [] a.xf = "ft_transfer_call" -> FtTransferCallAct(a2, r, a.rc, a.amt, a.msg)
                [] OTHER                     -> a2
        dep == a.nd + a.sd + (IF a.xf # "" THEN TokYocto ELSE 0)
    IN IF r.dep # dep THEN AE([acc EXCEPT !.key = BatchKey(a)],
                              "Requires attached deposit of exactly 1 yoctoNEAR")
       ELSE IF a.nd > 0 /\ r.to \notin WNearAccts THEN AE([a3 EXCEPT !.key = BatchKey(a)], "method not found")
       ELSE [a3 EXCEPT !.key = BatchKey(a)]

TokHandle(r, ch) ==
    LET acc == TAcc0(r)  a == r.a IN
    TokOut(r,
      CASE r.m = "ft_transfer"         -> FtTransferAct(YoctoAct(acc, r.dep), r, a.rc, a.amt, ch)
        [] r.m = "ft_transfer_call"    -> FtTransferCallAct(YoctoAct(acc, r.dep), r, a.rc, a.amt, a.msg)
        [] r.m = "ft_resolve_transfer" -> FtResolveAct(acc, r)
        [] r.m = "ft_balance_of"       -> FtBalanceOfAct(acc, r, a.rc)
        [] r.m = "ft_total_supply"     -> FtTotalSupplyAct(acc, r)
        [] r.m = "storage_deposit"     -> SdAct(acc, r, a.rc, r.dep)
        [] r.m = "storage_balance_of"  -> SbAct(acc, r, a.rc)
        [] r.m = "near_deposit"  /\ r.to \in WNearAccts -> NearDepositAct(acc, r, r.dep)
        [] r.m = "near_withdraw" /\ r.to \in WNearAccts -> NearWithdrawAct(YoctoAct(acc, r.dep), r, a.amt)
        [] r.m = "batch"               -> BatchAct(acc, r, ch)
        [] OTHER                       -> AE(acc, "method not found"))

IsTokRcpt(r) == r.to \in TokenAccts /\ ~IsBuiltin(r) /\ r.m \notin {"ADDKEY", "DELKEY"}

TokChoices(r) ==
    IF /\ r.to \in TokenAccts
       /\ "retBytes" \in TokDev[r.to]
       /\ \/ r.m = "ft_transfer"
          \/ (r.m = "batch" /\ r.a.xf = "ft_transfer")
    THEN {EMPTY, NONEMPTY} ELSE {EMPTY}

TokStep(r, O) ==
    /\ Exec(r, O)
    /\ tk' = IF Ok(r, O) THEN O.tk ELSE tk

RECURSIVE TSum(_, _)
TSum(f, S) == IF S = {} THEN 0 ELSE LET x == CHOOSE y \in S : TRUE IN f[x] + TSum(f, S \ {x})
TokSupplyOK == \A t \in TokenAccts : tk[t].sup = TSum(tk[t].bal, DOMAIN tk[t].bal)
TokTypeOK   == \A t \in TokenAccts : /\ DOMAIN tk[t].bal = TokHolders[t]
                                     /\ \A h \in DOMAIN tk[t].bal : tk[t].bal[h] >= 0
=============================================================================
