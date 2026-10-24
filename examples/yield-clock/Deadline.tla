------------------------------ MODULE Deadline ------------------------------
(***************************************************************************)
(* Yield timeouts on the block clock.  A yield created at height h may     *)
(* time out once the height reaches h + the timeout, and at any later      *)
(* height: the timeout fires late, never early (the queue is drained at    *)
(* the end of a chunk while expires_at <= block_height and stops at the    *)
(* compute limit, runtime/runtime/src/lib.rs:3113-3221, :3130-3132, :3146  *)
(* at nearcore b7b4737), and its callback runs in a later block.           *)
(*                                                                         *)
(* Contract Q: as examples/yield-resume (request / answer / on_answer),    *)
(* plus cancel(y), which U may call once blk >= at + CancelAt (at = the    *)
(* request's height): it refunds U and drops request y if still open.      *)
(* on_answer ignores a dropped request.                                    *)
(*                                                                         *)
(* Handler (Bug):                                                          *)
(*   "none"            correct.                                            *)
(*   "trusts_timeout"  on_answer refunds a dropped request on Failed too:  *)
(*                     it assumes that with CancelAt > the timeout the     *)
(*                     timeout has always run before any cancel.           *)
(*   "after_answer"    cancel also refunds an answered request whose       *)
(*                     callback is still in flight.                        *)
(* NoEarlyTimeout (ghost): no on_answer saw Failed before its deadline.    *)
(* With the clock bound MaxBlk below a deadline it can fail: ClockBoundOK  *)
(* reports that case.                                                      *)
(***************************************************************************)
EXTENDS NearAsync

CONSTANTS MaxTx, Steps, CancelAt, Bug

VARIABLES cr, esc, opPaid, reqs, ntx, early
mine == <<cr, esc, opPaid, reqs, ntx, early>>
vars == <<platformVars, mine>>

U == "u"  OP == "o"  Q == "q"
Accts == {U, OP, Q}
TxIds == 1..MaxTx
PFloor == [a \in Accts |-> 0]
NoGasTable == [x \in {} |-> 0]
Cred0 == 3
Arg(y) == [y |-> y]
Out0 == Outcome({}, {}, RVal(0), 0, 0)

Send ==
    /\ ntx < MaxTx
    /\ \E s \in Steps :
         CASE s = "request" -> Submit(Rcpt(nid, ntx + 1, Q, U, "request", Arg(0), 0, U, 0))
           [] s = "answer"  -> \E y \in DOMAIN reqs :
                                 Submit(Rcpt(nid, ntx + 1, Q, OP, "answer", Arg(y), 0, OP, 0))
           [] s = "cancel"  -> \E y \in DOMAIN reqs :
                                 Submit(Rcpt(nid, ntx + 1, Q, U, "cancel", Arg(y), 0, U, 0))
           [] OTHER -> FALSE
    /\ ntx' = ntx + 1
    /\ UNCHANGED <<cr, esc, opPaid, reqs, early>>

Forget(y) == [x \in DOMAIN reqs \ {y} |-> reqs[x]]

\* Q's handler: [O |-> outcome, cr, esc, op, reqs].  request() records the
\* height (env::block_height() is blk).
HQ(r) ==
  LET K == [O |-> Out0, cr |-> cr, esc |-> esc, op |-> opPaid, reqs |-> reqs] IN
  CASE r.m = "request" ->
         IF cr < 1 THEN [K EXCEPT !.O = OErr(Out0, "no credit")]
         ELSE [K EXCEPT !.O = Outcome({}, {YieldRcpt(nid, r, "on_answer", Arg(nid), 0, r.cb)}, RProm, 0, 1),
                        !.cr = cr - 1, !.esc = esc + 1,
                        !.reqs = (nid :> [at |-> blk, st |-> "open"]) @@ reqs]
    [] r.m = "answer" ->
         LET y   == r.a.y
             pay == CanResume(r, y) /\ y \in DOMAIN reqs /\ reqs[y].st = "open"
         IN [K EXCEPT !.O    = OResume(Out0, y, 7, 0),
                      !.op   = IF pay THEN opPaid + 1 ELSE opPaid,
                      !.esc  = IF pay THEN esc - 1 ELSE esc,
                      !.reqs = IF pay THEN [reqs EXCEPT ![y].st = "answered"] ELSE reqs]
    [] r.m = "on_answer" ->
         LET y == r.a.y IN
         IF y \notin DOMAIN reqs /\ Bug # "trusts_timeout"
         THEN K                                     \* cancelled: nothing left to do
         ELSE IF IsFailed(r.res)
         THEN [K EXCEPT !.cr = cr + 1, !.esc = esc - 1, !.reqs = Forget(y)]   \* timed out
         ELSE [K EXCEPT !.reqs = Forget(y)]
    [] r.m = "cancel" ->
         LET y == r.a.y IN
         IF \/ y \notin DOMAIN reqs
            \/ blk < reqs[y].at + CancelAt
            \/ reqs[y].st # "open" /\ Bug # "after_answer"
         THEN [K EXCEPT !.O = OErr(Out0, "cannot cancel")]
         ELSE [K EXCEPT !.cr = cr + 1, !.esc = esc - 1, !.reqs = Forget(y)]
    [] OTHER -> [K EXCEPT !.O = OErr(Out0, "method not found")]

\* Ghost: an on_answer for a live request sees Failed before its deadline.
Early(r) == /\ r.m = "on_answer" /\ IsFailed(r.res) /\ r.a.y \in DOMAIN reqs
            /\ blk < reqs[r.a.y].at + YieldTicks

RunQ(r) ==
    LET h == HQ(r) IN
    /\ Exec(r, h.O)
    /\ IF Ok(r, h.O) THEN cr' = h.cr /\ esc' = h.esc /\ opPaid' = h.op /\ reqs' = h.reqs
       ELSE UNCHANGED <<cr, esc, opPaid, reqs>>
    /\ early' = (early \/ Early(r))
    /\ UNCHANGED ntx

Run == \E r \in Runnable :
         IF IsBuiltin(r) THEN ExecBuiltin(r) /\ UNCHANGED mine ELSE RunQ(r)

Init == /\ PlatformInit([a \in Accts |-> 0], TxIds)
        /\ cr = Cred0 /\ esc = 0 /\ opPaid = 0 /\ reqs = <<>> /\ ntx = 0 /\ early = FALSE

Next == Send \/ Run \/ (BlockTick /\ UNCHANGED mine)
Spec == Init /\ [][Next]_vars

Books          == Idle => cr + esc + opPaid = Cred0
NoNegEscrow    == esc >= 0
Settled        == Idle => esc = 0
NoEarlyTimeout == ~early
Sane           == NoOrphans /\ NearConserved(0)
=============================================================================
