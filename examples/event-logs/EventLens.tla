------------------------------ MODULE EventLens ------------------------------
(***************************************************************************)
(* The event-log lengths of TokenCommon / Nep245 (docs/SEMANTICS.md T8)    *)
(* against the lengths nearcore logged in the sim                          *)
(* (conformance/tests/events.rs), case by case.  No behaviour: one state,  *)
(* and LensOK says every case's length is the observed one.                *)
(*                                                                         *)
(* Two kinds of case:                                                      *)
(*  - the formulas on byte lengths (EvLen and the item operators), with    *)
(*    the sim's account ids, token ids, amounts and memos: alice.near (10  *)
(*    bytes), bo.near (7), a 55-byte id, p-probe.near (12), mr-probe.near  *)
(*    (13); ft_mint and mt_burn against the crates' own test strings       *)
(*    (mt_burn's ids replaced by generic ids of the same lengths);         *)
(*  - the handlers on model receipts (TokHandle, MtHandle): their declared *)
(*    log count and bytes (O.lgn, O.lgb), with EvAcctLen giving the model  *)
(*    accounts the sim's lengths, and an id class (MtIdCount) standing for *)
(*    the 162 and 163 entries of the sim's crossing test, at the 16384-   *)
(*    byte limit.                                                          *)
(***************************************************************************)
EXTENDS Tokens, Nep245

CONSTANT K   \* the size of the id class "big"
VARIABLE ntx
vars == <<platformVars, tk, mtk, ntx>>

Accts == {"alice", "bo", "long", "ft", "mt", "rx"}
PFloor      == [a \in Accts |-> 0]
NoGasTable  == [x \in {} |-> 0]
PTokHolders == [a \in {"ft"} |-> {"alice", "bo"}]
PTokMin     == [a \in {"ft"} |-> 1]
PTokDev     == [a \in {"ft"} |-> {}]
PTokReserve == [a \in {"ft"} |-> 0]
PMtHolders  == [a \in {"mt"} |-> {"alice", "bo", "long", "rx"}]
PMtDev      == [a \in {"mt"} |-> {"zeroAmountSkipped", "selfTransferCredits"}]
PMtReserve  == [a \in {"mt"} |-> 0]
\* The sim's account ids, by length.
PAcctLen == [a \in {"alice", "bo", "long", "rx"} |->
               CASE a = "alice" -> 10 [] a = "bo" -> 7 [] a = "long" -> 55 [] OTHER -> 13]
\* "big": one class of K ids of 64 bytes (the crossing test's id, K times).
PIdCount == [i \in {"big"} |-> K]
PIdLen   == [i \in {"big"} |-> 64]
\* 30-digit amounts on the token "mt" (a model 1 is 10^29 base units).
PAmtExp  == [t \in {"mt"} |-> 29]

Init == /\ PlatformInit([a \in Accts |-> 0], {1})
        /\ tk = [t \in {"ft"} |-> Ledger([h \in {"alice", "bo"} |-> 1000], {"alice", "bo"})]
        /\ mtk = [t \in {"mt"} |-> [bal |-> [h \in {"alice", "bo", "long", "rx"} |->
                                              [i \in MtIds |-> IF h = "alice" THEN 1000 ELSE 0]]]]
        /\ ntx = 0
Next == UNCHANGED vars
Spec == Init /\ [][Next]_vars

(* ---- the formulas on byte lengths ----------------------------------------- *)
FtX(o, n, d, m) == EvLen("nep141", "ft_transfer", <<FtXferItem(o, n, d, m)>>)
MtX(o, n, k, ib, ab, m) == EvLen("nep245", "mt_transfer", <<MtXferItem(o, n, k, ib, ab, m)>>)
MtM(o, k, ib, ab) == EvLen("nep245", "mt_mint", <<MtOwnerItem(o, k, ib, ab, -1)>>)
Formulas == <<
    \* ft_transfer: from, to, digits, memo (-1: none) -> bytes
    <<"ft_transfer 1",            FtX(10, 7, 1, -1), 149>>,
    <<"ft_transfer empty memo",   FtX(10, 7, 5, 0), 163>>,
    <<"ft_transfer long id",      FtX(10, 55, 25, 6), 237>>,
    <<"ft_transfer escaped memo", FtX(10, 55, 38, 12), 256>>,
    <<"ft_transfer 500 memo",     FtX(10, 7, 1, 500), 659>>,
    <<"ft_transfer_call",         FtX(10, 12, 2, 3), 168>>,
    <<"ft refund",                FtX(7, 10, 2, 6), 166>>,
    <<"ft_burn refund",           EvLen("nep141", "ft_burn", <<FtOwnerItem(7, 2, 6)>>), 130>>,
    <<"ft_mint fixture",          EvLen("nep141", "ft_mint", <<FtOwnerItem(3, 3, -1)>>), 111>>,
    <<"two ft_mints fixture",     EvLen("nep141", "ft_mint", <<FtOwnerItem(3, 3, -1), FtOwnerItem(5, 3, 8)>>), 165>>,
    \* mt_mint by new: owner, ids, id bytes, amount digits
    <<"mt_mint t1",               MtM(10, 1, 2, 31), 168>>,
    <<"mt_mint 22-byte id",       MtM(10, 1, 22, 31), 188>>,
    <<"mt_mint x",                MtM(10, 1, 1, 31), 167>>,
    <<"mt_mint escaped id",       MtM(10, 1, 4, 31), 170>>,
    <<"mt_burn fixture",          EvLen("nep245", "mt_burn", <<MtOwnerItem(15, 2, 22, 4, -1)>>), 172>>,
    \* mt_transfer: from, to, ids, id bytes, amount digits, memo
    <<"mt_batch_transfer 1 id",   MtX(10, 7, 1, 2, 1, -1), 171>>,
    <<"mt_batch_transfer 2 ids",  MtX(10, 55, 2, 24, 26, 5), 287>>,
    <<"mt_batch_transfer repeat", MtX(10, 7, 3, 6, 6, 17), 219>>,
    <<"mt_batch_transfer zeros",  MtX(10, 7, 1, 1, 1, -1), 170>>,
    <<"mt_transfer",              MtX(10, 55, 1, 22, 9, 6), 263>>,
    <<"mt_batch_transfer_call",   MtX(10, 13, 2, 3, 4, 1), 198>>,
    <<"mt resolver 2 refunds",    MtX(13, 10, 2, 3, 3, -1), 186>>,
    <<"mt resolver 1 refund",     MtX(13, 10, 1, 2, 2, -1), 178>>,
    <<"162 entries",              MtX(10, 7, 162, 162 * 64, 162 * 30, -1), 16362>>,
    <<"163 entries",              MtX(10, 7, 163, 163 * 64, 163 * 30, -1), 16462>>
>>

(* ---- the handlers on model receipts --------------------------------------- *)
FtR(m, a) == Rcpt(1, 1, "ft", "alice", m, a, TokYocto, "alice", 0)
MtR(m, a) == Rcpt(1, 1, "mt", "alice", m, a, TokYocto, "alice", 0)
\* The resolver of a transfer of 50 alice -> bo, bo answering Failed.
FtRes == [Rcpt(1, 1, "ft", "ft", "ft_resolve_transfer", ResArgs("alice", "bo", 50), 0, "ft", 0)
            EXCEPT !.res = FailedRes]
\* A batch resolver for <<"big">>, rx answering Failed: rx holds nothing, so
\* nothing is refunded and nothing logged.
MtRes == [Rcpt(1, 1, "mt", "mt", "mt_resolve_transfer", MtBatchResArgs("alice", "rx", <<"big">>, <<1>>), 0, "mt", 0)
            EXCEPT !.res = FailedRes]
LogsOf(O) == <<LogCount(O), LogBytes(O)>>
Handlers == <<
    <<"ft_transfer handler",         LogsOf(TokHandle(FtR("ft_transfer", FtArgs("bo", 1, "")), EMPTY)), <<1, 149>>>>,
    <<"ft_transfer handler memo",    LogsOf(TokHandle(FtR("ft_transfer", WithMemo(FtArgs("bo", 7, ""), 500)), EMPTY)), <<1, 659>>>>,
    <<"ft_resolve_transfer handler", LogsOf(TokHandle(FtRes, EMPTY)), <<1, 166>>>>,
    <<"ft_transfer panics, no log",  LogsOf(TokHandle(FtR("ft_transfer", FtArgs("alice", 1, "")), EMPTY)), <<0, 0>>>>,
    <<"class of K ids",              LogsOf(MtHandle(MtR("mt_batch_transfer", MtBatchArgs("bo", <<"big">>, <<1>>, "")))),
                                     <<1, MtX(10, 7, K, K * 64, K * 30, -1)>>>>,
    <<"class of K ids, gas size",    <<MtHandle(MtR("mt_batch_transfer", MtBatchArgs("bo", <<"big">>, <<1>>, ""))).sz, 0>>,
                                     <<K, 0>>>>,
    <<"zero entry, no log",          LogsOf(MtHandle(MtR("mt_batch_transfer", MtBatchArgs("bo", <<"big">>, <<0>>, "")))), <<0, 0>>>>,
    <<"resolver, nothing refunded",  LogsOf(MtHandle(MtRes)), <<0, 0>>>>
>>

\* Every case: the model's length is the one observed.  BadF / BadH name the
\* cases that differ.
BadF == {Formulas[i][1] : i \in {j \in DOMAIN Formulas : Formulas[j][2] # Formulas[j][3]}}
BadH == {Handlers[i][1] : i \in {j \in DOMAIN Handlers : Handlers[j][2] # Handlers[j][3]}}
LensOK == BadF = {} /\ BadH = {}
\* The class batch is over the limit exactly when K > 162 (the sim's edge).
EdgeOK == (HostLimitErr(MtR("mt_batch_transfer", MtBatchArgs("bo", <<"big">>, <<1>>, "")),
                        MtHandle(MtR("mt_batch_transfer", MtBatchArgs("bo", <<"big">>, <<1>>, "")))) = "TotalLogLengthExceeded")
          = (K > 162)
Sane == NearConserved(0) /\ NoOrphans
=============================================================================
