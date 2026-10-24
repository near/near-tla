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
(*                                                                         *)
(* Oversized results (the refund_cap_oversized runs): X may answer        *)
(* "keepbig", a valid "0" padded to 43 bytes.  near-contract-standards     *)
(* 5.24.0 and later read the result with a 42-byte bound, so the resolver  *)
(* treats it as all unused and refunds min(amt, X's balance):              *)
(* OversizedRefunded holds.  Wrong: TokResolveMaxLen = -1, a resolver that *)
(* reads the result unbounded (the 5.23.0 code) and honours the "0", so it *)
(* refunds nothing.                                                        *)
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
\* big: X answered "keepbig"; full: the resolver then refunded min(amt, X's
\* balance).  Both stay constant unless XResps has "keepbig".
G0 == [amt |-> 0, refund |-> 0, done |-> FALSE, big |-> FALSE, full |-> TRUE]

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
                 THEN [gT EXCEPT ![r.tx].refund = O.ev.refund, ![r.tx].done = TRUE,
                                 ![r.tx].full = ~gT[r.tx].big \/
                                     O.ev.refund = TMin(gT[r.tx].amt, tk[FT].bal[X])]
                 ELSE gT
        /\ UNCHANGED ntx

RunX(r) == \E resp \in XResps :
             /\ Exec(r, RecvOutcome(r.a.amt, resp))
             /\ gT' = IF resp = "keepbig" THEN [gT EXCEPT ![r.tx].big = TRUE] ELSE gT
             /\ UNCHANGED <<tk, ntx>>

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
\* An oversized answer counts as all unused: the refund is min(amt, X's balance).
OversizedRefunded == \A t \in TxIds : gT[t].full
\* Supply = sum of balances; balances are never negative (the balance cap).
Sane == TokSupplyOK /\ TokTypeOK /\ NearConserved(0)
=============================================================================
