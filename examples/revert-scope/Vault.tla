-------------------------------- MODULE Vault --------------------------------
(***************************************************************************)
(* Revert scope: a failed receipt reverts only its own state; earlier      *)
(* committed receipts of the same transaction stay committed; the failed   *)
(* receipt's deposit is refunded to its predecessor.                       *)
(*                                                                         *)
(* User U calls V.stash() with deposit d.  V commits held := held + d and  *)
(* forwards the d NEAR with E.hold() .then(V.on_hold(d)).  Escrow E either *)
(* accepts (esc := esc + d, keeps the NEAR) or panics.  If E panics, E's   *)
(* own write is reverted and d is refunded to V, while V's stash (an       *)
(* earlier receipt of the same transaction) stays committed.               *)
(*                                                                         *)
(* Correct V: on_hold sees Failed and undoes its own bookkeeping           *)
(* (held := held - d); the NEAR is back on V.                              *)
(* Wrong V (Wrong = TRUE): treats a failure as if the whole transaction    *)
(* had rolled back ("my stash was undone too") and does nothing, so V      *)
(* believes E holds d that E never kept.                                   *)
(*                                                                         *)
(* Books: once idle, V's belief matches E's state and every NEAR is where  *)
(* the books say.  EscrowBacked: E's state and E's NEAR always agree (a    *)
(* panicking hold reverted both).                                          *)
(***************************************************************************)
EXTENDS NearAsync

CONSTANTS U, V, E, MaxTx, Deps, EResps, Wrong

VARIABLES held, esc, stashed, ntx
vars == <<platformVars, held, esc, stashed, ntx>>

Accts == {U, V, E}
TxIds == 1..MaxTx
InitU == 10
PFloor == [a \in Accts |-> 0]
NoGasTable == [x \in {} |-> 0]
Arg(d) == [d |-> d]

Stash == /\ ntx < MaxTx
         /\ \E d \in Deps : Submit(Rcpt(nid, ntx + 1, V, U, "stash", Arg(d), d, U, 0))
         /\ ntx' = ntx + 1
         /\ UNCHANGED <<held, esc, stashed>>

\* V's handlers return <<outcome, new held, new stashed>>.
HV(r) ==
    IF r.m = "stash"
    THEN LET d  == r.dep
             h  == Rcpt(nid, r.tx, E, V, "hold", Arg(d), d, V, nid + 1)
             cb == Rcpt(nid + 1, r.tx, V, V, "on_hold", Arg(d), 0, V, r.cb)
         IN <<Outcome({h}, {cb}, RProm, d, 2), held + r.dep, stashed + r.dep>>
    ELSE \* on_hold(d)
         LET d == r.a.d IN
         IF r.res.ok \/ Wrong THEN <<Outcome({}, {}, RVal(0), 0, 0), held, stashed>>
         ELSE <<Outcome({}, {}, RVal(0), 0, 0), held - d, stashed>>

RunV(r) == LET p == HV(r) IN
           /\ Exec(r, p[1])
           /\ held'    = IF Ok(r, p[1]) THEN p[2] ELSE held
           /\ stashed' = IF Ok(r, p[1]) THEN p[3] ELSE stashed
           /\ UNCHANGED <<esc, ntx>>

\* E.hold: accept (keep the NEAR, record it) or panic.
RunE(r) == \E resp \in EResps :
             LET O == IF resp = "panic" THEN OErr(Outcome({}, {}, RVal(0), 0, 0), "rejected")
                      ELSE Outcome({}, {}, RVal(0), 0, 0) IN
             /\ Exec(r, O)
             /\ esc' = IF Ok(r, O) THEN esc + r.dep ELSE esc
             /\ UNCHANGED <<held, stashed, ntx>>

Run == \E r \in Runnable :
         CASE IsBuiltin(r) -> ExecBuiltin(r) /\ UNCHANGED <<held, esc, stashed, ntx>>
           [] r.to = E     -> RunE(r)
           [] OTHER        -> RunV(r)

Init == /\ PlatformInit([a \in Accts |-> IF a = U THEN InitU ELSE 0], TxIds)
        /\ held = 0 /\ esc = 0 /\ stashed = 0 /\ ntx = 0

Next == Stash \/ Run
Spec == Init /\ [][Next]_vars

Books == Idle => /\ held = esc
                 /\ near[E] = esc
                 /\ near[V] = stashed - held
                 /\ near[U] = InitU - stashed
EscrowBacked == near[E] = esc
Sane == NearConserved(InitU)
=============================================================================
