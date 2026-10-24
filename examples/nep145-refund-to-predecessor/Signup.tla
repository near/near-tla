------------------------------ MODULE Signup --------------------------------
(***************************************************************************)
(* NEP-145 storage_deposit refunds the excess to the PREDECESSOR, not to   *)
(* account_id.                                                              *)
(*                                                                         *)
(* Toy contract R registers user U on token FT.  U calls R.register() with *)
(* deposit D = min + Extra.  R calls                                       *)
(*   FT.storage_deposit(account_id = U) with D .then(R.on_registered(D)).   *)
(* FT keeps min and refunds D - min to its predecessor, which is R.  If    *)
(* storage_deposit fails, the platform refunds all of D to R.              *)
(*                                                                         *)
(* Correct R: on_registered forwards to U what came back to R: D - min on  *)
(* success, D on failure.  UserMadeWhole: once idle, U has paid exactly    *)
(* min if registered, else nothing.                                        *)
(* Wrong R (Wrong = TRUE): assumes FT refunded the excess to account_id    *)
(* (U) directly, so forwards nothing on success; U is short by Extra and   *)
(* R keeps it.                                                             *)
(*                                                                         *)
(* R starts with a buffer InitR so its forward never depends on whether   *)
(* FT's refund Transfer arrives before or after the callback.              *)
(***************************************************************************)
EXTENDS Tokens

CONSTANTS U, R, FT, Extra, InitU, InitR, Wrong

VARIABLE sent
vars == <<platformVars, tk, sent>>

Accts == {U, R, FT}
Min == 1
PFloor      == [a \in Accts |-> 0]
PTokHolders == [a \in {FT} |-> {U}]
PTokMin     == [a \in {FT} |-> Min]
PTokDev     == [a \in {FT} |-> {}]
PTokReserve == [a \in {FT} |-> 0]
NoGasTable  == [x \in {} |-> 0]

Register ==
    /\ ~sent
    /\ Submit(Rcpt(nid, 1, R, U, "register", TA0, Min + Extra, U, 0))
    /\ sent' = TRUE
    /\ UNCHANGED tk

H(r) ==
    IF r.m = "register"
    THEN LET d  == r.dep
             sd == Rcpt(nid, r.tx, FT, R, "storage_deposit", SdArgs(U), d, R, nid + 1)
             cb == Rcpt(nid + 1, r.tx, R, R, "on_registered", CxArgs(d), 0, R, r.cb)
         IN Outcome({sd}, {cb}, RProm, d, 2)
    ELSE \* on_registered(d)
         LET d    == r.a.cx[1]
             back == IF ~r.res.ok THEN d                    \* failed: the platform refunded all of d to R
                     ELSE IF Wrong THEN 0                   \* WRONG: "FT refunded U directly"
                     ELSE d - Min                           \* FT refunded the excess to R
             fwd  == Rcpt(nid, r.tx, U, R, XFER, TA0, back, R, 0)
         IN IF back = 0 THEN Outcome({}, {}, RVal(0), 0, 0)
            ELSE Outcome({fwd}, {}, RVal(0), back, 1)

RunR(r) == Exec(r, H(r)) /\ UNCHANGED <<tk, sent>>
RunTok(r) == \E ch \in TokChoices(r) : LET O == TokHandle(r, ch) IN TokStep(r, O) /\ UNCHANGED sent

Run == \E r \in Runnable :
         IF IsBuiltin(r) THEN ExecBuiltin(r) /\ UNCHANGED <<tk, sent>>
         ELSE IF IsTokRcpt(r) THEN RunTok(r)
         ELSE RunR(r)

Init == /\ PlatformInit([a \in Accts |-> CASE a = U -> InitU [] a = R -> InitR [] OTHER -> 0], {1})
        /\ tk = [a \in {FT} |-> Ledger([h \in {U} |-> 0], {})]
        /\ sent = FALSE

Next == Register \/ Run \/ (\E r \in Runnable : ForcedFail(r) /\ UNCHANGED <<tk, sent>>)
Spec == Init /\ [][Next]_vars

UserMadeWhole == Idle => near[U] = InitU - (IF U \in tk[FT].reg THEN Min ELSE 0)
RKeepsNothing == Idle => near[R] = InitR
Sane == NearConserved(InitU + InitR) /\ TokSupplyOK /\ TokTypeOK
=============================================================================
