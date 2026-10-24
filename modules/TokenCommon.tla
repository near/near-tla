---------------------------- MODULE TokenCommon ----------------------------
(***************************************************************************)
(* Shared vocabulary of the token-standard modules (no variables).         *)
(*                                                                         *)
(*  - one argument-record shape for every token-standard receipt           *)
(*  - the selectable non-standard behaviours ("deviations")                *)
(*  - the NEP-141 / NEP-245 resolver arithmetic                            *)
(*  - a generic arbitrary receiver (ft_on_transfer / mt_on_transfer)       *)
(*                                                                         *)
(* Sources: the NEP-141 (ft_resolve_transfer), NEP-145 (storage_deposit)   *)
(* and NEP-245 (mt_resolve_transfer) specifications and the                *)
(* near-contract-standards reference implementation; docs/SEMANTICS.md     *)
(* says which version the defaults encode.                                 *)
(***************************************************************************)
EXTENDS NearAsync

CONSTANT TokYocto   \* 1-yocto attachment required by ft_transfer[_call], near_withdraw,
                    \* mt_transfer[_call]; 0 = not modelled (no check, nothing attached)

TMin(a, b) == IF a < b THEN a ELSE b
TMax(a, b) == IF a > b THEN a ELSE b

----------------------------------------------------------------------------
(* Argument record.  Every token-standard receipt carries this shape, so  *)
(* receipts compare cleanly; unused fields keep their defaults.  `msg` is *)
(* always a string (the contract's own encoding of its message).          *)
(*   rc     receiver_id / account_id                                       *)
(*   s      sender_id (ft_on_transfer, resolvers)                          *)
(*   amt    amount                                                         *)
(*   msg    msg                                                            *)
(*   tid    token_id (NEP-245)                                             *)
(*   nd, sd, sdAcct, xf   batch only: near_deposit amount, storage_deposit *)
(*          amount and account, last action "ft_transfer"|"ft_transfer_call"|"" *)
(*   cx     a payload slot for the model's own receipts: <<>> or <<v>>, so  *)
(*          a contract's receipts share the TA0 shape with token receipts  *)
TA0 == [rc |-> "", s |-> "", amt |-> 0, msg |-> "", tid |-> "",
        nd |-> 0, sd |-> 0, sdAcct |-> "", xf |-> "", cx |-> <<>>]
CxArgs(v) == [TA0 EXCEPT !.cx = <<v>>]
FtArgs(rc, amt, msg)       == [TA0 EXCEPT !.rc = rc, !.amt = amt, !.msg = msg]
OnArgs(s, rc, amt, msg)    == [TA0 EXCEPT !.s = s, !.rc = rc, !.amt = amt, !.msg = msg]
ResArgs(s, rc, amt)        == [TA0 EXCEPT !.s = s, !.rc = rc, !.amt = amt]
SdArgs(acct)               == [TA0 EXCEPT !.rc = acct]          \* "" = predecessor
NwArgs(amt)                == [TA0 EXCEPT !.amt = amt]
MtArgs(rc, tid, amt, msg)  == [TA0 EXCEPT !.rc = rc, !.tid = tid, !.amt = amt, !.msg = msg]
MtOnArgs(s, rc, tid, amt, msg) == [TA0 EXCEPT !.s = s, !.rc = rc, !.tid = tid, !.amt = amt, !.msg = msg]
MtResArgs(s, rc, tid, amt) == [TA0 EXCEPT !.s = s, !.rc = rc, !.tid = tid, !.amt = amt]
\* Batch [near_deposit(nd)?, storage_deposit(sdAcct, sd)?, ft_transfer[_call](rc, amt, msg)?]
\* on one token account: one receipt, atomic, result = the last action's.
BatchArgs(nd, sd, sdAcct, xf, rc, amt, msg) ==
    [TA0 EXCEPT !.nd = nd, !.sd = sd, !.sdAcct = sdAcct, !.xf = xf,
                !.rc = rc, !.amt = amt, !.msg = msg]

----------------------------------------------------------------------------
(* Non-standard behaviour, selectable per token account (TokDev[acct]).   *)
(*  "retBytes"             ft_transfer (and a batch ending in it) may      *)
(*                         return non-empty bytes on success (chosen       *)
(*                         nondeterministically per call: EMPTY|NONEMPTY)  *)
(*  "resolveIgnoresResult" ft/mt_resolve_transfer ignores the receiver's   *)
(*                         result: never refunds, reports all as used      *)
(*  "resolveNoCap"         the receiver's returned unused amount is not    *)
(*                         capped at the transferred amount (still capped  *)
(*                         by the receiver's balance)                      *)
(*  "sdRefundToAccount"    storage_deposit refunds (already registered,    *)
(*                         or excess) to account_id, not to the            *)
(*                         predecessor                                     *)
(*  "autoRegister"         transfers to an unregistered receiver succeed   *)
(*                         and register it for free (no NEP-145 check)     *)
(* "Unregistered receiver" as a *scenario* (standard token, receiver not   *)
(* registered) is the initial registration set, a plain parameter.        *)
Deviations == {"retBytes", "resolveIgnoresResult", "resolveNoCap",
               "sdRefundToAccount", "autoRegister"}

----------------------------------------------------------------------------
(* Resolver arithmetic (NEP-141 ft_resolve_transfer, NEP-245             *)
(* mt_resolve_transfer, one token id).  Standard:                         *)
(*   unused = Failed or unparsable -> amt ; U128 v -> min(v, amt)          *)
(*   refund = min(unused, receiver's current balance)                      *)
ResolveUnused(res, amt, dev) ==
    IF "resolveIgnoresResult" \in dev THEN 0
    ELSE IF "resolveNoCap" \in dev THEN NumOr(res, amt)
    ELSE TMin(NumOr(res, amt), amt)
ResolveRefund(res, amt, rcvBal, dev) ==
    LET u == ResolveUnused(res, amt, dev) IN
    IF u > 0 /\ rcvBal > 0 THEN TMin(rcvBal, u) ELSE 0

----------------------------------------------------------------------------
(* An arbitrary receiver contract (environment actor).  resp:            *)
(*   "keep" -> "0", "return" -> amt, "over" -> amt+1, "mal" -> MAL,        *)
(*   "nonempty" -> NONEMPTY, "empty" -> EMPTY, "panic" -> fails.           *)
RecvResps == {"keep", "return", "over", "mal", "nonempty", "empty", "panic"}
RecvValue(amt, resp) ==
    CASE resp = "keep"     -> 0
      [] resp = "return"   -> amt
      [] resp = "over"     -> amt + 1
      [] resp = "mal"      -> MAL
      [] resp = "nonempty" -> NONEMPTY
      [] resp = "empty"    -> EMPTY
      [] OTHER             -> 0
RecvOutcome(amt, resp) ==
    LET O == Outcome({}, {}, RVal(RecvValue(amt, resp)), 0, 0) IN
    IF resp = "panic" THEN OErr(O, "receiver panicked") ELSE O
=============================================================================
