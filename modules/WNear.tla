-------------------------------- MODULE WNear --------------------------------
(***************************************************************************)
(* wNEAR (the near/core-contracts w-near contract):                        *)
(* an FT (Nep141 + Nep145) whose supply is backed by the NEAR the token   *)
(* account holds natively.                                                 *)
(*                                                                         *)
(* near_deposit()  payable, deposit > 0.  Predecessor not registered:      *)
(*   deposit >= storage min, register, mint deposit - min; else mint all.  *)
(*   Returns () = EMPTY.                                                   *)
(* near_withdraw(amount)  1 yocto; burn from predecessor (panics if not    *)
(*   registered / short), returns Promise::transfer(amount + 1 yocto) to   *)
(*   the predecessor, so a .then callback sees the Transfer's EMPTY bytes. *)
(***************************************************************************)
EXTENDS Nep141

CONSTANT WNearAccts   \* subset of TokenAccts that also implement near_deposit / near_withdraw

NearDepositAct(acc, r, x) ==
    LET L == acc.L  p == r.fr  min == TokStorageMin[r.to] IN
    IF ~Live(acc) THEN acc
    ELSE IF x = 0 THEN AE(acc, "Requires positive attached deposit")
    ELSE IF p \notin DOMAIN L.bal
         THEN Assert(FALSE, <<"near_deposit from an account outside TokHolders", r.to, p>>)
    ELSE IF p \in L.reg
         THEN [acc EXCEPT !.L = [L EXCEPT !.bal[p] = @ + x, !.sup = @ + x],
                          !.ret = RVal(EMPTY), !.ev.nd = @ + x]
    ELSE IF x < min THEN AE(acc, "ERR_DEPOSIT_TOO_SMALL")
    ELSE [acc EXCEPT !.L = [L EXCEPT !.reg = @ \cup {p}, !.bal[p] = @ + (x - min),
                                     !.sup = @ + (x - min)],
                     !.ret = RVal(EMPTY), !.ev.nd = @ + x]

NearWithdrawAct(acc, r, x) ==
    LET L == acc.L  p == r.fr IN
    IF ~Live(acc) THEN acc
    ELSE IF p \notin L.reg THEN AE(acc, "The account is not registered")
    ELSE IF L.bal[p] < x THEN AE(acc, "The account doesn't have enough balance")
    ELSE [acc EXCEPT !.L = [L EXCEPT !.bal[p] = @ - x, !.sup = @ - x],
                     !.rd = @ \cup {Rcpt(acc.n, r.tx, p, r.to, XFER, TA0, x + TokYocto, r.to, r.cb)},
                     !.n = @ + 1, !.out = @ + x + TokYocto, !.ret = RProm, !.ev.nw = x]
=============================================================================
