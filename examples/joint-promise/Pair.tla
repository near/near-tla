-------------------------------- MODULE Pair --------------------------------
(***************************************************************************)
(* A joint callback (promise_and(p, q).then(cb)) runs once, after both     *)
(* inputs, and sees one result per input in promise_and order.  Each       *)
(* input succeeds or fails on its own: Failed and Successful mix           *)
(* (runtime/runtime/src/lib.rs:861-899, :1146-1189 at nearcore bc4e9e8).   *)
(*                                                                         *)
(* Contract S: U calls S.split(), which moves 2 of U's credits into escrow *)
(* and calls A.take() and B.take() jointly, then S.on_both.  Each take()   *)
(* adds 1 to its own total or panics.  on_both releases the escrow and     *)
(* credits U back 1 per failed leg.                                        *)
(*                                                                         *)
(* Handler (Bug):                                                          *)
(*   "none"   correct: one refund per Failed position, over NRes(r).       *)
(*   "first"  reads only promise_result(0) and refunds both legs or none   *)
(*            (assumes one input).                                         *)
(*   "any"    refunds both legs when any leg failed (assumes the inputs    *)
(*            succeed or fail together).                                   *)
(*   "res"    reads r.res, as a single-input callback would.  On a joint   *)
(*            callback r.res is JointMark (Failed), so it always refunds   *)
(*            both legs, also when both succeeded (run joint_reads_res,    *)
(*            where take() never panics).                                  *)
(* Books: once idle, U's credits + escrow + both totals are conserved.     *)
(***************************************************************************)
EXTENDS NearAsync

CONSTANTS MaxTx, Bug, TakeOk   \* TakeOk: the outcomes take() may have (TRUE = adds)

VARIABLES cr, esc, tot, ntx
mine == <<cr, esc, tot, ntx>>
vars == <<platformVars, mine>>

U == "u"  S == "s"  A == "a"  B == "b"
Accts == {U, S, A, B}
TxIds == 1..MaxTx
PFloor == [a \in Accts |-> 0]
NoGasTable == [x \in {} |-> 0]
Cred0 == 3
Arg0 == [n |-> 0]
Out0 == Outcome({}, {}, RVal(0), 0, 0)

Send == /\ ntx < MaxTx
        /\ Submit(Rcpt(nid, ntx + 1, S, U, "split", Arg0, 0, U, 0))
        /\ ntx' = ntx + 1
        /\ UNCHANGED <<cr, esc, tot>>

Take(id, r, to) == Rcpt(id, r.tx, to, S, "take", Arg0, 0, S, 0)

\* S's handler: [O |-> outcome, cr, esc].
HS(r) ==
  CASE r.m = "split" ->
         IF cr < 2 THEN [O |-> OErr(Out0, "no credit"), cr |-> cr, esc |-> esc]
         ELSE \* ids: two inputs, the callback, and two data ids
              LET j == AndThen(<<Take(nid, r, A), Take(nid + 1, r, B)>>,
                               Rcpt(nid + 2, r.tx, S, S, "on_both", Arg0, 0, S, r.cb), nid + 3)
              IN [O |-> Outcome({j.kids[1], j.kids[2]}, {j.cb}, RProm, 0, 5),
                  cr |-> cr - 2, esc |-> esc + 2]
    [] r.m = "on_both" ->
         LET nf   == Cardinality({i \in 1..NRes(r) : IsFailed(ResAt(r, i))})
             back == CASE Bug = "first" -> (IF IsFailed(ResAt(r, 1)) THEN 2 ELSE 0)
                       [] Bug = "any"   -> (IF nf > 0 THEN 2 ELSE 0)
                       [] Bug = "res"   -> (IF IsFailed(r.res) THEN 2 ELSE 0)
                       [] OTHER         -> nf
         IN [O |-> Out0, cr |-> cr + back, esc |-> esc - 2]
    [] OTHER -> [O |-> OErr(Out0, "method not found"), cr |-> cr, esc |-> esc]

RunS(r) ==
    LET h == HS(r) IN
    /\ Exec(r, h.O)
    /\ IF Ok(r, h.O) THEN cr' = h.cr /\ esc' = h.esc ELSE UNCHANGED <<cr, esc>>
    /\ UNCHANGED <<tot, ntx>>

\* A.take / B.take: add 1 to its own total, or panic.
RunTake(r) == \E ok \in TakeOk :
    LET O == IF ok THEN Outcome({}, {}, RVal(1), 0, 0) ELSE OErr(Out0, "take panics") IN
    /\ Exec(r, O)
    /\ tot' = IF Ok(r, O) THEN [tot EXCEPT ![r.to] = @ + 1] ELSE tot
    /\ UNCHANGED <<cr, esc, ntx>>

Run == \E r \in Runnable :
         CASE IsBuiltin(r) -> ExecBuiltin(r) /\ UNCHANGED mine
           [] r.to = S     -> RunS(r)
           [] OTHER        -> RunTake(r)

Init == /\ PlatformInit([a \in Accts |-> 0], TxIds)
        /\ cr = Cred0 /\ esc = 0 /\ tot = [a \in {A, B} |-> 0] /\ ntx = 0

Next == Send \/ Run
Spec == Init /\ [][Next]_vars

Books == Idle => cr + esc + tot[A] + tot[B] = Cred0
\* U's credits never go negative.  Books alone misses a split that overdraws them:
\* the overdraft is a term of the conserved sum.
NoOverdraft == cr >= 0
Sane  == NoOrphans /\ NearConserved(0)
=============================================================================
