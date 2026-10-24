------------------------------ MODULE Upgrade ------------------------------
(***************************************************************************)
(* Global contracts (NEP-591; docs/SEMANTICS.md A10).  Account y runs a    *)
(* global contract: by account (GAcct(o): whatever o last published) or    *)
(* by hash (GHash("v1"): that code, fixed).  y.go() locks y, calls q.ping  *)
(* and chains y's callback, which unlocks.  In v1 (and v3) the callback is *)
(* on_ping; v2 renamed it on_pong.  o publishes v2 by account while a      *)
(* call may be in flight.  A receipt runs the code its account has when it *)
(* runs (lib.rs:684-700), so the callback y.go made under v1 can run under *)
(* v2, where on_ping does not exist: it fails (MethodNotFound) and y stays *)
(* locked.                                                                 *)
(*                                                                         *)
(* upgrade_assumes_old_code: by account; Unlocked fails.                   *)
(* upgrade_by_hash: the same with y on GHash("v1"): o's redeploy does not  *)
(*   touch y, Unlocked holds.                                              *)
(* upgrade_two_deploys: o publishes v2, then v3 once v2's deploy has run;  *)
(*   both distributions can be in flight and arrive in either order.  The *)
(*   nonce check keeps the later one: y ends on v3 (LatestWins).          *)
(* upgrade_use_races_deploy: p publishes v1 by account for the first time; *)
(*   z uses GAcct(p) once p's deploy has committed.  The code is published *)
(*   only when the distribution receipt runs, so z's UseGlobalContract can *)
(*   fail with GlobalContractDoesNotExist (UseWorks fails; sim:            *)
(*   conformance/tests/global.rs, deploy_global).                          *)
(* upgrade_use_race_instant: the same with GlobalInstant = TRUE, which     *)
(*   publishes at the deploy's commit: UseWorks holds.  That is the        *)
(*   switch's under-approximation (N-global-instant), not a fix.           *)
(***************************************************************************)
EXTENDS NearAsync

CONSTANTS
    Acts,       \* the steps this run takes: "go", "upgrade", "upgrade2", "publish", "race"
    Mode        \* y's identifier: "acct" (GAcct(o)) or "hash" (GHash("v1"))

VARIABLES lock, done, usefail
\* lock: y's lock (go sets it, the callback clears it); done: the steps taken;
\* usefail: z's UseGlobalContract failed
mine == <<lock, done, usefail>>
vars == <<platformVars, mine>>

O == "o"  P == "p"  Y == "y"  Z == "z"  Q == "q"  A == "a"
Accts   == {O, P, Y, Z, Q, A}
Near0   == [a \in Accts |-> 10]
Total0  == 60
Floor0  == [a \in Accts |-> 0]
QCode   == {Q}
TxIds   == 1..4
NoTable == [x \in {} |-> 0]
Arg     == [x |-> 0]
Out0    == Outcome({}, {}, RVal(0), 0, 0)

\* Published at the start: v1 by o's account and by its hash; y runs one of them.
YId    == IF Mode = "hash" THEN GHash("v1") ELSE GAcct(O)
UGCode == (GAcct(O) :> "v1") @@ (GHash("v1") :> "v1")
UUses  == (Y :> YId)

\* The methods of each version, and the name of go's callback.
Methods(t) == IF t = "v2" THEN {"go", "on_pong"} ELSE {"go", "on_ping"}
CbName(t)  == IF t = "v2" THEN "on_pong" ELSE "on_ping"

\* y runs the code CodeOf(Y) gives when the receipt runs.  A method that
\* code lacks fails before any code runs (MethodNotFound): y's state stays.
RunY(r) ==
    LET t == CodeOf(Y) IN
    IF r.m \notin Methods(t) THEN FailP(r, FALSE) /\ UNCHANGED mine
    ELSE IF r.m = "go" THEN
        LET O1 == Outcome({Rcpt(nid, r.tx, Q, Y, "ping", Arg, 0, Y, nid + 1)},
                          {Rcpt(nid + 1, r.tx, Y, Y, CbName(t), Arg, 0, Y, 0)}, RVal(0), 0, 2) IN
        /\ Exec(r, O1)
        /\ lock' = IF Ok(r, O1) THEN TRUE ELSE lock
        /\ UNCHANGED <<done, usefail>>
    ELSE
        /\ Exec(r, Out0)
        /\ lock' = IF Ok(r, Out0) THEN FALSE ELSE lock
        /\ UNCHANGED <<done, usefail>>

\* An ACCOUNT receipt (a deploy or a use); records whether z's use failed.
RunAcct(r) ==
    /\ ExecAcct(r)
    /\ usefail' = (usefail \/ (r.to = Z /\ Ug(r) # NoGid /\ Z \notin DOMAIN guse'))
    /\ UNCHANGED <<lock, done>>

Run == \E r \in Runnable :
         IF IsBuiltin(r) THEN ExecBuiltin(r) /\ UNCHANGED mine
         ELSE IF IsAcctRcpt(r) THEN RunAcct(r)
         ELSE IF r.to = Y THEN RunY(r)
         ELSE Exec(r, Out0) /\ UNCHANGED mine           \* q.ping

\* Has a's ACCOUNT transaction run (its distribution may still be in flight)?
DeployRan(a) == ~\E r \in rq : IsAcctRcpt(r) /\ r.to = a
Step(s, guard, r) ==
    /\ s \in Acts /\ s \notin done /\ guard
    /\ Submit(r)
    /\ done' = done \cup {s}
    /\ UNCHANGED <<lock, usefail>>
Go       == Step("go", TRUE, Rcpt(nid, 1, Y, A, "go", Arg, 0, A, 0))
Upgrade  == Step("upgrade", TRUE, DeployGlobalRcpt(nid, 2, O, Arg, "v2", "acct", 0))
Upgrade2 == Step("upgrade2", "upgrade" \in done /\ DeployRan(O),
                 DeployGlobalRcpt(nid, 3, O, Arg, "v3", "acct", 0))
Publish  == Step("publish", TRUE, DeployGlobalRcpt(nid, 3, P, Arg, "v1", "acct", 0))
Race     == Step("race", "publish" \in done /\ DeployRan(P), UseGlobalRcpt(nid, 4, Z, Arg, GAcct(P), 0))

Init == /\ PlatformInit(Near0, TxIds)
        /\ lock = FALSE /\ done = {} /\ usefail = FALSE
Next == Go \/ Upgrade \/ Upgrade2 \/ Publish \/ Race \/ Run
Spec == Init /\ [][Next]_vars

\* Once all is settled, y is not locked: its callback ran.
Unlocked == Idle => ~lock
\* Once all is settled after both upgrades, y runs the later one.
LatestWins == (Idle /\ "upgrade2" \in done) => CodeOf(Y) = "v3"
\* z's UseGlobalContract, sent after p's deploy committed, never fails.
UseWorks == ~usefail
Sane == NearConserved(Total0) /\ NoOrphans
=============================================================================
