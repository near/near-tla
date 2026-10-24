------------------------------- MODULE Rotator -------------------------------
(***************************************************************************)
(* Local-receipt priority.  A transaction whose signer is its receiver     *)
(* produces a local receipt, which runs in the chunk that includes the     *)
(* transaction, before delayed and incoming receipts                       *)
(* (runtime/runtime/src/lib.rs:2316-2324, :2800-2821 @ b7b4737).  The      *)
(* transaction's access key is checked when it is included, so no other    *)
(* receipt can remove the key between that check and the local receipt.   *)
(*                                                                         *)
(* Account G runs a contract and has full-access keys k0 and k1.           *)
(*  - G.revoke(), signed with k0, removes k1 by emitting a DeleteKey(k1)   *)
(*    receipt to G.  That receipt is NOT local (only a transaction's first *)
(*    receipt is), so it runs in a later chunk.                            *)
(*  - G.act(), signed with k1, may be submitted while k1 still exists.     *)
(* NoStaleKeyAct: act never executes after its signing key was deleted.    *)
(* RevokeTakesEffect: once the revoke settles, k1 is gone and k0 is kept.  *)
(*                                                                         *)
(* The pair is about the platform assumption, not the contract:            *)
(*  - local_on  (LocalOn = TRUE, the receipt step conjoins                 *)
(*    LocalPriorityOK): act, once submitted, runs before the pending       *)
(*    DeleteKey, so the invariant holds.  ON assumes no congestion.        *)
(*  - local_off (LocalOn = FALSE, any causally enabled order): TLC runs    *)
(*    the DeleteKey between act's submission and its execution.  OFF is    *)
(*    the conservative setting, and this order is reachable on chain:      *)
(*    under congestion a local receipt that does not fit the compute       *)
(*    limit is delayed (lib.rs:2513-2520), and a DeleteKey already in the  *)
(*    delayed queue runs first.                                            *)
(* So the invariant holds only for an uncongested chunk.                   *)
(***************************************************************************)
EXTENDS NearKeys

CONSTANTS G, LocalOn

VARIABLES stale, revokes, acts
vars == <<platformVars, keyVars, stale, revokes, acts>>

Accts == {G}
TxIds == 1..2
Keys0 == [a \in {G} |-> ("k0" :> FullPerm) @@ ("k1" :> FullPerm)]
PFloor == [a \in Accts |-> 0]
NoGasTable == [x \in {} |-> 0]
Arg(k) == [k |-> k]

Revoke == /\ ~revokes
          /\ SubmitSigned(Rcpt(nid, 1, G, G, "revoke", Arg("k1"), 0, G, 0), G, "k0")
          /\ revokes' = TRUE
          /\ UNCHANGED <<stale, acts>>
Act == /\ ~acts
       /\ SubmitSigned(Rcpt(nid, 2, G, G, "act", Arg("k1"), 0, G, 0), G, "k1")
       /\ acts' = TRUE
       /\ UNCHANGED <<stale, revokes>>

RunG(r) ==
    IF r.m = "revoke"
    THEN /\ Exec(r, Outcome({DelKeyRcpt(nid, r.tx, G, Arg("k1"), 0)}, {}, RVal(0), 0, 1))
         /\ UNCHANGED <<keyVars, stale, revokes, acts>>
    ELSE LET O == Outcome({}, {}, RVal(0), 0, 0) IN
         /\ Exec(r, O)
         /\ stale' = (stale \/ ~KeyPresent(G, SignerKey(r)))
         /\ UNCHANGED <<keyVars, revokes, acts>>

Step(r) ==
    CASE IsBuiltin(r) -> ExecBuiltin(r) /\ UNCHANGED <<keyVars, stale, revokes, acts>>
      [] IsKeyRcpt(r) -> ExecKeyAct(r, r.a.k, FullPerm) /\ UNCHANGED <<stale, revokes, acts>>
      [] OTHER        -> RunG(r)

Run == \E r \in Runnable : (LocalOn => LocalPriorityOK(r)) /\ Step(r)

Init == /\ PlatformInit([a \in Accts |-> 0], TxIds)
        /\ KeysInit(Keys0)
        /\ stale = FALSE /\ revokes = FALSE /\ acts = FALSE

Next == Revoke \/ Act \/ Run
Spec == Init /\ [][Next]_vars

NoStaleKeyAct == ~stale
\* Once the revoke has settled, k1 is gone and the signing key k0 is kept
\* (NoStaleKeyAct alone passes when the revoke deletes nothing).
RevokeTakesEffect == (revokes /\ Idle) => ~KeyPresent(G, "k1") /\ KeyPresent(G, "k0")
\* Library sanity: native NEAR conserved, and no orphans.
Sane == NearConserved(0) /\ NoOrphans
=============================================================================
