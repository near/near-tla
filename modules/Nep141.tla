------------------------------- MODULE Nep141 -------------------------------
(***************************************************************************)
(* NEP-141 fungible-token core as in-spec handler actions on tk[r.to].     *)
(*                                                                         *)
(* ft_transfer(receiver_id, amount)            1 yocto; returns () = EMPTY *)
(*   (deviation "retBytes": may return NONEMPTY bytes on success)          *)
(* ft_transfer_call(receiver_id, amount, msg)  1 yocto; moves the tokens, *)
(*   then receiver.ft_on_transfer(sender_id, amount, msg)                  *)
(*   .then(self.ft_resolve_transfer(sender_id, receiver_id, amount));      *)
(*   returns the resolver's promise (its value: used amount)               *)
(* ft_resolve_transfer (private), NEP-141 and the reference               *)
(*   implementation:                                                       *)
(*     unused = Failed or unparsable -> amount ; U128 v -> min(v, amount)  *)
(*     refund = min(unused, receiver balance) moved back to the sender;    *)
(*              burnt if the sender is no longer registered                *)
(*     returns amount - refund (credited) or amount (burnt)                *)
(*   (deviations "resolveIgnoresResult", "resolveNoCap")                   *)
(* Internal transfer panics: sender = receiver, amount 0, sender or        *)
(* receiver not registered (deviation "autoRegister": receiver registered *)
(* for free), insufficient balance.                                        *)
(* Views: ft_balance_of(account_id) (0 for an unknown account),            *)
(*   ft_total_supply().  Both return a number.                             *)
(*                                                                         *)
(* Per-token gas parameters of ft_transfer_call (gas mode):                *)
(*   TokCallReserve[t]       (constant, Nep145) reserve kept by the token; *)
(*                           prepaid <= reserve panics (0: no check)       *)
(*   TokOnTransferStatic[t]  (overridable definition, default -1) static   *)
(*                           gas of ft_on_transfer; -1 = prepaid - reserve *)
(*   TokOnTransferWeight[t]  (overridable definition, default 0) unused-gas *)
(*                           weight of the ft_on_transfer call             *)
(*   GasCall["t.ft_resolve_transfer"]  static gas and weight of the        *)
(*                           resolver callback (and its exec fee)          *)
(* The defaults give ft_on_transfer prepaid - reserve with weight 0.  A    *)
(* token that hands ft_on_transfer the leftover by weight sets             *)
(* TokOnTransferWeight[t] = 1 (and TokOnTransferStatic[t] if its static is *)
(* fixed).                                                                 *)
(***************************************************************************)
EXTENDS Nep145

FtXferAct(acc, r, s, rc, amt) ==
    LET L == acc.L IN
    IF ~Live(acc) THEN acc
    ELSE IF s = rc THEN AE(acc, "Sender and receiver should be different")
    ELSE IF amt = 0 THEN AE(acc, "The amount should be a positive number")
    ELSE IF s \notin L.reg THEN AE(acc, "The account is not registered (sender)")
    ELSE IF rc \notin L.reg /\ "autoRegister" \notin TokDev[r.to]
         THEN AE(acc, "The account is not registered (receiver)")
    ELSE IF rc \notin DOMAIN L.bal
         THEN Assert(FALSE, <<"transfer to an account outside TokHolders", r.to, rc>>)
    ELSE IF L.bal[s] < amt THEN AE(acc, "The account doesn't have enough balance")
    ELSE [acc EXCEPT !.L = [L EXCEPT !.bal[s] = @ - amt, !.bal[rc] = @ + amt,
                                     !.reg = @ \cup {rc}],
                     !.ev.s = s, !.ev.rc = rc, !.ev.moved = @ + amt]

\* ch \in TokChoices(r): the success bytes (EMPTY, or NONEMPTY under "retBytes")
FtTransferAct(acc, r, rc, amt, ch) ==
    LET a1 == FtXferAct(acc, r, r.fr, rc, amt) IN
    IF ~Live(a1) THEN a1 ELSE [a1 EXCEPT !.ret = RVal(ch)]

\* Gas: ft_on_transfer gets static prepaid - reserve and weight
\* TokOnTransferWeight[token]; the resolver's static/weight come from GasCall
\* ("acct.ft_resolve_transfer" or "ft_resolve_transfer").
\* Overridable definition (cfg: TokOnTransferWeight <- MyWeights).
TokOnTransferWeight == [t \in TokenAccts |-> 0]
TokOnTransferStatic == [t \in TokenAccts |-> -1]
OnTransferWeight(r) == IF r.to \in DOMAIN TokOnTransferWeight THEN TokOnTransferWeight[r.to] ELSE 0
OnTransferStatic(r) ==
    IF GasMode # "gas" THEN 0
    ELSE IF r.to \in DOMAIN TokOnTransferStatic /\ TokOnTransferStatic[r.to] >= 0
         THEN TokOnTransferStatic[r.to]
         ELSE LastGas(r) - TokCallReserve[r.to]
ReserveShort(r) == GasMode = "gas" /\ TokCallReserve[r.to] > 0 /\ LastGas(r) <= TokCallReserve[r.to]

FtTransferCallAct(acc, r, rc, amt, msg) ==
    LET a1  == IF ReserveShort(r) /\ Live(acc)
               THEN AE(acc, "prepaid gas - GAS_FOR_FT_TRANSFER_CALL overflow")
               ELSE FtXferAct(acc, r, r.fr, rc, amt)
        onT == WithCall(Rcpt(a1.n, r.tx, rc, r.to, "ft_on_transfer",
                             OnArgs(r.fr, rc, amt, msg), 0, r.to, a1.n + 1),
                        <<OnTransferStatic(r)>>, <<OnTransferWeight(r)>>)
        res == Rcpt(a1.n + 1, r.tx, r.to, r.to, "ft_resolve_transfer",
                    ResArgs(r.fr, rc, amt), 0, r.to, r.cb)
    IN IF ~Live(a1) THEN a1
       ELSE [a1 EXCEPT !.rd = @ \cup {onT}, !.ps = @ \cup {res}, !.n = @ + 2,
                       !.ret = RProm, !.ev.call = TRUE]

FtResolveAct(acc, r) ==
    LET s == r.a.s  rc == r.a.rc  amt == r.a.amt  L == acc.L
        rb     == IF rc \in DOMAIN L.bal THEN L.bal[rc] ELSE 0
        refund == ResolveRefund(r.res, amt, rb, TokDev[r.to])
        sReg   == s \in L.reg
        L1 == IF refund = 0 THEN L
              ELSE IF sReg THEN [L EXCEPT !.bal[rc] = @ - refund, !.bal[s] = @ + refund]
              ELSE [L EXCEPT !.bal[rc] = @ - refund, !.sup = @ - refund]
        used == IF refund > 0 /\ sReg THEN amt - refund ELSE amt
    IN IF ~Live(acc) THEN acc
       ELSE IF r.fr # r.to THEN AE(acc, "Method ft_resolve_transfer is private")
       ELSE [acc EXCEPT !.L = L1, !.ret = RVal(TMax(used, 0)),   \* "resolveNoCap" may refund > amount
                        !.ev.s = s, !.ev.rc = rc, !.ev.refund = refund, !.ev.credited = sReg]
\* Views.
FtBalanceOfAct(acc, r, acct) ==
    IF ~Live(acc) THEN acc
    ELSE [acc EXCEPT !.ret = RVal(IF acct \in DOMAIN acc.L.bal THEN acc.L.bal[acct] ELSE 0)]
FtTotalSupplyAct(acc, r) ==
    IF ~Live(acc) THEN acc ELSE [acc EXCEPT !.ret = RVal(acc.L.sup)]
=============================================================================
