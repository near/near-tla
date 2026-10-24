------------------------------ MODULE Limits ------------------------------
(***************************************************************************)
(* Protocol limits (docs/SEMANTICS.md, R6), at the last value              *)
(* nearcore accepts and the first it refuses.  U starts one scenario       *)
(* (Shape); D is a contract that pays or asks P, a payee contract.         *)
(*                                                                         *)
(*  "batch"  D pays N times through P.pay, in receipts of at most B        *)
(*           function calls.  A receipt of more than 100 actions fails D   *)
(*           after its call (new-receipt validation): nothing is paid.     *)
(*  "tx"     U sends one transaction of N P.pay calls itself.  More than   *)
(*           100 actions make it invalid: it is never sent.                *)
(*  "fan"    D pays N times through N receipts.  More than 1024 promises   *)
(*           in one call fail D's call.                                    *)
(*  "join"   D asks P for N quotes and reads them in one joint callback,   *)
(*           D.gather.  More than 128 inputs fail D's call.                *)
(*  "nest"   D pays N times through N receipts and asks P for 3 quotes,    *)
(*           joined by a nested promise_and(promise_and(q1, q2), q3)       *)
(*           .then(D.gather): N + 4 receipts and 2 joins, which D states   *)
(*           with OJoins(O, J) (J = -1: not stated).  More than 1024       *)
(*           promises fail D's call; unstated, a count that the nesting    *)
(*           could take past 1024 is an Assert.                            *)
(*  "multi"  U sends D.go as one receipt of two function calls; the first  *)
(*           pays B times, the second N - B times, each through its own    *)
(*           receipts, and pa says which call made which (PA).  The 1024   *)
(*           promises are per call.  Without pa, more than 1024 in all is  *)
(*           an Assert.                                                    *)
(*  "ret"    D calls P.blob, which returns Bytes bytes, and reads it in    *)
(*           D.got.  More than 4 MiB fail P.blob; D.got reads Failed.      *)
(*  "addkey" U adds a function-call key for P whose method names take      *)
(*           Bytes bytes.  More than 2000 is an Assert: nearcore refuses   *)
(*           it where it is created, which the model does not represent.   *)
(*  "log"    D's call writes N logs of Bytes bytes each (OLog).  More than *)
(*           100 logs, or 16384 bytes in all, fail D's call.               *)
(*                                                                         *)
(* Receipts run one at a time, in a fixed order (CHOOSE): the outcome does *)
(* not depend on the order here, and a fixed one keeps the 1024-receipt    *)
(* fan-out to one behaviour.                                               *)
(*                                                                         *)
(* Done: once the scenario has started and the system is idle, P was paid  *)
(* N times ("batch", "tx", "fan", "multi"; and 3 quotes gathered,        *)
(* "nest"), D gathered N quotes ("join"), D read                           *)
(* the blob ("ret"), U has the key ("addkey"), or D's call ran ("log").    *)
(* Sane: no orphans, and NEAR is conserved.                                *)
(***************************************************************************)
EXTENDS NearKeys

CONSTANTS U, D, P, Shape, N, B, Bytes, J, PA

VARIABLES started, npaid, got
mine == <<started, npaid, got>>
vars == <<platformVars, keyVars, mine>>

Accts == {U, D, P}
PFloor == [a \in Accts |-> 0]
NoGasTable == [x \in {} |-> 0]
Out0 == Outcome({}, {}, RVal(0), 0, 0)

\* A receipt of n function calls to P.pay (one static each: a batch).
PayBatch(id, fr, n) == WithStatic(Rcpt(id, 1, P, fr, "pay", n, 0, fr, 0), [i \in 1..n |-> 0])
NBatches == (N + B - 1) \div B
BatchSize(i) == IF (i + 1) * B <= N THEN B ELSE N - i * B
\* The key U adds in "addkey": its method names take Bytes bytes.
NamesKey == WithMethodBytes(Perm(P, {"pay"}, FALSE), Bytes)

Start ==
    /\ ~started
    /\ started' = TRUE
    /\ UNCHANGED <<npaid, got>>
    /\ CASE Shape = "tx"     -> IF CanSubmit(PayBatch(nid, U, N), U)
                                THEN SubmitSigned(PayBatch(nid, U, N), U, "k0")
                                ELSE UNCHANGED <<platformVars, keyVars>>
         [] Shape = "addkey" -> SubmitSigned(AddKeyRcpt(nid, 1, U, "s", NamesKey, 0), U, "k0")
         [] Shape = "multi"  -> Submit(WithStatic(Rcpt(nid, 1, D, U, "go", 0, 0, U, 0), <<0, 0>>))
                                /\ UNCHANGED keyVars
         [] OTHER            -> Submit(Rcpt(nid, 1, D, U, "go", 0, 0, U, 0)) /\ UNCHANGED keyVars

\* An outcome with n more logs of b bytes each.
RECURSIVE Logs(_, _, _)
Logs(O, b, n) == IF n = 0 THEN O ELSE Logs(OLog(O, b), b, n - 1)

\* D's and P's handlers.
H(r) ==
  CASE r.m = "go" /\ Shape = "batch" ->
         Outcome({PayBatch(nid + i, D, BatchSize(i)) : i \in 0..(NBatches - 1)}, {}, RVal(0), 0, NBatches)
    [] r.m = "go" /\ Shape = "fan" ->
         Outcome({Rcpt(nid + i, 1, P, D, "pay", 1, 0, D, 0) : i \in 0..(N - 1)}, {}, RVal(0), 0, N)
    [] r.m = "go" /\ Shape = "nest" ->
         LET pays == {Rcpt(nid + i, 1, P, D, "pay", 1, 0, D, 0) : i \in 0..(N - 1)}
             j == AndThen([i \in 1..3 |-> Rcpt(nid + N + i - 1, 1, P, D, "quote", 0, 0, D, 0)],
                          Rcpt(nid + N + 3, 1, D, D, "gather", 0, 0, D, 0), nid + N + 4)
             O == Outcome(pays \cup {j.kids[i] : i \in 1..3}, {j.cb}, RVal(0), 0, N + 7) IN
         IF J >= 0 THEN OJoins(O, J) ELSE O
    [] r.m = "go" /\ Shape = "multi" ->
         LET O == Outcome({Rcpt(nid + i, 1, P, D, "pay", 1, 0, D, 0) : i \in 0..(N - 1)}, {}, RVal(0), 0, N) IN
         IF PA THEN [pa |-> <<[kids |-> nid..(nid + B - 1)], [kids |-> (nid + B)..(nid + N - 1)]>>] @@ O ELSE O
    [] r.m = "go" /\ Shape = "join" ->
         LET j == AndThen([i \in 1..N |-> Rcpt(nid + i - 1, 1, P, D, "quote", 0, 0, D, 0)],
                          Rcpt(nid + N, 1, D, D, "gather", 0, 0, D, 0), nid + N + 1) IN
         Outcome({j.kids[i] : i \in 1..N}, {j.cb}, RVal(0), 0, 2 * N + 1)
    [] r.m = "go" /\ Shape = "ret" ->
         Outcome({Rcpt(nid, 1, P, D, "blob", 0, 0, D, nid + 1)}, {Rcpt(nid + 1, 1, D, D, "got", 0, 0, D, 0)},
                 RVal(0), 0, 2)
    [] r.m = "go" /\ Shape = "log" -> Logs(Outcome({}, {}, RVal(0), 0, 0), Bytes, N)
    [] r.m = "quote" -> Outcome({}, {}, RVal(1), 0, 0)
    [] r.m = "blob"  -> Outcome({}, {}, RValLen(1, Bytes), 0, 0)
    [] OTHER         -> Out0

RunC(r) ==
    LET O == H(r) IN
    /\ Exec(r, O)
    /\ npaid' = IF Ok(r, O) /\ r.m = "pay" THEN npaid + NCalls(r) ELSE npaid
    /\ got'  = CASE Ok(r, O) /\ r.m = "gather" -> Cardinality({i \in 1..NRes(r) : ResAt(r, i).ok})
                 [] Ok(r, O) /\ r.m = "got"    -> IF r.res.ok THEN 1 ELSE 0
                 [] Ok(r, O) /\ r.m = "go" /\ Shape = "log" -> 1
                 [] OTHER                      -> got
    /\ UNCHANGED <<keyVars, started>>

RunOne ==
    /\ Runnable # {}
    /\ LET r == CHOOSE x \in Runnable : TRUE IN
       CASE IsKeyRcpt(r) -> ExecKeyAct(r, "s", NamesKey) /\ UNCHANGED mine
         [] IsBuiltin(r) -> ExecBuiltin(r) /\ UNCHANGED <<keyVars, mine>>
         [] OTHER        -> RunC(r)

Init == /\ PlatformInit([a \in Accts |-> 10], {1})
        /\ KeysInit([a \in {U} |-> ("k0" :> FullPerm)])
        /\ started = FALSE /\ npaid = 0 /\ got = 0

Next == Start \/ RunOne
Spec == Init /\ [][Next]_vars

Done == started /\ Idle =>
          CASE Shape \in {"batch", "tx", "fan", "multi"} -> npaid = N
            [] Shape = "nest"                            -> npaid = N /\ got = 3
            [] Shape = "join"                            -> got = N
            [] Shape \in {"ret", "log"}                  -> got = 1
            [] OTHER                                     -> KeyPresent(U, "s")
Sane == NoOrphans /\ NearConserved(30)
=============================================================================
