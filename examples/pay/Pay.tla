-------------------------------- MODULE Pay ---------------------------------
(***************************************************************************)
(* Minimal contract model on the token modules (see docs/USAGE.md).       *)
(*                                                                         *)
(* Contract C keeps an internal balance ib for user U, backed by C's       *)
(* balance on the FT contract.  U calls C.pay(amt): C debits ib and calls  *)
(*   FT.ft_transfer_call(RX, amt, "").then(C.on_paid(amt))                  *)
(* on_paid reads the resolver's value (the amount RX used) and credits the *)
(* unused part back to ib.  RX is an arbitrary receiver contract.          *)
(***************************************************************************)
EXTENDS Tokens

CONSTANTS
    U, C, FT, RX,     \* account names
    MaxTx,            \* number of pay transactions
    Amts,             \* amounts U may pay
    InitC, InitRx,    \* C's / RX's initial FT balance (ib starts at InitC)
    RxResps,          \* RX.ft_on_transfer behaviours, subset of RecvResps
    RxReg,            \* is RX registered (NEP-145) on FT
    Dev,              \* FT's deviations, subset of Deviations
    GasMenu           \* prepaid gas U may attach to pay (gas mode)

VARIABLES ib, ntx, gT
vars == <<platformVars, tk, ib, ntx, gT>>

Accts == {U, C, FT, RX}
TxIds == 1..MaxTx

(* ---- values for the platform / token constants (named in runs.toml) --- *)
PFloor      == [a \in Accts |-> 0]
PTokHolders == [a \in {FT} |-> {U, C, RX}]
PTokMin     == [a \in {FT} |-> 1]
PTokDev     == [a \in {FT} |-> Dev]
PTokReserve == [a \in {FT} |-> 30000]          \* used only with TokFtGasShape "reserve" (3.x)
NoGasTable  == [x \in {} |-> 0]
PayMenu     == {t * 100 : t \in 390..420} \cup {300000}   \* 39.0-42.0 Tgas in 0.1 steps, and 300

\* The gas calibration table (Ggas).  ILLUSTRATIVE numbers, not measured:
\* a real model fills these from a calibration sweep (docs/CONFORMANCE.md).
GC(st, wt, fee) == [st |-> st, wt |-> wt, fee |-> fee]
\* GasCall: static gas / weight per function call, and the exec fee of the receipt,
\* for a receipt calling "acct.method" (looked up first) or "method".
PGasCall ==
       ("ft.ft_transfer_call"    :> GC(<<35000>>, <<1>>, 900))   \* C's call: 35 Tgas static, weight 1
    @@ ("on_paid"                :> GC(<<1000>>, <<1>>, 900))    \* C's callback: 1 Tgas, weight 1
    @@ ("ft.ft_resolve_transfer" :> GC(<<5000>>, <<0>>, 900))    \* the token's resolver
    @@ ("ft_on_transfer"         :> GC(<<>>, <<>>, 900))         \* static/weight set by the token
\* GasBurn: what each receipt burns of its own gas, per burn key.
\* Token handlers use "<acct>.<method>"; contract handlers r.m unless they set gk.
PGasBurn ==
       ("pay"                    :> [base |-> 2000, per |-> 0])
    @@ ("on_paid"                :> [base |-> 1500, per |-> 0])
    @@ ("ft.ft_transfer_call"    :> [base |-> 1600, per |-> 0])
    @@ ("ft.ft_resolve_transfer" :> [base |-> 800,  per |-> 0])
    @@ ("rx.ft_on_transfer"      :> [base |-> 200,  per |-> 0])

\* The same with the token side from CalibStd (measured near-contract-standards
\* 5.29.1 FT): C's own entries stay illustrative, the token's burns and the
\* resolver's static / weight / fee come from StdFtGasBurn / StdFtGasCall.
Std == INSTANCE CalibStd
PStdGasCall ==
       ("ft.ft_transfer_call"    :> GC(<<35000>>, <<1>>, 900))
    @@ ("on_paid"                :> GC(<<1000>>, <<1>>, 900))
    @@ ("ft_on_transfer"         :> GC(<<>>, <<>>, 900))
    @@ Std!StdFtGasCall(FT)
PStdGasBurn ==
       ("pay"                    :> [base |-> 2000, per |-> 0])
    @@ ("on_paid"                :> [base |-> 1500, per |-> 0])
    @@ ("rx.ft_on_transfer"      :> [base |-> 200,  per |-> 0])
    @@ Std!StdFtGasBurn(FT)

(* ---- contract C ------------------------------------------------------- *)
\* A handler returns <<outcome, new ib>>.
H_pay(r) ==
    LET amt == r.a.amt
        ftc == Rcpt(nid, r.tx, FT, C, "ft_transfer_call", FtArgs(RX, amt, ""), TokYocto, C, nid + 1)
        cb  == Rcpt(nid + 1, r.tx, C, C, "on_paid", [TA0 EXCEPT !.amt = amt], 0, C, r.cb)
    IN IF ib < amt THEN <<OErr(Outcome({}, {}, RVal(0), 0, 0), "insufficient"), ib>>
       ELSE <<Outcome({ftc}, {cb}, RProm, TokYocto, 2), ib - amt>>

\* on_paid: Successful(U128 used) -> credit amt - used; Failed -> nothing was
\* moved (ft_transfer_call panicked), credit amt; other bytes -> treat as used.
H_on_paid(r) ==
    LET amt  == r.a.amt
        used == IF IsNum(r.res) THEN TMin(r.res.v, amt)
                ELSE IF ~r.res.ok THEN 0 ELSE amt
    IN <<Outcome({}, {}, RVal(used), 0, 0), ib + (amt - used)>>

RunC(r) ==
    LET p == IF r.m = "pay" THEN H_pay(r) ELSE H_on_paid(r)
        O == p[1] IN
    /\ Exec(r, O)
    /\ ib' = IF Ok(r, O) THEN p[2] ELSE ib
    /\ gT' = IF Ok(r, O) /\ r.m = "on_paid"
             THEN [gT EXCEPT ![r.tx].refund = r.a.amt - O.ret.v, ![r.tx].done = TRUE]
             ELSE gT
    /\ UNCHANGED <<tk, ntx>>

(* ---- receiver RX (environment) ----------------------------------------- *)
RunRx(r) ==
    \E resp \in RxResps :
        LET O == OKey(RecvOutcome(r.a.amt, resp), "rx.ft_on_transfer") IN
        /\ Exec(r, O)
        \* what RX asked to get back (Failed / unparsable = everything, per NEP-141)
        /\ gT' = [gT EXCEPT ![r.tx].req = CASE resp \in {"keep"}  -> 0
                                             [] resp = "over"     -> r.a.amt + 1
                                             [] OTHER             -> r.a.amt]
        /\ UNCHANGED <<tk, ib, ntx>>

(* ---- token receipts: the module does everything ------------------------ *)
RunTok(r) ==
    \E ch \in TokChoices(r) :
        LET O == TokHandle(r, ch) IN TokStep(r, O) /\ UNCHANGED <<ib, ntx, gT>>

Run == \E r \in Runnable :
         IF r.m \in {XFER, REFND} THEN (ExecTransfer(r) \/ ExecTransferFail(r)) /\ UNCHANGED <<tk, ib, ntx, gT>>
         ELSE IF IsTokRcpt(r) THEN RunTok(r)
         ELSE IF r.to = RX THEN RunRx(r)
         ELSE RunC(r)

Pay ==
    /\ ntx < MaxTx
    /\ \E amt \in Amts, p \in (IF GasMode = "gas" THEN GasMenu ELSE {0}) :
         /\ Submit(WithGas(Rcpt(nid, ntx + 1, C, U, "pay", [TA0 EXCEPT !.amt = amt], 0, U, 0), p))
         /\ ntx' = ntx + 1
         /\ gT' = [gT EXCEPT ![ntx + 1] = [amt |-> amt, req |-> amt, refund |-> 0, done |-> FALSE, gas |-> p]]
         /\ UNCHANGED <<tk, ib>>

Init ==
    /\ PlatformInit([a \in Accts |-> 0], TxIds)
    /\ tk = [a \in {FT} |-> Ledger([h \in {U, C, RX} |-> CASE h = C -> InitC [] h = RX -> InitRx [] OTHER -> 0],
                                   {U, C} \cup (IF RxReg THEN {RX} ELSE {}))]
    /\ ib = InitC /\ ntx = 0
    /\ gT = [t \in TxIds |-> [amt |-> 0, req |-> 0, refund |-> 0, done |-> FALSE, gas |-> 0]]

Next == Run \/ Pay \/ (\E r \in Runnable : ForcedFail(r) /\ UNCHANGED <<tk, ib, ntx, gT>>)
Spec == Init /\ [][Next]_vars

(* ---- invariants --------------------------------------------------------- *)
\* C's books match what it holds on FT once nothing is in flight.
Books == Idle => ib = tk[FT].bal[C]
\* A settled pay was refunded what RX asked back (capped at amt; NEP-141).
Honored == \A t \in 1..ntx : (TxSettled(t) /\ gT[t].done) => gT[t].refund = TMin(gT[t].req, gT[t].amt)
Sane == NearConserved(0) /\ TokSupplyOK /\ TokTypeOK /\ GasBounded(LAMBDA t : gT[t].gas)
\* print-only: every settled tx whose books broke, with its prepaid gas (TLC keeps going)
WinBooks == (Idle /\ ib # tk[FT].bal[C]) => PrintT(<<"WIN", "Books", gT[ntx].gas, oog>>)
=============================================================================
