-------------------------------- MODULE Vault --------------------------------
(***************************************************************************)
(* An owed callback: the library's OwedOK (docs/SEMANTICS.md, F2).         *)
(*                                                                         *)
(* Vault V keeps an internal balance for user U.  U calls                  *)
(* V.withdraw(n, memo): V debits n (committed in that receipt) and calls   *)
(*     T.deliver(n).then(V.on_deliver(n, memo))                            *)
(* on_deliver is owed (WithOwed): it completes the withdrawal when T took  *)
(* the funds, and undoes the debit (credits n back) when T failed.  If     *)
(* on_deliver itself fails, nothing undoes the debit: U loses n.  The      *)
(* model writes no invariant about on_deliver; it marks it, lists the      *)
(* library's OwedOK, and the library reports any failure with its cause.   *)
(*                                                                         *)
(* T.deliver takes the funds and returns the amount, panics, or takes     *)
(* nothing and returns malformed bytes (TResps).  memo is a byte length U  *)
(* chooses (Memos).                                                        *)
(*                                                                         *)
(* Bug selects a wrong vault, one per cause:                               *)
(*   "none"   correct: a non-number result counts as a failure; the log    *)
(*            and the returned value have a fixed size.                    *)
(*   "panic"  on_deliver unwraps the result as a number and panics on      *)
(*            malformed bytes.                                             *)
(*   "log"    on_deliver logs "refund " ++ memo: past 16384 bytes it fails *)
(*            with TotalLogLengthExceeded (R6), unless withdraw caps the   *)
(*            memo (MemoCap) at 16377 bytes or less.                       *)
(*   "ret"    on_deliver returns a receipt that echoes the memo: past      *)
(*            4 MiB it fails with ReturnedValueLengthExceeded (R6).        *)
(*   "gas"    (gas mode) on_deliver gets a fixed 3 Tgas; its refund path   *)
(*            burns 4 Tgas, so it runs out of gas whenever T failed.       *)
(*                                                                         *)
(* ILLUSTRATIVE gas numbers, not measured.                                 *)
(***************************************************************************)
EXTENDS NearAsync

CONSTANTS U, V, T,
    MaxTx,      \* withdraw transactions
    Amts,       \* amounts U may withdraw
    InitBal,    \* U's balance in V
    TResps,     \* T.deliver behaviors: subset of {"ok", "panic", "mal"}
    Memos,      \* memo lengths (bytes) U may send
    GasMenu,    \* prepaid gas U may attach (gas mode), Ggas
    MemoCap,    \* withdraw refuses a longer memo
    Bug         \* "none" | "panic" | "log" | "ret" | "gas"

VARIABLES bal, held, got, ntx, gas
mine == <<bal, held, got, ntx, gas>>
vars == <<platformVars, mine>>

Accts   == {U, V, T}
TxIds   == 1..MaxTx
Floor0  == [a \in Accts |-> 0]
NoTable == [x \in {} |-> 0]
Menu    == {t * 100 : t \in 50..90} \cup {300000}   \* 5.0-9.0 Tgas by 0.1, and 300 Tgas

\* Gas tables (Ggas).  on_deliver gets a fixed static budget and no share of
\* the leftover; T.deliver gets the leftover.
GC(st, wt, fee) == [st |-> st, wt |-> wt, fee |-> fee]
OnBudget == IF Bug = "gas" THEN 3000 ELSE 6000
VGasCall == ("deliver"    :> GC(<<0>>, <<1>>, 300))
         @@ ("on_deliver" :> GC(<<OnBudget>>, <<0>>, 300))
VGasBurn == ("withdraw"          :> [base |-> 2000, per |-> 0])
         @@ ("deliver"           :> [base |-> 3000, per |-> 0])
         @@ ("on_deliver/sent"   :> [base |-> 2000, per |-> 0])
         @@ ("on_deliver/refund" :> [base |-> 4000, per |-> 0])

Args(n, memo) == [n |-> n, memo |-> memo]
Out0 == Outcome({}, {}, RVal(EMPTY), 0, 0)

(* ---- vault V ------------------------------------------------------------ *)
\* withdraw(n, memo): debit n, deliver it through T, then on_deliver (owed).
H_withdraw(r) ==
    LET n  == r.a.n
        d  == Rcpt(nid, r.tx, T, V, "deliver", r.a, 0, V, nid + 1)
        cb == WithOwed(Rcpt(nid + 1, r.tx, V, V, "on_deliver", r.a, 0, V, r.cb))
    IN IF bal < n THEN [O |-> OErr(Out0, "not enough balance"), b |-> bal, h |-> held]
       ELSE IF r.a.memo > MemoCap THEN [O |-> OErr(Out0, "memo too long"), b |-> bal, h |-> held]
       ELSE [O |-> Outcome({d}, {cb}, RProm, 0, 2), b |-> bal - n, h |-> held + n]

\* on_deliver(n, memo): T took n (a number came back), or credit n back.
Took(r) == IF Bug = "panic" THEN r.res.ok ELSE IsNum(r.res)
H_on_deliver(r) ==
    LET n    == r.a.n
        took == Took(r)
        O0   == OKey(Out0, IF took THEN "on_deliver/sent" ELSE "on_deliver/refund")
        O1   == IF Bug = "panic" /\ r.res.ok /\ ~IsNum(r.res)
                THEN OErr(O0, "unexpected result")          \* .unwrap() on the parse
                ELSE O0
        O2   == IF took THEN O1
                ELSE OLog(O1, IF Bug = "log" THEN 7 + r.a.memo ELSE 20)
        O3   == IF Bug = "ret" THEN [O2 EXCEPT !.ret = RValLen(0, 32 + r.a.memo)] ELSE O2
    IN [O |-> O3, b |-> IF took THEN bal ELSE bal + n, h |-> held - n]

RunV(r) ==
    LET h == IF r.m = "withdraw" THEN H_withdraw(r) ELSE H_on_deliver(r) IN
    /\ Exec(r, h.O)
    /\ bal'  = IF Ok(r, h.O) THEN h.b ELSE bal
    /\ held' = IF Ok(r, h.O) THEN h.h ELSE held
    /\ UNCHANGED <<got, ntx, gas>>

(* ---- receiver T ---------------------------------------------------------- *)
RunT(r) == \E resp \in TResps :
    LET O == CASE resp = "ok"    -> Outcome({}, {}, RVal(r.a.n), 0, 0)
               [] resp = "mal"   -> Outcome({}, {}, RVal(MAL), 0, 0)
               [] OTHER          -> OErr(Out0, "deliver failed") IN
    /\ Exec(r, O)
    /\ got' = IF Ok(r, O) /\ resp = "ok" THEN got + r.a.n ELSE got   \* "mal": T took nothing
    /\ UNCHANGED <<bal, held, ntx, gas>>

(* ---- dispatcher, transactions, Next ------------------------------------- *)
Withdraw ==
    /\ ntx < MaxTx
    /\ \E n \in Amts, memo \in Memos, g \in (IF GasMode = "gas" THEN GasMenu ELSE {0}) :
         /\ Submit(WithGas(Rcpt(nid, ntx + 1, V, U, "withdraw", Args(n, memo), 0, U, 0), g))
         /\ gas' = [gas EXCEPT ![ntx + 1] = g]
    /\ ntx' = ntx + 1
    /\ UNCHANGED <<bal, held, got>>

Run == \E r \in Runnable :
         CASE IsBuiltin(r) -> ExecBuiltin(r) /\ UNCHANGED mine
           [] r.to = T     -> RunT(r)
           [] OTHER        -> RunV(r)

Init == /\ PlatformInit([a \in Accts |-> 0], TxIds)
        /\ bal = InitBal /\ held = 0 /\ got = 0 /\ ntx = 0
        /\ gas = [t \in TxIds |-> 0]

Next == \/ Withdraw \/ Run
        \/ \E r \in Runnable : ForcedFail(r) /\ UNCHANGED mine
Spec == Init /\ [][Next]_vars

(* ---- properties ---------------------------------------------------------- *)
\* Once idle, nothing is held and U's balance plus what T received is the start.
Books == Idle => held = 0 /\ bal + got = InitBal
NoOverdraft == bal >= 0
Sane == NearConserved(0) /\ NoOrphans
\* Print-only: every state where an owed callback has failed, with the prepaid gas.
WinOwed == OwedFailed # {} => PrintT(<<"WIN", "OwedOK", gas[(CHOOSE x \in OwedFailed : TRUE).tx], OwedFailed>>)
=============================================================================
