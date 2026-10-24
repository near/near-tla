----------------------------- MODULE ResolverLog -----------------------------
(***************************************************************************)
(* An owed resolver that fails on its own log.                             *)
(*                                                                         *)
(* U sends Amt to a receiver X with ft_transfer_call on a standard         *)
(* NEP-141 token FT (near-contract-standards 5.29.1); X keeps it or asks   *)
(* for all of it back.  The library emits the token's events itself        *)
(* (TokEvents): the transfer logs an ft_transfer event, the resolver's     *)
(* refund another, with the memo "refund", 16 bytes longer than the        *)
(* transfer's when U gave no memo (TokenCommon FtTransferLog): 134 and 150 *)
(* bytes here, for the ids "u" and "x".                                    *)
(*                                                                         *)
(* The protocol's 16384 bytes leave both far below the limit (an           *)
(* ft_transfer event is at most 298 bytes plus its memo: two 64-byte ids,  *)
(* 39 digits).  The runs                                                   *)
(* lower MaxLogBytes to show the mechanism: with room for the transfer's   *)
(* event but not the refund's, ft_transfer_call commits and its owed       *)
(* resolver fails with TotalLogLengthExceeded, so X keeps what it asked    *)
(* back.  OwedOK reports it, the cause in ofail's why.                     *)
(*                                                                         *)
(* Properties: OwedOK (no owed resolver fails), Honored (once settled, U   *)
(* holds what it started with less what X kept).                           *)
(***************************************************************************)
EXTENDS Tokens

CONSTANTS U, X, FT, Amt, XResps
VARIABLES ntx, kept
mine == <<tk, ntx, kept>>
vars == <<platformVars, mine>>

Accts == {U, X, FT}
PFloor      == [a \in Accts |-> 0]
NoGasTable  == [x \in {} |-> 0]
PTokHolders == [a \in {FT} |-> {U, X}]
PTokMin     == [a \in {FT} |-> 1]
PTokDev     == [a \in {FT} |-> {}]
PTokReserve == [a \in {FT} |-> 0]
InitU == 2

Send == /\ ntx = 0
        /\ Submit(Rcpt(nid, 1, FT, U, "ft_transfer_call", FtArgs(X, Amt, ""), TokYocto, U, 0))
        /\ ntx' = 1
        /\ UNCHANGED <<tk, kept>>

\* X keeps the tokens ("keep", answers 0) or asks for all of them back.
RunX(r) == \E resp \in XResps :
    /\ Exec(r, RecvOutcome(r.a.amt, resp))
    /\ kept' = IF resp = "keep" THEN r.a.amt ELSE 0
    /\ UNCHANGED <<tk, ntx>>

Run == \E r \in Runnable :
         CASE IsBuiltin(r)  -> ExecBuiltin(r) /\ UNCHANGED mine
           [] IsTokRcpt(r)  -> TokStep(r, TokHandle(r, EMPTY)) /\ UNCHANGED <<ntx, kept>>
           [] OTHER         -> RunX(r)

Init == /\ PlatformInit([a \in Accts |-> 0], {1})
        /\ tk = [t \in {FT} |-> Ledger([h \in {U, X} |-> IF h = U THEN InitU ELSE 0], {U, X})]
        /\ ntx = 0 /\ kept = 0
Next == Send \/ Run
Spec == Init /\ [][Next]_vars

\* Once the transfer settles, U holds InitU less what X kept.
Honored == (ntx = 1 /\ TxSettled(1)) => tk[FT].bal[U] = InitU - kept
Sane == NearConserved(0) /\ NoOrphans
=============================================================================
