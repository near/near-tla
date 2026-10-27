-------------------------------- MODULE Tally --------------------------------
(***************************************************************************)
(* The minimal model that docs/TUTORIAL.md builds step by step.            *)
(*                                                                         *)
(* User U calls C.ping() with a 1-unit deposit.  ping calls D.work() and   *)
(* then its own callback C.done():                                         *)
(*     D.work().then(C.done())                                             *)
(* D counts the works that committed (works); C counts in done the works   *)
(* it believes happened (n).  Counted: once nothing is in flight, n =      *)
(* works.  done must look at its promise result: work can fail (a forced   *)
(* fault, or out of gas in gas mode), and done runs anyway, seeing Failed. *)
(* Trusting = TRUE is the wrong contract: done counts without looking.     *)
(***************************************************************************)
EXTENDS NearAsync

CONSTANTS U, C, D,     \* account names
    MaxTx,             \* number of ping transactions
    InitU,             \* U's initial balance (pays the deposits)
    GasMenu,           \* prepaid gas U may attach (gas mode), Ggas
    Trusting           \* TRUE: done counts a work without checking its result

VARIABLES n, works, ntx, gas
mine == <<n, works, ntx, gas>>
vars == <<platformVars, mine>>

Accts   == {U, C, D}
TxIds   == 1..MaxTx
Near0   == [a \in Accts |-> IF a = U THEN InitU ELSE 0]
Menu    == {t * 100 : t \in 80..95} \cup {1000000}   \* 8.0-9.5 Tgas by 0.1, and the 1000 Tgas maximum

\* Gas tables (Ggas).  ILLUSTRATIVE numbers, not measured (docs/USAGE.md, Calibrating).
GC(st, wt, fee) == [st |-> st, wt |-> wt, fee |-> fee]
TGasCall == ("work" :> GC(<<5000>>, <<1>>, 300))     \* 5 Tgas static + all the leftover
         @@ ("done" :> GC(<<2000>>, <<0>>, 300))     \* 2 Tgas static, no share
TGasBurn == ("ping" :> [base |-> 1000, per |-> 0])
         @@ ("work" :> [base |-> 5500, per |-> 0])
         @@ ("done" :> [base |-> 600,  per |-> 0])

(* ---- contract C -------------------------------------------------------- *)
\* ping(): D.work().then(C.done()); returns done's result.
H_ping(r) ==
    LET w  == Rcpt(nid, r.tx, D, C, "work", r.a, 0, C, nid + 1)
        dn == Rcpt(nid + 1, r.tx, C, C, "done", r.a, 0, C, r.cb)
    IN Outcome({w}, {dn}, RProm, 0, 2)

\* done(): count the work only if it succeeded (Trusting: count it anyway).
H_done(r) == Outcome({}, {}, RVal(EMPTY), 0, 0)
NewN(r) == IF Trusting \/ ~IsFailed(r.res) THEN n + 1 ELSE n

RunC(r) ==
    LET O == IF r.m = "ping" THEN H_ping(r) ELSE H_done(r) IN
    /\ Exec(r, O)
    /\ n' = IF Ok(r, O) /\ r.m = "done" THEN NewN(r) ELSE n
    /\ UNCHANGED <<works, ntx, gas>>

(* ---- contract D -------------------------------------------------------- *)
RunD(r) ==
    LET O == Outcome({}, {}, RVal(EMPTY), 0, 0) IN
    /\ Exec(r, O)
    /\ works' = IF Ok(r, O) THEN works + 1 ELSE works
    /\ UNCHANGED <<n, ntx, gas>>

(* ---- dispatcher, transactions, Next ----------------------------------- *)
Step(r) ==
    CASE IsPlatformRcpt(r)              -> PlatformStep(r) /\ UNCHANGED mine  \* no contract code
      [] ~IsPlatformRcpt(r) /\ r.to = D -> RunD(r)
      [] OTHER                          -> RunC(r)

Ping ==
    /\ ntx < MaxTx
    /\ \E g \in (IF GasMode = "gas" THEN GasMenu ELSE {0}) :
         /\ Submit(WithGas(Rcpt(nid, ntx + 1, C, U, "ping", [x |-> 0], 1, U, 0), g))
         /\ gas' = [gas EXCEPT ![ntx + 1] = g]
    /\ ntx' = ntx + 1
    /\ UNCHANGED <<n, works>>

Init == /\ PlatformInit(Near0, TxIds)
        /\ n = 0 /\ works = 0 /\ ntx = 0
        /\ gas = [t \in TxIds |-> 0]

\* Named steps, so a trace says which kind of step each state took.
RunReceipt == \E r \in Runnable : Step(r)
Fault      == \E r \in Runnable : ForcedFail(r) /\ UNCHANGED mine

Next == Ping \/ RunReceipt \/ Fault
Spec == Init /\ [][Next]_vars

(* ---- properties --------------------------------------------------------- *)
Counted == Idle => n = works
\* At the 1000 Tgas maximum every work commits: the split gives work enough gas.
WorkFits == (Idle /\ \A t \in 1..ntx : gas[t] = 1000000) => works = ntx
\* Library sanity: NEAR conserved from the initial total (only U starts with
\* NEAR), no receipt holds more than its transaction's prepaid gas, no orphans.
Sane == NearConserved(InitU) /\ GasBounded(LAMBDA t : gas[t]) /\ NoOrphans
\* Print-only: every bad end state, with its prepaid gas.
WinCounted == (Idle /\ n # works) => PrintT(<<"WIN", "Counted", gas[ntx], oog>>)
=============================================================================
