------------------------------- MODULE Nep141 -------------------------------
(***************************************************************************)
(* NEP-141 fungible-token core as in-spec handler actions on tk[r.to].     *)
(*                                                                         *)
(* ft_transfer(receiver_id, amount)            1 yocto; returns () = EMPTY *)
(*   (deviation "retBytes": may return NONEMPTY bytes on success)          *)
(* ft_transfer_call(receiver_id, amount, msg)  1 yocto; moves the tokens,  *)
(*   then receiver.ft_on_transfer(sender_id, amount, msg)                  *)
(*   .then(self.ft_resolve_transfer(sender_id, receiver_id, amount));      *)
(*   returns the resolver's promise (its value: used amount)               *)
(* ft_resolve_transfer (private), NEP-141 and the reference                *)
(*   implementation:                                                       *)
(*     unused = Failed, unparsable, or longer than TokResolveMaxLen[t]     *)
(*              bytes (42; near-contract-standards >= 5.24.0) -> amount ;  *)
(*              U128 v -> min(v, amount)                                   *)
(*     refund = min(unused, receiver balance) moved back to the sender;    *)
(*              burnt if the sender is no longer registered (it called     *)
(*              storage_unregister(force) meanwhile, Nep145)               *)
(*     returns amount - refund (credited) or amount (burnt)                *)
(*   (deviations "resolveIgnoresResult", "resolveNoCap")                   *)
(* Internal transfer panics: sender = receiver, amount 0, sender or        *)
(* receiver not registered (deviation "autoRegister": receiver registered  *)
(* for free), insufficient balance.                                        *)
(* Views: ft_balance_of(account_id) (0 for an unknown account),            *)
(*   ft_total_supply().  Both return a number.                             *)
(*                                                                         *)
(* Gas of ft_transfer_call (gas mode), per token t.  TokFtGasShape[t]:     *)
(*  "standard" (default; near-contract-standards 5.x, fungible_token/      *)
(*      core_impl.rs:13, :142-151): ft_on_transfer gets static 0 and       *)
(*      unused-gas weight 1; no reserve check; the resolver gets static    *)
(*      TokResolveStatic[t] (5 Tgas) and weight 0.                         *)
(*  "reserve" (near-contract-standards 3.x): ft_on_transfer gets static    *)
(*      prepaid - TokCallReserve[t] and weight 0; prepaid <= reserve       *)
(*      panics; the resolver gets static TokResolveStatic[t], weight 0     *)
(*      (GAS_FOR_RESOLVE_TRANSFER).                                        *)
(* Overrides (overridable definitions; -1 = the shape's default):          *)
(*   TokOnTransferStatic[t], TokOnTransferWeight[t]  ft_on_transfer        *)
(*   TokResolveStatic[t]     resolver static (both shapes)                 *)
(*   TokResolveMaxLen[t]     resolver's byte bound on the result (default  *)
(*                           42; -1 = unbounded, 5.23.0 and older)         *)
(* A GasCall entry "t.ft_resolve_transfer" (or "ft_resolve_transfer")      *)
(* wins for the resolver in both shapes; its .fee is the exec fee.         *)
(* Burn keys: "<t>.<method>"; ft_resolve_transfer uses                     *)
(* "<t>.ft_resolve_transfer/refund" or "/norefund" when GasBurn has it     *)
(* (PathKey, Nep145).                                                      *)
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

\* Gas parameters (see the header).  Overridable definitions, e.g. in the
\* cfg `TokFtGasShape <- MyShapes` with MyShapes == [t \in {"ft"} |-> "reserve"].
TokFtGasShape       == [t \in TokenAccts |-> "standard"]
TokOnTransferWeight == [t \in TokenAccts |-> -1]
TokOnTransferStatic == [t \in TokenAccts |-> -1]
TokResolveStatic    == [t \in TokenAccts |-> 5000]
\* Byte bound of the resolver's read of the ft_on_transfer result: a longer
\* result counts as all unused.  42 (FtMaxResultLen) for near-contract-standards
\* 5.24.0 and later; -1 = unbounded (5.23.0 and older, so 3.x/4.x tokens).
\* Independent of TokFtGasShape (5.23.0 has the standard shape and no bound).
TokResolveMaxLen    == [t \in TokenAccts |-> FtMaxResultLen]
ResolveMaxLen(t) == IF t \in DOMAIN TokResolveMaxLen THEN TokResolveMaxLen[t] ELSE FtMaxResultLen
FtShape(t) == IF t \in DOMAIN TokFtGasShape THEN TokFtGasShape[t] ELSE "standard"
ReserveShape(r) == FtShape(r.to) = "reserve"
TokKnob(f, t) == IF t \in DOMAIN f THEN f[t] ELSE -1
OnTransferWeight(r) ==
    IF TokKnob(TokOnTransferWeight, r.to) >= 0 THEN TokOnTransferWeight[r.to]
    ELSE IF ReserveShape(r) THEN 0 ELSE 1
OnTransferStatic(r) ==
    IF GasMode # "gas" THEN 0
    ELSE IF TokKnob(TokOnTransferStatic, r.to) >= 0 THEN TokOnTransferStatic[r.to]
    ELSE IF ReserveShape(r) THEN LastGas(r) - TokCallReserve[r.to]
    ELSE 0
\* 3.x only: prepaid gas must exceed the reserve.
ReserveShort(r) ==
    /\ GasMode = "gas" /\ ReserveShape(r)
    /\ TokCallReserve[r.to] > 0 /\ LastGas(r) <= TokCallReserve[r.to]
\* The resolver receipt: GasCall wins; else TokResolveStatic (5 Tgas), weight 0.
ResolveGas(r, res) ==
    IF GasMode # "gas" \/ HasCallDef(r.to, "ft_resolve_transfer") THEN res
    ELSE WithCall(res, <<TMax(TokKnob(TokResolveStatic, r.to), 0)>>, <<0>>)

FtTransferCallAct(acc, r, rc, amt, msg) ==
    LET a1  == IF ReserveShort(r) /\ Live(acc)
               THEN AE(acc, "prepaid gas - GAS_FOR_FT_TRANSFER_CALL overflow")
               ELSE FtXferAct(acc, r, r.fr, rc, amt)
        onT == WithCall(Rcpt(a1.n, r.tx, rc, r.to, "ft_on_transfer",
                             OnArgs(r.fr, rc, amt, msg), 0, r.to, a1.n + 1),
                        <<OnTransferStatic(r)>>, <<OnTransferWeight(r)>>)
        res == ResolveGas(r, Rcpt(a1.n + 1, r.tx, r.to, r.to, "ft_resolve_transfer",
                                  ResArgs(r.fr, rc, amt), 0, r.to, r.cb))
    IN IF ~Live(a1) THEN a1
       ELSE [a1 EXCEPT !.rd = @ \cup {onT}, !.ps = @ \cup {res}, !.n = @ + 2,
                       !.ret = RProm, !.ev.call = TRUE]

FtResolveAct(acc, r) ==
    LET s == r.a.s  rc == r.a.rc  amt == r.a.amt  L == acc.L
        rb     == IF rc \in DOMAIN L.bal THEN L.bal[rc] ELSE 0
        refund == ResolveRefundLim(r.res, amt, rb, TokDev[r.to], ResolveMaxLen(r.to))
        sReg   == s \in L.reg
        L1 == IF refund = 0 THEN L
              ELSE IF sReg THEN [L EXCEPT !.bal[rc] = @ - refund, !.bal[s] = @ + refund]
              ELSE [L EXCEPT !.bal[rc] = @ - refund, !.sup = @ - refund]
        used == IF refund > 0 /\ sReg THEN amt - refund ELSE amt
    IN IF ~Live(acc) THEN acc
       ELSE IF r.fr # r.to THEN AE(acc, "Method ft_resolve_transfer is private")
       ELSE [acc EXCEPT !.L = L1, !.ret = RVal(TMax(used, 0)),   \* "resolveNoCap" may refund > amount
                        !.ev.s = s, !.ev.rc = rc, !.ev.refund = refund, !.ev.credited = sReg,
                        !.key = PathKey(r, "ft_resolve_transfer", IF refund > 0 THEN "refund" ELSE "norefund")]
\* Views.
FtBalanceOfAct(acc, r, acct) ==
    IF ~Live(acc) THEN acc
    ELSE [acc EXCEPT !.ret = RVal(IF acct \in DOMAIN acc.L.bal THEN acc.L.bal[acct] ELSE 0)]
FtTotalSupplyAct(acc, r) ==
    IF ~Live(acc) THEN acc ELSE [acc EXCEPT !.ret = RVal(acc.L.sup)]
=============================================================================
