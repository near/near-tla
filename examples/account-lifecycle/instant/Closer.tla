------------------------------- MODULE Closer -------------------------------
(***************************************************************************)
(* A contract that closes by deleting itself relies on the delete being    *)
(* instant (docs/SEMANTICS.md, S5).                                        *)
(*                                                                         *)
(* Contract K counts uses: use() commits and counts, from anyone.  Its     *)
(* owner O calls close(), which emits [DeleteAccount(K -> B)] on K itself  *)
(* and keeps no "closed" flag: once the account is gone, every later call  *)
(* fails (AccountDoesNotExist, A7).  That is enough only because the       *)
(* delete is instant: it runs right after close, before any receipt        *)
(* already on its way to K (receipt.rs:468-491, lib.rs:1222-1224,          *)
(* :2747-2775).  NoUseAfterClose: no use commits after close did.          *)
(*                                                                         *)
(* Run instant_on_passes: the library's rule (InstantFirst).  Run          *)
(* instant_empty_join_passes: the same with the delete as a joint callback *)
(* with no inputs (EmptyJoin).                                             *)
(* instant_off_spurious: InstantFirst <- FALSE, the rule before the        *)
(* library modeled it; a use in flight runs between close and its delete  *)
(* and NoUseAfterClose fails, a false positive.  So a model of such a      *)
(* contract needs InstantFirst, and a contract that adds anything to the   *)
(* delete's receipt (a Transfer: then it is not instant) needs a flag.     *)
(***************************************************************************)
EXTENDS NearAsync

VARIABLES uses, closed, late, sent
\* uses: K's counter; closed: ghost, close committed; late: ghost, a use
\* committed after close; sent: steps submitted
mine == <<uses, closed, late, sent>>
vars == <<platformVars, mine>>

O == "o"  U == "u"  K == "k"  B == "b"
Accts   == {O, U, K, B}
TxIds   == 1..4      \* 1, 2: U's uses; 3: O's close; 4: U's close
Near0   == [x \in Accts |-> IF x = K THEN 3 ELSE 0]
Total0  == 3
Floor0  == [x \in Accts |-> 0]
KCode   == {K}
NoTable == [x \in {} |-> 0]
Arg(n)  == [n |-> n]
Out0    == Outcome({}, {}, RVal(0), 0, 0)

\* EmptyJoin (overridable): close emits the delete as .then on an empty
\* promise_and, a joint callback with no inputs, which is instant too (S5).
EmptyJoin == FALSE
Del(r) == DeleteAcctRcpt(nid, r.tx, K, Arg(0), B, 0)
\* K's handlers.
H(r) ==
    IF r.m = "use" THEN Out0
    ELSE IF r.fr # O THEN OErr(Out0, "only the owner closes")
    ELSE IF EmptyJoin THEN Outcome({}, {AndThen(<<>>, Del(r), nid + 1).cb}, RVal(0), 0, 1)
    ELSE Outcome({Del(r)}, {}, RVal(0), 0, 1)

RunK(r) ==
    LET O1 == H(r) IN
    /\ Exec(r, O1)
    /\ uses'   = IF Ok(r, O1) /\ r.m = "use" THEN uses + 1 ELSE uses
    /\ late'   = (late \/ (Ok(r, O1) /\ r.m = "use" /\ closed))
    /\ closed' = (closed \/ (Ok(r, O1) /\ r.m = "close"))
    /\ UNCHANGED sent

Run == \E r \in Runnable :
         IF IsBuiltin(r) THEN ExecBuiltin(r) /\ UNCHANGED mine
         ELSE IF IsAcctRcpt(r) THEN ExecAcct(r) /\ UNCHANGED mine
         ELSE RunK(r)

\* Each step once, in any order (Submit is disabled while a delete is instant-pending).
Step(s, r) == /\ s \notin sent /\ Submit(r) /\ sent' = sent \cup {s} /\ UNCHANGED <<uses, closed, late>>
Use1   == Step("u1", Rcpt(nid, 1, K, U, "use", Arg(0), 0, U, 0))
Use2   == Step("u2", Rcpt(nid, 2, K, U, "use", Arg(0), 0, U, 0))
CloseO == Step("co", Rcpt(nid, 3, K, O, "close", Arg(0), 0, O, 0))
CloseU == Step("cu", Rcpt(nid, 4, K, U, "close", Arg(0), 0, U, 0))

Init == PlatformInit(Near0, TxIds) /\ uses = 0 /\ closed = FALSE /\ late = FALSE /\ sent = {}
Next == Use1 \/ Use2 \/ CloseO \/ CloseU \/ Run
Spec == Init /\ [][Next]_vars

\* No use commits after close did.
NoUseAfterClose == ~late
\* Only the owner's close deletes K: the payout to B comes from O's transaction alone.
OwnerCloses == \A t \in TxIds \ {3} : paid[t][B] = 0
Sane == NearConserved(Total0) /\ NoOrphans
=============================================================================
