------------------------------ MODULE ResultRead ------------------------------
(***************************************************************************)
(* Result-read gas (docs/SEMANTICS.md, C4): a resolver that reads its      *)
(* receiver's result unbounded pays to copy every byte of it.             *)
(*                                                                         *)
(* U calls FT.ft_transfer_call(X, amt).  X is any contract U names; its    *)
(* ft_on_transfer asks for everything back, as the number amt, either      *)
(* plainly ("num") or padded with spaces to HugeLen bytes ("huge"; still   *)
(* valid JSON).  The token's resolver, owed (Nep141 TokOwedResolve),       *)
(* reads that result:                                                      *)
(*   bounded (TokResolveMaxLen 42, near-contract-standards 5.24.0 and      *)
(*     later): a result over 42 bytes is not read and counts as all        *)
(*     unused, so the refund is amt either way;                            *)
(*   unbounded (-1, 5.23.0 and older): the resolver copies the result into *)
(*     its memory at 2.82 Mgas per byte.  A 4 MiB result costs 11.8 Tgas,  *)
(*     more than the resolver's 5 Tgas: it runs out of gas, the refund     *)
(*     never happens and X keeps amt.  OwedOK reports it ("out of gas").   *)
(* The token side is CalibStd (measured near-contract-standards 5.29.1);   *)
(* X's burn is ILLUSTRATIVE.                                               *)
(***************************************************************************)
EXTENDS Tokens

CONSTANTS U, X, FT,
          MaxTx,      \* transactions
          Amts,       \* amounts U may send
          InitU,
          XResps,     \* X.ft_on_transfer: subset of {"num", "huge"}
          HugeLen,    \* bytes of the padded answer
          Dev         \* FT deviations

VARIABLES ntx
vars == <<platformVars, tk, ntx>>

Accts == {U, X, FT}
TxIds == 1..MaxTx
PFloor      == [a \in Accts |-> 0]
PTokHolders == [a \in {FT} |-> {U, X}]
PTokMin     == [a \in {FT} |-> 1]
PTokDev     == [a \in {FT} |-> Dev]
PTokReserve == [a \in {FT} |-> 0]
Unbounded   == [a \in {FT} |-> -1]

GC(st, wt, fee) == [st |-> st, wt |-> wt, fee |-> fee]
Std == INSTANCE CalibStd
RGasCall == ("ft_on_transfer" :> GC(<<>>, <<>>, 900)) @@ Std!StdFtGasCall(FT)
\* X pays to return its answer: the data receipt's per-byte fee is its own.
RGasBurn == ("x.ft_on_transfer" :> [base |-> 200, per |-> 0]) @@ Std!StdFtGasBurn(FT)

\* U sends amt to X with ft_transfer_call, 300 Tgas prepaid.
Send == /\ ntx < MaxTx
        /\ \E amt \in Amts :
             Submit(WithGas(Rcpt(nid, ntx + 1, FT, U, "ft_transfer_call", FtArgs(X, amt, ""), TokYocto, U, 0),
                            300000))
        /\ ntx' = ntx + 1
        /\ UNCHANGED tk

RunTok(r) ==
    \E ch \in TokChoices(r) :
        /\ TokStep(r, TokHandle(r, ch))
        /\ UNCHANGED ntx

\* X asks for all of amt back.
RunX(r) == \E resp \in XResps :
             /\ Exec(r, OKey(Outcome({}, {}, IF resp = "huge" THEN RValLen(r.a.amt, HugeLen) ELSE RVal(r.a.amt), 0, 0),
                             "x.ft_on_transfer"))
             /\ UNCHANGED <<tk, ntx>>

Run == \E r \in Runnable :
         IF IsBuiltin(r) THEN ExecBuiltin(r) /\ UNCHANGED <<tk, ntx>>
         ELSE IF IsTokRcpt(r) THEN RunTok(r)
         ELSE RunX(r)

Init == /\ PlatformInit([a \in Accts |-> 0], TxIds)
        /\ tk = [a \in {FT} |-> Ledger([h \in {U, X} |-> IF h = U THEN InitU ELSE 0], {U, X})]
        /\ ntx = 0

Next == Send \/ Run
Spec == Init /\ [][Next]_vars

\* X asked for everything back, so once idle U holds all its tokens again.
Refunded == Idle => tk[FT].bal[U] = InitU
Sane == TokSupplyOK /\ TokTypeOK /\ NearConserved(0) /\ NoOrphans
=============================================================================
