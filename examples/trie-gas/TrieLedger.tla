------------------------------ MODULE TrieLedger ------------------------------
(***************************************************************************)
(* Worst-case trie gas in an owed callback (docs/SEMANTICS.md, G6).        *)
(*                                                                         *)
(* Ledger V keeps U's balance.  U calls V.send(n): V debits n (committed   *)
(* in that receipt) and calls                                              *)
(*     T.take(n).then(V.on_take(n))                                        *)
(* on_take is owed (WithOwed) and has a fixed static gas, CbBudget, and no *)
(* share of the leftover.  When T took n it records the transfer (one      *)
(* storage write); when T failed it credits n back and clears the pending  *)
(* entry (two storage writes).  Each write's key is KeyLen bytes; the      *)
(* outcomes declare them with OWriteKey.                                   *)
(*                                                                         *)
(* The calibrated burns fit the budget.  But a write's trie-node gas       *)
(* grows with the depth of the trie under V's keys, which other users can  *)
(* deepen (with keys sharing a prefix with V's).  With TrieGasWorst on,    *)
(* each write may cost up to its worst case, (2 (2 + 64 + KeyLen) + 2) x   *)
(* 2.28 Ggas for a 64-byte account id: 488 Ggas at KeyLen 40, so the      *)
(* refund path needs 4000 + 976 Ggas.  A 4.5 Tgas budget then runs out on  *)
(* the refund path, and U's n is lost: the library's OwedOK reports it as  *)
(* "out of gas (worst-case trie depth)".  5 Tgas is enough.                *)
(*                                                                         *)
(* ILLUSTRATIVE burns, not measured; the trie-node price and bound are     *)
(* nearcore's (88).                                                        *)
(***************************************************************************)
EXTENDS NearAsync

CONSTANTS U, V, T,
    MaxTx,      \* send transactions
    Amts,       \* amounts U may send
    InitBal,    \* U's balance in V
    TResps,     \* T.take behaviours: subset of {"ok", "panic"}
    GasMenu,    \* prepaid gas U may attach, Ggas
    CbBudget,   \* on_take's fixed static gas, Ggas
    KeyLen      \* bytes of each key on_take writes

VARIABLES bal, held, got, ntx
mine == <<bal, held, got, ntx>>
vars == <<platformVars, mine>>

Accts   == {U, V, T}
TxIds   == 1..MaxTx
Floor0  == [a \in Accts |-> 0]
NoTable == [x \in {} |-> 0]

\* Gas tables (Ggas).  on_take: a fixed static budget, weight 0; T.take gets
\* the leftover.
GC(st, wt, fee) == [st |-> st, wt |-> wt, fee |-> fee]
LGasCall == ("take"    :> GC(<<0>>, <<1>>, 300))
         @@ ("on_take" :> GC(<<CbBudget>>, <<0>>, 300))
LGasBurn == ("send"           :> [base |-> 2000, per |-> 0])
         @@ ("take"           :> [base |-> 3000, per |-> 0])
         @@ ("on_take/sent"   :> [base |-> 3000, per |-> 0])
         @@ ("on_take/refund" :> [base |-> 4000, per |-> 0])

Out0 == Outcome({}, {}, RVal(EMPTY), 0, 0)

(* ---- ledger V ----------------------------------------------------------- *)
\* send(n): debit n, take it through T, then on_take (owed).
H_send(r) ==
    LET n  == r.a
        t  == Rcpt(nid, r.tx, T, V, "take", n, 0, V, nid + 1)
        cb == WithOwed(Rcpt(nid + 1, r.tx, V, V, "on_take", n, 0, V, r.cb))
    IN IF bal < n THEN [O |-> OErr(Out0, "not enough balance"), b |-> bal, h |-> held]
       ELSE [O |-> OWriteKey(Outcome({t}, {cb}, RProm, 0, 2), KeyLen), b |-> bal - n, h |-> held + n]

\* on_take(n): T took n (record it: one write), or credit n back and clear
\* the pending entry (two writes).
H_on_take(r) ==
    LET n    == r.a
        took == r.res.ok
        O    == IF took THEN OWriteKey(OKey(Out0, "on_take/sent"), KeyLen)
                ELSE OWriteKey(OWriteKey(OKey(Out0, "on_take/refund"), KeyLen), KeyLen)
    IN [O |-> O, b |-> IF took THEN bal ELSE bal + n, h |-> held - n]

RunV(r) ==
    LET h == IF r.m = "send" THEN H_send(r) ELSE H_on_take(r) IN
    /\ Exec(r, h.O)
    /\ bal'  = IF Ok(r, h.O) THEN h.b ELSE bal
    /\ held' = IF Ok(r, h.O) THEN h.h ELSE held
    /\ UNCHANGED <<got, ntx>>

(* ---- receiver T ---------------------------------------------------------- *)
RunT(r) == \E resp \in TResps :
    LET O == IF resp = "ok" THEN Outcome({}, {}, RVal(r.a), 0, 0)
             ELSE OErr(Out0, "take failed") IN
    /\ Exec(r, O)
    /\ got' = IF Ok(r, O) THEN got + r.a ELSE got
    /\ UNCHANGED <<bal, held, ntx>>

(* ---- transactions, Next -------------------------------------------------- *)
Send ==
    /\ ntx < MaxTx
    /\ \E n \in Amts, g \in GasMenu :
         Submit(WithGas(Rcpt(nid, ntx + 1, V, U, "send", n, 0, U, 0), g))
    /\ ntx' = ntx + 1
    /\ UNCHANGED <<bal, held, got>>

Run == \E r \in Runnable :
         CASE IsBuiltin(r) -> ExecBuiltin(r) /\ UNCHANGED mine
           [] r.to = T     -> RunT(r)
           [] OTHER        -> RunV(r)

Init == /\ PlatformInit([a \in Accts |-> 0], TxIds)
        /\ bal = InitBal /\ held = 0 /\ got = 0 /\ ntx = 0

Next == Send \/ Run
Spec == Init /\ [][Next]_vars

(* ---- properties ---------------------------------------------------------- *)
\* Once idle, nothing is held and U's balance plus what T took is the start.
Books == Idle => held = 0 /\ bal + got = InitBal
Sane == NearConserved(0) /\ NoOrphans
=============================================================================
