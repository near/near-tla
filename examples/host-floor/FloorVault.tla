------------------------------ MODULE FloorVault ------------------------------
(***************************************************************************)
(* Gas mode without a calibrated table: the host-cost floor               *)
(* (docs/SEMANTICS.md, G7).                                                *)
(*                                                                         *)
(* Vault V keeps U's balance.  U calls V.send(n): V debits n and records a *)
(* pending batch of Batch keys (committed in that receipt), and calls     *)
(*     T.take(n).then(V.on_take(n))                                        *)
(* on_take is owed (WithOwed) and has a fixed static gas, CbBudget, and no *)
(* share of the leftover.  When T took n it records the transfer (one      *)
(* write); when T failed it removes the batch's Batch keys, credits n      *)
(* back and logs one refund event of 50 + 40 bytes per entry.  Every key   *)
(* is KeyLen bytes; the outcomes declare the writes (OWriteKeys) and the   *)
(* event (OLog).                                                           *)
(*                                                                         *)
(* No burn is measured: GasBurn is empty, and with HostFloorGas on each    *)
(* receipt burns only the floor of the host calls it declares.  That is a  *)
(* lower bound of what it burns on real wasm, so when on_take's floor     *)
(* exceeds its fixed budget, on_take runs out on real wasm too.  At       *)
(* KeyLen 100 a removed entry costs at least 57.3 Ggas and its event      *)
(* bytes 4.9 Ggas: the refund path needs 4987 Ggas at 80 entries (within  *)
(* 5 Tgas) and 5049 at 81, where OwedOK reports U's n lost.  With          *)
(* TrieGasWorst on as well, each remove may also pay its worst-case trie  *)
(* depth (G6): 7 entries are then too many.  A pass says nothing: the     *)
(* wasm's own burn comes on top of the floor.                              *)
(***************************************************************************)
EXTENDS NearAsync

CONSTANTS U, V, T,
    MaxTx,      \* send transactions
    Amts,       \* amounts U may send
    InitBal,    \* U's balance in V
    TResps,     \* T.take behaviors: subset of {"ok", "panic"}
    GasMenu,    \* prepaid gas U may attach, Ggas
    CbBudget,   \* on_take's fixed static gas, Ggas
    KeyLen,     \* bytes of each key V writes
    Batch       \* keys in a pending batch

VARIABLES bal, held, got, ntx
mine == <<bal, held, got, ntx>>
vars == <<platformVars, mine>>

Accts   == {U, V, T}
TxIds   == 1..MaxTx
Floor0  == [a \in Accts |-> 0]
NoTable == [x \in {} |-> 0]

\* Gas tables (Ggas): statics only; no burns (the floor stands in for them).
\* on_take: a fixed static budget, weight 0; T.take gets the leftover.
GC(st, wt, fee) == [st |-> st, wt |-> wt, fee |-> fee]
LGasCall == ("take"    :> GC(<<0>>, <<1>>, 300))
         @@ ("on_take" :> GC(<<CbBudget>>, <<0>>, 300))

\* The refund event's bytes.
EvBytes == 50 + 40 * Batch

Out0 == Outcome({}, {}, RVal(EMPTY), 0, 0)

(* ---- vault V ------------------------------------------------------------ *)
\* send(n): debit n, record the batch, take n through T, then on_take (owed).
H_send(r) ==
    LET n  == r.a
        t  == Rcpt(nid, r.tx, T, V, "take", n, 0, V, nid + 1)
        cb == WithOwed(Rcpt(nid + 1, r.tx, V, V, "on_take", n, 0, V, r.cb))
    IN IF bal < n THEN [O |-> OErr(Out0, "not enough balance"), b |-> bal, h |-> held]
       ELSE [O |-> OWriteKeys(Outcome({t}, {cb}, RProm, 0, 2), KeyLen, Batch),
             b |-> bal - n, h |-> held + n]

\* on_take(n): T took n (one write), or remove the batch, credit n back and
\* log the refund.
H_on_take(r) ==
    LET n    == r.a
        took == r.res.ok
        O    == IF took THEN OWriteKey(OKey(Out0, "on_take/sent"), KeyLen)
                ELSE OLog(OWriteKeys(OKey(Out0, "on_take/refund"), KeyLen, Batch), EvBytes)
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
