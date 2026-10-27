-------------------------------- MODULE Edge ---------------------------------
(***************************************************************************)
(* A gas budget at the edge of a Transfer fee (gas mode), under both       *)
(* NearFees.FeeRounding modes.                                             *)
(*                                                                         *)
(* U calls P.pay(); P calls R.forward() with deposit Amt and a static gas  *)
(* budget ForwardBurn + Attach (weight 0, so no leftover share); R.forward *)
(* sends a Transfer of Amt to a named account To.  At protocol 88 that     *)
(* Transfer costs R 446.37 Ggas of its gas at creation: the receipt base   *)
(* (108.0595) and the transfer (115.1231), each on the send and the exec   *)
(* side (core/parameters/src/snapshots/                                    *)
(* near_parameters__config_store__tests__88.json.snap:9-13, :52-56;        *)
(* charged by promise_batch_action_transfer,                               *)
(* runtime/near-vm-runner/src/logic/host.rs:3621-3661 @ bc4e9e8).  So in   *)
(* nearcore Attach = 446 runs out of gas and Attach >= 447 is enough.      *)
(*                                                                         *)
(* NearFees rounds each fee entry to a whole Ggas:                         *)
(*   "nearest": 2 x (108 + 115) = 446, so Attach = 446 fits: a FALSE PASS, *)
(*              the real flow runs out of gas (run edge_nearest_misses);   *)
(*   "up":      2 x (109 + 116) = 450, so 446 fails, as in nearcore (run   *)
(*              edge_up_catches), and so do 447..449, which nearcore       *)
(*              accepts: a false counterexample within the documented      *)
(*              margin of < 4 Ggas per single-action receipt (run          *)
(*              edge_up_tight_false_cex).                                  *)
(* Delivered: once idle, To holds the Transfer.                            *)
(***************************************************************************)
EXTENDS NearAsync

CONSTANTS U, P, R, To, Amt, Attach

VARIABLE sent
vars == <<platformVars, sent>>

Accts == {U, P, R, To}
PFloor == [a \in Accts |-> 0]
InitP == 5
ForwardBurn == 1000
PGasCall == "forward" :> [st |-> <<0>>, wt |-> <<0>>, fee |-> 300]
PGasBurn == ("pay" :> [base |-> 2000, per |-> 0]) @@ ("forward" :> [base |-> ForwardBurn, per |-> 0])

Start == /\ ~sent
         /\ Submit(WithGas(Rcpt(nid, 1, P, U, "pay", [n |-> 0], 0, U, 0), 300000))
         /\ sent' = TRUE

H(r) ==
    IF r.m = "pay"
    THEN Outcome({WithCall(Rcpt(nid, r.tx, R, P, "forward", [n |-> 0], Amt, P, 0),
                           <<ForwardBurn + Attach>>, <<0>>)}, {}, RVal(0), Amt, 1)
    ELSE Outcome({Rcpt(nid, r.tx, To, R, XFER, [n |-> 0], r.dep, R, 0)}, {}, RVal(0), r.dep, 1)

Run == \E r \in Runnable :
         /\ IF IsBuiltin(r) THEN ExecBuiltin(r) ELSE Exec(r, H(r))
         /\ UNCHANGED sent

Init == /\ PlatformInit([a \in Accts |-> IF a = P THEN InitP ELSE 0], {1})
        /\ sent = FALSE

Next == Start \/ Run
Spec == Init /\ [][Next]_vars

Delivered == (sent /\ Idle) => near[To] = Amt
\* Library sanity: NEAR conserved, gas bounded by the prepaid gas, no orphans
\* (nothing here waits on a result; the conjunct keeps that true).
Sane == NearConserved(InitP) /\ GasBounded(LAMBDA t : 300000) /\ NoOrphans
=============================================================================
