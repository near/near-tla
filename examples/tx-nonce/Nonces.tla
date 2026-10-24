------------------------------ MODULE Nonces ------------------------------
(***************************************************************************)
(* Transaction nonces (docs/SEMANTICS.md, K5).  The user U pays            *)
(* merchant M by signed transactions: M.pay(n) with a deposit of 1, signed *)
(* with U's key k0 and the wallet's next nonce n (Sign).  A signed         *)
(* transaction is public: the network delivers any of them, any number of  *)
(* times, in any order (Deliver), so it replays them and lets a later one  *)
(* overtake an earlier one.  nearcore refuses a delivery whose nonce is    *)
(* not above the key's (TxErr = "InvalidNonce"); the model records a       *)
(* payment refused before it ever landed as lost.                          *)
(*                                                                         *)
(* Parallel = FALSE: the wallet signs the next payment only once the       *)
(* previous one has landed.  Parallel = TRUE: it signs them all at once;   *)
(* when a later one lands first, the earlier one is refused for good.      *)
(* NoNonce = TRUE: deliveries go through SubmitSigned, which checks no     *)
(* nonce (N-tx-validity); every replay pays again.                         *)
(*                                                                         *)
(* PaidOnce:      M is paid at most once for each signed payment.          *)
(* NoLostPayment: no signed payment is refused before it has landed.       *)
(* Sane:          NEAR is conserved.                                       *)
(***************************************************************************)
EXTENDS NearKeys

CONSTANTS U, M, MaxSign, MaxTx, Parallel, NoNonce

VARIABLES signed, nn, landed, lost, credits, ntx
mine == <<signed, nn, landed, lost, credits, ntx>>
vars == <<platformVars, keyVars, mine>>

Accts == {U, M}
TxIds == 1..MaxTx
PFloor == [a \in Accts |-> 0]
NoGasTable == [x \in {} |-> 0]

\* Payment n, as U signs it (id and tx are set at each delivery).
Pay(n) == SignedTx(U, "k0", n, Rcpt(0, 0, M, U, "pay", n, 1, U, 0))
\* The delivery of st as transaction t, first receipt id i.
Sent(st, i, t) == [st EXCEPT !.r = [@ EXCEPT !.id = i, !.tx = t]]

Sign == /\ nn < MaxSign
        /\ IF Parallel THEN TRUE ELSE \A st \in signed : st.n \in landed
        /\ signed' = signed \cup {Pay(nn + 1)}
        /\ nn' = nn + 1
        /\ UNCHANGED <<platformVars, keyVars, landed, lost, credits, ntx>>

Deliver ==
    /\ ntx < MaxTx
    /\ \E st \in signed :
         LET s == Sent(st, nid, ntx + 1) IN
         IF NoNonce
         THEN /\ SubmitSigned(s.r, U, "k0")
              /\ landed' = landed \cup {st.n} /\ ntx' = ntx + 1
              /\ UNCHANGED <<signed, nn, lost, credits>>
         ELSE IF TxErr(s) = ""
         THEN /\ SubmitTx(s)
              /\ landed' = landed \cup {st.n} /\ ntx' = ntx + 1
              /\ UNCHANGED <<signed, nn, lost, credits>>
         ELSE /\ TxErr(s) = "InvalidNonce" /\ st.n \notin landed \cup lost
              /\ lost' = lost \cup {st.n}
              /\ UNCHANGED <<platformVars, keyVars, signed, nn, landed, credits, ntx>>

RunM(r) ==
    LET O == Outcome({}, {}, RVal(0), 0, 0) IN
    /\ Exec(r, O)
    /\ credits' = IF Ok(r, O) THEN [credits EXCEPT ![r.a] = @ + 1] ELSE credits
    /\ UNCHANGED <<keyVars, signed, nn, landed, lost, ntx>>

Run == \E r \in Runnable : IF IsBuiltin(r) THEN ExecBuiltin(r) /\ UNCHANGED <<keyVars, mine>> ELSE RunM(r)

Init == /\ PlatformInit([a \in Accts |-> IF a = U THEN 10 ELSE 0], TxIds)
        /\ KeysInit([a \in {U} |-> ("k0" :> FullPerm)])
        /\ signed = {} /\ nn = 0 /\ landed = {} /\ lost = {}
        /\ credits = [n \in 1..MaxSign |-> 0] /\ ntx = 0

Next == Sign \/ Deliver \/ Run
Spec == Init /\ [][Next]_vars

\* A delivered payment that nearcore refuses as a replay.
ReplayRefused == \E st \in signed : st.n \in landed /\ TxErr(Sent(st, 0, 0)) = "InvalidNonce"

PaidOnce      == \A n \in 1..MaxSign : credits[n] <= 1
NoLostPayment == lost = {}
Sane          == NearConserved(10) /\ NoOrphans
=============================================================================
