---------------------------- MODULE TokenCommon ----------------------------
(***************************************************************************)
(* Shared vocabulary of the token-standard modules (no variables).         *)
(*                                                                         *)
(*  - one argument-record shape for every token-standard receipt           *)
(*  - the selectable non-standard behaviors ("deviations")                 *)
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
                    \* mt_transfer[_call]; 0 = not modeled (no check, nothing attached)

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
(*   bat    TRUE for a batch's arguments (MtBatch*Args), FALSE otherwise:  *)
(*          what tells a batch's resolver from a single id's               *)
(*   nd, sd, sdAcct, xf   batch only: near_deposit amount, storage_deposit *)
(*          amount and account, last action "ft_transfer"|"ft_transfer_call"|"" *)
(*   force  storage_unregister(force)                                      *)
(*   cx     a payload slot for the model's own receipts: <<>> or <<v>>, so *)
(*          a contract's receipts share the TA0 shape with token receipts  *)
TA0 == [rc |-> "", s |-> "", amt |-> 0, msg |-> "", tid |-> "", tids |-> <<>>, amts |-> <<>>, bat |-> FALSE,
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
\* NEP-245 batches: token_ids and amounts as sequences (tid "", amt 0, bat TRUE).
MtBatchArgs(rc, tids, amts, msg)      == [TA0 EXCEPT !.rc = rc, !.tids = tids, !.amts = amts, !.msg = msg,
                                                       !.bat = TRUE]
MtBatchOnArgs(s, rc, tids, amts, msg) == [MtBatchArgs(rc, tids, amts, msg) EXCEPT !.s = s]
MtBatchResArgs(s, rc, tids, amts)     == [MtBatchArgs(rc, tids, amts, "") EXCEPT !.s = s]
\* Batch [near_deposit(nd)?, storage_deposit(sdAcct, sd)?, ft_transfer[_call](rc, amt, msg)?]
\* on one token account: one receipt, atomic, result = the last action's.
BatchArgs(nd, sd, sdAcct, xf, rc, amt, msg) ==
    [TA0 EXCEPT !.nd = nd, !.sd = sd, !.sdAcct = sdAcct, !.xf = xf,
                !.rc = rc, !.amt = amt, !.msg = msg]

----------------------------------------------------------------------------
(* Non-standard behavior, selectable per token account (TokDev[acct]).     *)
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
(*  "zeroAmountSkipped"    NEP-245 (MtDev): an entry of amount 0 moves     *)
(*                         nothing and does not panic (checked first: a    *)
(*                         zero transfer to oneself is skipped too)        *)
(*  "selfTransferCredits"  NEP-245 (MtDev): no sender = receiver check; a  *)
(*                         transfer to oneself adds the amount to one's    *)
(*                         balance (both read before either is written)    *)
(* near-sdk-contract-tools 4.0.0 behaves as MtDev = {"zeroAmountSkipped",  *)
(* "selfTransferCredits"} (docs/SEMANTICS.md T5, N-mt).                    *)
(* "Unregistered receiver" as a *scenario* (standard token, receiver not   *)
(* registered) is the initial registration set, a plain parameter.         *)
Deviations == {"retBytes", "resolveIgnoresResult", "resolveNoCap",
               "sdRefundToAccount", "autoRegister", "zeroAmountSkipped", "selfTransferCredits"}

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
(* Event logs (NEP-297; docs/SEMANTICS.md T8, R6).  The token handlers     *)
(* emit the standard events of the implementations they encode, one log    *)
(* each, whose byte length is computed from the event's content and        *)
(* declared on the outcome (OLog's fields lgn, lgb), so nearcore's         *)
(* per-call log limits (100 logs, 16384 bytes) apply on their own: a call  *)
(* over them fails with NumberOfLogsExceeded or TotalLogLengthExceeded     *)
(* (HostLimitErr), the cause OwedOK reports for an owed resolver.          *)
(*                                                                         *)
(* The log is `EVENT_JSON:` and the compact JSON                           *)
(*   {"standard":S,"version":"1.0.0","event":E,"data":[item,..]}           *)
(* (near-contract-standards 5.29.1 src/event.rs:5-30,                      *)
(* fungible_token/events.rs:98-123; near-sdk-contract-tools 4.0.0          *)
(* src/standard/nep297.rs:41-89).  Items, every string quoted, amounts as  *)
(* decimal strings (U128), memo omitted when None:                         *)
(*   ft_transfer  {"old_owner_id","new_owner_id","amount","memo"?}         *)
(*   ft_mint, ft_burn  {"owner_id","amount","memo"?}  (events.rs:21-96)    *)
(*   mt_transfer  {"old_owner_id","new_owner_id","token_ids":[..],         *)
(*                 "amounts":[..],"memo"?}                                 *)
(*   mt_mint, mt_burn  {"owner_id","token_ids":[..],"amounts":[..],        *)
(*                 "memo"?}  (contract-tools src/standard/nep245/          *)
(*                 event.rs:39-90; authorized_id is always None in the     *)
(*                 core, nep245/mod.rs:810, :859)                          *)
(* Lengths are UTF-8 bytes after JSON escaping (a '"' or '\' takes two).   *)
(* Account ids are ASCII without either, so their length is Len(id);       *)
(* memos and token ids are given as their escaped byte length.             *)
(* The NEP-141 logs are near-contract-standards 5.29.1's whatever          *)
(* TokFtGasShape selects; an older version may log differently (not        *)
(* modeled).  WNear's own methods declare no logs (their source was not    *)
(* read).                                                                  *)
(*                                                                         *)
(* Knobs (overridable zero-arity definitions):                             *)
(*   TokEvents   TRUE (default): the handlers declare their logs; FALSE:   *)
(*               none (the 0.2 behavior)                                   *)
(*   EvAcctLen   a partial function account -> its real id length in       *)
(*               bytes; an account outside its domain counts Len(a), the   *)
(*               model's own string                                        *)
(*   EvAmtExp    a partial function token account -> e: a model amount x   *)
(*               stands for x * 10^e base units, so it prints with         *)
(*               Digits(x) + e digits (0 prints "0"); default e = 0        *)
(* A call's memo is the optional field memo of its arguments (WithMemo):   *)
(* its escaped byte length, absent = None.                                 *)
TokEvents == TRUE
EvAcctLen == [a \in {} |-> 0]
EvAmtExp  == [t \in {} |-> 0]
AcctLen(a) == IF a \in DOMAIN EvAcctLen THEN EvAcctLen[a] ELSE Len(a)
AmtExp(t)  == IF t \in DOMAIN EvAmtExp THEN EvAmtExp[t] ELSE 0
\* Decimal digits of x >= 0 (TLC's integers are below 2^31: at most 10).
Digits(x) == IF x >= 1000000000 THEN 10
             ELSE CHOOSE k \in 1..9 : x < 10 ^ k /\ (k = 1 \/ x >= 10 ^ (k - 1))
AmtLen(t, x) == IF x = 0 THEN 1 ELSE Digits(x) + AmtExp(t)
\* The memo of a call's arguments, -1 for None; WithMemo(args, m) gives one
\* of m bytes (escaped).
MemoOf(a) == IF "memo" \in DOMAIN a THEN a.memo ELSE -1
WithMemo(args, m) == [memo |-> m] @@ args
\* The formulas, on byte lengths (sim: conformance/tests/events.rs).
\* EvLen(s, e, items): the log of event e of standard s whose data holds
\* items of the given byte lengths: EVENT_JSON: (11) {"standard":" (13) s
\* ","version":" (13) 1.0.0 (5) ","event":" (11) e ","data":[ (10) the
\* items with a comma between each two (none for fewer than two), ]} (2).
EvLen(s, e, items) == 65 + Len(s) + Len(e) + SumSeq(items) + (IF items = <<>> THEN 0 ELSE Len(items) - 1)
\* ,"memo":"m" for a memo of m >= 0 bytes, nothing for None (m < 0).
EvMemo(m) == IF m < 0 THEN 0 ELSE 10 + m
\* A JSON array of n strings of b bytes in all, without its brackets.
EvList(n, b) == IF n = 0 THEN 0 ELSE b + 3 * n - 1
FtXferItem(o, n, d, m)        == 49 + o + n + d + EvMemo(m)
FtOwnerItem(o, d, m)          == 27 + o + d + EvMemo(m)
\* n ids of ib bytes in all, their amounts ab digits in all.
MtXferItem(o, rc, n, ib, ab, m) == 65 + o + rc + EvList(n, ib) + EvList(n, ab) + EvMemo(m)
MtOwnerItem(o, n, ib, ab, m)  == 43 + o + EvList(n, ib) + EvList(n, ab) + EvMemo(m)
\* The NEP-141 events a token t emits, for model accounts and amounts.
FtTransferLog(t, s, rc, x, m) == EvLen("nep141", "ft_transfer", <<FtXferItem(AcctLen(s), AcctLen(rc), AmtLen(t, x), m)>>)
FtMintLog(t, o, x, m)         == EvLen("nep141", "ft_mint", <<FtOwnerItem(AcctLen(o), AmtLen(t, x), m)>>)
FtBurnLog(t, o, x, m)         == EvLen("nep141", "ft_burn", <<FtOwnerItem(AcctLen(o), AmtLen(t, x), m)>>)
\* near-contract-standards' plain (non-event) logs (fungible_token/
\* core_impl.rs:221, storage_impl.rs:61, :33).
LogSenderDeleted      == 37   \* "The account of the sender was deleted"
LogAlreadyRegistered  == 56   \* "The account is already registered, refunding the deposit"
LogNotRegistered(a)   == 30 + AcctLen(a)   \* "The account <a> is not registered"
\* A handler's accumulator acc carries lgn / lgb; ALog adds one log of b
\* bytes (nothing with TokEvents off).
ALog(acc, b) == IF TokEvents THEN [acc EXCEPT !.lgn = @ + 1, !.lgb = @ + b] ELSE acc

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
