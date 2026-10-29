------------------------------- MODULE Notify --------------------------------
(***************************************************************************)
(* Two receipts on one sender-receiver pair, in the order they were made?  *)
(* nearcore does not promise it (docs/SEMANTICS.md, S4).                   *)
(*                                                                         *)
(* User U calls S.open(); S sends D.d_open(seq 1).  Only once S.open has   *)
(* run does U call S.close(); S sends D.d_close(seq 2).  So D.d_open is    *)
(* created first, by the same account, to the same account.  In nearcore   *)
(* it can still run second: a new receipt skips the sender shard's         *)
(* outgoing buffer whenever it fits the link's limits, while an earlier    *)
(* one waits there (runtime/runtime/src/congestion_control.rs:292-325,     *)
(* :451 @ bc4e9e8; the sim shows it, sim tests/order.rs:414-447, and so    *)
(* does conformance/tests/semantics.rs,                                    *)
(* later_receipt_overtakes_buffered).  The model lets any ready receipt    *)
(* run next, so it finds that order without any switch.                    *)
(*                                                                         *)
(* NoDangling: once both are sent and nothing is in flight, D is closed.   *)
(*   Seqno = FALSE (wrong, assumes FIFO): d_open opens and d_close closes, *)
(*     so d_close then d_open leaves D open forever (pair_assumes_fifo).   *)
(*   Seqno = TRUE (correct): D keeps the highest sequence number seen and  *)
(*     ignores an older message, so either order ends closed               *)
(*     (pair_seqno_ok).                                                    *)
(***************************************************************************)
EXTENDS NearAsync

CONSTANTS U, S, D,
    Seqno            \* TRUE: D applies a message only if its seq is the newest

VARIABLES sentOpen, sentClose, sOpened, dOpen, dHi
mine == <<sentOpen, sentClose, sOpened, dOpen, dHi>>
vars == <<platformVars, mine>>

Accts == {U, S, D}
Zero  == [a \in Accts |-> 0]

(* ---- contract S -------------------------------------------------------- *)
\* open() / close(): one message to D, numbered 1 and 2.
HS(r) ==
    LET m == IF r.m = "open" THEN "d_open" ELSE "d_close"
        s == IF r.m = "open" THEN 1 ELSE 2
    IN  Outcome({Rcpt(nid, r.tx, D, S, m, [s |-> s], 0, S, 0)}, {}, RVal(EMPTY), 0, 1)

RunS(r) ==
    /\ Exec(r, HS(r))
    /\ sOpened' = (sOpened \/ (Ok(r, HS(r)) /\ r.m = "open"))
    /\ UNCHANGED <<sentOpen, sentClose, dOpen, dHi>>

(* ---- contract D -------------------------------------------------------- *)
HD == Outcome({}, {}, RVal(EMPTY), 0, 0)
Fresh(r) == ~Seqno \/ r.a.s > dHi

RunD(r) ==
    /\ Exec(r, HD)
    /\ IF Ok(r, HD) /\ Fresh(r)
       THEN /\ dOpen' = (r.m = "d_open")
            /\ dHi' = IF r.a.s > dHi THEN r.a.s ELSE dHi
       ELSE UNCHANGED <<dOpen, dHi>>
    /\ UNCHANGED <<sentOpen, sentClose, sOpened>>

(* ---- dispatcher, transactions, Next ----------------------------------- *)
Step(r) ==
    CASE IsBuiltin(r) -> ExecBuiltin(r) /\ UNCHANGED mine     \* refunds
      [] r.to = D     -> RunD(r)
      [] OTHER        -> RunS(r)

OpenTx ==
    /\ ~sentOpen
    /\ Submit(Rcpt(nid, 1, S, U, "open", [s |-> 0], 0, U, 0))
    /\ sentOpen' = TRUE
    /\ UNCHANGED <<sentClose, sOpened, dOpen, dHi>>

\* U closes only after S.open has run, so d_open was made first.
CloseTx ==
    /\ sOpened /\ ~sentClose
    /\ Submit(Rcpt(nid, 2, S, U, "close", [s |-> 0], 0, U, 0))
    /\ sentClose' = TRUE
    /\ UNCHANGED <<sentOpen, sOpened, dOpen, dHi>>

Init == /\ PlatformInit(Zero, {1, 2})
        /\ sentOpen = FALSE /\ sentClose = FALSE /\ sOpened = FALSE
        /\ dOpen = FALSE /\ dHi = 0

Next == \/ OpenTx \/ CloseTx
        \/ \E r \in Runnable : Step(r)
Spec == Init /\ [][Next]_vars

(* ---- properties --------------------------------------------------------- *)
NoDangling == (sentClose /\ Idle) => ~dOpen
\* Once S has opened and nothing is in flight before the close, D is open: the open
\* message was applied, not dropped (NoDangling alone holds if D never opens).
OpenApplied == (sOpened /\ ~sentClose /\ Idle) => dOpen
Sane == NearConserved(0) /\ NoOrphans
=============================================================================
