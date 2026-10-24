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
(* PlaysCapped: the key gets at most Cap plays through.                    *)
(* CapUsable:   once the allowance refuses a play, the key has had Cap.    *)
(* Counted:     once idle, G has run every play the key got through.       *)
(* Sane:        NEAR is conserved.                                         *)
(***************************************************************************)
EXTENDS NearKeys

CONSTANTS U, G, Allow, Cost, Refund, Cap, MaxTx

VARIABLES plays, ntx
mine == <<plays, ntx>>
vars == <<platformVars, keyVars, mine>>

Accts == {U, G}
TxIds == 1..MaxTx
PFloor == [a \in Accts |-> 0]
NoGasTable == [x \in {} |-> 0]
SessionPerm == WithAllowance(Perm(G, {"play"}, FALSE), Allow)
Keys0 == [a \in {U} |-> ("k0" :> FullPerm) @@ ("s" :> SessionPerm)]

\* One play, signed with the session key: its cost and refund stated.
PlayTx(id, t) == WithTxCost(Rcpt(id, t, G, U, "play", 0, 0, U, 0), Cost, Refund)

\* The allowance refuses the next play.
Exhausted == KeyPresent(U, "s") /\ ~AllowanceOK(U, "s", PlayTx(0, 0))

Play == /\ ntx < MaxTx
        /\ SubmitSigned(PlayTx(nid, ntx + 1), U, "s")
        /\ ntx' = ntx + 1
        /\ UNCHANGED plays

RunG(r) ==
    LET O == Outcome({}, {}, RVal(0), 0, 0) IN
    /\ Exec(r, O)
    /\ plays' = IF Ok(r, O) THEN plays + 1 ELSE plays
    /\ UNCHANGED <<keyVars, ntx>>

Run == \E r \in Runnable : RunG(r)

Init == /\ PlatformInit([a \in Accts |-> 0], TxIds)
        /\ KeysInit(Keys0)
        /\ plays = 0 /\ ntx = 0

Next == Play \/ Run
Spec == Init /\ [][Next]_vars

PlaysCapped == ntx <= Cap
CapUsable   == Exhausted => ntx = Cap
Counted     == Idle => plays = ntx
Sane        == NearConserved(0) /\ NoOrphans
=============================================================================
