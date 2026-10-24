------------------------------ MODULE Forwarder ------------------------------
(***************************************************************************)
(* A Transfer to an eth-implicit receiver ("0x" + 40 hex) costs its        *)
(* creator transfer + create_account fees, chosen by the receiver id's     *)
(* pattern even when the account already exists                            *)
(* (core/parameters/src/cost.rs:774-848; charged at creation by            *)
(* promise_batch_action_transfer,                                          *)
(* runtime/near-vm-runner/src/logic/host.rs:3621-3661 @ b7b4737).          *)
(*                                                                         *)
(* User U calls P.pay(); P calls R.forward() with deposit Amt and an exact *)
(* gas budget (static gas, weight 0); R.forward creates a Transfer of Amt  *)
(* to To.  R needs Burn(forward) + the Transfer's fee (NearFees, at        *)
(* FeeProtocol).  Toy ids cannot match the real pattern, so To's type is   *)
(* stated with AcctKind <- PKinds.  To already exists, except in run       *)
(* eth_fee_creates, where the Transfer creates it (Created holds).         *)
(*                                                                         *)
(* Correct P: budgets Burn(forward) + the receiver-type dependent fee,     *)
(* pinned here as literals at protocol 88 (Transfer send + exec plus the   *)
(* receipt base fee; eth-implicit adds create_account only,                *)
(* core/parameters/src/cost.rs:794-796, :832-834).  FeesPinned checks the  *)
(* library's fee table against them.  The literals depend on               *)
(* NearFees.FeeRounding, which rounds each fee entry on its own:           *)
(*   exact Ggas: receipt 108.0595 and transfer 115.1231, each charged      *)
(*   on the send and on the exec side; create_account 500 send, 7200 exec  *)
(*   "up" (default): 109 + 116 per side, so named 2 x 225 = 450, and       *)
(*                   eth-implicit 450 + 500 + 7200 = 8150                  *)
(*   "nearest":      108 + 115 per side, so named 2 x 223 = 446, and       *)
(*                   eth-implicit 446 + 500 + 7200 = 8146                  *)
(* against the exact 446.37 and 8146.37 (run eth_fee_ok_nearest).          *)
(* Wrong P (Wrong = TRUE): budgets the named-account fee.  For an          *)
(* eth-implicit To, R.forward runs out of gas, the deposit returns to P    *)
(* and To is never paid: Delivered fails (run eth_fee_named_budget).  The  *)
(* same wrong budget is fine for a named To (run eth_fee_named_rcv).       *)
(***************************************************************************)
EXTENDS NearAsync

CONSTANTS U, P, R, To, Amt, Wrong

VARIABLE sent
vars == <<platformVars, sent>>

Accts == {U, P, R, To, "0xe", "bob"}
PKinds == AcctKinds({"0xe"}, {})
PFloor == [a \in Accts |-> 0]
InitP == 5
ForwardBurn == 1000
PGasCall == "forward" :> [st |-> <<0>>, wt |-> <<0>>, fee |-> 300]
PGasBurn == ("pay" :> [base |-> 2000, per |-> 0]) @@ ("forward" :> [base |-> ForwardBurn, per |-> 0])

\* Ggas at protocol 88, by FeeRounding (see the header): Transfer to an
\* eth-implicit account, and to a named one.
Up == NearFeeTable!FeeRounding = "up"
EthFee   == IF Up THEN 8150 ELSE 8146
NamedFee == IF Up THEN 450 ELSE 446
Budget == ForwardBurn + (IF Wrong \/ KindOf(To) # "eth_implicit" THEN NamedFee ELSE EthFee)

Start == /\ ~sent
         /\ Submit(WithGas(Rcpt(nid, 1, P, U, "pay", [n |-> 0], 0, U, 0), 300000))
         /\ sent' = TRUE

H(r) ==
    IF r.m = "pay"
    THEN Outcome({WithCall(Rcpt(nid, r.tx, R, P, "forward", [n |-> 0], Amt, P, 0), <<Budget>>, <<0>>)},
                 {}, RVal(0), Amt, 1)
    ELSE Outcome({Rcpt(nid, r.tx, To, R, XFER, [n |-> 0], r.dep, R, 0)}, {}, RVal(0), r.dep, 1)

Run == \E r \in Runnable :
         /\ IF IsBuiltin(r) THEN ExecBuiltin(r) ELSE Exec(r, H(r))
         /\ UNCHANGED sent

Init == /\ PlatformInit([a \in Accts |-> IF a = P THEN InitP ELSE 0], {1})
        /\ sent = FALSE

Next == Start \/ Run
Spec == Init /\ [][Next]_vars

Delivered == (sent /\ Idle) => near[To] = Amt
Sane == NearConserved(InitP) /\ GasBounded(LAMBDA t : 300000)
Created == (sent /\ Idle /\ To \notin Exists) => To \in created
FeesPinned == /\ XferFee(R, "0xe") = EthFee
              /\ XferFee(R, "bob") = NamedFee
=============================================================================
