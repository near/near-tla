-------------------------------- MODULE Relay --------------------------------
(***************************************************************************)
(* A .then callback always runs, and sees Failed when the call it waits on *)
(* failed.  A callback can itself fail; that reverts only the callback's   *)
(* own receipt, never the call before it.                                   *)
(*                                                                         *)
(* Relay R keeps an internal balance bal for user U.  U calls R.send(n):   *)
(* R moves n from bal to pending and calls C.add(n) .then(R.on_added(n)).  *)
(* Counter C either adds (total := total + n) or panics.  on_added clears  *)
(* pending.                                                                *)
(*                                                                         *)
(* Correct R: on_added credits n back when the result is Failed.           *)
(* Wrong R (Wrong = TRUE): assumes the callback only runs after success    *)
(* (or that a failed add skips it), and never credits back.                *)
(* Books: once idle, nothing is pending and bal + total = InitBal.         *)
(*                                                                         *)
(* Run cb_self_fails: the correct R, but on_added itself may fail (forced  *)
(* fault, standing for an out-of-gas callback).  C.add stays committed     *)
(* (AddStays holds) while the callback's own write (clearing pending) is   *)
(* reverted, so Books fails: the failed callback reverted only itself.     *)
(***************************************************************************)
EXTENDS NearAsync

CONSTANTS U, R, C, MaxTx, Ns, CResps, Wrong

VARIABLES bal, pending, total, addsOk, ntx
vars == <<platformVars, bal, pending, total, addsOk, ntx>>

Accts == {U, R, C}
TxIds == 1..MaxTx
InitBal == 3
PFloor == [a \in Accts |-> 0]
NoGasTable == [x \in {} |-> 0]
Arg(n) == [n |-> n]

Send == /\ ntx < MaxTx
        /\ \E n \in Ns : Submit(Rcpt(nid, ntx + 1, R, U, "send", Arg(n), 0, U, 0))
        /\ ntx' = ntx + 1
        /\ UNCHANGED <<bal, pending, total, addsOk>>

\* R's handlers return <<outcome, new bal, new pending>>.
HR(r) ==
    LET n == r.a.n IN
    IF r.m = "send"
    THEN IF bal < n THEN <<OErr(Outcome({}, {}, RVal(0), 0, 0), "insufficient"), bal, pending>>
         ELSE LET add == Rcpt(nid, r.tx, C, R, "add", Arg(n), 0, R, nid + 1)
                  cb  == Rcpt(nid + 1, r.tx, R, R, "on_added", Arg(n), 0, R, r.cb)
              IN <<Outcome({add}, {cb}, RProm, 0, 2), bal - n, pending + n>>
    ELSE \* on_added(n)
         IF r.res.ok \/ Wrong THEN <<Outcome({}, {}, RVal(0), 0, 0), bal, pending - n>>
         ELSE <<Outcome({}, {}, RVal(0), 0, 0), bal + n, pending - n>>

RunR(r) == LET p == HR(r) IN
           /\ Exec(r, p[1])
           /\ bal'     = IF Ok(r, p[1]) THEN p[2] ELSE bal
           /\ pending' = IF Ok(r, p[1]) THEN p[3] ELSE pending
           /\ UNCHANGED <<total, addsOk, ntx>>

RunC(r) == \E resp \in CResps :
             LET O == IF resp = "panic" THEN OErr(Outcome({}, {}, RVal(0), 0, 0), "add failed")
                      ELSE Outcome({}, {}, RVal(r.a.n), 0, 0) IN
             /\ Exec(r, O)
             /\ total'  = IF Ok(r, O) THEN total + r.a.n ELSE total
             /\ addsOk' = IF Ok(r, O) THEN addsOk + r.a.n ELSE addsOk   \* ghost, C's own commit
             /\ UNCHANGED <<bal, pending, ntx>>

Run == \E r \in Runnable :
         CASE IsBuiltin(r) -> ExecBuiltin(r) /\ UNCHANGED <<bal, pending, total, addsOk, ntx>>
           [] r.to = C     -> RunC(r)
           [] OTHER        -> RunR(r)

Init == /\ PlatformInit([a \in Accts |-> 0], TxIds)
        /\ bal = InitBal /\ pending = 0 /\ total = 0 /\ addsOk = 0 /\ ntx = 0

Next == Send \/ Run \/ (\E r \in Runnable : ForcedFail(r) /\ UNCHANGED <<bal, pending, total, addsOk, ntx>>)
Spec == Init /\ [][Next]_vars

Books == Idle => pending = 0 /\ bal + total = InitBal
\* A committed add is never undone by what happens to its callback.
AddStays == total = addsOk
=============================================================================
