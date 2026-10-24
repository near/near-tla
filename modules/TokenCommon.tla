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
(* Argument record.  Every token-standard receipt carries this shape, so   *)
(* receipts compare cleanly; unused fields keep their defaults.  `msg` is  *)
(* always a string (the contract's own encoding of its message).           *)
(*   rc     receiver_id / account_id                                       *)
(*   s      sender_id (ft_on_transfer, resolvers)                          *)
(*   amt    amount                                                         *)
(*   msg    msg                                                            *)
(*   tid    token_id (NEP-245)                                             *)
(*   tids, amts  token_ids and amounts (NEP-245): a batch call's vectors;  *)
(*          a single-id call has <<tid>> and <<amt>>, a batch tid = ""     *)
(*   nd, sd, sdAcct, xf   batch only: near_deposit amount, storage_deposit *)
(*          amount and account, last action "ft_transfer"|"ft_transfer_call"|"" *)
(*   force  storage_unregister(force)                                      *)
(*   cx     a payload slot for the model's own receipts: <<>> or <<v>>, so *)
(*          a contract's receipts share the TA0 shape with token receipts  *)
TA0 == [rc |-> "", s |-> "", amt |-> 0, msg |-> "", tid |-> "", tids |-> <<>>, amts |-> <<>>,
        nd |-> 0, sd |-> 0, sdAcct |-> "", xf |-> "", force |-> FALSE, cx |-> <<>>]
CxArgs(v) == [TA0 EXCEPT !.cx = <<v>>]
FtArgs(rc, amt, msg)       == [TA0 EXCEPT !.rc = rc, !.amt = amt, !.msg = msg]
OnArgs(s, rc, amt, msg)    == [TA0 EXCEPT !.s = s, !.rc = rc, !.amt = amt, !.msg = msg]
ResArgs(s, rc, amt)        == [TA0 EXCEPT !.s = s, !.rc = rc, !.amt = amt]
SdArgs(acct)               == [TA0 EXCEPT !.rc = acct]          \* "" = predecessor
NwArgs(amt)                == [TA0 EXCEPT !.amt = amt]
SuArgs(force)              == [TA0 EXCEPT !.force = force]
MtArgs(rc, tid, amt, msg)  == [TA0 EXCEPT !.rc = rc, !.tid = tid, !.amt = amt, !.msg = msg,
                                           !.tids = <<tid>>, !.amts = <<amt>>]
MtOnArgs(s, rc, tid, amt, msg) == [MtArgs(rc, tid, amt, msg) EXCEPT !.s = s]
MtResArgs(s, rc, tid, amt) == [MtArgs(rc, tid, amt, "") EXCEPT !.s = s]
\* NEP-245 batches: token_ids and amounts as sequences (tid "", amt 0).
MtBatchArgs(rc, tids, amts, msg)      == [TA0 EXCEPT !.rc = rc, !.tids = tids, !.amts = amts, !.msg = msg]
MtBatchOnArgs(s, rc, tids, amts, msg) == [MtBatchArgs(rc, tids, amts, msg) EXCEPT !.s = s]
MtBatchResArgs(s, rc, tids, amts)     == [MtBatchArgs(rc, tids, amts, "") EXCEPT !.s = s]
\* Batch [near_deposit(nd)?, storage_deposit(sdAcct, sd)?, ft_transfer[_call](rc, amt, msg)?]
\* on one token account: one receipt, atomic, result = the last action's.
BatchArgs(nd, sd, sdAcct, xf, rc, amt, msg) ==
    [TA0 EXCEPT !.nd = nd, !.sd = sd, !.sdAcct = sdAcct, !.xf = xf,
                !.rc = rc, !.amt = amt, !.msg = msg]

----------------------------------------------------------------------------
(* Non-standard behaviour, selectable per token account (TokDev[acct]).    *)
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
(* registered) is the initial registration set, a plain parameter.         *)
Deviations == {"retBytes", "resolveIgnoresResult", "resolveNoCap",
               "sdRefundToAccount", "autoRegister"}

----------------------------------------------------------------------------
(* Resolver arithmetic (NEP-141 ft_resolve_transfer, NEP-245               *)
(* mt_resolve_transfer, one token id).  Standard:                          *)
(*   unused = Failed, unparsable, or longer than max bytes -> amt ;        *)
(*            U128 v -> min(v, amt)                                        *)
(*   refund = min(unused, receiver's current balance)                      *)
(* max is the bound of the resolver's checked read (NumOrChecked; < 0 =    *)
(* unbounded).  near-contract-standards 5.24.0 and later read the result   *)
(* with promise_result_checked(0, 42), 42 bytes being the length of the   *)
(* JSON string "+340282366920938463463374607431768211455" (u128::MAX with  *)
(* a sign, quotes included), so a longer result counts as all unused      *)
(* (5.29.1 fungible_token/core_impl.rs:175-183; the same in 5.24.0-5.29.1  *)
(* and 5.30.0-rc.1); 5.23.0 reads it unbounded (core_impl.rs:177).         *)
(* ResolveUnused / ResolveRefund are the unbounded forms.                  *)
FtMaxResultLen == 42
ResolveUnusedLim(res, amt, dev, max) ==
    IF "resolveIgnoresResult" \in dev THEN 0
    ELSE IF "resolveNoCap" \in dev THEN NumOrChecked(res, max, amt)
    ELSE TMin(NumOrChecked(res, max, amt), amt)
ResolveRefundLim(res, amt, rcvBal, dev, max) ==
    LET u == ResolveUnusedLim(res, amt, dev, max) IN
    IF u > 0 /\ rcvBal > 0 THEN TMin(rcvBal, u) ELSE 0
ResolveUnused(res, amt, dev)         == ResolveUnusedLim(res, amt, dev, -1)
ResolveRefund(res, amt, rcvBal, dev) == ResolveRefundLim(res, amt, rcvBal, dev, -1)

----------------------------------------------------------------------------
(* An arbitrary receiver contract (environment actor).  resp:              *)
(*   "keep" -> "0", "return" -> amt, "over" -> amt+1, "mal" -> MAL,        *)
(*   "nonempty" -> NONEMPTY, "empty" -> EMPTY, "panic" -> fails,           *)
(*   "keepbig" -> "0" padded with 40 spaces to 43 bytes (valid JSON, one   *)
(*   byte over FtMaxResultLen).                                            *)
RecvResps == {"keep", "return", "over", "mal", "nonempty", "empty", "panic", "keepbig"}
RecvValue(amt, resp) ==
    CASE resp = "keep"     -> 0
      [] resp = "keepbig"  -> 0
      [] resp = "return"   -> amt
      [] resp = "over"     -> amt + 1
      [] resp = "mal"      -> MAL
      [] resp = "nonempty" -> NONEMPTY
      [] resp = "empty"    -> EMPTY
      [] OTHER             -> 0
RecvOutcome(amt, resp) ==
    LET ret == IF resp = "keepbig" THEN RValLen(0, FtMaxResultLen + 1)
               ELSE RVal(RecvValue(amt, resp))
        O == Outcome({}, {}, ret, 0, 0) IN
    IF resp = "panic" THEN OErr(O, "receiver panicked") ELSE O
=============================================================================
