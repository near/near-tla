------------------------------- MODULE Nep145 -------------------------------
(***************************************************************************)
(* NEP-145 storage management for fungible-token contracts, and the token *)
(* ledger state the FT modules share.                                      *)
(*                                                                         *)
(* One ledger per token account a \in TokenAccts:                          *)
(*   tk[a] = [bal |-> [TokHolders[a] -> Nat], reg |-> SUBSET, sup |-> Nat] *)
(* The ledger is the token contract's state: it is committed only when    *)
(* the token's receipt succeeds (Exec / Verdict), like any contract.       *)
(*                                                                         *)
(* storage_deposit(account_id, registration_only)  (NEP-145; the          *)
(* near-contract-standards FT implementation ignores registration_only):   *)
(*   account already registered -> whole deposit refunded to predecessor  *)
(*   otherwise deposit < min     -> panic                                  *)
(*   otherwise register; deposit - min refunded to predecessor             *)
(*   returns StorageBalance JSON (NONEMPTY)                                *)
(* Deviation "sdRefundToAccount": refunds go to account_id instead.        *)
(***************************************************************************)
EXTENDS TokenCommon

CONSTANTS
    TokenAccts,      \* accounts running a standard FT contract (NEP-141 + NEP-145)
    TokHolders,      \* [TokenAccts -> SUBSET accounts]: who can ever hold a balance there
    TokStorageMin,   \* [TokenAccts -> Nat]: storage_balance_bounds.min (= max)
    TokDev,          \* [TokenAccts -> SUBSET Deviations]: selected non-standard behaviour
    TokCallReserve   \* [TokenAccts -> Nat]: gas mode only.  ft_transfer_call keeps this much
                     \* (GAS_FOR_FT_TRANSFER_CALL) and gives ft_on_transfer
                     \* static = prepaid - reserve; prepaid <= reserve panics.
                     \* See Nep141 for the other per-token gas parameters.

VARIABLE tk

\* Initial ledger helper: balances b (a function on TokHolders[a]), registered set.
Ledger(b, reg) ==
    [bal |-> b, reg |-> reg,
     sup |-> LET F[S \in SUBSET DOMAIN b] == IF S = {} THEN 0
                                           ELSE LET x == CHOOSE y \in S : TRUE IN b[x] + F[S \ {x}]
             IN F[DOMAIN b]]

----------------------------------------------------------------------------
(* Execution accumulator.  A token receipt is a sequence of actions (one, *)
(* or several for a batch) folded over this record; the first error wins  *)
(* and the whole receipt fails (and reverts) as one.                       *)
TEv0 == [m |-> "", s |-> "", rc |-> "", moved |-> 0, call |-> FALSE,
         refund |-> 0, credited |-> FALSE,
         stoKept |-> 0, stoRefund |-> 0, stoTo |-> "", stoAcct |-> "",
         nd |-> 0, nw |-> 0]
\* ev is what the receipt did, for the calling model's per-tx ghosts:
\*   s, rc, moved   tokens moved s -> rc by ft_transfer[_call]
\*   call           a receiver call + resolver were created
\*   refund         resolver moved this much back rc -> s (credited = s registered,
\*                  else burnt)
\*   stoKept, stoRefund, stoTo, stoAcct   storage_deposit: kept for a new
\*                  registration of stoAcct / refunded natively to stoTo
\*   nd, nw         near_deposit / near_withdraw amounts (WNear)
TAcc0(r) == [L |-> tk[r.to], n |-> nid, rd |-> {}, ps |-> {}, out |-> 0,
             ret |-> RVal(EMPTY), err |-> "", ev |-> TEv0, key |-> r.m]
Live(acc) == acc.err = ""
AE(acc, e) == IF acc.err = "" THEN [acc EXCEPT !.err = e] ELSE acc

\* A native refund (Transfer action) from the token account.
TokRefund(acc, r, to, x) ==
    IF x = 0 THEN acc
    ELSE [acc EXCEPT !.rd = @ \cup {Rcpt(acc.n, r.tx, to, r.to, XFER, TA0, x, r.to, 0)},
                     !.n = @ + 1, !.out = @ + x]

YoctoAct(acc, dep) ==
    IF TokYocto > 0 /\ dep # TokYocto
    THEN AE(acc, "Requires attached deposit of exactly 1 yoctoNEAR") ELSE acc

\* Outcome record of a token receipt (gas burn key "acct.method[/path]", size 0).
TokOut(r, acc) ==
    [ready |-> acc.rd, post |-> acc.ps, ret |-> acc.ret, out |-> acc.out,
     ids |-> acc.n - nid, err |-> acc.err, gk |-> CallKey(r.to, acc.key), sz |-> 0,
     tk |-> [tk EXCEPT ![r.to] = acc.L], ev |-> [acc.ev EXCEPT !.m = r.m]]

----------------------------------------------------------------------------
(* storage_deposit(acct0 = "" means predecessor) with attached x.          *)
SdAct(acc, r, acct0, x) ==
    LET a   == IF acct0 = "" THEN r.fr ELSE acct0
        to  == IF "sdRefundToAccount" \in TokDev[r.to] THEN a ELSE r.fr
        min == TokStorageMin[r.to]
    IN IF ~Live(acc) THEN acc
       ELSE IF a \notin DOMAIN acc.L.bal
            THEN Assert(FALSE, <<"storage_deposit for an account outside TokHolders", r.to, a>>)
       ELSE IF a \in acc.L.reg
            THEN [TokRefund(acc, r, to, x) EXCEPT !.ret = RVal(NONEMPTY),
                    !.ev.stoRefund = @ + x, !.ev.stoTo = to, !.ev.stoAcct = a]
       ELSE IF x < min
            THEN AE(acc, "The attached deposit is less than the minimum storage balance")
       ELSE [TokRefund([acc EXCEPT !.L.reg = @ \cup {a}], r, to, x - min)
               EXCEPT !.ret = RVal(NONEMPTY), !.ev.stoKept = @ + min,
                      !.ev.stoRefund = @ + (x - min), !.ev.stoTo = to, !.ev.stoAcct = a]

\* storage_balance_of(acct): Some(total) is encoded as the number, null as NONEMPTY.
SbAct(acc, r, acct0) ==
    LET a == IF acct0 = "" THEN r.fr ELSE acct0 IN
    [acc EXCEPT !.ret = IF a \in acc.L.reg THEN RVal(TokStorageMin[r.to]) ELSE RVal(NONEMPTY)]
=============================================================================
