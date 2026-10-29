------------------------------- MODULE MetaTx -------------------------------
(***************************************************************************)
(* Delegate actions (NEP-366, meta transactions).  Users sign delegates    *)
(* for L.claim(bad) (Sign, one per user and nonce); the relayer RL submits *)
(* any signed delegate, any number of times (Relay, so it replays them);   *)
(* users may also call L.claim directly (Direct).  L.claim panics if bad.  *)
(*                                                                         *)
(* In a relayed claim the signer is RL and the predecessor is the user     *)
(* (runtime/runtime/src/actions.rs:500-512).                               *)
(*                                                                         *)
(* Correct L: credits the predecessor r.fr.                                *)
(* Wrong L (Wrong = TRUE): credits Signer(r) (env::signer_account_id), the *)
(* rule of examples/signer-propagation: right for direct calls, wrong for  *)
(* relayed ones, where it credits the relayer.                             *)
(* Dep > 0: each claim attaches a deposit.  RL pays it for a relayed claim *)
(* and a failing inner call refunds it to the user, its predecessor        *)
(* (actions.rs:514-519; core/primitives/src/receipt.rs:428-430).           *)
(* NoNonceCheck = TRUE: a mutant runtime that skips the delegate nonce     *)
(* check (the dispatcher hands ExecDelegate a delegate whose nonce is      *)
(* always fresh); every other check is unchanged.  The relayer's replays   *)
(* then credit a claim twice: the nonce check is what stops them.          *)
(*                                                                         *)
(* Credited:     no account is credited more claims than it authorized     *)
(*               (signed a delegate for, or sent directly) that are good:  *)
(*               a bad claim must never be credited.                       *)
(* NoUserProfit: once idle, no user holds more NEAR than it started with.  *)
(* Sane:         NEAR is conserved.                                        *)
(***************************************************************************)
EXTENDS NearKeys

CONSTANTS Users, RL, L, MaxTx, MaxSign, Wrong, Dep, Mbh

\* Mutant switch (see above); overridable in a run's constants.
NoNonceCheck == FALSE

VARIABLES credit, auth, signed, ntx, nn
mine == <<credit, auth, signed, ntx, nn>>
vars == <<platformVars, keyVars, mine>>

Accts == Users \cup {RL, L}
TxIds == 1..MaxTx
PFloor == [a \in Accts |-> 0]
NoGasTable == [x \in {} |-> 0]
Keys0 == [a \in Users \cup {RL} |-> IF a = RL THEN ("r0" :> FullPerm) ELSE ("k0" :> FullPerm)]
Near0 == [a \in Accts |-> IF a = L THEN 0 ELSE 10]

Claim(u, bad) == Rcpt(0, 0, L, u, "claim", [bad |-> bad], Dep, u, 0)

\* The user's own step: its signature over the next nonce.
Sign == \E u \in Users, bad \in BOOLEAN :
          /\ nn[u] < MaxSign
          /\ signed' = signed \cup {SignedDelegate(u, "k0", nn[u] + 1, Mbh, Claim(u, bad))}
          /\ nn' = [nn EXCEPT ![u] = @ + 1]
          /\ auth' = [auth EXCEPT ![u] = @ + (IF bad THEN 0 ELSE 1)]
          /\ UNCHANGED <<platformVars, keyVars, credit, ntx>>

Relay == /\ ntx < MaxTx
         /\ \E sd \in signed : SubmitDelegate(nid, ntx + 1, RL, "r0", sd)
         /\ ntx' = ntx + 1
         /\ UNCHANGED <<credit, auth, signed, nn>>

Direct == /\ ntx < MaxTx
          /\ \E u \in Users, bad \in BOOLEAN :
               /\ SubmitSigned([Claim(u, bad) EXCEPT !.id = nid, !.tx = ntx + 1], u, "k0")
               /\ auth' = [auth EXCEPT ![u] = @ + (IF bad THEN 0 ELSE 1)]
          /\ ntx' = ntx + 1
          /\ UNCHANGED <<credit, signed, nn>>

RunL(r) ==
    LET O   == IF r.a.bad THEN OErr(Outcome({}, {}, RVal(0), 0, 0), "bad claim")
               ELSE Outcome({}, {}, RVal(0), 0, 0)
        who == IF Wrong THEN Signer(r) ELSE r.fr IN
    /\ Exec(r, O)
    /\ credit' = IF Ok(r, O) THEN [credit EXCEPT ![who] = @ + 1] ELSE credit
    /\ UNCHANGED <<keyVars, auth, signed, ntx, nn>>

\* The mutant: the delegate's nonce replaced by one above the key's.
Fresh(r) == IF r.to \in KeyAccts /\ KeyPresent(r.to, r.a.k)
            THEN [r EXCEPT !.a.n = KeyNonce(r.to, r.a.k) + 1] ELSE r

Run == \E r \in Runnable :
         CASE IsBuiltin(r) -> ExecBuiltin(r) /\ UNCHANGED <<keyVars, mine>>
           [] IsDeleg(r)   -> ExecDelegate(IF NoNonceCheck THEN Fresh(r) ELSE r) /\ UNCHANGED mine
           [] OTHER        -> RunL(r)

Init == /\ PlatformInit(Near0, TxIds)
        /\ KeysInit(Keys0)
        /\ credit = [a \in Accts |-> 0] /\ auth = [a \in Accts |-> 0]
        /\ signed = {} /\ ntx = 0 /\ nn = [u \in Users |-> 0]

Next == Sign \/ Relay \/ Direct \/ Run \/ (BlockTick /\ UNCHANGED <<keyVars, mine>>)
Spec == Init /\ [][Next]_vars

Credited     == \A a \in Accts : credit[a] <= auth[a]
NoUserProfit == Idle => \A u \in Users : near[u] <= 10
\* Library sanity: NEAR conserved, no orphans (nothing waits on a result here;
\* the conjunct keeps that true).
Sane         == NearConserved(10 * Cardinality(Users) + 10) /\ NoOrphans
=============================================================================
