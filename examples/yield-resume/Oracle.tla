------------------------------- MODULE Oracle -------------------------------
(***************************************************************************)
(* Yield/resume (NEP-519).  A yielded callback runs once: with the payload *)
(* of the first resume to arrive, or with Failed when the yield times out. *)
(* promise_yield_resume returns TRUE for every call made before the        *)
(* callback has run, not only for the first                                *)
(* (runtime/runtime/src/ext.rs:406-430 at nearcore bc4e9e8; extra resumes  *)
(* are dropped on arrival, runtime/runtime/src/lib.rs:1616-1622).          *)
(*                                                                         *)
(* Contract Q: U calls Q.request(), which escrows 1 of U's credits, yields *)
(* Q.on_answer and returns the yield (U's transaction result is the        *)
(* callback's).  Operator O calls Q.answer(y): it resumes y and, if the    *)
(* resume returned TRUE and request y is still open, pays O 1 credit from  *)
(* the escrow and marks the request answered.  on_answer forgets the       *)
(* request; on Failed (the timeout) it refunds U.                          *)
(*                                                                         *)
(* Handler (Bug):                                                          *)
(*   "none"    correct.                                                    *)
(*   "nofail"  on_answer treats a timeout like an answer (no refund).      *)
(*   "double"  answer() pays whenever the resume returned TRUE, with no    *)
(*             "answered" flag: two answers before the callback both pay.  *)
(* Books: once idle, U's credits + escrow + O's pay are conserved.         *)
(* NoNegEscrow: the escrow never pays out more than it holds.              *)
(* Settled: once idle, the escrow is empty.                                *)
(* NoNegCredit: U's credits never go negative.  Forgotten: once idle, no   *)
(* request is left behind.                                                 *)
(***************************************************************************)
EXTENDS NearAsync

CONSTANTS MaxTx, Steps, Bug

VARIABLES cr, esc, opPaid, reqs, ntx
mine == <<cr, esc, opPaid, reqs, ntx>>
vars == <<platformVars, mine>>

U == "u"  OP == "o"  Q == "q"
Accts == {U, OP, Q}
TxIds == 1..MaxTx
PFloor == [a \in Accts |-> 0]
NoGasTable == [x \in {} |-> 0]
Cred0 == 3
Arg(y) == [y |-> y]
Out0 == Outcome({}, {}, RVal(0), 0, 0)

\* U calls request(); O calls answer(y) for a request it has seen.
Send ==
    /\ ntx < MaxTx
    /\ \E s \in Steps :
         CASE s = "request" -> Submit(Rcpt(nid, ntx + 1, Q, U, "request", Arg(0), 0, U, 0))
           [] s = "answer"  -> \E y \in DOMAIN reqs :
                                 Submit(Rcpt(nid, ntx + 1, Q, OP, "answer", Arg(y), 0, OP, 0))
           [] OTHER -> FALSE
    /\ ntx' = ntx + 1
    /\ UNCHANGED <<cr, esc, opPaid, reqs>>

Forget(y) == [x \in DOMAIN reqs \ {y} |-> reqs[x]]

\* Q's handler: [O |-> outcome, cr, esc, op, reqs].
HQ(r) ==
  LET K == [O |-> Out0, cr |-> cr, esc |-> esc, op |-> opPaid, reqs |-> reqs] IN
  CASE r.m = "request" ->
         IF cr < 1 THEN [K EXCEPT !.O = OErr(Out0, "no credit")]
         ELSE [K EXCEPT !.O = Outcome({}, {YieldRcpt(nid, r, "on_answer", Arg(nid), 0, r.cb)}, RProm, 0, 1),
                        !.cr = cr - 1, !.esc = esc + 1, !.reqs = (nid :> "open") @@ reqs]
    [] r.m = "answer" ->
         LET y    == r.a.y
             ok   == CanResume(r, y)                 \* promise_yield_resume's return value
             pay  == ok /\ y \in DOMAIN reqs /\ (reqs[y] = "open" \/ Bug = "double")
         IN [K EXCEPT !.O    = OResume(Out0, y, 7, 0),
                      !.op   = IF pay THEN opPaid + 1 ELSE opPaid,
                      !.esc  = IF pay THEN esc - 1 ELSE esc,
                      !.reqs = IF pay THEN [reqs EXCEPT ![y] = "answered"] ELSE reqs]
    [] r.m = "on_answer" ->
         LET y == r.a.y IN
         IF IsFailed(r.res) /\ Bug # "nofail"
         THEN [K EXCEPT !.cr = cr + 1, !.esc = esc - 1, !.reqs = Forget(y)]   \* timed out
         ELSE [K EXCEPT !.reqs = Forget(y)]        \* answered: O was paid in answer()
    [] OTHER -> [K EXCEPT !.O = OErr(Out0, "method not found")]

RunQ(r) ==
    LET h == HQ(r) IN
    /\ Exec(r, h.O)
    /\ IF Ok(r, h.O) THEN cr' = h.cr /\ esc' = h.esc /\ opPaid' = h.op /\ reqs' = h.reqs
       ELSE UNCHANGED <<cr, esc, opPaid, reqs>>
    /\ UNCHANGED ntx

Run == \E r \in Runnable :
         IF IsBuiltin(r) THEN ExecBuiltin(r) /\ UNCHANGED mine ELSE RunQ(r)

Init == /\ PlatformInit([a \in Accts |-> 0], TxIds)
        /\ cr = Cred0 /\ esc = 0 /\ opPaid = 0 /\ reqs = <<>> /\ ntx = 0

Next == Send \/ Run
Spec == Init /\ [][Next]_vars

Books       == Idle => cr + esc + opPaid = Cred0
NoNegEscrow == esc >= 0
Settled     == Idle => esc = 0
\* U's credits never go negative (a conserved sum such as Books cannot see that).
NoNegCredit == cr >= 0
\* Once idle, every request is forgotten: no callback left one behind.
Forgotten   == Idle => DOMAIN reqs = {}
Sane        == NoOrphans /\ NearConserved(0)
=============================================================================
