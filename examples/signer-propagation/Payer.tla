-------------------------------- MODULE Payer --------------------------------
(***************************************************************************)
(* The transaction signer is inherited by every receipt of the            *)
(* transaction: a cross-contract child and a callback see the original     *)
(* signer, while the predecessor is the immediate caller.                  *)
(*                                                                         *)
(* Users sign txs to Payer P: P.pay() calls Escrow E.claim()               *)
(* .then(P.on_claim()).  E credits one unit to the user who started the    *)
(* transaction.  In E.claim the predecessor is P and the signer is the     *)
(* user; in P.on_claim the predecessor is P itself and the signer is still *)
(* the user.                                                               *)
(*                                                                         *)
(* Correct E: credits Signer(r).  P.on_claim records Signer(r) as the      *)
(* claimant of the transaction.                                            *)
(* Wrong E (Wrong = TRUE): credits the predecessor r.fr, which is P, so    *)
(* users are never credited.                                               *)
(*                                                                         *)
(* Credited: once idle, each user's credit = the claims it signed.         *)
(* CallbackSigner: every callback saw the signer of its transaction.       *)
(***************************************************************************)
EXTENDS NearAsync

CONSTANTS Users, P, E, MaxTx, Wrong

VARIABLES credit, signedBy, sawSigner, ntx
vars == <<platformVars, credit, signedBy, sawSigner, ntx>>

Accts == Users \cup {P, E}
TxIds == 1..MaxTx
PFloor == [a \in Accts |-> 0]
NoGasTable == [x \in {} |-> 0]
A0 == [n |-> 0]

Pay == /\ ntx < MaxTx
       /\ \E u \in Users :
            /\ Submit(Rcpt(nid, ntx + 1, P, u, "pay", A0, 0, u, 0))
            /\ signedBy' = [signedBy EXCEPT ![ntx + 1] = u]
       /\ ntx' = ntx + 1
       /\ UNCHANGED <<credit, sawSigner>>

RunP(r) ==
    IF r.m = "pay"
    THEN LET cl == Rcpt(nid, r.tx, E, P, "claim", A0, 0, P, nid + 1)
             cb == Rcpt(nid + 1, r.tx, P, P, "on_claim", A0, 0, P, r.cb)
         IN Exec(r, Outcome({cl}, {cb}, RProm, 0, 2)) /\ UNCHANGED <<credit, signedBy, sawSigner, ntx>>
    ELSE LET O == Outcome({}, {}, RVal(0), 0, 0) IN
         /\ Exec(r, O)
         /\ sawSigner' = [sawSigner EXCEPT ![r.tx] = Signer(r)]
         /\ UNCHANGED <<credit, signedBy, ntx>>

RunE(r) ==
    LET who == IF Wrong THEN r.fr ELSE Signer(r) IN
    /\ Exec(r, Outcome({}, {}, RVal(0), 0, 0))
    /\ credit' = [credit EXCEPT ![who] = @ + 1]
    /\ UNCHANGED <<signedBy, sawSigner, ntx>>

Run == \E r \in Runnable :
         CASE IsBuiltin(r) -> ExecBuiltin(r) /\ UNCHANGED <<credit, signedBy, sawSigner, ntx>>
           [] r.to = E     -> RunE(r)
           [] OTHER        -> RunP(r)

Init == /\ PlatformInit([a \in Accts |-> 0], TxIds)
        /\ credit = [a \in Accts |-> 0]
        /\ signedBy = [t \in TxIds |-> ""]
        /\ sawSigner = [t \in TxIds |-> ""]
        /\ ntx = 0

Next == Pay \/ Run
Spec == Init /\ [][Next]_vars

Credited == Idle => \A a \in Accts :
                      credit[a] = Cardinality({t \in 1..ntx : signedBy[t] = a})
CallbackSigner == \A t \in TxIds : sawSigner[t] \in {"", signedBy[t]}
=============================================================================
