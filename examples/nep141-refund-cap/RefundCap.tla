------------------------------ MODULE RefundCap ------------------------------
(***************************************************************************)
(* NEP-141 ft_resolve_transfer caps the refund at the transferred amount   *)
(* and at the receiver's current balance.                                   *)
(*                                                                         *)
(* U calls FT.ft_transfer_call(X, amt).  X is an arbitrary receiver: its   *)
(* ft_on_transfer returns some number of "unused" tokens (possibly more    *)
(* than amt), malformed bytes, or panics.  Independently, X may spend      *)
(* tokens it holds (an ft_transfer to Y) before the resolver runs.  The    *)
(* resolver then refunds min(unused, amt, X's balance) to U.               *)
(*                                                                         *)
(* Correct: the standard token (Dev = {}).  RefundCapped holds: no         *)
(* resolution refunds more than its amount, and no balance goes negative.  *)
(* Wrong:   Dev = {"resolveNoCap"}, a token whose resolver does not cap    *)
(* the receiver's answer at the amount.  X holds 1 token of its own and    *)
(* answers amt + 1; the resolver pulls amt + 1 back from X, so U gains one *)
(* of X's tokens and RefundCapped fails.                                   *)
(***************************************************************************)
EXTENDS Tokens

CONSTANTS U, X, Y, FT,
          MaxTx,      \* transactions: U's transfers and X's spends together
          Amts,       \* amounts U may send
          InitU, InitX,
          XResps,     \* X.ft_on_transfer behaviours, subset of RecvResps
          Dev         \* FT deviations

VARIABLES ntx, gT
vars == <<platformVars, tk, ntx, gT>>

Accts == {U, X, Y, FT}
TxIds == 1..MaxTx
PFloor      == [a \in Accts |-> 0]
PTokHolders == [a \in {FT} |-> {U, X, Y}]
PTokMin     == [a \in {FT} |-> 1]
PTokDev     == [a \in {FT} |-> Dev]
PTokReserve == [a \in {FT} |-> 0]
NoGasTable  == [x \in {} |-> 0]
G0 == [amt |-> 0, refund |-> 0, done |-> FALSE]

\* U sends amt to X with ft_transfer_call.
Send == /\ ntx < MaxTx
        /\ \E amt \in Amts :
             /\ Submit(Rcpt(nid, ntx + 1, FT, U, "ft_transfer_call", FtArgs(X, amt, ""), TokYocto, U, 0))
             /\ gT' = [gT EXCEPT ![ntx + 1].amt = amt]
        /\ ntx' = ntx + 1
        /\ UNCHANGED tk

\* X spends one token (moves it to Y), at any time.
Spend == /\ ntx < MaxTx
         /\ Submit(Rcpt(nid, ntx + 1, FT, X, "ft_transfer", FtArgs(Y, 1, ""), TokYocto, X, 0))
         /\ ntx' = ntx + 1
         /\ UNCHANGED <<tk, gT>>

RunTok(r) ==
    \E ch \in TokChoices(r) :
        LET O == TokHandle(r, ch) IN
        /\ TokStep(r, O)
        /\ gT' = IF Ok(r, O) /\ r.m = "ft_resolve_transfer"
                 THEN [gT EXCEPT ![r.tx].refund = O.ev.refund, ![r.tx].done = TRUE]
                 ELSE gT
        /\ UNCHANGED ntx

RunX(r) == \E resp \in XResps :
             /\ Exec(r, RecvOutcome(r.a.amt, resp))
             /\ UNCHANGED <<tk, ntx, gT>>

Run == \E r \in Runnable :
         IF IsBuiltin(r) THEN ExecBuiltin(r) /\ UNCHANGED <<tk, ntx, gT>>
         ELSE IF IsTokRcpt(r) THEN RunTok(r)
         ELSE RunX(r)

Init == /\ PlatformInit([a \in Accts |-> 0], TxIds)
        /\ tk = [a \in {FT} |-> Ledger([h \in {U, X, Y} |-> CASE h = U -> InitU [] h = X -> InitX [] OTHER -> 0],
                                       {U, X, Y})]
        /\ ntx = 0
        /\ gT = [t \in TxIds |-> G0]

Next == Send \/ Spend \/ Run
Spec == Init /\ [][Next]_vars

\* No resolution refunds more than its transfer moved.
RefundCapped == \A t \in TxIds : gT[t].refund <= gT[t].amt
\* Supply = sum of balances; balances are never negative (the balance cap).
Sane == TokSupplyOK /\ TokTypeOK /\ NearConserved(0)
=============================================================================
