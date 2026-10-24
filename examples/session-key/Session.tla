------------------------------ MODULE Session ------------------------------
(***************************************************************************)
(* A session key with an allowance (docs/SEMANTICS.md, K2, N-allowance).   *)
(* The user U has added a function-call key "s" for game G's play, with    *)
(* allowance Allow.  The app signs G.play with it (Play) for as long as    *)
(* the allowance lets it.  Conversion charges each play its cost, Cost;    *)
(* the gas refund then adds Refund of it back (WithTxCost; the library     *)
(* credits it at conversion), so a play nets Cost - Refund, but the        *)
(* allowance must still hold the whole Cost before each one.  G counts the *)
(* plays it runs.                                                          *)
(*                                                                         *)
(* The app wants exactly Cap plays per session and sizes Allow for that.   *)
(* Cost + (Cap - 1) * (Cost - Refund) is right: the last play needs the    *)
(* whole Cost, the earlier ones only their net.  Cap * Cost, the size that *)
(* forgets the refunds, lets more plays through.                           *)
(*                                                                         *)
(* Stated = FALSE: the plays state no cost, which the library refuses (an  *)
(* Assert: nearcore's cost is never 0).  NewKey # "": U may also delete    *)
(* and add the key NewKey with the same allowance (Rekey).  Re-adding "s"  *)
(* after a play is an Assert: nearcore adds the old plays' late refunds to *)
(* the new key, which the model does not represent; a fresh id is fine.    *)
(* BatchRekey = TRUE: U instead sends one ACCOUNT receipt that adds        *)
(* NewKey and deletes it again ([DeleteKey, AddKey, DeleteKey], the first  *)
(* only if present): no re-added key is left for a late refund, so it is   *)
(* fine even for "s".                                                      *)
(*                                                                         *)
(* PlaysCapped: the key gets at most Cap plays through.                    *)
(* CapUsable:   once the allowance refuses a play, the key has had Cap.    *)
(* Counted:     once idle, G has run every play the key got through.       *)
(* Sane:        NEAR is conserved.                                         *)
(***************************************************************************)
EXTENDS NearKeys

CONSTANTS U, G, Allow, Cost, Refund, Cap, MaxTx, Stated, NewKey, BatchRekey

VARIABLES plays, ntx, nk
mine == <<plays, ntx, nk>>
vars == <<platformVars, keyVars, mine>>

Accts == {U, G}
TxIds == 1..MaxTx
PFloor == [a \in Accts |-> 0]
NoGasTable == [x \in {} |-> 0]
SessionPerm == WithAllowance(Perm(G, {"play"}, FALSE), Allow)
Keys0 == [a \in {U} |-> ("k0" :> FullPerm) @@ ("s" :> SessionPerm)]

\* One play, signed with the session key: its cost and refund stated.
PlayTx(id, t) == IF Stated THEN WithTxCost(Rcpt(id, t, G, U, "play", 0, 0, U, 0), Cost, Refund)
                 ELSE Rcpt(id, t, G, U, "play", 0, 0, U, 0)

\* The allowance refuses the next play.
Exhausted == KeyPresent(U, "s") /\ ~AllowanceOK(U, "s", PlayTx(0, 0))

Play == /\ ntx + nk < MaxTx
        /\ SubmitSigned(PlayTx(nid, ntx + nk + 1), U, "s")
        /\ ntx' = ntx + 1
        /\ UNCHANGED <<plays, nk>>

\* U deletes NewKey if present, else adds it, signed with its full-access key;
\* or, with BatchRekey, adds it and deletes it again in one ACCOUNT receipt.
BatchActs == (IF KeyPresent(U, NewKey) THEN <<DelKeyAct(NewKey)>> ELSE <<>>)
             \o <<AddKeyAct(NewKey, SessionPerm), DelKeyAct(NewKey)>>
Rekey == /\ NewKey # "" /\ ntx + nk < MaxTx
         /\ SubmitSigned(IF BatchRekey THEN WithAcctKeys(AcctRcpt(nid, ntx + nk + 1, U, U, 0, 0, 0, FALSE, ""), BatchActs)
                         ELSE IF KeyPresent(U, NewKey) THEN DelKeyRcpt(nid, ntx + nk + 1, U, 0, 0)
                         ELSE AddKeyRcpt(nid, ntx + nk + 1, U, 0, SessionPerm, 0), U, "k0")
         /\ nk' = nk + 1
         /\ UNCHANGED <<plays, ntx>>

RunG(r) ==
    LET O == Outcome({}, {}, RVal(0), 0, 0) IN
    /\ Exec(r, O)
    /\ plays' = IF Ok(r, O) THEN plays + 1 ELSE plays
    /\ UNCHANGED <<keyVars, ntx, nk>>

Run == \E r \in Runnable : IF IsKeyRcpt(r) THEN ExecKeyAct(r, NewKey, SessionPerm) /\ UNCHANGED mine
                            ELSE IF IsAcctRcpt(r) THEN ExecAcctK(r) /\ UNCHANGED mine
                            ELSE RunG(r)

Init == /\ PlatformInit([a \in Accts |-> 0], TxIds)
        /\ KeysInit(Keys0)
        /\ plays = 0 /\ ntx = 0 /\ nk = 0

Next == Play \/ Rekey \/ Run
Spec == Init /\ [][Next]_vars

PlaysCapped == ntx <= Cap
CapUsable   == Exhausted => ntx = Cap
Counted     == Idle => plays = ntx
Sane        == NearConserved(0) /\ NoOrphans
=============================================================================
