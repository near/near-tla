------------------------------ MODULE Splitter ------------------------------
(***************************************************************************)
(* Unused-gas split (runtime/runtime/src/receipt_manager.rs:679-721 @      *)
(* b7b4737).  The gas a receipt attached but did not need, U, goes to the  *)
(* function calls it created with weight w > 0, in creation order: each   *)
(* gets floor(U * w / W), and the last weighted call also gets the         *)
(* remainder.  W = 0 distributes nothing.                                  *)
(*                                                                         *)
(* S.split() creates, in this order:                                       *)
(*   W.work_a()                       static 1 Tgas, weight Wts[1]          *)
(*   W.work_b() .then(S.on_done())    static 1 Tgas, weight Wts[2]          *)
(*   S.on_done()                      static 1 Tgas, weight Wts[3]          *)
(* Illustrative table (Ggas, not measured): split burns 2000, each child   *)
(* costs its creator a 300 exec fee, work_a/work_b burn 500, on_done burns *)
(* 2500, so on_done needs at least 1500 of leftover gas on top of its      *)
(* static.  Prepaid 10001: Need(split) = 2000 + 3 * (300 + 1000) = 5900,   *)
(* U = 4101.                                                               *)
(*   Wts = <<1, 1, 2>>  W = 4: work_a 1000+1025, work_b 1000+1025,         *)
(*                      on_done 1000+2051 (floor 2050 + remainder 1): ok   *)
(*   Wts = <<1, 1, 0>>  W = 2: work_a 1000+2050, work_b 1000+2051 (last    *)
(*                      weighted), on_done 1000: out of gas                *)
(*   Wts = <<0, 0, 0>>  W = 0: every child gets exactly its static         *)
(*                                                                         *)
(* Correct S: weight on the callback that needs leftover gas (run          *)
(* weight_split_ok).  Wrong S: weight 0 on that callback (run              *)
(* weight_split_cb_zero): CallbackDone fails.  Run weight_split_w0 checks  *)
(* NothingDistributed with all weights 0.  SplitExact checks every child's *)
(* gas against the formula above, computed independently of the platform. *)
(***************************************************************************)
EXTENDS NearAsync

CONSTANTS U, S, W, Wts, Prepaid

VARIABLES got, done, sent
vars == <<platformVars, got, done, sent>>

Accts == {U, S, W}
PFloor == [a \in Accts |-> 0]
St == 1000
Fee == 300
Calls == <<"work_a", "work_b", "on_done">>
GC(fee) == [st |-> <<St>>, wt |-> <<0>>, fee |-> fee]
PGasCall == ("work_a" :> GC(Fee)) @@ ("work_b" :> GC(Fee)) @@ ("on_done" :> GC(Fee))
B(x) == [base |-> x, per |-> 0]
PGasBurn == ("split" :> B(2000)) @@ ("work_a" :> B(500)) @@ ("work_b" :> B(500)) @@ ("on_done" :> B(2500))

\* Expected split, written out independently of the platform's Share.
Left == Prepaid - (2000 + 3 * (Fee + St))
WSumT == Wts[1] + Wts[2] + Wts[3]
LastW == CHOOSE i \in 1..3 : Wts[i] > 0 /\ \A j \in 1..3 : Wts[j] > 0 => j <= i
FloorShare(i) == (Left * Wts[i]) \div WSumT
Expected(i) ==
    St + (IF WSumT = 0 \/ Wts[i] = 0 THEN 0
          ELSE IF i = LastW
               THEN Left - (IF i # 1 /\ Wts[1] > 0 THEN FloorShare(1) ELSE 0)
                         - (IF i # 2 /\ Wts[2] > 0 THEN FloorShare(2) ELSE 0)
                         - (IF i # 3 /\ Wts[3] > 0 THEN FloorShare(3) ELSE 0)
               ELSE FloorShare(i))
Idx(m) == CHOOSE i \in 1..3 : Calls[i] = m

Start == /\ ~sent
         /\ Submit(WithGas(Rcpt(nid, 1, S, U, "split", [n |-> 0], 0, U, 0), Prepaid))
         /\ sent' = TRUE
         /\ UNCHANGED <<got, done>>

HSplit(r) ==
    LET a  == WithCall(Rcpt(nid, r.tx, W, S, "work_a", [n |-> 0], 0, S, 0), <<St>>, <<Wts[1]>>)
        b  == WithCall(Rcpt(nid + 1, r.tx, W, S, "work_b", [n |-> 0], 0, S, nid + 2), <<St>>, <<Wts[2]>>)
        cb == WithCall(Rcpt(nid + 2, r.tx, S, S, "on_done", [n |-> 0], 0, S, 0), <<St>>, <<Wts[3]>>)
    IN Outcome({a, b}, {cb}, RVal(0), 0, 3)

Step(r) ==
    LET O == IF r.m = "split" THEN HSplit(r) ELSE Outcome({}, {}, RVal(0), 0, 0) IN
    /\ Exec(r, O)
    /\ got'  = IF r.m = "split" THEN got ELSE [got EXCEPT ![r.m] = GasOf(r)]
    /\ done' = (done \/ (r.m = "on_done" /\ Ok(r, O)))
    /\ UNCHANGED sent

Run == \E r \in Runnable :
         IF IsBuiltin(r) THEN ExecBuiltin(r) /\ UNCHANGED <<got, done, sent>> ELSE Step(r)

Init == /\ PlatformInit([a \in Accts |-> 0], {1})
        /\ got = [m \in {"work_a", "work_b", "on_done"} |-> -1]
        /\ done = FALSE /\ sent = FALSE

Next == Start \/ Run
Spec == Init /\ [][Next]_vars

SplitExact == \A m \in DOMAIN got : got[m] # -1 => got[m] = Expected(Idx(m))
NothingDistributed == \A m \in DOMAIN got : got[m] # -1 => got[m] = St
CallbackDone == (sent /\ Idle) => done
=============================================================================
